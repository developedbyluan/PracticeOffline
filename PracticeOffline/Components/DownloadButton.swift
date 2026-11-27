import SwiftUI

/// Port of src/components/DownloadButton.tsx: the 44×44 button on each lesson card.
///
/// | State | Shows | Tapping it |
/// | Not downloaded | Circle with a down arrow | Starts the download |
/// | Downloading | Spinner while the transcript saves, then e.g. "42%" | Cancels |
/// | Downloaded | Filled blue circle with a white checkmark | Asks "Remove download?" |
/// | Updating | Small blue spinner | Cancels the update, keeping the old copy |
struct DownloadButton: View {
    let source: DownloadSource
    let name: String
    /// The lesson left the favorites list: removing it means it can't be downloaded again.
    var notInFavorites = false

    @State private var downloads = MediaDownloads.shared
    @State private var confirmingRemove = false

    private var state: DownloadState {
        downloads.state(mediaId: source.mediaId, fileUrl: source.fileUrl)
    }

    var body: some View {
        Button(action: handleTap) {
            icon
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .confirmationDialog("Remove download?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                downloads.deleteDownload(mediaId: source.mediaId, fileUrl: source.fileUrl)
            }
        } message: {
            Text(notInFavorites
                 ? "\(name) is no longer in your favorites, so you won't be able to download it again."
                 : name)
        }
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .none:
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 24))
                .foregroundStyle(.primary)
        case .downloading(nil):
            ProgressView()
        case .downloading(let progress?):
            Text("\(progress)%")
                .font(.system(size: 12, weight: .bold))
                .monospacedDigit()
        case .downloaded(_, _, true, _):
            ProgressView().controlSize(.small).tint(.blue)
        case .downloaded:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 24))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .blue)
        }
    }

    private var label: String {
        switch state {
        case .none: "Download \(name)"
        case .downloading: "Cancel download of \(name)"
        case .downloaded(_, _, true, _): "Updating \(name). Tap to cancel"
        case .downloaded: "Remove download of \(name)"
        }
    }

    private func handleTap() {
        switch state {
        case .none:
            Task {
                do {
                    try await downloads.startDownload(source)
                } catch {
                    print("Download failed:", error)
                    // A friendly message instead of the raw system error.
                    Toast.show(isOfflineError(error)
                               ? "You're offline. Connect to the internet to download this lesson."
                               : "Couldn't download this lesson. Please try again.")
                }
            }
        case .downloading, .downloaded(_, _, true, _):
            // Cancelling an update keeps the old copy; the next refresh tries again.
            downloads.cancelDownload(mediaId: source.mediaId)
        case .downloaded:
            confirmingRemove = true
        }
    }
}
