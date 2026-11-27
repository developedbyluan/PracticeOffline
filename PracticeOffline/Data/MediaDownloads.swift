import Foundation
import Observation

// Port of src/data/mediaDownloads.ts (see docs/media-downloads.md and docs/download-updates.md).
//
// Downloaded media lives in <Documents>/media, one set of files per mediaId, shared by all accounts:
//   media-<mediaId><ext>        the media file
//   media-<mediaId>.json        its transcript (required: a download only finishes when it's saved)
//   media-<mediaId>-thumb       its thumbnail (best effort; no extension, iOS reads the format from the bytes)
//   media-<mediaId>.meta.json   which version is on the phone (see DownloadRecord)
// The folder is excluded from iCloud backup, since everything in it can be downloaded again.
// One shared store, so a download keeps running when its card goes off screen, and cards
// that show the same mediaId stay in sync.

nonisolated enum DownloadState: Equatable, Sendable {
    case none
    /// 0–100; nil while the transcript saves, or when the server doesn't send the size.
    case downloading(progress: Int?)
    /// `updating`: a newer version is downloading; the old copy stays playable.
    /// `version`: the saved copy's updatedAtOfMedia (0 if unknown); changes when files are replaced.
    case downloaded(hasThumbnail: Bool, hasTranscript: Bool, updating: Bool, version: Double)

    var isDownloaded: Bool {
        if case .downloaded = self { true } else { false }
    }

    fileprivate var kind: Int {
        switch self {
        case .none: 0
        case .downloading: 1
        case .downloaded: 2
        }
    }
}

/// What's needed to download an item.
nonisolated struct DownloadSource: Sendable {
    var mediaId: Int
    var fileUrl: String
    var fileJsonId: Int
    var thumbnailUrl: String?
    /// ms since 1970
    var updatedAtOfMedia: Double?
    // Shown when the lesson is no longer in the favorites list.
    var fileName: String?
    var fileAuthor: String?
    var fileSlug: String?

    init(mediaId: Int, fileUrl: String, fileJsonId: Int, thumbnailUrl: String?,
         updatedAtOfMedia: Double?, fileName: String?, fileAuthor: String?, fileSlug: String?) {
        self.mediaId = mediaId
        self.fileUrl = fileUrl
        self.fileJsonId = fileJsonId
        self.thumbnailUrl = thumbnailUrl.flatMap { $0.isEmpty ? nil : $0 }
        self.updatedAtOfMedia = updatedAtOfMedia
        self.fileName = fileName.flatMap { $0.isEmpty ? nil : $0 }
        self.fileAuthor = fileAuthor.flatMap { $0.isEmpty ? nil : $0 }
        self.fileSlug = fileSlug.flatMap { $0.isEmpty ? nil : $0 }
    }

    init(_ item: MediaItem) {
        self.init(mediaId: item.mediaId, fileUrl: item.fileUrl, fileJsonId: item.fileJsonId,
                  thumbnailUrl: item.fileThumbnailUrl, updatedAtOfMedia: item.updatedAtOfMedia,
                  fileName: item.fileName, fileAuthor: item.fileAuthor, fileSlug: item.fileSlug)
    }
}

/// Which version of an item is on the phone, saved next to its files.
nonisolated struct DownloadRecord: Codable, Sendable {
    var fileUrl: String
    var fileJsonId: Int
    var thumbnailUrl: String?
    /// ms since 1970; 0 if the server didn't send it.
    var updatedAtOfMedia: Double
    /// ms since 1970
    var downloadedAt: Double?
    // The lesson's details, so it can still be shown after it leaves the favorites list.
    var fileName: String?
    var fileAuthor: String?
    var fileSlug: String?

    init(_ source: DownloadSource) {
        fileUrl = source.fileUrl
        fileJsonId = source.fileJsonId
        thumbnailUrl = source.thumbnailUrl
        updatedAtOfMedia = source.updatedAtOfMedia ?? 0
        downloadedAt = Date.now.timeIntervalSince1970 * 1000
        fileName = source.fileName
        fileAuthor = source.fileAuthor
        fileSlug = source.fileSlug
    }

    /// Whether the server has a newer version than this saved copy.
    func isOutdated(comparedTo source: DownloadSource) -> Bool {
        (source.updatedAtOfMedia ?? 0) > updatedAtOfMedia
            || fileUrl != source.fileUrl
            || fileJsonId != source.fileJsonId
            || thumbnailUrl != source.thumbnailUrl
    }
}

/// A lesson that's on the phone, read from its record. Favorite or not.
nonisolated struct DownloadedItem: Sendable, Identifiable {
    var mediaId: Int
    var record: DownloadRecord
    var id: Int { mediaId }
}

/// A download was cancelled, or an update was skipped.
private nonisolated struct Stopped: Error {}

@MainActor @Observable
final class MediaDownloads {
    static let shared = MediaDownloads()

    /// States that changed since launch. Views re-draw when this changes.
    private var states: [Int: DownloadState] = [:]
    /// Bumped when a record's details change, so lists of downloads re-draw.
    private var revision = 0

    /// States read from disk, before any change.
    @ObservationIgnored private var checked: [Int: DownloadState] = [:]
    /// Running downloads and updates, so they can be cancelled.
    @ObservationIgnored private var tasks: [Int: Task<Void, any Error>] = [:]
    @ObservationIgnored private var extrasInFlight: Set<Int> = []
    /// Records read from disk. `.some(nil)` means "checked, there's none".
    @ObservationIgnored private var records: [Int: DownloadRecord?] = [:]
    /// How many open players use each item. Its files aren't replaced while it's in use.
    @ObservationIgnored private var inUse: [Int: Int] = [:]
    /// Items waiting for an update, run one at a time.
    @ObservationIgnored private var updateQueue: [DownloadSource] = []
    @ObservationIgnored private var updateQueueRunning = false
    /// Everything on the phone, read from the records. nil until read, and after a change.
    @ObservationIgnored private var cachedItems: [DownloadedItem]?

    private let files = FileManager.default

    private init() {}

    // MARK: - Paths

    private var mediaDirectory: URL { URL.documentsDirectory.appending(path: "media", directoryHint: .isDirectory) }

    private func mediaFile(_ mediaId: Int, _ fileUrl: String) -> URL {
        mediaDirectory.appending(path: "media-\(mediaId)\(fileExtension(fileUrl))")
    }

    private func transcriptFile(_ mediaId: Int) -> URL {
        mediaDirectory.appending(path: "media-\(mediaId).json")
    }

    private func thumbnailFile(_ mediaId: Int) -> URL {
        mediaDirectory.appending(path: "media-\(mediaId)-thumb")
    }

    private func recordFile(_ mediaId: Int) -> URL {
        mediaDirectory.appending(path: "media-\(mediaId).meta.json")
    }

    private func cacheFile(_ name: String) -> URL {
        URL.cachesDirectory.appending(path: name)
    }

    /// The media file that's actually on the phone. Uses the saved record's URL, so a changed
    /// extension on the server still finds (and later replaces) the old file.
    private func savedMediaFile(_ mediaId: Int, _ fileUrl: String) -> URL {
        mediaFile(mediaId, readRecord(mediaId)?.fileUrl ?? fileUrl)
    }

    private func exists(_ url: URL) -> Bool {
        files.fileExists(atPath: url.path(percentEncoded: false))
    }

    private func deleteQuietly(_ url: URL) {
        try? files.removeItem(at: url)
    }

    private func createMediaDirectory() throws {
        guard !exists(mediaDirectory) else { return }
        try files.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        var folder = mediaDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
    }

    // MARK: - Records

    private func readRecord(_ mediaId: Int) -> DownloadRecord? {
        if let cached = records[mediaId] { return cached }
        // Missing or broken: treated as an item downloaded before records existed.
        let record = (try? Data(contentsOf: recordFile(mediaId)))
            .flatMap { try? JSONDecoder().decode(DownloadRecord.self, from: $0) }
        records[mediaId] = .some(record)
        return record
    }

    private func writeRecord(_ mediaId: Int, _ record: DownloadRecord) {
        records[mediaId] = .some(record)
        cachedItems = nil
        do {
            try createMediaDirectory()
            try JSONEncoder().encode(record).write(to: recordFile(mediaId), options: .atomic)
        } catch {
            print("Could not save the download record:", error)
        }
    }

    // MARK: - State

    /// The download state of an item. The first call for a mediaId checks the disk.
    func state(mediaId: Int, fileUrl: String) -> DownloadState {
        if let state = states[mediaId] { return state }
        if let state = checked[mediaId] { return state }
        let state = exists(savedMediaFile(mediaId, fileUrl)) ? downloadedState(mediaId) : .none
        checked[mediaId] = state
        return state
    }

    private func currentState(_ mediaId: Int) -> DownloadState? {
        states[mediaId] ?? checked[mediaId]
    }

    private func setState(_ mediaId: Int, _ state: DownloadState) {
        // A download appeared or went away: list the files again next time.
        if currentState(mediaId)?.kind != state.kind { cachedItems = nil }
        checked[mediaId] = nil
        states[mediaId] = state
    }

    /// A "downloaded" state read from the disk and the record.
    private func downloadedState(_ mediaId: Int, updating: Bool = false) -> DownloadState {
        .downloaded(
            hasThumbnail: exists(thumbnailFile(mediaId)),
            hasTranscript: exists(transcriptFile(mediaId)),
            updating: updating,
            version: readRecord(mediaId)?.updatedAtOfMedia ?? 0
        )
    }

    // MARK: - Downloading

    /// Downloads to a temporary file in Caches, then moves it into place, so a half-finished
    /// download never appears at the destination.
    private func downloadTo(
        _ url: String,
        tempName: String,
        destination: URL,
        onProgress: (@Sendable (Int?) -> Void)? = nil
    ) async throws {
        guard let remote = URL(string: url) else { throw URLError(.badURL) }
        let temp = cacheFile(tempName)
        do {
            try await FileDownloader.download(from: remote, to: temp, onProgress: onProgress)
            try Task.checkCancellation()
            try createMediaDirectory()
            deleteQuietly(destination)
            try files.moveItem(at: temp, to: destination)
        } catch {
            deleteQuietly(temp)
            throw error
        }
    }

    /// Saves the transcript and checks that it's a real transcript, not an error page.
    private func downloadTranscript(_ mediaId: Int, fileJsonId: Int, to destination: URL? = nil) async throws {
        let destination = destination ?? transcriptFile(mediaId)
        do {
            try await downloadTo(mediaJSONURL(fileJsonId: fileJsonId).absoluteString,
                                 tempName: "media-\(mediaId).json.part", destination: destination)
        } catch {
            if Task.isCancelled { throw error }
            throw TranscriptDownloadError(reason: error.localizedDescription, underlying: error)
        }
        guard let data = try? Data(contentsOf: destination), isMediaJSON(data) else {
            deleteQuietly(destination)
            throw TranscriptDownloadError(reason: "unexpected format", underlying: nil)
        }
    }

    /// Downloads the transcript, then the media file. Returns when both are saved or the
    /// download was cancelled; throws if either failed, keeping nothing. The media file is
    /// moved into place last, so a downloaded item always has its transcript.
    /// The thumbnail follows in the background.
    func startDownload(_ source: DownloadSource) async throws {
        let mediaId = source.mediaId
        guard state(mediaId: mediaId, fileUrl: source.fileUrl) == .none else { return }

        let task = Task<Void, any Error> {
            try await downloadTranscript(mediaId, fileJsonId: source.fileJsonId)
            try Task.checkCancellation()
            try await downloadTo(source.fileUrl, tempName: "media-\(mediaId).part",
                                 destination: mediaFile(mediaId, source.fileUrl)) { progress in
                Task { @MainActor in MediaDownloads.shared.progressChanged(mediaId, progress) }
            }
        }
        tasks[mediaId] = task
        setState(mediaId, .downloading(progress: nil))

        do {
            try await task.value
        } catch {
            tasks[mediaId] = nil
            deleteQuietly(transcriptFile(mediaId))
            setState(mediaId, .none)
            if task.isCancelled { return }
            throw error
        }
        tasks[mediaId] = nil
        writeRecord(mediaId, DownloadRecord(source))
        setState(mediaId, downloadedState(mediaId))
        Task { await ensureExtras(source) }
    }

    private func progressChanged(_ mediaId: Int, _ progress: Int?) {
        // Ignore late reports after the download finished or was cancelled.
        guard case .downloading = currentState(mediaId), let progress else { return }
        setState(mediaId, .downloading(progress: progress))
    }

    /// Saves what a downloaded item is missing: its thumbnail (if there's a URL), and its
    /// transcript for items downloaded before transcripts were saved. Never throws; failures
    /// are retried the next time it's called.
    func ensureExtras(_ source: DownloadSource) async {
        let mediaId = source.mediaId
        guard case .downloaded(let hasThumbnail, let hasTranscript, _, _) = currentState(mediaId) else { return }
        let needsThumbnail = !hasThumbnail && source.thumbnailUrl != nil
        let needsTranscript = !hasTranscript
        guard needsThumbnail || needsTranscript, !extrasInFlight.contains(mediaId) else { return }

        extrasInFlight.insert(mediaId)
        defer { extrasInFlight.remove(mediaId) }
        var gotTranscript = false
        var gotThumbnail = false

        if needsTranscript {
            // Offline or the request failed: retried next time.
            gotTranscript = (try? await downloadTranscript(mediaId, fileJsonId: source.fileJsonId)) != nil
        }
        if needsThumbnail, let thumbnailUrl = source.thumbnailUrl {
            // Offline or the URL failed: the remote or cached image is shown instead.
            gotThumbnail = (try? await downloadTo(thumbnailUrl, tempName: "media-\(mediaId)-thumb.part",
                                                  destination: thumbnailFile(mediaId))) != nil
        }

        if case .downloaded(let hasThumbnail, let hasTranscript, let updating, let version) = currentState(mediaId) {
            if gotThumbnail || gotTranscript {
                setState(mediaId, .downloaded(hasThumbnail: hasThumbnail || gotThumbnail,
                                              hasTranscript: hasTranscript || gotTranscript,
                                              updating: updating, version: version))
            }
        } else {
            // The download was removed while these were saving.
            if gotTranscript { deleteQuietly(transcriptFile(mediaId)) }
            if gotThumbnail { deleteQuietly(thumbnailFile(mediaId)) }
        }
    }

    /// Cancels a download, or a background update (which keeps the old copy).
    func cancelDownload(mediaId: Int) {
        tasks[mediaId]?.cancel()
    }

    /// Deletes the media, transcript, thumbnail and record.
    func deleteDownload(mediaId: Int, fileUrl: String) {
        // Stop a background update first, so it doesn't put files back.
        updateQueue.removeAll { $0.mediaId == mediaId }
        tasks[mediaId]?.cancel()
        deleteQuietly(savedMediaFile(mediaId, fileUrl))
        deleteQuietly(mediaFile(mediaId, fileUrl))
        deleteQuietly(transcriptFile(mediaId))
        deleteQuietly(thumbnailFile(mediaId))
        deleteQuietly(recordFile(mediaId))
        records[mediaId] = .some(nil)
        setState(mediaId, .none)
    }

    /// The player calls this while it's open, so an update never replaces a file being
    /// played. Returns a function that releases it.
    func markInUse(mediaId: Int) -> () -> Void {
        inUse[mediaId, default: 0] += 1
        return { [weak self] in
            guard let self else { return }
            let count = (self.inUse[mediaId] ?? 1) - 1
            self.inUse[mediaId] = count > 0 ? count : nil
        }
    }

    // MARK: - Updates

    /// Compares downloaded items with the latest favorites and updates the outdated ones in
    /// the background. Called after every successful favorites fetch.
    func syncDownloads(_ items: [MediaItem]) {
        for item in items where !item.fileUrl.isEmpty {
            let source = DownloadSource(item)
            let mediaId = source.mediaId
            guard case .downloaded(let hasThumbnail, let hasTranscript, let updating, _) =
                    state(mediaId: mediaId, fileUrl: source.fileUrl), !updating else { continue }

            guard var record = readRecord(mediaId) else {
                // Downloaded before records existed: assume it's current, instead of
                // downloading everything again.
                writeRecord(mediaId, DownloadRecord(source))
                setState(mediaId, .downloaded(hasThumbnail: hasThumbnail, hasTranscript: hasTranscript,
                                              updating: false, version: source.updatedAtOfMedia ?? 0))
                continue
            }
            // Keep the name, author and slug current, so the lesson can still be shown if it
            // leaves the favorites list. Only the record changes, never the files.
            if record.fileName != source.fileName || record.fileAuthor != source.fileAuthor
                || record.fileSlug != source.fileSlug {
                record.fileName = source.fileName
                record.fileAuthor = source.fileAuthor
                record.fileSlug = source.fileSlug
                writeRecord(mediaId, record)
                revision += 1
            }
            if record.isOutdated(comparedTo: source) {
                updateQueue.removeAll { $0.mediaId == mediaId }
                updateQueue.append(source)
            }
        }
        Task { await runUpdateQueue() }
    }

    private func runUpdateQueue() async {
        guard !updateQueueRunning else { return }
        updateQueueRunning = true
        defer { updateQueueRunning = false }
        while !updateQueue.isEmpty {
            let source = updateQueue.removeFirst()
            // An open player keeps the old copy; the next sync tries again.
            if inUse[source.mediaId] != nil { continue }
            await updateDownload(source)
        }
    }

    /// Downloads the new version next to the old one, then swaps it in. On any failure the
    /// old copy and record stay, and the next sync tries again.
    private func updateDownload(_ source: DownloadSource) async {
        let mediaId = source.mediaId
        guard case .downloaded(let hasThumbnail, let hasTranscript, false, let version) = currentState(mediaId),
              let record = readRecord(mediaId) else { return }

        let stagedTranscript = cacheFile("media-\(mediaId).json.next")
        let stagedMedia = mediaDirectory.appending(path: "media-\(mediaId).next\(fileExtension(source.fileUrl))")
        let task = Task<Void, any Error> {
            try await downloadTranscript(mediaId, fileJsonId: source.fileJsonId, to: stagedTranscript)
            try await downloadTo(source.fileUrl, tempName: "media-\(mediaId).part", destination: stagedMedia)
        }
        tasks[mediaId] = task
        setState(mediaId, .downloaded(hasThumbnail: hasThumbnail, hasTranscript: hasTranscript,
                                      updating: true, version: version))
        defer { tasks[mediaId] = nil }

        do {
            try await task.value
            if task.isCancelled { throw Stopped() }
            // Removed, or opened in the player, while downloading: keep things as they are.
            guard currentState(mediaId)?.isDownloaded == true, inUse[mediaId] == nil else { throw Stopped() }

            // Swap: the new media and transcript replace the old ones.
            deleteQuietly(mediaFile(mediaId, record.fileUrl))
            deleteQuietly(mediaFile(mediaId, source.fileUrl))
            try files.moveItem(at: stagedMedia, to: mediaFile(mediaId, source.fileUrl))
            deleteQuietly(transcriptFile(mediaId))
            try files.moveItem(at: stagedTranscript, to: transcriptFile(mediaId))

            // The thumbnail is best effort, as for new downloads; ensureExtras retries later.
            deleteQuietly(thumbnailFile(mediaId))
            if let thumbnailUrl = source.thumbnailUrl {
                try? await downloadTo(thumbnailUrl, tempName: "media-\(mediaId)-thumb.part",
                                      destination: thumbnailFile(mediaId))
            }

            writeRecord(mediaId, DownloadRecord(source))
            setState(mediaId, downloadedState(mediaId))
        } catch {
            deleteQuietly(stagedTranscript)
            deleteQuietly(stagedMedia)
            if case .downloaded(let hasThumbnail, let hasTranscript, _, let version) = currentState(mediaId) {
                setState(mediaId, .downloaded(hasThumbnail: hasThumbnail, hasTranscript: hasTranscript,
                                              updating: false, version: version))
            }
        }
    }

    // MARK: - Reading downloaded files

    /// The downloaded media file, or nil if it isn't on the phone. Always work the path out
    /// with this instead of saving it: the app's folder path can change after an app update.
    func localMediaURL(mediaId: Int, fileUrl: String) -> URL? {
        let file = savedMediaFile(mediaId, fileUrl)
        guard exists(file) else {
            // The file was removed outside the app. Correct the state so the card updates.
            if currentState(mediaId)?.isDownloaded == true { setState(mediaId, .none) }
            return nil
        }
        return file
    }

    /// Like localMediaURL, but uses the known state instead of checking the disk, so it's
    /// cheap while drawing, and views re-draw when the download finishes or is removed.
    func downloadedMediaURL(mediaId: Int, fileUrl: String) -> URL? {
        state(mediaId: mediaId, fileUrl: fileUrl).isDownloaded ? savedMediaFile(mediaId, fileUrl) : nil
    }

    /// What a player should load: the local file when it's downloaded, otherwise the online URL.
    func playbackURL(mediaId: Int, fileUrl: String) -> URL? {
        localMediaURL(mediaId: mediaId, fileUrl: fileUrl) ?? URL(string: fileUrl)
    }

    /// The saved transcript of a downloaded item, or nil if it isn't saved or can't be read.
    func loadLocalTranscript(mediaId: Int) -> MediaJSON? {
        guard let data = try? Data(contentsOf: transcriptFile(mediaId)), isMediaJSON(data) else { return nil }
        return try? JSONDecoder().decode(MediaJSON.self, from: data)
    }

    /// What a player should use: the saved transcript when there is one, otherwise fetch it.
    func transcript(mediaId: Int, fileJsonId: Int) async throws -> MediaJSON {
        if let saved = loadLocalTranscript(mediaId: mediaId) { return saved }
        return try await fetchMediaJSON(fileJsonId: fileJsonId)
    }

    /// The saved thumbnail file, or nil. Uses the known state, so it's cheap while drawing.
    func localThumbnailURL(mediaId: Int) -> URL? {
        guard case .downloaded(true, _, _, _) = states[mediaId] ?? checked[mediaId] else { return nil }
        return thumbnailFile(mediaId)
    }

    // MARK: - Listing downloads

    /// Every lesson on the phone that has a record and a media file, newest download first.
    /// Favorites and lessons that left the list alike; downloads are never deleted automatically.
    func downloadedItems() -> [DownloadedItem] {
        // Read so views re-draw when downloads change.
        _ = states.count
        _ = revision
        if let cachedItems { return cachedItems }
        var items: [DownloadedItem] = []
        let names = (try? files.contentsOfDirectory(atPath: mediaDirectory.path(percentEncoded: false))) ?? []
        for name in names {
            guard let match = name.wholeMatch(of: /media-(\d+)\.meta\.json/),
                  let mediaId = Int(match.1),
                  let record = readRecord(mediaId),
                  exists(mediaFile(mediaId, record.fileUrl)) else { continue }
            items.append(DownloadedItem(mediaId: mediaId, record: record))
        }
        items.sort { ($0.record.downloadedAt ?? 0) > ($1.record.downloadedAt ?? 0) }
        cachedItems = items
        return items
    }

    /// A downloaded lesson's saved details, or nil if it isn't on the phone or has no record.
    func downloadDetails(mediaId: Int) -> DownloadRecord? {
        readRecord(mediaId)
    }
}

/// The transcript couldn't be saved, so the download stopped before the media.
nonisolated struct TranscriptDownloadError: LocalizedError {
    let reason: String
    let underlying: (any Error)?

    var errorDescription: String? { "Couldn't download the transcript: \(reason)" }
}
