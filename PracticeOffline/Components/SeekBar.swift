import SwiftUI

/// Port of src/components/SeekBar.tsx. Dragging moves the thumb and the time label;
/// the audio jumps there when the finger lifts. A tap jumps straight to that spot.
struct SeekBar: View {
    /// seconds
    let currentTime: Double
    /// seconds; 0 until the media is loaded
    let duration: Double
    let onSeek: (Double) async -> Void

    private static let thumbSize: CGFloat = 28
    private static let stepSeconds: Double = 5

    @State private var dragRatio: Double?

    private var ratio: Double {
        dragRatio ?? (duration > 0 ? clamp01(currentTime / duration) : 0)
    }

    private var shownTime: Double {
        dragRatio.map { $0 * duration } ?? currentTime
    }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                let width = max(geometry.size.width, 1)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(.systemGray5))
                        .frame(height: 4)
                    Capsule()
                        .fill(Color(.systemGray))
                        .frame(width: width * ratio, height: 4)
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
                        .frame(width: Self.thumbSize, height: Self.thumbSize)
                        .offset(x: width * ratio - Self.thumbSize / 2)
                }
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard duration > 0 else { return }
                            dragRatio = clamp01(value.location.x / width)
                        }
                        .onEnded { value in
                            guard duration > 0 else { return }
                            // Worked out from the gesture, so a quick tap still seeks.
                            let target = clamp01(value.location.x / width) * duration
                            Task {
                                await onSeek(target)
                                dragRatio = nil
                            }
                        }
                )
            }
            .frame(height: 44)
            .accessibilityElement()
            .accessibilityLabel("Playback position")
            .accessibilityValue("\(formatTime(shownTime)) of \(formatTime(duration))")
            .accessibilityAdjustableAction { direction in
                let delta = direction == .increment ? Self.stepSeconds : -Self.stepSeconds
                Task { await onSeek(min(duration, max(0, currentTime + delta))) }
            }

            HStack {
                Text(formatTime(shownTime))
                Spacer()
                Text(formatTime(duration))
            }
            .font(.footnote.monospacedDigit())
            .accessibilityHidden(true)
        }
    }
}

private func clamp01(_ value: Double) -> Double {
    min(1, max(0, value.isFinite ? value : 0))
}

/// 75 → "01:15"; 3725 → "1:02:05".
func formatTime(_ seconds: Double) -> String {
    let total = Int(max(0, seconds.isFinite ? seconds : 0))
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    return h > 0
        ? String(format: "%d:%02d:%02d", h, m, s)
        : String(format: "%02d:%02d", m, s)
}

#Preview {
    SeekBar(currentTime: 75, duration: 300) { _ in }
        .padding()
}
