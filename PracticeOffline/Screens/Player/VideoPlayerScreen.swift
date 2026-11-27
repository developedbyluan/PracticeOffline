import AVFoundation
import SwiftUI
import UIKit

/// Port of src/components/player/VideoPlayerScreen.tsx: plays a downloaded video in the
/// picture's place. Everything else — transcript, seek bar, ±5 s, repeat range, text size,
/// resume and the lock screen — is the same as audio, because it uses the same
/// PlayerLayout and PlaybackEngine. The sound keeps playing in the background until the
/// player closes. The fullscreen button opens VideoFullscreen, which shows subtitles.
struct VideoPlayerScreen: View {
    let mediaId: Int
    /// The signed-in Clerk user, stored on the listening session.
    let userId: String?
    /// The downloaded file.
    let localURL: URL
    let title: String
    let author: String
    /// Shown on the lock screen.
    let artworkFile: URL?
    let artworkURL: String?
    let transcript: TranscriptResult?

    @State private var engine: PlaybackEngine?
    @State private var fullscreen = false

    private var lines: [TranscriptLine]? {
        if case .lines(let lines) = transcript { lines } else { nil }
    }

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
                url: localURL, mediaId: mediaId, userId: userId,
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
        // Over the player, which keeps running underneath.
        .fullScreenCover(isPresented: $fullscreen) {
            if let engine {
                VideoFullscreen(engine: engine, lines: lines) { setFullscreen(false) }
            }
        }
    }

    /// Without the slide-up animation, which looks odd while the screen rotates.
    private func setFullscreen(_ on: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { fullscreen = on }
    }

    /// Full width, 16:9, black, no built-in controls.
    private var videoArea: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.black
            // The picture shows in one place at a time: here, or in fullscreen.
            if let engine, !fullscreen {
                VideoSurface(player: engine.avPlayer)
                    .accessibilityLabel("Video")
            }
            if engine?.failed == true {
                Text("Couldn't play this video.")
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Button {
                    setFullscreen(true)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.black.opacity(0.5), in: .circle)
                }
                .buttonStyle(.plain)
                .padding(12)
                .accessibilityLabel("Full screen")
                .disabled(engine?.isLoaded != true)
            }
        }
    }
}

/// Shows an AVPlayer's picture. Used in the player and in fullscreen.
struct VideoSurface: UIViewRepresentable {
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
final class PlayerView: UIView {
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
