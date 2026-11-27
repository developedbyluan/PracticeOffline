import Foundation

/// Downloads one URL to a file, with progress and cancellation.
/// Cancelling the Swift task that awaits it cancels the network download.
nonisolated enum FileDownloader {
    /// Downloads `url` into `destination` (replacing it). `onProgress` gets whole
    /// percentages 0–100, or nil while the server hasn't said how big the file is.
    @concurrent
    static func download(
        from url: URL,
        to destination: URL,
        onProgress: (@Sendable (Int?) -> Void)? = nil
    ) async throws {
        let box = TaskBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let task = URLSession.shared.downloadTask(with: url) { location, response, error in
                    box.finish()
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        continuation.resume(throwing: HTTPStatusError(what: "file", status: http.statusCode))
                        return
                    }
                    guard let location else {
                        continuation.resume(throwing: URLError(.cannotCreateFile))
                        return
                    }
                    // `location` is deleted when this handler returns, so move it now.
                    do {
                        try? FileManager.default.removeItem(at: destination)
                        try FileManager.default.moveItem(at: location, to: destination)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                if let onProgress {
                    box.observe(task.progress, report: onProgress)
                }
                box.start(task)
            }
        } onCancel: {
            box.cancel()
        }
    }
}

/// Holds the running URLSession task so cancelling works from any thread,
/// even if it happens before the task has started.
private nonisolated final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false
    private var observation: NSKeyValueObservation?
    private var lastPercent: Int?? = .none

    func start(_ task: URLSessionTask) {
        lock.lock()
        self.task = task
        let cancelled = self.cancelled
        lock.unlock()
        task.resume()
        if cancelled { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func observe(_ progress: Progress, report: @escaping @Sendable (Int?) -> Void) {
        let observation = progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self] progress, _ in
            let percent: Int? = progress.totalUnitCount > 0
                ? min(100, Int(progress.fractionCompleted * 100))
                : nil
            // Only report when the whole percentage changes.
            guard let self, self.changed(to: percent) else { return }
            report(percent)
        }
        lock.lock()
        self.observation = observation
        lock.unlock()
    }

    func finish() {
        lock.lock()
        let observation = self.observation
        self.observation = nil
        lock.unlock()
        observation?.invalidate()
    }

    private func changed(to percent: Int?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .some(let last) = lastPercent, last == percent { return false }
        lastPercent = .some(percent)
        return true
    }
}
