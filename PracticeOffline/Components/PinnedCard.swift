import SwiftUI
import UIKit

/// Port of src/components/PinnedCard.tsx: one pinned message, with its time window (and a
/// green Now tag while it's under way), the body as light markdown, the poster's name, and
/// for events the "I'll be there!" toggle. The message's links show only once the user has
/// said "I'll be there!" (see docs/pinned-messages.md).
struct PinnedCard: View {
    let message: PinnedMessage
    /// When the list loaded; the time label and Now tag are worked out from it.
    let now: Date
    /// Whether the user has answered "I'll be there!", and whether a request is running.
    var replied = false
    var busy = false
    var onToggleReply: () -> Void = {}
    /// Whether the user's role is in allowed_roles, and whether the role is known at all.
    var joinable = false
    var roleKnown = false

    private static let buttonHeight: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let range = message.pinnedRange {
                whenRow(range)
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

            // Only events (messages with a time window) can be replied to.
            if message.pinnedRange != nil {
                if joinable {
                    replyButton
                    if replied, !message.links.isEmpty {
                        VStack(spacing: 12) {
                            ForEach(message.links) { link in
                                LinkRow(link: link, height: Self.buttonHeight)
                            }
                        }
                        .padding(.top, 4)
                    }
                } else if roleKnown {
                    // For users whose role can't reply, in place of the button.
                    Text(rolesLabel(message.allowedRoles).map { "For \($0) members" } ?? "Not open for replies")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 14))
    }

    private func whenRow(_ range: PinnedRange) -> some View {
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

    /// Outlined blue until the user replies, then filled green with a tick.
    private var replyButton: some View {
        Button(action: onToggleReply) {
            ZStack {
                if busy {
                    ProgressView().tint(replied ? .white : .blue)
                } else {
                    Text(replied ? "✓ \(attendingReply)" : attendingReply)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(replied ? .white : .blue)
                }
            }
            .frame(maxWidth: .infinity, minHeight: Self.buttonHeight)
            .background(replied ? Color.green : Color(.systemBackground), in: .rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(replied ? Color.green : Color.blue, lineWidth: 1.5)
            }
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .padding(.top, 8)
        .accessibilityLabel(attendingReply)
        .accessibilityValue(replied ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
        .accessibilityHint(replied ? "Removes your reply" : "Sends a reply")
    }
}

/// One of the message's links: a full-width blue button that opens it, a copy button next
/// to it, and the link's note (e.g. "at 20:30") centered underneath.
private struct LinkRow: View {
    let link: MessageLink
    let height: CGFloat

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Button(action: open) {
                    Text(verbatim: link.text)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity, minHeight: height)
                        .background(Color.blue, in: .rect(cornerRadius: 12))
                        .contentShape(.rect(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(link.note.map { "\(link.text), \($0)" } ?? link.text)
                .accessibilityAddTraits(.isLink)
                .accessibilityHint("Opens the link")

                Button(action: copy) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 20))
                        .foregroundStyle(.blue)
                        .frame(width: height, height: height)
                        .background(Color(.systemBackground), in: .rect(cornerRadius: 12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12).strokeBorder(Color.blue, lineWidth: 1.5)
                        }
                        .contentShape(.rect(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy link: \(link.text)")
            }
            if let note = link.note {
                // Already read as part of the button's label.
                Text(verbatim: note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
            }
        }
    }

    /// Opens the link with the phone, e.g. in the Zoom app or Safari.
    private func open() {
        guard let url = URL(string: link.url.trimmingCharacters(in: .whitespaces)), url.scheme != nil else {
            Toast.show("Couldn't open this link.")
            return
        }
        openURL(url) { accepted in
            if !accepted { Toast.show("Couldn't open this link.") }
        }
    }

    /// Copies the URL, e.g. to paste into Zoom on a computer.
    private func copy() {
        UIPasteboard.general.string = link.url
        Toast.show("Link copied")
    }
}

#Preview {
    let now = Date.now
    let range = PinnedRange(start: now.timeIntervalSince1970 - 600, end: now.timeIntervalSince1970 + 3000)
    ScrollView {
        VStack(spacing: 16) {
            PinnedCard(message: PinnedMessage(
                id: 1, displayName: "Coach",
                body: "# Speaking club\nPractice the week's lessons together.",
                links: [MessageLink(id: 1, text: "Join Zoom Meeting", url: "https://zoom.us", note: "at 20:30")],
                pinRank: 1, pinnedRange: range, createdAt: 0, replies: [], allowedRoles: ["vvip"]),
                now: now, replied: true, joinable: true, roleKnown: true)
            PinnedCard(message: PinnedMessage(
                id: 2, displayName: "Coach", body: "# Workshop", links: [], pinRank: 2,
                pinnedRange: range, createdAt: 0, replies: [], allowedRoles: ["vvip", "vip"]),
                now: now, roleKnown: true)
        }
        .padding()
    }
}
