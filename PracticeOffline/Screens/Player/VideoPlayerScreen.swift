import AVFoundation
import SwiftUI
import UIKit

/// Port of src/components/player/VideoPlayerScreen.tsx: plays a downloaded video in the
/// picture's place. Everything else — transcript, seek bar, ±5 s, repeat range, text size,
/// resume and the lock screen — is the same as audio, because it uses the same
/// PlayerLayout and PlaybackEngine. The sound keeps playing in the background until the
/// player closes. The fullscreen button (VideoFullscreen.tsx) comes in a later milestone.
struct VideoPlayerScreen: View {
    let mediaId: Int
    /// The downloaded file.
    let localURL: URL
    let title: String
    let author: String
    /// Shown on the lock screen.
    let artworkFile: URL?
    let artworkURL: String?
    let transcript: TranscriptResult?

    @State private var engine: PlaybackEngine?

    var body: some View {
        PlayerLayout(
            title: title,
            media: { videoArea },
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
                nowPlaying: .init(title: title, author: author, artworkFile: artworkFile,
                                  artworkURL: artworkURL, isVideo: true)
            )
            self.engine = engine
            await engine.load()
        }
        .onDisappear {
            // Saves the position, stops the video and removes the lock-screen controls.
            engine?.stop()
        }
    }

    /// Full width, 16:9, black, no built-in controls.
    private var videoArea: some View {
        ZStack {
            Color.black
            if let engine {
                VideoSurface(player: engine.avPlayer)
                    .accessibilityLabel("Video")
            }
            if engine?.failed == true {
                Text("Couldn't play this video.")
                    .font(.subheadline)
                    .foregroundStyle(.white)
            }
        }
    }
}

/// Shows an AVPlayer's picture.
private struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.attach(player)
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        view.attach(player)
    }

    static func dismantleUIView(_ view: PlayerView, coordinator: ()) {
        view.detach()
    }
}

/// A view whose layer is the video picture. iOS pauses a video in the background while
/// its picture is on screen, so the picture is unhooked when the app leaves the screen
/// (the sound goes on) and hooked back up when it returns.
private final class PlayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    private var player: AVPlayer?
    private var observing = false

    func attach(_ player: AVPlayer) {
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
        self.player = player
        if UIApplication.shared.applicationState != .background {
            playerLayer.player = player
        }
        guard !observing else { return }
        observing = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(didEnterBackground),
                           name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(willEnterForeground),
                           name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    func detach() {
        NotificationCenter.default.removeObserver(self)
        observing = false
        playerLayer.player = nil
        player = nil
    }

    @objc private func didEnterBackground() {
        playerLayer.player = nil
    }

    @objc private func willEnterForeground() {
        playerLayer.player = player
    }
}
