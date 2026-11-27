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
/// - Lines in the repeat range get a blue bar; long-pressing a line adds it to the range.
///
/// Beyond the Android app: each line also shows its IPA and Vietnamese, and questions and
/// answers get a Q or A badge (the badge style comes from the Android fullscreen subtitles).
struct TranscriptView: View {
    let lines: [TranscriptLine]
    /// seconds
    let currentTime: Double
    let onSeek: (Double) async -> Void
    let textSize: TranscriptTextSize
    /// The repeat range, if any: its lines get a blue bar.
    var range: PlayRange? = nil
    /// Long-pressing a line (while a range is on) adds it to the range.
    var onLineLongPress: ((Int) -> Void)? = nil

    /// After the user scrolls by hand, wait this long before following the audio again.
    private static let manualScrollPause: TimeInterval = 4

    @State private var lastManualScroll = Date.distantPast
    /// Grows with the phone's own text-size setting.
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        let active = activeLineIndex(lines, currentTime: currentTime)

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        let inRange = range?.contains(line) ?? false
                        TranscriptLineView(
                            line: line,
                            isActive: index == active,
                            hidden: line.isAnswerHidden(at: currentTime),
                            inRange: inRange,
                            fontSize: textSize.fontSize * scale,
                            lineHeight: textSize.lineHeight * scale
                        )
                        .equatable()
                        .contentShape(.rect)
                        .onTapGesture { Task { await onSeek(line.start) } }
                        .onLongPressGesture {
                            onLineLongPress?(index)
                        }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAddTraits(onLineLongPress != nil && inRange ? .isSelected : [])
                        .accessibilityHint("Plays from this line")
                        .accessibilityActions {
                            if let onLineLongPress {
                                Button("Add to repeat range") { onLineLongPress(index) }
                            }
                        }
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
    /// Part of the repeat range.
    let inRange: Bool
    let fontSize: CGFloat
    let lineHeight: CGFloat

    /// The IPA and Vietnamese are a little smaller than the English.
    private var smallSize: CGFloat { (fontSize * 0.875).rounded() }

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
                              color: badge == .question ? .blue : .green,
                              fontSize: fontSize)
                        .accessibilityLabel(badge == .question ? "Question" : "Answer")
                }
                texts
                    // A real blur: you can see the shape of the words but not read them.
                    // Same size as the readable text, so revealing it moves nothing.
                    .blur(radius: hidden ? (fontSize * 0.45).rounded() : 0)
                    .accessibilityHidden(hidden)
                    .overlay {
                        if hidden {
                            Color.clear.accessibilityElement().accessibilityLabel("Hidden answer")
                        }
                    }
            }
        }
        // Lines in the repeat range are indented, with a blue line in the gap.
        .padding(.leading, inRange ? 16 : 0)
        .overlay(alignment: .leading) {
            if inRange {
                Rectangle().fill(.blue).frame(width: 3)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var texts: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(line.target.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: fontSize))
                .lineSpacing(max(0, lineHeight - fontSize * 1.2))
                .foregroundStyle(isActive ? Color.primary : Color(.systemGray2))
            if !line.ipa.isEmpty {
                Text(line.ipa)
                    .font(.system(size: smallSize))
                    .foregroundStyle(isActive ? Color.secondary : Color(.systemGray3))
            }
            if !line.mine.isEmpty {
                Text(line.mine)
                    .font(.system(size: smallSize))
                    .italic()
                    .foregroundStyle(isActive ? Color.secondary : Color(.systemGray3))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func == (a: Self, b: Self) -> Bool {
        a.line.id == b.line.id && a.isActive == b.isActive && a.hidden == b.hidden
            && a.inRange == b.inRange && a.fontSize == b.fontSize && a.lineHeight == b.lineHeight
    }
}

/// The round Q / A badge.
private struct BadgeView: View {
    let letter: String
    let color: Color
    /// The line's text size; the badge grows with it.
    let fontSize: CGFloat

    var body: some View {
        let size = (fontSize * 1.3).rounded()
        // Its letter's baseline lines up with the first line of text, which centres the badge.
        Text(letter)
            .font(.system(size: (fontSize * 0.7).rounded(), weight: .bold))
            .foregroundStyle(.white)
            .frame(minWidth: size, minHeight: size)
            .background(color, in: .circle)
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
