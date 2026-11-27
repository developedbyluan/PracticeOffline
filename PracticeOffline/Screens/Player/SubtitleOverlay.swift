import SwiftUI

/// Port of src/components/player/SubtitleOverlay.tsx: the line being spoken, drawn over
/// fullscreen video like a subtitle, with its speaker: a Q or A badge for questions and
/// answers, or a label such as "Narrator:" above the line. Nothing shows between lines.
/// Answers stay blurred until they're spoken.
struct SubtitleOverlay: View {
    let lines: [TranscriptLine]
    let currentTime: Double
    let duration: Double
    /// From the shared Aa setting.
    let fontSize: CGFloat
    let lineHeight: CGFloat

    var body: some View {
        let index = activeLineIndex(lines, currentTime: currentTime)
        if index >= 0, currentTime < lineEnd(lines, index: index, duration: duration) {
            let line = lines[index]
            let text = line.target.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                box(line: line, text: text, hidden: line.isAnswerHidden(at: currentTime))
            }
        }
    }

    private func box(line: TranscriptLine, text: String, hidden: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label = line.speakerLabel {
                Text(label)
                    .font(.system(size: (fontSize * 0.75).rounded(), weight: .semibold))
                    .foregroundStyle(Color(white: 0.78))
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if line.speaker == "question" || line.speaker == "answer" {
                    let question = line.speaker == "question"
                    // The badge grows with the text.
                    Text(question ? "Q" : "A")
                        .font(.system(size: (fontSize * 0.7).rounded(), weight: .bold))
                        .foregroundStyle(.white)
                        .frame(minWidth: (fontSize * 1.3).rounded(), minHeight: (fontSize * 1.3).rounded())
                        .background(question ? Color.blue : Color.green, in: .circle)
                        .accessibilityLabel(question ? "Question" : "Answer")
                }
                Text(text)
                    .font(.system(size: fontSize, weight: .medium))
                    .lineSpacing(max(0, lineHeight - fontSize * 1.2))
                    .foregroundStyle(.white)
                    .blur(radius: hidden ? (fontSize * 0.45).rounded() : 0)
                    .accessibilityLabel(hidden ? "Hidden answer" : text)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black.opacity(0.6), in: .rect(cornerRadius: 10))
        .clipShape(.rect(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .allowsHitTesting(false)
    }
}
