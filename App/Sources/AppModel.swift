import AppKit
import Foundation
import Observation

enum Route: Equatable {
    case list
    case detail(UUID)
}

enum ListSection: String, CaseIterable, Identifiable {
    case all, recent, trash
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .recent: return "最近打开"
        case .trash: return "回收站"
        }
    }

    var icon: String {
        switch self {
        case .all: return "house"
        case .recent: return "clock"
        case .trash: return "trash"
        }
    }
}

enum ListSort: String, CaseIterable, Identifiable {
    case created, opened
    var id: String { rawValue }

    var title: String {
        switch self {
        case .created: return "最近创建"
        case .opened: return "最近打开"
        }
    }
}

struct ImportDraft: Equatable {
    var media: URL?
    var subtitle: URL?
}

@MainActor
@Observable
final class AppModel {
    let settings: AppSettings
    let library: Library

    var route: Route = .list
    var section: ListSection = .all
    var sort: ListSort = .created
    var listQuery = ""
    var selection: Set<UUID> = []
    private(set) var detail: DetailModel?

    var toast: String?
    var showImportDialog = false
    var importDraft = ImportDraft()
    var isImporting = false
    var listSearchFocusToken = 0

    var renameTarget: UUID?
    var renameText = ""

    @ObservationIgnored weak var mainWindow: NSWindow?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    private let keyMonitor: KeyMonitor
    @ObservationIgnored private var terminateObserver: NSObjectProtocol?

    init() {
        settings = AppSettings()
        library = Library()
        keyMonitor = KeyMonitor()
        keyMonitor.handler = { [weak self] event in self?.handleKey(event) ?? false }
        keyMonitor.start()
        terminateObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                   object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.detail?.persistPosition()
            }
        }
        Task { await library.load() }
    }

    // MARK: Navigation

    func open(_ id: UUID) {
        guard var m = library.minute(id), m.deletedAt == nil else { return }
        detail?.close()
        m.lastOpenedAt = Date()
        library.save(m)
        let d = DetailModel(minute: m, app: self)
        detail = d
        route = .detail(id)
        selection = []
        d.start()
    }

    func backToList() {
        guard detail != nil else { return }
        if detail?.isVideoFullscreen == true { detail?.setFullscreen(false) }
        detail?.close()
        detail = nil
        route = .list
    }

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if Task.isCancelled { return }
            self?.toast = nil
        }
    }

    func focusSearch() {
        if let detail {
            detail.focusSearch()
        } else {
            listSearchFocusToken += 1
        }
    }

    // MARK: List data

    var visibleMinutes: [Minute] {
        _ = library.searchIndexVersion
        var items = library.minutes
        switch section {
        case .all:
            items = items.filter { $0.deletedAt == nil }
        case .recent:
            items = items.filter { $0.deletedAt == nil && $0.lastOpenedAt != nil }
        case .trash:
            items = items.filter { $0.deletedAt != nil }
        }
        let q = listQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            let needle = TextFold.fold(q)
            items = items.filter { m in
                if !TextFold.occurrences(of: needle, in: TextFold.fold(m.title)).isEmpty { return true }
                if let text = library.searchText(m.id) { return !TextFold.occurrences(of: needle, in: text).isEmpty }
                return false
            }
        }
        switch section {
        case .trash:
            items.sort { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
        case .recent:
            items.sort { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
        case .all:
            if sort == .opened {
                items.sort { ($0.lastOpenedAt ?? .distantPast, $0.createdAt) > ($1.lastOpenedAt ?? .distantPast, $1.createdAt) }
            } else {
                items.sort { $0.createdAt > $1.createdAt }
            }
        }
        return items
    }

    // MARK: List actions

    func beginRename(_ id: UUID) {
        guard let m = library.minute(id) else { return }
        renameText = m.title
        renameTarget = id
    }

    func commitRename() {
        guard let id = renameTarget else { return }
        let t = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { library.update(id) { $0.title = t } }
        renameTarget = nil
    }

    func moveToTrash(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        if let d = detail, ids.contains(d.minute.id) { backToList() }
        library.moveToTrash(ids)
        selection.subtract(ids)
        showToast(ids.count == 1 ? "已移到回收站" : "已将 \(ids.count) 项移到回收站")
    }

    func restore(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        library.restore(ids)
        selection.subtract(ids)
        showToast("已恢复")
    }

    func deleteForever(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let ok = Alerts.confirm(ids.count == 1 ? "彻底删除这个妙记？" : "彻底删除 \(ids.count) 个妙记？",
                                "删除后无法恢复。原始音视频文件不会被删除。", ok: "彻底删除", destructive: true)
        guard ok else { return }
        library.deletePermanently(ids)
        selection.subtract(ids)
    }

    func revealMedia(_ id: UUID) {
        guard let m = library.minute(id), let r = Bookmarks.resolve(m.mediaBookmark) else {
            Alerts.error("找不到媒体文件", "文件可能已被移动或删除。打开妙记后可以「重新定位」。")
            return
        }
        let access = ScopedAccess(url: r.url)
        FilePanels.reveal(r.url)
        access.stop()
    }

    func reimportSRT(_ id: UUID) {
        guard let url = FilePanels.chooseSRT() else { return }
        do {
            let (tr, _) = try attachSRT(url, toMinute: id)
            showToast(Self.importSummaryText(transcript: tr, duration: library.minute(id)?.duration ?? 0))
        } catch {
            Alerts.error("无法导入字幕", error.localizedDescription)
        }
    }

    // MARK: Import (§9.1)

    func presentImportDialog(prefillSubtitle: URL? = nil) {
        importDraft = ImportDraft(media: nil, subtitle: prefillSubtitle)
        showImportDialog = true
    }

    func importFolder() {
        guard let folder = FilePanels.chooseFolder() else { return }
        importURLs([folder])
    }

    /// Files and/or folders from drag-and-drop or panels; pairs media with SRTs automatically.
    func importURLs(_ urls: [URL]) {
        let files = FilePanels.expand(urls)
        let media = files.filter(MediaTypes.isMedia)
        let subtitles = files.filter(MediaTypes.isSubtitle)

        if media.isEmpty {
            if subtitles.count == 1, let srt = subtitles.first {
                if let d = detail {
                    d.importSRT(from: srt)
                } else {
                    presentImportDialog(prefillSubtitle: srt)
                }
            } else if !subtitles.isEmpty {
                Alerts.info("请同时选择音视频文件", "字幕需要与对应的音视频一起导入。")
            } else if !files.isEmpty || !urls.isEmpty {
                Alerts.info("没有可导入的文件", "支持的媒体：mp4 / mov / m4v / mp3 / m4a / wav / aac；字幕：srt。")
            }
            return
        }

        var pairs: [FilePairing.Pair] = []
        var leftoverSubtitles: [URL] = []
        if media.count == 1 && subtitles.count <= 1 {
            pairs = [FilePairing.Pair(media: media[0], subtitle: subtitles.first)]
        } else {
            let result = FilePairing.pair(media: media, subtitles: subtitles, suffixes: settings.general.filenameSuffixes)
            pairs = result.pairs
            for s in result.suggestions {
                let use = Alerts.confirm("使用「\(s.subtitle.lastPathComponent)」作为字幕？",
                                         "没有找到与「\(s.media.lastPathComponent)」同名的 SRT，同一文件夹中只有这一个字幕文件。",
                                         ok: "使用", cancel: "不使用")
                if use {
                    pairs.append(FilePairing.Pair(media: s.media, subtitle: s.subtitle))
                } else {
                    pairs.append(FilePairing.Pair(media: s.media, subtitle: nil))
                    leftoverSubtitles.append(s.subtitle)
                }
            }
            leftoverSubtitles += result.unmatchedSubtitles
        }
        let leftovers = leftoverSubtitles
        let finalPairs = pairs
        Task {
            await runImport(finalPairs)
            if !leftovers.isEmpty {
                let names = leftovers.map(\.lastPathComponent).joined(separator: "\n")
                Alerts.info("有 \(leftovers.count) 个字幕未能配对",
                            "\(names)\n\n可以打开对应的妙记，在「··· → 重新导入 SRT」或文字记录空状态中手动指定。")
            }
        }
    }

    func importFromDialog() {
        guard let media = importDraft.media else { return }
        let pair = FilePairing.Pair(media: media, subtitle: importDraft.subtitle)
        showImportDialog = false
        Task { await runImport([pair]) }
    }

    private func runImport(_ pairs: [FilePairing.Pair]) async {
        guard !pairs.isEmpty else { return }
        isImporting = true
        defer { isImporting = false }
        var created: [(Minute, Transcript?)] = []
        var failures: [String] = []
        for pair in pairs {
            do {
                created.append(try await createMinute(media: pair.media, subtitle: pair.subtitle))
            } catch {
                failures.append("\(pair.media.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        if section == .trash { section = .all }
        if created.count == 1, let first = created.first {
            let (m, tr) = first
            if let tr {
                showToast(Self.importSummaryText(transcript: tr, duration: m.duration))
            } else {
                showToast("已导入「\(m.title)」，时长 \(TimeFormat.compactDuration(m.duration))")
            }
        } else if created.count > 1 {
            showToast("已导入 \(created.count) 个妙记")
        }
        if !failures.isEmpty {
            Alerts.error("部分文件导入失败", failures.joined(separator: "\n"))
        }
    }

    struct ImportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func createMinute(media: URL, subtitle: URL?) async throws -> (Minute, Transcript?) {
        let access = ScopedAccess(url: media)
        defer { access.stop() }
        guard let bookmark = Bookmarks.make(for: media) else {
            throw ImportError(message: "无法访问该文件")
        }
        let info: MediaInspector.Info
        do {
            info = try await MediaInspector.inspect(url: media)
        } catch {
            throw ImportError(message: "无法读取媒体：\(error.localizedDescription)")
        }
        let baseName = media.deletingPathExtension().lastPathComponent
        let title = FilePairing.normalizedTitle(baseName, suffixes: settings.general.filenameSuffixes)
        let now = Date()
        let createdAt = FilePairing.dateFromFileName(baseName, fallback: now) ?? now
        var minute = Minute(title: title, createdAt: createdAt, duration: info.duration, mediaBookmark: bookmark,
                            mediaPath: media.path, mediaFileName: media.lastPathComponent, isAudioOnly: !info.hasVideo)
        library.save(minute)

        var transcript: Transcript?
        if let subtitle {
            do {
                transcript = try attachSRT(subtitle, toMinute: minute.id).0
                if let m = library.minute(minute.id) { minute = m }
            } catch {
                Alerts.error("字幕「\(subtitle.lastPathComponent)」解析失败", error.localizedDescription)
            }
        }
        if info.hasVideo, let jpeg = await MediaInspector.coverJPEG(url: media, duration: info.duration) {
            library.setThumbnail(jpeg, id: minute.id)
        }
        return (minute, transcript)
    }

    /// Parses an SRT, copies it into the minute folder and updates the minute (§9.2, §9.4).
    /// Speaker names that were renamed before keep their names when the same speaker ids reappear.
    @discardableResult
    func attachSRT(_ url: URL, toMinute id: UUID) throws -> (Transcript, SRTParseResult) {
        let access = ScopedAccess(url: url)
        defer { access.stop() }
        let data = try Data(contentsOf: url)
        var result = try SRTParser.parse(data: data)
        if let old = library.loadTranscript(id) {
            for i in result.speakers.indices {
                if let prev = old.speaker(result.speakers[i].id) {
                    result.speakers[i].name = prev.name
                }
            }
        }
        let transcript = Transcript(cues: result.cues, speakers: result.speakers,
                                    srtFileName: url.lastPathComponent, importedAt: Date())
        library.saveTranscript(transcript, id: id)
        library.saveSourceSRT(data, id: id)
        library.update(id) { m in
            m.srtFileName = url.lastPathComponent
            m.srtBookmark = Bookmarks.make(for: url)
            m.cueCount = transcript.cues.count
            m.speakerCount = transcript.speakers.count
            if m.duration <= 0 { m.duration = transcript.cues.map(\.end).max() ?? 0 }
        }
        return (transcript, result)
    }

    static func importSummaryText(transcript: Transcript, duration: Double) -> String {
        let d = duration > 0 ? duration : (transcript.cues.map(\.end).max() ?? 0)
        return "已导入 \(transcript.cues.count) 条字幕，\(transcript.speakers.count) 位发言人，时长 \(TimeFormat.compactDuration(d))"
    }

    // MARK: Keyboard (§11)

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let window = event.window, window === mainWindow else { return false }
        if window.attachedSheet != nil || showImportDialog { return false }
        let editing = KeyMonitor.isEditingText(in: window)
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad, .capsLock])
        let code = event.keyCode

        if let d = detail {
            switch code {
            case 53: // Esc
                if d.isVideoFullscreen { d.setFullscreen(false); return true }
                if !d.searchQuery.isEmpty { d.clearSearch(); return true }
                return false
            case 36, 76: // Return
                guard mods.isEmpty || mods == .shift else { return false }
                guard !d.searchQuery.isEmpty, !editing || d.searchFieldFocused else { return false }
                if mods == .shift { d.previousHit() } else { d.nextHit() }
                return true
            default:
                break
            }
            guard !editing, mods.isEmpty else { return false }
            switch code {
            case 49: d.player.togglePlay(); return true          // Space
            case 123: d.player.skip(by: -15); return true        // ←
            case 124: d.player.skip(by: 15); return true         // →
            default: return false
            }
        }

        if code == 51, mods == .command, !editing, !selection.isEmpty, section != .trash {
            moveToTrash(selection)
            return true
        }
        return false
    }
}
