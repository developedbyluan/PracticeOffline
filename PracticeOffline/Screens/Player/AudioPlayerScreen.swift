import AVFoundation
import SwiftUI

/// Port of src/components/player/AudioPlayerScreen.tsx: plays a downloaded file.
/// Background playback and lock-screen controls come in a later milestone.
struct AudioPlayerScreen: View {
    /// The downloaded file.
    let localURL: URL
    let title: String
    let artwork: ThumbnailImage

    @State private var engine: PlaybackEngine?

    var body: some View {
        PlayerLayout(
            title: title,
            media: { artwork },
            currentTime: engine?.currentTime ?? 0,
            duration: engine?.duration ?? 0,
            isLoaded: engine?.isLoaded ?? false,
            playing: engine?.playing ?? false,
            onPlay: { engine?.play() },
            onPause: { engine?.pause() },
            onSeek: { seconds in await engine?.seek(to: seconds) }
        )
        .task(id: localURL) {
            let engine = PlaybackEngine(url: localURL)
            self.engine = engine
            await engine.load()
        }
        .onDisappear {
            engine?.stop()
        }
    }
}

/// Wraps AVPlayer and publishes what the screen shows: time, length, loaded, playing.
@MainActor @Observable
final class PlaybackEngine {
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isLoaded = false
    private(set) var playing = false

    @ObservationIgnored private let player: AVPlayer
    @ObservationIgnored private var timeObserver: Any?

    init(url: URL) {
        player = AVPlayer(url: url)
    }

    /// Reads the file's length, then starts reporting the time 4 times a second.
    func load() async {
        // Play even when the iPhone's silent switch is on.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)

        guard let asset = player.currentItem?.asset,
              let length = try? await asset.load(.duration),
              !Task.isCancelled // closed while loading
        else { return }
        duration = length.seconds.isFinite ? length.seconds : 0

        // Also called when playback starts or stops, and after a seek.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.update(time) }
        }
        isLoaded = true
    }

    private func update(_ time: CMTime) {
        currentTime = time.seconds.isFinite ? time.seconds : 0
        playing = player.timeControlStatus != .paused
    }

    func play() {
        player.play()
        playing = true
    }

    func pause() {
        player.pause()
        playing = false
    }

    func seek(to seconds: Double) async {
        let target = CMTime(seconds: max(0, min(seconds, duration)), preferredTimescale: 600)
        await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = target.seconds
    }

    /// Stops playback when the player closes.
    func stop() {
        player.pause()
        playing = false
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
