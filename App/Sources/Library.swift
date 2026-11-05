import AppKit
import Foundation
import Observation

/// On-disk store: `~/Library/Application Support/BaconMinutes/minutes/<uuid>/`
/// with `meta.json`, `transcript.json`, `summaries.json` (every summary version), `source.srt`,
/// `thumbs/cover.jpg` and, for media imported into the app, `media/<file name>` (§9.4).
@MainActor
@Observable
final class Library {
    private(set) var minutes: [Minute] = []
    private(set) var folders: [Folder] = []
    private(set) var isLoading = true
    private(set) var thumbnails: [UUID: NSImage] = [:]
    /// Bumped when the full-text search index gains entries.
    private(set) var searchIndexVersion = 0

    let root: URL
    @ObservationIgnored private var searchIndex: [UUID: [UInt16]] = [:]
    @ObservationIgnored private var indexing = false

    init() {
        root = AppPaths.support.appendingPathComponent("minutes", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: Paths & coding

    nonisolated static func folder(root: URL, id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func folder(_ id: UUID) -> URL { Self.folder(root: root, id: id) }

    /// Where media imported into the app is kept.
    func mediaDirectory(_ id: UUID) -> URL { folder(id).appendingPathComponent("media", isDirectory: true) }

    /// The in-app copy of an imported minute's media.
    func importedMediaURL(_ m: Minute) -> URL { mediaDirectory(m.id).appendingPathComponent(m.mediaFileName) }

    nonisolated static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    nonisolated static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try Self.encoder().encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("BaconMinutes: failed to write \(url.lastPathComponent): \(error)")
        }
    }

    // MARK: Loading

    func load() async {
        let root = self.root
        let loaded = await Task.detached(priority: .userInitiated) { () -> [(Minute, Data?)] in
            Library.readAll(root: root)
        }.value
        minutes = loaded.map { $0.0 }
        var thumbs: [UUID: NSImage] = [:]
        for (m, data) in loaded {
            if let data, let img = NSImage(data: data) { thumbs[m.id] = img }
        }
        thumbnails = thumbs
        folders = Self.readFolders(url: foldersURL)
        isLoading = false
        backfillMediaSizes()
    }

    // MARK: Folders

    private var foldersURL: URL { root.deletingLastPathComponent().appendingPathComponent("folders.json") }

    nonisolated static func readFolders(url: URL) -> [Folder] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? decoder().decode([Folder].self, from: data)) ?? []
    }

    private func saveFolders() {
        write(folders, to: foldersURL)
    }

    func userFolder(_ id: UUID) -> Folder? { folders.first { $0.id == id } }

    @discardableResult
    func createFolder(named name: String) -> Folder {
        let f = Folder(name: name)
        folders.append(f)
        saveFolders()
        return f
    }

    func renameFolder(_ id: UUID, to name: String) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[i].name = name
        saveFolders()
    }

    /// Removes the folder; its minutes stay in the library, just unfiled.
    func deleteFolder(_ id: UUID) {
        folders.removeAll { $0.id == id }
        saveFolders()
        for m in minutes where m.folderID == id {
            update(m.id) { $0.folderID = nil }
        }
    }

    func move(_ ids: Set<UUID>, toFolder folderID: UUID?) {
        for id in ids { update(id) { $0.folderID = folderID } }
    }

    // MARK: Stats

    struct Stats {
        var count = 0
        var duration: Double = 0
        var bytes: Int64 = 0
    }

    /// Count, total duration and total media size of minutes that are not in the trash.
    func stats(inFolder folderID: UUID? = nil) -> Stats {
        var s = Stats()
        for m in minutes where m.deletedAt == nil && (folderID == nil || m.folderID == folderID) {
            s.count += 1
            s.duration += m.duration
            s.bytes += m.mediaSize ?? 0
        }
        return s
    }

    nonisolated static func fileSize(of url: URL) -> Int64? {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize { return Int64(size) }
        return nil
    }

    /// Minutes imported before sizes were recorded get their media size measured once.
    private func backfillMediaSizes() {
        let missing = minutes.filter { $0.mediaSize == nil && $0.storage == .linked }.map { ($0.id, $0.mediaBookmark) }
        guard !missing.isEmpty else { return }
        Task {
            let sizes = await Task.detached(priority: .utility) { () -> [UUID: Int64] in
                var out: [UUID: Int64] = [:]
                for (id, bookmark) in missing {
                    // Never mounts a network volume; offline files are just skipped.
                    guard let resolved = Bookmarks.resolve(bookmark, allowMounting: false) else { continue }
                    let access = ScopedAccess(url: resolved.url)
                    if let size = Library.fileSize(of: resolved.url) { out[id] = size }
                    access.stop()
                }
                return out
            }.value
            for (id, size) in sizes { update(id) { $0.mediaSize = size } }
        }
    }

    /// Reads every minute. Trash is kept until the user deletes it.
    nonisolated static func readAll(root: URL) -> [(Minute, Data?)] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles]) else { return [] }
        let decoder = Self.decoder()
        var out: [(Minute, Data?)] = []
        for dir in dirs {
            let metaURL = dir.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let minute = try? decoder.decode(Minute.self, from: data) else { continue }
            let thumb = try? Data(contentsOf: dir.appendingPathComponent("thumbs/cover.jpg"))
            out.append((minute, thumb))
        }
        return out
    }

    // MARK: Minutes

    func minute(_ id: UUID) -> Minute? { minutes.first { $0.id == id } }

    func save(_ minute: Minute) {
        if let i = minutes.firstIndex(where: { $0.id == minute.id }) {
            minutes[i] = minute
        } else {
            minutes.append(minute)
        }
        write(minute, to: folder(minute.id).appendingPathComponent("meta.json"))
    }

    func update(_ id: UUID, _ change: (inout Minute) -> Void) {
        guard var m = minute(id) else { return }
        change(&m)
        save(m)
    }

    func moveToTrash(_ ids: Set<UUID>) {
        let now = Date()
        for id in ids { update(id) { $0.deletedAt = now } }
    }

    func restore(_ ids: Set<UUID>) {
        for id in ids { update(id) { $0.deletedAt = nil } }
    }

    func deletePermanently(_ ids: Set<UUID>) {
        for id in ids {
            try? FileManager.default.removeItem(at: folder(id))
            thumbnails[id] = nil
            searchIndex[id] = nil
        }
        minutes.removeAll { ids.contains($0.id) }
    }

    // MARK: Transcript & summary

    func loadTranscript(_ id: UUID) -> Transcript? {
        guard let data = try? Data(contentsOf: folder(id).appendingPathComponent("transcript.json")) else { return nil }
        return try? Self.decoder().decode(Transcript.self, from: data)
    }

    func saveTranscript(_ transcript: Transcript, id: UUID) {
        write(transcript, to: folder(id).appendingPathComponent("transcript.json"))
        searchIndex[id] = nil
    }

    func saveSourceSRT(_ data: Data, id: UUID) {
        let url = folder(id).appendingPathComponent("source.srt")
        try? FileManager.default.createDirectory(at: folder(id), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Every summary version, oldest first. A single `summary.json` from older builds is
    /// moved into the list the first time it is read.
    func loadSummaries(_ id: UUID) -> [Summary] {
        let dir = folder(id)
        let listURL = dir.appendingPathComponent("summaries.json")
        if let data = try? Data(contentsOf: listURL) {
            return (try? Self.decoder().decode([Summary].self, from: data)) ?? []
        }
        let legacyURL = dir.appendingPathComponent("summary.json")
        guard let data = try? Data(contentsOf: legacyURL),
              let old = try? Self.decoder().decode(Summary.self, from: data) else { return [] }
        write([old], to: listURL)
        try? FileManager.default.removeItem(at: legacyURL)
        return [old]
    }

    func saveSummaries(_ list: [Summary], id: UUID) {
        let url = folder(id).appendingPathComponent("summaries.json")
        if list.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            write(list, to: url)
        }
    }

    /// Adds a version and makes it the one shown. Returns the full list, or nil when the minute
    /// no longer exists (deleted while its summary was being generated).
    @discardableResult
    func appendSummary(_ s: Summary, to id: UUID) -> [Summary]? {
        guard minute(id) != nil else { return nil }
        var list = loadSummaries(id)
        list.append(s)
        saveSummaries(list, id: id)
        return list
    }

    // MARK: Thumbnails

    func setThumbnail(_ jpeg: Data, id: UUID) {
        let url = folder(id).appendingPathComponent("thumbs/cover.jpg")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? jpeg.write(to: url, options: .atomic)
        thumbnails[id] = NSImage(data: jpeg)
    }

    // MARK: Full-text search (§9.5 suggestion)

    func searchText(_ id: UUID) -> [UInt16]? { searchIndex[id] }

    /// Builds the folded transcript text of every minute in the background.
    func ensureSearchIndex() {
        guard !indexing else { return }
        let missing = minutes.map(\.id).filter { searchIndex[$0] == nil }
        guard !missing.isEmpty else { return }
        indexing = true
        let root = self.root
        Task {
            let built = await Task.detached(priority: .utility) { () -> [UUID: [UInt16]] in
                var out: [UUID: [UInt16]] = [:]
                let decoder = Library.decoder()
                for id in missing {
                    let url = Library.folder(root: root, id: id).appendingPathComponent("transcript.json")
                    if let data = try? Data(contentsOf: url), let t = try? decoder.decode(Transcript.self, from: data) {
                        out[id] = TextFold.fold(t.cues.map(\.text).joined(separator: "\n"))
                    } else {
                        out[id] = []
                    }
                }
                return out
            }.value
            for (id, text) in built { searchIndex[id] = text }
            indexing = false
            searchIndexVersion += 1
        }
    }
}
