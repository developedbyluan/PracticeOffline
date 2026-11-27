import CryptoKit
import SwiftUI
import UIKit

/// A lesson thumbnail. Each image is kept on the phone after the first load, so the list
/// still has pictures offline (the Expo app gets this from expo-image's disk cache).
/// Falls back to the bundled placeholder when there's no URL or it fails to load.
struct ThumbnailImage: View {
    let url: String?
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable()
            } else {
                Image(.thumbnailFallback).resizable()
            }
        }
        .scaledToFit()
        .task(id: url) {
            guard let url, !url.isEmpty else { image = nil; return }
            if let data = await ThumbnailStore.data(for: url) {
                image = UIImage(data: data)
            } else {
                image = nil
            }
        }
    }
}

/// Thumbnail files in the Caches folder, named after their URL.
nonisolated enum ThumbnailStore {
    private static let folder = URL.cachesDirectory.appending(path: "thumbnails", directoryHint: .isDirectory)

    private static func fileURL(for url: String) -> URL {
        let hash = SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appending(path: hash)
    }

    /// The saved copy if there is one, otherwise downloads and saves it. Nil on failure.
    @concurrent
    static func data(for url: String) async -> Data? {
        let file = fileURL(for: url)
        if let saved = try? Data(contentsOf: file) { return saved }
        guard let remote = URL(string: url),
              let (data, response) = try? await URLSession.shared.data(from: remote),
              (response as? HTTPURLResponse)?.statusCode ?? 200 < 300,
              UIImage(data: data) != nil
        else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return data
    }
}
