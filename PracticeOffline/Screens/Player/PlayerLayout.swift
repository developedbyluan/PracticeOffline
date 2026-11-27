import SwiftUI

/// Port of src/components/player/PlayerLayout.tsx: title, picture, transcript, seek bar,
/// play/pause, the repeat range (see docs/play-range.md) and the "Aa" text size.
/// The player screen's look, shared by every player engine: each engine passes in its
/// state and controls; this view doesn't know what's playing.
/// The ±5 s buttons and the Favorites menu button come in later milestones.
struct PlayerLayout<Media: View>: View {
    let title: String
    /// The artwork (audio) or the video, shown full width.
    @ViewBuilder let media: Media
    /// nil while loading.
    let transcript: TranscriptResult?
    /// seconds
    let currentTime: Double
    /// seconds; 0 until loaded
    let duration: Double
    let isLoaded: Bool
    let playing: Bool
    let onPlay: () -> Void
    let onPause: () -> Void
    let onSeek: (Double) async -> Void

    /// How close to the end counts as finished, so Play starts again from the beginning.
    private static var endToleranceSeconds: Double { 0.25 }
    /// Pressing Play this close after a range's End (while paused) plays the range again.
    private static var rangeRestartAfterSeconds: Double { 0.5 }
    /// Jump back this close to End, to make up a little for the time updates' spacing.
    private static var loopEarlySeconds: Double { 0.05 }
    /// A bigger step between two time updates is a seek, not playback crossing End.
    private static var maxTickSeconds: Double { 1.5 }
    private static var playButtonSize: CGFloat { 76 }

    /// The part of the lesson playing on repeat. Not saved: closing the player clears it.
    @State private var range: PlayRange?
    /// Set while the jump back to Start is landing, so it never seeks twice.
    @State private var jumping = false
    @AppStorage(TranscriptTextSize.storageKey) private var textSizeIndex = TranscriptTextSize.defaultIndex

    private var lines: [TranscriptLine]? {
        if case .lines(let lines) = transcript { lines } else { nil }
    }

    /// Waits for the transcript, so it starts from the right line, and for the length.
    private var canUseRange: Bool {
        isLoaded && duration > 0 && transcript != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
                .accessibilityAddTraits(.isHeader)

            media
                .frame(maxWidth: .infinity)
                .aspectRatio(16 / 9, contentMode: .fit)

            transcriptArea
                .padding(.horizontal, 24)
                .padding(.top, 16)

            SeekBar(currentTime: currentTime, duration: duration, onSeek: onSeek)
                .padding(.horizontal, 24)
                .padding(.top, 8)

            controls
                .padding(.top, 16)

            menu
                .padding(.top, 12)
        }
        .padding(.top, 24)
        .padding(.bottom, 16)
        .onChange(of: currentTime) { previous, current in
            loopIfNeeded(previous: previous, current: current)
        }
    }

    // MARK: - Parts

    @ViewBuilder private var transcriptArea: some View {
        switch transcript {
        case nil:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error(let message):
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        case .lines(let lines):
            TranscriptView(
                lines: lines,
                currentTime: currentTime,
                onSeek: onSeek,
                textSize: TranscriptTextSize.at(textSizeIndex),
                range: range,
                onLineLongPress: range == nil ? nil : { extendRange(toLine: $0) }
            )
        }
    }

    /// While a range is on, Start and End sit on either side of Play.
    private var controls: some View {
        HStack(spacing: 0) {
            Group {
                if let range {
                    RangeEnd(label: "Start", time: range.start, currentTime: currentTime, onSet: setStartHere)
                } else {
                    Color.clear.frame(height: 1)
                }
            }
            .frame(maxWidth: .infinity)

            Button {
                Task { await togglePlay() }
            } label: {
                ZStack {
                    Circle().fill(Color(.systemGray4))
                    if isLoaded {
                        Image(systemName: playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.black)
                    } else {
                        ProgressView().tint(.black)
                    }
                }
                .frame(width: Self.playButtonSize, height: Self.playButtonSize)
            }
            .buttonStyle(.plain)
            .disabled(!isLoaded)
            .accessibilityLabel(playing ? "Pause" : "Play")

            Group {
                if let range {
                    RangeEnd(label: "End", time: range.end, currentTime: currentTime, onSet: setEndHere)
                } else {
                    Color.clear.frame(height: 1)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Grey and smaller than the playback controls, so it reads as secondary.
    private var menu: some View {
        let textSize = TranscriptTextSize.at(textSizeIndex)
        return HStack(spacing: 48) {
            MenuButton(systemImage: "textformat.size", caption: "Text size", color: .gray) {
                textSizeIndex = TranscriptTextSize.next(after: textSizeIndex)
            }
            .accessibilityLabel("Transcript text size: \(textSize.name)")
            .accessibilityHint("Changes to the next size")

            MenuButton(systemImage: "repeat", caption: "Range", color: range == nil ? .gray : .blue) {
                Task { await toggleRange() }
            }
            .disabled(!canUseRange && range == nil)
            .opacity(!canUseRange && range == nil ? 0.35 : 1)
            .accessibilityLabel(range == nil ? "Repeat a range" : "Stop repeating")
            .accessibilityHint(range == nil ? "Repeats the current line. Long-press lines to add them." : "")
            .accessibilityAddTraits(range == nil ? [] : .isSelected)
        }
    }

    // MARK: - Actions

    private func togglePlay() async {
        if playing {
            onPause()
            return
        }
        if let range,
           currentTime >= range.end - Self.endToleranceSeconds,
           currentTime <= range.end + Self.rangeRestartAfterSeconds {
            // Paused at the range's End: play the range again.
            await onSeek(range.start)
        } else if duration > 0, currentTime >= duration - Self.endToleranceSeconds {
            // Finished: start again from the beginning.
            await onSeek(0)
        }
        onPlay()
    }

    private func toggleRange() async {
        if range != nil {
            range = nil
            return
        }
        var next = PlayRange.initial(lines: lines, currentTime: currentTime, duration: duration)
        if next == nil {
            next = PlayRange.withoutLines(currentTime: currentTime, duration: duration)
            Toast.show("No subtitles here. Use ◎ to set Start and End.")
        }
        guard let next else { return }
        range = next
        await onSeek(next.start)
    }

    private func setStartHere() {
        guard let range else { return }
        let change = range.withStart(currentTime, duration: duration)
        self.range = change.range
        if let notice = change.notice { Toast.show(notice) }
    }

    private func setEndHere() {
        guard let range else { return }
        let change = range.withEnd(currentTime)
        self.range = change.range
        if let notice = change.notice { Toast.show(notice) }
        // Play the new range from the start right away.
        Task { await onSeek(change.range.start) }
    }

    private func extendRange(toLine index: Int) {
        guard let lines, let range, lines.indices.contains(index) else { return }
        self.range = range.extended(toLine: index, of: lines, duration: duration)
    }

    /// When playback runs across End from inside the range, jump back to Start. A seek past
    /// End doesn't loop, so the user can look for a new End.
    private func loopIfNeeded(previous: Double, current: Double) {
        guard let range else {
            jumping = false
            return
        }
        if jumping {
            if current < range.end { jumping = false }
            return
        }
        guard playing else { return }
        let crossedEnd = previous < range.end
            && current >= range.end - Self.loopEarlySeconds
            && current - previous < Self.maxTickSeconds
        if crossedEnd {
            jumping = true
            Task { await onSeek(range.start) }
        }
    }
}

/// One end of the repeat range: "Start: 00:12" and a ◎ button that moves it to the
/// current playback time.
private struct RangeEnd: View {
    let label: String
    let time: Double
    let currentTime: Double
    let onSet: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text("\(Text("\(label): ").foregroundStyle(.secondary))\(Text(formatTime(time)).fontWeight(.semibold))")
                .font(.callout.monospacedDigit())
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            Button(action: onSet) {
                Image(systemName: "smallcircle.filled.circle")
                    .font(.system(size: 24))
                    .foregroundStyle(.blue)
                    .frame(width: 36, height: 36)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Set \(label.lowercased()) to current time, now \(formatTime(currentTime))")
        }
    }
}

/// A grey icon with a small caption under it.
private struct MenuButton: View {
    let systemImage: String
    let caption: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(size: 20))
                Text(caption)
                    .font(.caption)
                    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            }
            .foregroundStyle(color)
            .frame(minWidth: 64)
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// A full-screen message instead of the player, e.g. when the lesson isn't downloaded.
struct PlayerMessage: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
