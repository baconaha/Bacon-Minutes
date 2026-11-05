import Foundation

/// Finds a minute's media without blocking the main thread. Bookmark resolution and file checks
/// run on a background queue with a time limit: once a NAS or other network volume is out of
/// reach, any file-system call on it can hang for a minute or more, which used to freeze the
/// whole app when such a minute was opened.
enum MediaLocator {
    enum Outcome: Sendable {
        /// `bookmark` is a fresh bookmark when the file moved or the old one went stale.
        case found(URL, bookmark: Data?)
        /// Not at its last location (moved, renamed or deleted).
        case missing
        /// The volume did not answer in time.
        case unreachable
    }

    /// Seconds before a silent volume counts as unreachable.
    static let timeout: Double = 4

    /// A linked file. `allowMounting` lets macOS mount the file's network volume first
    /// ("重新检测路径"); opening a minute never does, because mounting can stall too.
    static func locate(bookmark: Data, path: String, allowMounting: Bool) async -> Outcome {
        let key = volumeKey(for: path)
        if Hub.shared.isStuck(key) { return .unreachable }
        return await Hub.shared.run(key: key, timeout: timeout) {
            search(bookmark: bookmark, path: path, allowMounting: allowMounting)
        }
    }

    /// A copy inside the app's library (always on the local disk).
    static func locateLocal(_ url: URL) async -> Outcome {
        await Hub.shared.run(key: url.path, timeout: timeout) {
            isPlayableFile(url) ? .found(url, bookmark: nil) : .missing
        }
    }

    private static func search(bookmark: Data, path: String, allowMounting: Bool) -> Outcome {
        if let resolved = Bookmarks.resolve(bookmark, allowMounting: allowMounting) {
            let url = resolved.url
            let started = url.startAccessingSecurityScopedResource()
            defer { if started { url.stopAccessingSecurityScopedResource() } }
            // A bookmark follows a file into the Trash; treat that as deleted.
            if isPlayableFile(url), !isInTrash(url) {
                let fresh = resolved.isStale || url.path != path ? Bookmarks.make(for: url) : nil
                return .found(url, bookmark: fresh)
            }
        }
        // The bookmark lost track (e.g. the file was copied elsewhere and back): try the path.
        if !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            if isPlayableFile(url) { return .found(url, bookmark: Bookmarks.make(for: url)) }
        }
        return .missing
    }

    static func isPlayableFile(_ url: URL) -> Bool {
        guard (try? url.checkResourceIsReachable()) == true else { return false }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        return values?.isRegularFile ?? false
    }

    static func isInTrash(_ url: URL) -> Bool {
        let p = url.path
        return p.contains("/.Trash/") || p.contains("/.Trashes/")
    }

    /// Files under /Volumes share their volume's key, so one stalled check stands for all of them.
    static func volumeKey(for path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count >= 2, parts[0] == "Volumes" { return "/Volumes/\(parts[1])" }
        return path
    }

    /// Runs checks off the main thread with a deadline. While a check on a volume is overdue,
    /// further checks on it answer "unreachable" at once instead of queueing more stuck threads.
    private final class Hub: @unchecked Sendable {
        static let shared = Hub()
        private let lock = NSLock()
        private var stuck: Set<String> = []
        private let queue = DispatchQueue(label: "BaconMinutes.MediaLocator", qos: .userInitiated, attributes: .concurrent)

        func isStuck(_ key: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return stuck.contains(key)
        }

        private func setStuck(_ key: String, _ on: Bool) {
            lock.lock()
            if on { stuck.insert(key) } else { stuck.remove(key) }
            lock.unlock()
        }

        func run(key: String, timeout: Double, work: @escaping @Sendable () -> Outcome) async -> Outcome {
            await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
                let once = Once()
                queue.async {
                    let result = work()
                    // The volume answered, however late.
                    self.setStuck(key, false)
                    if once.claim() { continuation.resume(returning: result) }
                }
                queue.asyncAfter(deadline: .now() + timeout) {
                    if once.claim() {
                        self.setStuck(key, true)
                        continuation.resume(returning: .unreachable)
                    }
                }
            }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}

/// Copies a media file into the library on a background thread, reporting progress.
enum MediaCopier {
    struct CopyError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// `progress` receives 0…1 on the main actor. A partial copy is removed on failure.
    static func copy(from source: URL, to destination: URL, progress: @escaping @MainActor (Double) -> Void) async throws {
        let total = await Task.detached(priority: .userInitiated) { () -> Int64 in
            Library.fileSize(of: source) ?? 0
        }.value
        let copy = Task.detached(priority: .userInitiated) { () throws -> Void in
            let fm = FileManager.default
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            do {
                try fm.copyItem(at: source, to: destination)
            } catch {
                try? fm.removeItem(at: destination)
                throw error
            }
        }
        let poll = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { return }
                // attributesOfItem, not URL resource values, which are cached per URL.
                let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path)
                let done = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                let fraction = total > 0 ? min(0.99, Double(done) / Double(total)) : 0
                await MainActor.run { progress(fraction) }
            }
        }
        defer { poll.cancel() }
        try await copy.value
        await MainActor.run { progress(1) }
    }
}
