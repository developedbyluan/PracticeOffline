import CryptoKit
import SwiftUI
import UIKit

/// A lesson thumbnail. Tries, in order:
/// 1. `localFile`, the thumbnail saved with a downloaded lesson;
/// 2. `url`, kept on the phone after the first load so it also shows offline
///    (the Expo app gets this from expo-image's disk cache);
/// 3. the bundled placeholder.
struct ThumbnailImage: View {
    let url: String?
    var localFile: URL? = nil
    /// The download's version. An update replaces the local file at the same path,
    /// so this makes the new picture load.
    var version: Double = 0

    @State private var image: UIImage?

    private var loadKey: String {
        "\(localFile?.path() ?? "")#\(version)|\(url ?? "")"
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable()
            } else {
                Image(.thumbnailFallback).resizable()
            }
        }
        .scaledToFit()
        .task(id: loadKey) {
            image = await load().flatMap(UIImage.init(data:))
        }
    }

    private func load() async -> Data? {
        if let localFile, let data = await ThumbnailStore.localData(at: localFile) {
            return data
        }
        guard let url, !url.isEmpty else { return nil }
        return await ThumbnailStore.data(for: url)
    }
}

/// Thumbnail files in the Caches folder, named after their URL.
nonisolated enum ThumbnailStore {
    private static let folder = URL.cachesDirectory.appending(path: "thumbnails", directoryHint: .isDirectory)

    private static func fileURL(for url: String) -> URL {
        let hash = SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appending(path: hash)
    }

    /// A saved picture, if it's there and really is an image.
    @concurrent
    static func localData(at file: URL) async -> Data? {
        guard let data = try? Data(contentsOf: file), UIImage(data: data) != nil else { return nil }
        return data
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
