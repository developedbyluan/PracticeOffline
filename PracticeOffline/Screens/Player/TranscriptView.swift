import SwiftUI

/// Port of src/hooks/useTranscript.ts: the lesson's transcript, or why it couldn't load.
enum TranscriptResult {
    case lines([TranscriptLine])
    case error(String)
}

/// Port of src/components/Transcript.tsx: the transcript list in the player.
/// - The line being spoken is highlighted and scrolls itself near the top.
/// - After scrolling by hand, it waits 4 seconds before following the audio again.
/// - Tapping a line plays from it.
/// - Answer lines stay blurred until they're spoken.
///
/// Beyond the Android app: each line also shows its IPA and Vietnamese, and questions and
/// answers get a Q or A badge (the badge style comes from the Android fullscreen subtitles).
struct TranscriptView: View {
    let lines: [TranscriptLine]
    /// seconds
    let currentTime: Double
    let onSeek: (Double) async -> Void

    /// After the user scrolls by hand, wait this long before following the audio again.
    private static let manualScrollPause: TimeInterval = 4

    @State private var lastManualScroll = Date.distantPast

    var body: some View {
        let active = activeLineIndex(lines, currentTime: currentTime)

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        TranscriptLineView(
                            line: line,
                            isActive: index == active,
                            hidden: line.isAnswerHidden(at: currentTime)
                        )
                        .equatable()
                        .contentShape(.rect)
                        .onTapGesture { Task { await onSeek(line.start) } }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint("Plays from this line")
                        .id(line.id)
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 48)
            }
            .onManualScroll { lastManualScroll = .now }
            // Start at the current line (e.g. when a lesson opens part-way through).
            .onAppear { follow(active, proxy: proxy, animated: false) }
            // Follow the audio, unless the user scrolled recently.
            .onChange(of: active) { _, active in
                follow(active, proxy: proxy, animated: true)
            }
        }
    }

    private func follow(_ active: Int, proxy: ScrollViewProxy, animated: Bool) {
        guard active >= 0, active < lines.count,
              Date.now.timeIntervalSince(lastManualScroll) >= Self.manualScrollPause else { return }
        // Keep the current line a little below the top of the list.
        let scroll = { proxy.scrollTo(lines[active].id, anchor: UnitPoint(x: 0.5, y: 0.05)) }
        if animated {
            withAnimation(.easeInOut(duration: 0.35), scroll)
        } else {
            scroll()
        }
    }
}

/// One line. Equatable, so only the lines whose highlight or blur changes re-draw while
/// the audio plays (the Android app memoizes its lines for the same reason).
private struct TranscriptLineView: View, Equatable {
    let line: TranscriptLine
    let isActive: Bool
    /// A blurred answer line.
    let hidden: Bool

    private enum Badge { case question, answer }

    private var badge: Badge? {
        switch line.speaker {
        case "question": .question
        case "answer": .answer
        default: nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label = line.speakerLabel {
                Text(label)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let badge {
                    BadgeView(letter: badge == .question ? "Q" : "A",
                              color: badge == .question ? .blue : .green)
                        .accessibilityLabel(badge == .question ? "Question" : "Answer")
                }
                texts
                    // A real blur: you can see the shape of the words but not read them.
                    // Same size as the readable text, so revealing it moves nothing.
                    .blur(radius: hidden ? 7 : 0)
                    .accessibilityHidden(hidden)
                    .overlay {
                        if hidden {
                            Color.clear.accessibilityElement().accessibilityLabel("Hidden answer")
                        }
                    }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var texts: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(line.target.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.body)
                .foregroundStyle(isActive ? Color.primary : Color(.systemGray2))
            if !line.ipa.isEmpty {
                Text(line.ipa)
                    .font(.subheadline)
                    .foregroundStyle(isActive ? Color.secondary : Color(.systemGray3))
            }
            if !line.mine.isEmpty {
                Text(line.mine)
                    .font(.subheadline)
                    .italic()
                    .foregroundStyle(isActive ? Color.secondary : Color(.systemGray3))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func == (a: Self, b: Self) -> Bool {
        a.line.id == b.line.id && a.isActive == b.isActive && a.hidden == b.hidden
    }
}

/// The round Q / A badge.
private struct BadgeView: View {
    let letter: String
    let color: Color
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 22

    var body: some View {
        Text(letter)
            .font(.caption.bold())
            .foregroundStyle(.white)
            .frame(minWidth: size, minHeight: size)
            .background(color, in: .circle)
            // Line up with the first line of text.
            .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - (size - 15) / 2 }
    }
}

private extension View {
    /// Calls `action` while the user scrolls by hand (dragging, or the glide after it).
    @ViewBuilder func onManualScroll(_ action: @escaping () -> Void) -> some View {
        if #available(iOS 18.0, *) {
            // Also on the way out of a hand scroll, so the pause counts from when it stops.
            onScrollPhaseChange { old, new in
                let manual: Set<ScrollPhase> = [.interacting, .decelerating]
                if manual.contains(new) || manual.contains(old) { action() }
            }
        } else {
            simultaneousGesture(DragGesture(minimumDistance: 10).onChanged { _ in action() })
        }
    }
}
