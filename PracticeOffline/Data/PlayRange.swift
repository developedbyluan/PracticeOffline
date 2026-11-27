import Foundation

// Port of the pure helpers in src/hooks/usePlayRange.ts (see docs/play-range.md).
// The loop itself lives in PlayerLayout.

/// A part of the lesson that plays on repeat, in seconds.
nonisolated struct PlayRange: Equatable, Sendable {
    var start: Double
    var end: Double

    /// The shortest range allowed, so Start and End never meet.
    static let minLength: Double = 0.5
    /// Without subtitles, a new range covers this much from the current time.
    static let noLinesLength: Double = 10

    /// A range change, and a message to show if the other end had to move.
    struct Change {
        var range: PlayRange
        var notice: String?
    }

    /// Start moves to `time`. If that's at or after End, End moves to the end of the lesson.
    func withStart(_ time: Double, duration: Double) -> Change {
        let start = round1(time)
        if start <= end - Self.minLength {
            return Change(range: PlayRange(start: start, end: end))
        }
        return Change(range: PlayRange(start: start, end: max(duration, start + Self.minLength)),
                      notice: "End moved to the end of the lesson.")
    }

    /// End moves to `time`. If that's at or before Start, Start moves to the beginning.
    func withEnd(_ time: Double) -> Change {
        let end = round1(time)
        if end >= start + Self.minLength {
            return Change(range: PlayRange(start: start, end: end))
        }
        return Change(range: PlayRange(start: 0, end: max(end, Self.minLength)),
                      notice: "Start moved to the beginning.")
    }

    /// Grows the range to include a line.
    func extended(toLine index: Int, of lines: [TranscriptLine], duration: Double) -> PlayRange {
        let line = PlayRange.forLine(index, of: lines, duration: duration)
        return PlayRange(start: min(start, line.start), end: max(end, line.end))
    }

    /// Whether a line overlaps the range. A line with broken timing counts from its start.
    func contains(_ line: TranscriptLine) -> Bool {
        let lineEnd = line.end > line.start ? line.end : line.start
        return line.start < end && lineEnd >= start
    }

    static func forLine(_ index: Int, of lines: [TranscriptLine], duration: Double) -> PlayRange {
        PlayRange(start: lines[index].start, end: lineEnd(lines, index: index, duration: duration))
    }

    /// The range for the highlighted line (line 0 before the first line starts), or nil when
    /// there are no lines.
    static func initial(lines: [TranscriptLine]?, currentTime: Double, duration: Double) -> PlayRange? {
        guard let lines, !lines.isEmpty else { return nil }
        return forLine(max(0, activeLineIndex(lines, currentTime: currentTime)), of: lines, duration: duration)
    }

    /// From now to 10 s later, or the last 10 s when there's almost nothing left.
    static func withoutLines(currentTime: Double, duration: Double) -> PlayRange {
        let start = round1(currentTime)
        if duration - start >= minLength {
            return PlayRange(start: start, end: min(start + noLinesLength, duration))
        }
        return PlayRange(start: max(0, duration - noLinesLength), end: duration)
    }
}

/// When a line ends. A line with broken timing (end not after start) ends where the next
/// line starts, or at the end of the lesson.
nonisolated func lineEnd(_ lines: [TranscriptLine], index: Int, duration: Double) -> Double {
    let line = lines[index]
    if line.end > line.start { return line.end }
    if index + 1 < lines.count, lines[index + 1].start > line.start { return lines[index + 1].start }
    return max(duration, line.start + PlayRange.minLength)
}

private nonisolated func round1(_ seconds: Double) -> Double {
    (seconds * 10).rounded() / 10
}
