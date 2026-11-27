import SwiftUI

/// Port of the reading part of src/components/PinnedCard.tsx: one pinned message, with
/// its time window (and a green Now tag while it's under way), the body as light markdown,
/// and the poster's name. The "I'll be there!" button and links aren't ported yet.
struct PinnedCard: View {
    let message: PinnedMessage
    /// When the list loaded; the time label and Now tag are worked out from it.
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let range = message.pinnedRange {
                HStack(spacing: 8) {
                    if isHappeningNow(range, now: now) {
                        Text("Now")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.green, in: .rect(cornerRadius: 8))
                    }
                    Text(formatPinnedRange(range, now: now))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.blue)
                }
                .accessibilityElement(children: .combine)
            }

            ForEach(Array(bodyLines(message.body).enumerated()), id: \.offset) { _, line in
                // `verbatim`: the text is shown as written, never read as SwiftUI markdown.
                if line.isHeading {
                    Text(verbatim: line.text)
                        .font(.system(size: line.level >= 3 ? 17 : 20, weight: .bold))
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(.isHeader)
                } else {
                    Text(verbatim: line.text)
                        .font(.system(size: 16))
                        .lineSpacing(3)
                        .foregroundStyle(.primary)
                }
            }

            if !message.displayName.isEmpty {
                Text(verbatim: message.displayName)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 14))
    }
}

#Preview {
    let now = Date.now
    VStack(spacing: 16) {
        PinnedCard(message: PinnedMessage(
            id: 1, displayName: "Coach",
            body: "# Speaking club\nPractice the week's lessons together.\n\n### Bring a question",
            pinRank: 1,
            pinnedRange: PinnedRange(start: now.timeIntervalSince1970 - 600, end: now.timeIntervalSince1970 + 3000),
            createdAt: 0), now: now)
        PinnedCard(message: PinnedMessage(
            id: 2, displayName: "", body: "A note without a time.", pinRank: nil, pinnedRange: nil, createdAt: 0), now: now)
    }
    .padding()
}
