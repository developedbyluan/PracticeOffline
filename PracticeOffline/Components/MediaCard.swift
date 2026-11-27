import SwiftUI

/// Port of src/components/MediaCard.tsx: thumbnail, title and author.
/// The download button, dimming and opening the player come in later milestones.
struct MediaCard: View {
    let name: String
    let author: String
    let thumbnail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ThumbnailImage(url: thumbnail)
                .frame(maxWidth: .infinity)
                .aspectRatio(16 / 9, contentMode: .fit)
            Text(name)
                .font(.subheadline.bold())
            Text(author)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
