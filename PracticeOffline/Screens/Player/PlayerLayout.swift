import SwiftUI

/// Port of src/components/player/PlayerLayout.tsx (play, pause and the seek bar only).
/// The player screen's look, shared by every player engine: each engine passes in its
/// state and controls; this view doesn't know what's playing.
/// The transcript, ±5 s buttons, repeat range and menu come in later milestones.
struct PlayerLayout<Media: View>: View {
    let title: String
    /// The artwork (audio) or the video, shown full width.
    @ViewBuilder let media: Media
    /// seconds
    let currentTime: Double
    /// seconds; 0 until loaded
    let duration: Double
    let isLoaded: Bool
    let playing: Bool
    let onPlay: () -> Void
    let onPause: () -> Void
    let onSeek: (Double) async -> Void

    /// How close to the end counts as finished, so Play starts again from the beginning.
    private static var endToleranceSeconds: Double { 0.25 }
    private static var playButtonSize: CGFloat { 76 }

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
                .accessibilityAddTraits(.isHeader)

            media
                .frame(maxWidth: .infinity)
                .aspectRatio(16 / 9, contentMode: .fit)

            // The transcript goes here in a later milestone.
            Spacer(minLength: 16)

            SeekBar(currentTime: currentTime, duration: duration, onSeek: onSeek)
                .padding(.horizontal, 24)
                .padding(.top, 8)

            Button {
                Task { await togglePlay() }
            } label: {
                ZStack {
                    Circle().fill(Color(.systemGray4))
                    if isLoaded {
                        Image(systemName: playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.black)
                    } else {
                        ProgressView().tint(.black)
                    }
                }
                .frame(width: Self.playButtonSize, height: Self.playButtonSize)
            }
            .buttonStyle(.plain)
            .disabled(!isLoaded)
            .accessibilityLabel(playing ? "Pause" : "Play")
            .padding(.top, 16)
        }
        .padding(.top, 24)
        .padding(.bottom, 16)
    }

    private func togglePlay() async {
        if playing {
            onPause()
            return
        }
        // Finished: start again from the beginning.
        if duration > 0, currentTime >= duration - Self.endToleranceSeconds {
            await onSeek(0)
        }
        onPlay()
    }
}

/// A full-screen message instead of the player, e.g. when the lesson isn't downloaded.
struct PlayerMessage: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
