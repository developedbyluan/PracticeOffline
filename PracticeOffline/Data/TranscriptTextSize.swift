import SwiftUI

/// Port of src/data/transcriptTextSize.ts: the transcript text sizes the player's "Aa"
/// button steps through. Medium is the default. The phone's own text-size setting scales
/// these too. The choice is saved on the phone and used for every lesson and account.
nonisolated struct TranscriptTextSize: Sendable {
    let name: String
    let fontSize: CGFloat
    let lineHeight: CGFloat

    static let all: [TranscriptTextSize] = [
        TranscriptTextSize(name: "Small", fontSize: 14, lineHeight: 20),
        TranscriptTextSize(name: "Medium", fontSize: 16, lineHeight: 22),
        TranscriptTextSize(name: "Large", fontSize: 18, lineHeight: 25),
        TranscriptTextSize(name: "Extra large", fontSize: 20, lineHeight: 28),
    ]

    static let defaultIndex = 1
    /// Where the choice is saved (UserDefaults, through @AppStorage).
    static let storageKey = "transcriptTextSizeIndex"

    /// The size at a saved position. A missing or out-of-range value means Medium.
    static func at(_ index: Int) -> TranscriptTextSize {
        all.indices.contains(index) ? all[index] : all[defaultIndex]
    }

    /// The position after `index`, wrapping back to Small.
    static func next(after index: Int) -> Int {
        all.indices.contains(index) ? (index + 1) % all.count : defaultIndex
    }
}
