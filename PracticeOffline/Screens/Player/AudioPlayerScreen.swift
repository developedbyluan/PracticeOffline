import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

/// Port of src/components/player/AudioPlayerScreen.tsx: plays a downloaded file.
/// Keeps playing in the background, with lock-screen controls, until the player closes.
struct AudioPlayerScreen: View {
    let mediaId: Int
    /// The downloaded file.
    let localURL: URL
    let title: String
    let author: String
    /// The saved thumbnail, or the online one; shown on the lock screen too.
    let artworkFile: URL?
    let artworkURL: String?
    let transcript: TranscriptResult?

    @State private var engine: PlaybackEngine?

    var body: some View {
        PlayerLayout(
            title: title,
            media: { ThumbnailImage(url: artworkURL, localFile: artworkFile) },
            transcript: transcript,
            currentTime: engine?.currentTime ?? 0,
            duration: engine?.duration ?? 0,
            isLoaded: engine?.isLoaded ?? false,
            playing: engine?.playing ?? false,
            onPlay: { engine?.play() },
            onPause: { engine?.pause() },
            onSeek: { seconds in await engine?.seek(to: seconds) }
        )
        .task(id: localURL) {
            let engine = PlaybackEngine(
                url: localURL, mediaId: mediaId,
                nowPlaying: .init(title: title, author: author, artworkFile: artworkFile, artworkURL: artworkURL)
            )
            self.engine = engine
            await engine.load()
        }
        .onDisappear {
            // Saves the position, stops the sound and removes the lock-screen controls.
            engine?.stop()
        }
    }
}

/// Wraps AVPlayer and publishes what the screen shows: time, length, loaded, playing.
/// Also does what has to keep working while the app is in the background or the screen
/// is locked: saving the position (port of usePlaybackPosition) and the lock-screen controls.
@MainActor @Observable
final class PlaybackEngine {
    struct NowPlaying {
        let title: String
        let author: String
        let artworkFile: URL?
        let artworkURL: String?
    }

    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isLoaded = false
    private(set) var playing = false

    /// Save at least this often while playing.
    private static let saveEverySeconds: Double = 5
    /// The lock screen's skip buttons, the same as the player's.
    private static let skipSeconds: Double = 5

    @ObservationIgnored private let player: AVPlayer
    @ObservationIgnored private let mediaId: Int
    @ObservationIgnored private let nowPlaying: NowPlaying
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var lastSaved: Double = 0
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var commandTargets: [(MPRemoteCommand, Any)] = []
    @ObservationIgnored private var appObservers: [any NSObjectProtocol] = []
    @ObservationIgnored private var artwork: MPMediaItemArtwork?

    init(url: URL, mediaId: Int, nowPlaying: NowPlaying) {
        player = AVPlayer(url: url)
        self.mediaId = mediaId
        self.nowPlaying = nowPlaying
    }

    /// Reads the file's length, jumps to where the lesson was left off (paused), then
    /// starts reporting the time 10 times a second (the Android app uses 4; more often
    /// keeps the repeat range's loop tight).
    func load() async {
        // Play even when the iPhone's silent switch is on, and keep playing in the
        // background or with the screen locked. Other apps' audio pauses.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)

        guard let asset = player.currentItem?.asset,
              let length = try? await asset.load(.duration),
              !Task.isCancelled, !stopped // closed while loading
        else { return }
        duration = length.seconds.isFinite ? length.seconds : 0

        // Open where the lesson was left off. Done before the time is reported, so the
        // 0 the player starts at never overwrites the saved position.
        let resume = PlaybackPositions.resumePosition(mediaId: mediaId)
        lastSaved = resume
        if resume > 0, resume < duration {
            await seek(to: resume)
        }
        guard !stopped else { return }

        // Also called when playback starts or stops, and after a seek.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.update(time) }
        }
        watchAppState()
        isLoaded = true
        setUpLockScreen()
        await loadArtwork()
    }

    private func update(_ time: CMTime) {
        currentTime = time.seconds.isFinite ? time.seconds : 0
        let wasPlaying = playing
        playing = player.timeControlStatus != .paused
        if wasPlaying != playing {
            updateNowPlaying()
            // On pause, including reaching the end, a phone call, or the lock screen.
            if !playing { savePosition() }
        }
        // Every few seconds of playback.
        if playing, abs(currentTime - lastSaved) >= Self.saveEverySeconds { savePosition() }
    }

    func play() {
        player.play()
        playing = true
        updateNowPlaying()
    }

    func pause() {
        player.pause()
        playing = false
        updateNowPlaying()
        savePosition()
    }

    func seek(to seconds: Double) async {
        let target = CMTime(seconds: max(0, min(seconds, duration)), preferredTimescale: 600)
        await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = target.seconds
        updateNowPlaying()
    }

    /// Saves the position, stops playback and clears the lock screen when the player closes.
    func stop() {
        guard !stopped else { return }
        savePosition()
        stopped = true
        player.pause()
        playing = false
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        appObservers.forEach(NotificationCenter.default.removeObserver)
        appObservers = []
        for (command, target) in commandTargets { command.removeTarget(target) }
        commandTargets = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Position

    private func savePosition() {
        guard isLoaded, !stopped, duration > 0 else { return }
        PlaybackPositions.save(mediaId: mediaId, seconds: currentTime, duration: duration)
        lastSaved = currentTime
    }

    /// When the app leaves the screen. Playback goes on; this is in case the app is then closed.
    private func watchAppState() {
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.savePosition() }
            }
            appObservers.append(observer)
        }
    }

    // MARK: - Lock screen

    /// Play, pause, 5 s back and forward, and dragging the progress bar, on the lock screen
    /// and in Control Centre.
    private func setUpLockScreen() {
        let center = MPRemoteCommandCenter.shared()
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipSeconds)]
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipSeconds)]

        addTarget(center.playCommand) { $0.play() }
        addTarget(center.pauseCommand) { $0.pause() }
        addTarget(center.togglePlayPauseCommand) { $0.playing ? $0.pause() : $0.play() }
        addTarget(center.skipBackwardCommand) { engine in
            Task { await engine.seek(to: engine.currentTime - Self.skipSeconds) }
        }
        addTarget(center.skipForwardCommand) { engine in
            Task { await engine.seek(to: engine.currentTime + Self.skipSeconds) }
        }
        addTarget(center.changePlaybackPositionCommand) { engine, event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return }
            let position = event.positionTime
            Task { await engine.seek(to: position) }
        }
        updateNowPlaying()
    }

    private func addTarget(_ command: MPRemoteCommand, _ action: @escaping (PlaybackEngine) -> Void) {
        addTarget(command) { engine, _ in action(engine) }
    }

    private func addTarget(_ command: MPRemoteCommand,
                           _ action: @escaping @MainActor (PlaybackEngine, MPRemoteCommandEvent) -> Void) {
        command.isEnabled = true
        let target = command.addTarget(handler: Self.commandHandler(engine: self, action: action))
        commandTargets.append((command, target))
    }

    /// iOS may call lock-screen handlers off the main thread, so the handler itself must
    /// not belong to the main actor: it hops there to do the work.
    private nonisolated static func commandHandler(
        engine: PlaybackEngine,
        action: @escaping @MainActor (PlaybackEngine, MPRemoteCommandEvent) -> Void
    ) -> @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { [weak engine] event in
            nonisolated(unsafe) let event = event
            Task { @MainActor in
                guard let engine, !engine.stopped else { return }
                action(engine, event)
            }
            return .success
        }
    }

    /// Title, author, picture, length and where playback is. iOS moves the time along by
    /// itself from the rate, so this only needs updating on play, pause and seeks.
    private func updateNowPlaying() {
        guard isLoaded, !stopped else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: nowPlaying.title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if !nowPlaying.author.isEmpty { info[MPMediaItemPropertyArtist] = nowPlaying.author }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// The saved thumbnail, or the online one (kept on the phone after the first load).
    private func loadArtwork() async {
        var data: Data?
        if let file = nowPlaying.artworkFile { data = await ThumbnailStore.localData(at: file) }
        if data == nil, let url = nowPlaying.artworkURL, !url.isEmpty { data = await ThumbnailStore.data(for: url) }
        guard let data, let image = UIImage(data: data), !stopped else { return }
        artwork = Self.makeArtwork(image)
        updateNowPlaying()
    }

    /// iOS asks for the picture from a background thread, so this must not belong to the
    /// main actor (that's what crashed the first version).
    private nonisolated static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
    }
}
