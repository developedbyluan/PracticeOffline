import Foundation

// Port of the reading part of src/data/pinnedMessages.ts (see docs/pinned-messages.md):
// the signed-in user's pinned messages, from the commonvocab server. Online only:
// nothing is saved on the phone. Replying ("I'll be there!") and links aren't ported yet.

/// Unix seconds.
nonisolated struct PinnedRange: Sendable, Equatable {
    let start: Double
    let end: Double
}

/// Only the fields the list shows.
nonisolated struct PinnedMessage: Sendable, Identifiable {
    let id: Int
    let displayName: String
    /// Light markdown: see `bodyLines`.
    let body: String
    let pinRank: Double?
    let pinnedRange: PinnedRange?
    /// Unix seconds.
    let createdAt: Double
}

/// The list wasn't a list.
nonisolated struct PinnedResponseError: LocalizedError {
    var errorDescription: String? { "Pinned messages response isn't a list" }
}

// Loose checks, like the Android app: a message without an id or body is skipped instead
// of failing the whole list.

private nonisolated func number(_ value: Any?) -> Double? {
    // JSON booleans also arrive as NSNumber; they aren't numbers here.
    guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
    let double = value.doubleValue
    return double.isFinite ? double : nil
}

private nonisolated func parseRange(_ value: Any?) -> PinnedRange? {
    guard let record = value as? [String: Any],
          let start = number(record["start"]), let end = number(record["end"]), end > start
    else { return nil }
    return PinnedRange(start: start, end: end)
}

private nonisolated func parseMessage(_ value: Any) -> PinnedMessage? {
    guard let record = value as? [String: Any],
          let id = number(record["id"]), id == id.rounded(),
          let body = record["body"] as? String,
          !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    return PinnedMessage(
        id: Int(id),
        displayName: record["display_name"] as? String ?? "",
        body: body,
        pinRank: number(record["pin_rank"]),
        pinnedRange: parseRange(record["pinned_range"]),
        createdAt: number(record["created_at"]) ?? 0
    )
}

/// GET /messages?user_id=…&pinned=true&include=replies with the commonvocab login.
@concurrent
nonisolated func fetchPinnedMessages(userId: String, baseURL: URL = API.commonvocabURL) async throws -> [PinnedMessage] {
    let url = baseURL.appending(path: "messages").appending(queryItems: [
        URLQueryItem(name: "user_id", value: userId),
        URLQueryItem(name: "pinned", value: "true"),
        URLQueryItem(name: "include", value: "replies"),
    ])
    var request = URLRequest(url: url)
    request.setValue(try APIAuth.commonvocabHeader(), forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else { throw HTTPStatusError(what: "pinned messages", status: status) }
    guard let list = try JSONSerialization.jsonObject(with: data) as? [Any] else { throw PinnedResponseError() }
    return list.compactMap(parseMessage)
}

/// Drops messages whose time window has ended, then sorts by pin rank (unranked last),
/// then newest first.
nonisolated func visiblePinned(_ messages: [PinnedMessage], now: Date) -> [PinnedMessage] {
    let nowSeconds = now.timeIntervalSince1970
    return messages
        .filter { $0.pinnedRange.map { $0.end > nowSeconds } ?? true }
        .sorted { a, b in
            let rankA = a.pinRank ?? .infinity
            let rankB = b.pinRank ?? .infinity
            if rankA != rankB { return rankA < rankB }
            return a.createdAt > b.createdAt
        }
}

nonisolated func isHappeningNow(_ range: PinnedRange, now: Date) -> Bool {
    let nowSeconds = now.timeIntervalSince1970
    return range.start <= nowSeconds && nowSeconds < range.end
}

/// e.g. "Today, 8:30 PM – 9:30 PM", in the phone's time zone and language. A window that
/// spans days names both days.
nonisolated func formatPinnedRange(_ range: PinnedRange, now: Date) -> String {
    let calendar = Calendar.current
    let start = Date(timeIntervalSince1970: range.start)
    let end = Date(timeIntervalSince1970: range.end)

    func dayLabel(_ date: Date) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        default: return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }
    }
    func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    if calendar.isDate(start, inSameDayAs: end) {
        return "\(dayLabel(start)), \(time(start)) – \(time(end))"
    }
    return "\(dayLabel(start)), \(time(start)) – \(dayLabel(end)), \(time(end))"
}

/// One line of a message body.
nonisolated struct BodyLine: Sendable {
    /// 1–6 for a heading ("#" to "######"), 0 for normal text.
    let level: Int
    let text: String
    var isHeading: Bool { level > 0 }
}

/// A light reading of the markdown body, as on Android: lines starting with "#" are
/// headings, the rest is text. Blank lines are dropped; nothing else is interpreted.
nonisolated func bodyLines(_ body: String) -> [BodyLine] {
    body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .compactMap { line -> BodyLine? in
            // Up to six "#"; any more stay in the text, as in the Android app.
            let hashes = min(6, line.prefix { $0 == "#" }.count)
            if hashes > 0 {
                let text = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                return text.isEmpty ? nil : BodyLine(level: hashes, text: text)
            }
            return BodyLine(level: 0, text: line)
        }
}
