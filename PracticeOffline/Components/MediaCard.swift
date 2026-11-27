import SwiftUI

/// Port of src/components/MediaCard.tsx: thumbnail, title, author and the download button.
/// Until the lesson is downloaded, the picture and text are dimmed to 40%; the button isn't.
/// Opening the player comes in a later milestone.
struct MediaCard: View {
    let source: DownloadSource
    let name: String
    let author: String
    /// Shown in the "Not in favorites anymore" section on Home.
    var notInFavorites = false

    /// Opacity of the thumbnail and text while the media isn't downloaded.
    private static let notDownloadedOpacity = 0.4

    @State private var downloads = MediaDownloads.shared

    var body: some View {
        let state = downloads.state(mediaId: source.mediaId, fileUrl: source.fileUrl)
        let dimmed = !state.isDownloaded
        let version: Double = if case .downloaded(_, _, _, let version) = state { version } else { 0 }

        VStack(alignment: .leading, spacing: 4) {
            ThumbnailImage(
                url: source.thumbnailUrl,
                localFile: downloads.localThumbnailURL(mediaId: source.mediaId),
                version: version
            )
            .frame(maxWidth: .infinity)
            .aspectRatio(16 / 9, contentMode: .fit)
            .opacity(dimmed ? Self.notDownloadedOpacity : 1)

            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.subheadline.bold())
                    Text(author)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(dimmed ? Self.notDownloadedOpacity : 1)
                .accessibilityElement(children: .combine)

                if !source.fileUrl.isEmpty {
                    DownloadButton(source: source, name: name, notInFavorites: notInFavorites)
                }
            }
        }
        // Save what a downloaded lesson is missing: its thumbnail (if an earlier attempt
        // failed), or its transcript (lessons downloaded before transcripts were saved).
        .task(id: needsExtras(state)) {
            if needsExtras(state) { await downloads.ensureExtras(source) }
        }
    }

    private func needsExtras(_ state: DownloadState) -> Bool {
        guard case .downloaded(let hasThumbnail, let hasTranscript, _, _) = state else { return false }
        return (!hasThumbnail && source.thumbnailUrl != nil) || !hasTranscript
    }
}

extension MediaCard {
    /// A card for a lesson in the favorites list.
    init(item: MediaItem) {
        self.init(source: DownloadSource(item), name: item.fileName, author: item.fileAuthor)
    }

    /// A card for a downloaded lesson that left the favorites list, drawn from its saved record.
    init(leftover: DownloadedItem) {
        let record = leftover.record
        self.init(
            source: DownloadSource(
                mediaId: leftover.mediaId, fileUrl: record.fileUrl, fileJsonId: record.fileJsonId,
                thumbnailUrl: record.thumbnailUrl, updatedAtOfMedia: record.updatedAtOfMedia,
                fileName: record.fileName, fileAuthor: record.fileAuthor, fileSlug: record.fileSlug
            ),
            name: record.fileName ?? "Lesson \(leftover.mediaId)",
            author: record.fileAuthor ?? "",
            notInFavorites: true
        )
    }
}
