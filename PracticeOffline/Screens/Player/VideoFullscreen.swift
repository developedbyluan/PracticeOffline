import SwiftUI

/// Port of src/components/player/VideoFullscreen.tsx (see docs/video-fullscreen.md):
/// the video filling the screen in landscape, with the status bar and home indicator
/// hidden, the current transcript line as a subtitle, and controls that fade while
/// playing. It's shown over the player, which keeps running underneath, so the saved
/// position, the lock screen and a repeat range keep working.
struct VideoFullscreen: View {
    let engine: PlaybackEngine
    /// nil or empty: the lesson has no subtitles, so Aa and CC aren't shown.
    let lines: [TranscriptLine]?
    let onClose: () -> Void

    /// Where the CC choice is saved, for every lesson. On by default.
    static let subtitlesStorageKey = "fullscreenSubtitlesShown"

    private static let skipSeconds: Double = 5
    /// While playing, the controls hide after this long without a touch.
    private static let controlsTimeout: Duration = .seconds(3)
    /// How long "Subtitles on/off" stays on screen.
    private static let toastDuration: Duration = .milliseconds(1500)
    private static let roundButtonSize: CGFloat = 52
    private static let playButtonSize: CGFloat = 68

    @AppStorage(Self.subtitlesStorageKey) private var subtitlesShown = true
    @AppStorage(TranscriptTextSize.storageKey) private var textSizeIndex = TranscriptTextSize.defaultIndex
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var controlsShown = true
    @State private var lastTouch = Date.now
    @State private var toast: String?

    private var hasLines: Bool { !(lines ?? []).isEmpty }
    /// With VoiceOver, the controls never hide.
    private var visible: Bool { controlsShown || voiceOver }
    private var textSize: TranscriptTextSize { TranscriptTextSize.at(textSizeIndex) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoSurface(player: engine.avPlayer)
                .ignoresSafeArea()
                .accessibilityLabel("Video")

            // Tapping the video shows or hides the controls.
            Color.clear
                .contentShape(.rect)
                .ignoresSafeArea()
                .onTapGesture {
                    touched()
                    withAnimation(.easeInOut(duration: 0.2)) { controlsShown.toggle() }
                }
                .accessibilityHidden(true)

            subtitles

            controls
                .opacity(visible ? 1 : 0)
                .allowsHitTesting(visible)
                .animation(.easeInOut(duration: 0.2), value: visible)

            if let toast {
                VStack {
                    Text(toast)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.6), in: .capsule)
                        .padding(.top, 24)
                    Spacer()
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        // Landscape while open (a taller-than-wide video stays portrait); back to portrait
        // when it closes, even if the player itself closes.
        .onAppear { OrientationLock.set(engine.videoIsPortrait ? .portrait : .landscape) }
        .onDisappear { OrientationLock.set(.portrait) }
        // Hide the controls a few seconds after the last touch, while playing.
        .task(id: "\(controlsShown)|\(engine.playing)|\(voiceOver)|\(lastTouch.timeIntervalSince1970)") {
            guard controlsShown, engine.playing, !voiceOver else { return }
            try? await Task.sleep(for: Self.controlsTimeout)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) { controlsShown = false }
        }
        // The message hides itself; a new one restarts the timer.
        .task(id: toast) {
            guard toast != nil else { return }
            try? await Task.sleep(for: Self.toastDuration)
            guard !Task.isCancelled else { return }
            withAnimation { toast = nil }
        }
    }

    // MARK: - Parts

    /// At the bottom centre, moving up above the seek bar while the controls show.
    @ViewBuilder private var subtitles: some View {
        if let lines, hasLines, subtitlesShown {
            GeometryReader { geometry in
                VStack {
                    Spacer()
                    SubtitleOverlay(
                        lines: lines,
                        currentTime: engine.currentTime,
                        duration: engine.duration,
                        fontSize: textSize.subtitleFontSize,
                        lineHeight: textSize.subtitleLineHeight
                    )
                    .frame(maxWidth: geometry.size.width * 0.8)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, visible ? 96 : 24)
                .animation(.easeInOut(duration: 0.2), value: visible)
            }
            .padding(.horizontal, 24)
            .allowsHitTesting(false)
        }
    }

    private var controls: some View {
        ZStack {
            // Top right: text size, subtitles on/off, exit.
            VStack {
                HStack(spacing: 12) {
                    Spacer()
                    if hasLines {
                        roundButton("textformat.size", size: 22) {
                            textSizeIndex = TranscriptTextSize.next(after: textSizeIndex)
                            show("Text size: \(TranscriptTextSize.at(textSizeIndex).name)")
                        }
                        .accessibilityLabel("Subtitle text size: \(textSize.name)")
                        .accessibilityHint("Changes to the next size")

                        roundButton(subtitlesShown ? "captions.bubble.fill" : "captions.bubble", size: 22) {
                            subtitlesShown.toggle()
                            show(subtitlesShown ? "Subtitles on" : "Subtitles off")
                        }
                        .accessibilityLabel(subtitlesShown ? "Hide subtitles" : "Show subtitles")
                        .accessibilityAddTraits(subtitlesShown ? .isSelected : [])
                    }
                    roundButton("arrow.down.right.and.arrow.up.left", size: 22, action: onClose)
                        .accessibilityLabel("Exit full screen")
                }
                Spacer()
            }
            .padding(16)

            // Centre: back 5 s, Play/Pause, forward 5 s.
            HStack(spacing: 48) {
                roundButton("gobackward.5", size: 28) { skip(-Self.skipSeconds) }
                    .accessibilityLabel("Back 5 seconds")
                Button(action: togglePlay) {
                    Image(systemName: engine.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.white)
                        .frame(width: Self.playButtonSize, height: Self.playButtonSize)
                        .background(.black.opacity(0.45), in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(engine.playing ? "Pause" : "Play")
                roundButton("goforward.5", size: 28) { skip(Self.skipSeconds) }
                    .accessibilityLabel("Forward 5 seconds")
            }

            // Bottom: the seek bar, in white.
            VStack {
                Spacer()
                SeekBar(currentTime: engine.currentTime, duration: engine.duration, onSeek: { seconds in
                    touched()
                    await engine.seek(to: seconds)
                }, tone: .light)
                .simultaneousGesture(TapGesture().onEnded { touched() })
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
    }

    private func roundButton(_ systemImage: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button {
            touched()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: size))
                .foregroundStyle(.white)
                .frame(width: Self.roundButtonSize, height: Self.roundButtonSize)
                .background(.black.opacity(0.45), in: .circle)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func touched() {
        lastTouch = .now
    }

    private func show(_ message: String) {
        withAnimation { toast = message }
    }

    private func skip(_ delta: Double) {
        Task { await engine.seek(to: min(engine.duration, max(0, engine.currentTime + delta))) }
    }

    private func togglePlay() {
        touched()
        if engine.playing {
            engine.pause()
            return
        }
        // Finished: start again from the beginning, as in the normal player.
        if engine.duration > 0, engine.currentTime >= engine.duration - 0.25 {
            Task {
                await engine.seek(to: 0)
                engine.play()
            }
        } else {
            engine.play()
        }
    }
}
