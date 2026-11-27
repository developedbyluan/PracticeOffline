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

    var body: some View {
        content
            // While the player is open, background updates leave this lesson's files alone.
            .task(id: request.source.mediaId) {
                let release = downloads.markInUse(mediaId: request.source.mediaId)
                // Check the disk once, in case the file was removed outside the app.
                _ = downloads.localMediaURL(mediaId: request.source.mediaId, fileUrl: request.source.fileUrl)
                await waitUntilCancelled()
                release()
            }
    }

    @ViewBuilder private var content: some View {
        let source = request.source
        // nil if the file isn't on the phone (e.g. the download was removed).
        let localURL = downloads.downloadedMediaURL(mediaId: source.mediaId, fileUrl: source.fileUrl)

        if source.fileUrl.isEmpty || MediaKind(fileUrl: source.fileUrl) == nil {
            PlayerMessage(text: "Couldn't open this lesson.")
        } else if let localURL {
            // Video lessons play their sound with the picture for now; showing the video
            // itself comes with the video player.
            AudioPlayerScreen(
                localURL: localURL,
                title: request.title,
                artwork: ThumbnailImage(
                    url: source.thumbnailUrl,
                    localFile: downloads.localThumbnailURL(mediaId: source.mediaId)
                )
            )
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
