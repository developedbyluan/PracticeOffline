import ClerkKit
import SwiftUI

/// What the player needs to open a lesson (the Expo app passes these as route params).
struct PlayerRequest: Identifiable {
    let source: DownloadSource
    let title: String
    let author: String
    var id: Int { source.mediaId }
}

/// Port of src/app/player.tsx. Opened from a downloaded lesson's card as a sheet.
/// Plays only the downloaded file, so it works with no internet connection.
struct PlayerScreen: View {
    let request: PlayerRequest

    @State private var downloads = MediaDownloads.shared
    /// nil while loading. Port of useTranscript: the saved copy when downloaded, otherwise fetched.
    @State private var transcript: TranscriptResult?

    var body: some View {
        content
            // Above the player's controls.
            .toastHost(bottomPadding: 210)
            // While the player is open, background updates leave this lesson's files alone.
            .task(id: request.source.mediaId) {
                let release = downloads.markInUse(mediaId: request.source.mediaId)
                // Check the disk once, in case the file was removed outside the app.
                let playable = downloads.localMediaURL(mediaId: request.source.mediaId, fileUrl: request.source.fileUrl) != nil
                    && MediaKind(fileUrl: request.source.fileUrl) != nil
                // The first lesson opened each day sets the practice reminder's habit time.
                if playable { ReminderSettingsStore.shared.recordLessonOpened() }
                await waitUntilCancelled()
                release()
            }
            .task(id: request.source.mediaId) {
                do {
                    let json = try await downloads.transcript(
                        mediaId: request.source.mediaId, fileJsonId: request.source.fileJsonId)
                    transcript = .lines(json.json)
                } catch {
                    if Task.isCancelled { return }
                    transcript = .error(error.localizedDescription)
                }
            }
    }

    @ViewBuilder private var content: some View {
        let source = request.source
        // nil if the file isn't on the phone (e.g. the download was removed).
        let localURL = downloads.downloadedMediaURL(mediaId: source.mediaId, fileUrl: source.fileUrl)

        // Audio or video, from the file's extension.
        let kind = MediaKind(fileUrl: source.fileUrl)

        if source.fileUrl.isEmpty || kind == nil {
            PlayerMessage(text: "Couldn't open this lesson.")
        } else if let localURL {
            // Only one of them is shown, so only one player is ever created.
            if kind == .video {
                VideoPlayerScreen(
                    mediaId: source.mediaId,
                    userId: Clerk.shared.user?.id,
                    localURL: localURL,
                    title: request.title,
                    author: request.author,
                    artworkFile: downloads.localThumbnailURL(mediaId: source.mediaId),
                    artworkURL: source.thumbnailUrl,
                    transcript: transcript
                )
            } else {
                AudioPlayerScreen(
                    mediaId: source.mediaId,
                    userId: Clerk.shared.user?.id,
                    localURL: localURL,
                    title: request.title,
                    author: request.author,
                    artworkFile: downloads.localThumbnailURL(mediaId: source.mediaId),
                    artworkURL: source.thumbnailUrl,
                    transcript: transcript
                )
            }
        } else {
            PlayerMessage(text: "This lesson isn't downloaded. Download it to play it offline.")
        }
    }
}

/// Suspends until the surrounding task is cancelled (the view went away).
private func waitUntilCancelled() async {
    while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(3600))
    }
}
