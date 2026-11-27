import Foundation

// Port of the reading part of src/data/pinnedMessages.ts (see docs/pinned-messages.md):
// the signed-in user's pinned messages from the commonvocab server, the user's role, and
// replying "I'll be there!". Online only: nothing is saved on the phone.

/// Unix seconds.
nonisolated struct PinnedRange: Sendable, Equatable {
    let start: Double
    let end: Double
}

nonisolated struct MessageLink: Sendable, Identifiable {
    let id: Int
    let text: String
    let url: String
    /// e.g. "at 20:30", shown under the link's button.
    let note: String?
}

nonisolated struct MessageReply: Sendable {
    let id: Int
    let userId: String
    let body: String
    /// Unix seconds.
    let createdAt: Double
}

/// Only the fields the app uses. Replies aren't listed; they tell whether the user has
/// answered "I'll be there!" (see `attendingReplyIds`).
nonisolated struct PinnedMessage: Sendable, Identifiable {
    let id: Int
    let displayName: String
    /// Light markdown: see `bodyLines`.
    let body: String
    /// Shown on the card only once the user has said "I'll be there!".
    let links: [MessageLink]
    let pinRank: Double?
    let pinnedRange: PinnedRange?
    /// Unix seconds.
    let createdAt: Double
    let replies: [MessageReply]
    /// Roles that can reply (e.g. ["vvip"]). Others get a partial copy and no button.
    let allowedRoles: [String]
}

/// The server's answer wasn't the expected shape.
nonisolated struct PinnedResponseError: LocalizedError {
    var what = "Pinned messages response isn't a list"
    var errorDescription: String? { what }
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

/// A whole number, as an id.
private nonisolated func wholeNumber(_ value: Any?) -> Int? {
    guard let double = number(value), double == double.rounded(), abs(double) < 1e15 else { return nil }
    return Int(double)
}

private nonisolated func parseLink(_ value: Any) -> MessageLink? {
    guard let record = value as? [String: Any],
          let id = wholeNumber(record["id"]), let url = record["url"] as? String
    else { return nil }
    let note = (record["note"] as? String).flatMap {
        $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
    }
    return MessageLink(id: id, text: record["text"] as? String ?? url, url: url, note: note)
}

private nonisolated func parseReply(_ value: Any) -> MessageReply? {
    guard let record = value as? [String: Any],
          let id = wholeNumber(record["id"]), let userId = record["user_id"] as? String
    else { return nil }
    return MessageReply(id: id, userId: userId, body: record["body"] as? String ?? "",
                        createdAt: number(record["created_at"]) ?? 0)
}

private nonisolated func parseMessage(_ value: Any) -> PinnedMessage? {
    guard let record = value as? [String: Any],
          let id = wholeNumber(record["id"]),
          let body = record["body"] as? String,
          !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    return PinnedMessage(
        id: id,
        displayName: record["display_name"] as? String ?? "",
        body: body,
        links: (record["links"] as? [Any] ?? []).compactMap(parseLink),
        pinRank: number(record["pin_rank"]),
        pinnedRange: parseRange(record["pinned_range"]),
        createdAt: number(record["created_at"]) ?? 0,
        replies: (record["replies"] as? [Any] ?? []).compactMap(parseReply),
        allowedRoles: (record["allowed_roles"] as? [Any] ?? []).compactMap { $0 as? String }
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
    var request = try commonvocabRequest(url)
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else { throw HTTPStatusError(what: "pinned messages", status: status) }
    guard let list = try JSONSerialization.jsonObject(with: data) as? [Any] else { throw PinnedResponseError() }
    return list.compactMap(parseMessage)
}

/// A request to the commonvocab server, with its login.
private nonisolated func commonvocabRequest(_ url: URL, method: String = "GET") throws -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue(try APIAuth.commonvocabHeader(), forHTTPHeaderField: "Authorization")
    return request
}

/// The user's membership role (standard, premium, vip, vvip), from the worker's users table.
@concurrent
nonisolated func fetchUserRole(userId: String, baseURL: URL = API.commonvocabURL) async throws -> String {
    // Clerk ids are letters, digits and "_", so they are safe in a path.
    var request = try commonvocabRequest(baseURL.appending(path: "users").appending(path: userId))
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else { throw HTTPStatusError(what: "the user's role", status: status) }
    guard let record = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let role = record["role"] as? String
    else { throw PinnedResponseError(what: "User role missing from response") }
    return role
}

/// The reply the card's button sends.
nonisolated let attendingReply = "I'll be there!"

/// Ignores case, spacing and curly vs straight apostrophes, so "I’ll be there!" matches.
private nonisolated func normalizeReply(_ text: String) -> String {
    text.lowercased()
        .replacing(/[\u{2018}\u{2019}]/, with: "'")
        .replacing(/\s+/, with: " ")
        .trimmingCharacters(in: .whitespaces)
}

/// The user's "I'll be there!" replies on a message. The button shows "going" when there's
/// at least one, and removing deletes all of them, never the user's other replies.
nonisolated func attendingReplyIds(_ message: PinnedMessage, userId: String) -> [Int] {
    let target = normalizeReply(attendingReply)
    return message.replies
        .filter { $0.userId == userId && normalizeReply($0.body) == target }
        .map(\.id)
}

/// POST /messages/{id}/replies.
@concurrent
nonisolated func sendReply(messageId: Int, userId: String, body: String,
                           baseURL: URL = API.commonvocabURL) async throws {
    let url = baseURL.appending(path: "messages").appending(path: String(messageId)).appending(path: "replies")
    var request = try commonvocabRequest(url, method: "POST")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["user_id": userId, "body": body])
    let (_, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else { throw HTTPStatusError(what: "the reply", status: status) }
}

/// DELETE /replies/{id}?user_id=…. A reply that's already gone (404) counts as deleted.
@concurrent
nonisolated func deleteReply(replyId: Int, userId: String, baseURL: URL = API.commonvocabURL) async throws {
    let url = baseURL.appending(path: "replies").appending(path: String(replyId))
        .appending(queryItems: [URLQueryItem(name: "user_id", value: userId)])
    var request = try commonvocabRequest(url, method: "DELETE")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let (_, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) || status == 404 else {
        throw HTTPStatusError(what: "removing the reply", status: status)
    }
}

/// Whether the user may reply "I'll be there!". Unknown role: no.
nonisolated func canJoin(_ message: PinnedMessage, role: String?) -> Bool {
    guard let role else { return false }
    return message.allowedRoles.contains(role)
}

/// Tier order, lowest first, with the names shown to users.
private nonisolated let roleNames: [(role: String, name: String)] = [
    ("standard", "Standard"), ("premium", "Premium"), ("vip", "VIP"), ("vvip", "VVIP"),
]

/// "VVIP", "VIP and VVIP", "Premium, VIP and VVIP": every role in tier order, unknown roles
/// last as written, no duplicates. nil when there are none.
nonisolated func rolesLabel(_ roles: [String]) -> String? {
    var seen = Set<String>()
    let unique = roles.filter { seen.insert($0).inserted }
    func rank(_ role: String) -> Int { roleNames.firstIndex { $0.role == role } ?? roleNames.count }
    // A stable sort, so unknown roles keep their order.
    let names = unique.enumerated()
        .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
        .map { item in roleNames.first { $0.role == item.element }?.name ?? item.element }
    guard let last = names.last else { return nil }
    if names.count == 1 { return last }
    return names.dropLast().joined(separator: ", ") + " and " + last
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

/// A short title for the message, e.g. for a notification: its first line, without "#".
nonisolated func messageTitle(_ body: String) -> String {
    bodyLines(body).first?.text ?? "Pinned event"
}
