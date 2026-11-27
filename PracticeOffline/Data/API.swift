import Foundation

/// Port of src/data/api.ts (the part the favorites list needs).
nonisolated enum API {
    /// The flucom-api-bun server (Cloudflare Workers). Same address the Expo app uses;
    /// it's public, so it lives here rather than in Secrets.xcconfig.
    static let baseURL = URL(string: "https://flucom-api-bun.developedbyluan.workers.dev")!
}

/// A request that reached the server but got an error reply (e.g. 500).
nonisolated struct HTTPStatusError: LocalizedError {
    let what: String
    let status: Int

    var errorDescription: String? { "Failed to load \(what) (\(status))" }
}
