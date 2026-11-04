import AppKit
import Foundation
import Observation
import SwiftUI

enum Route: Equatable {
    case list
    case detail(UUID)
}

enum ListSection: String, CaseIterable, Identifiable {
    case all, recent, trash
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return L("全部")
        case .recent: return L("最近打开")
        case .trash: return L("回收站")
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

/// What the list page shows: a fixed section or one user folder.
enum ListScope: Hashable {
    case all, recent, trash
    case folder(UUID)
}

extension ListSection {
    var scope: ListScope {
        switch self {
        case .all: return .all
        case .recent: return .recent
        case .trash: return .trash
        }
    }
}

/// A confirmation shown as an in-app dialog (Feishu style) instead of an NSAlert.
struct ConfirmRequest: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var confirmTitle: String
    var cancelTitle = L("取消")
    /// Shown in bold under the message (e.g. that the original media file is kept).
    var emphasis: String? = nil
    var onConfirm: () -> Void
}

enum ListSort: String, CaseIterable, Identifiable {
    case created, opened
    var id: String { rawValue }

    var title: String {
        switch self {
        case .created: return L("最近创建")
        case .opened: return L("最近打开")
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
    var section: ListScope = .all
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

    var confirmRequest: ConfirmRequest?
    /// Minutes being moved with the "移动到文件夹" dialog.
    var moveTarget: Set<UUID>?
    /// Folder whose properties dialog is open.
    var folderInfoTarget: UUID?
    /// Folder whose name is being edited inline in the sidebar.
    var renamingFolderID: UUID?

    var isDialogOpen: Bool { confirmRequest != nil || moveTarget != nil || folderInfoTarget != nil }

    @ObservationIgnored weak var mainWindow: NSWindow?
    /// Traffic-light buttons are hidden in full screen, so top bars can start at the left edge.
    var isWindowFullScreen = false
    @ObservationIgnored private var fullScreenObservers: [NSObjectProtocol] = []
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

    func attachWindow(_ window: NSWindow?) {
        guard let window, window !== mainWindow else { return }
        mainWindow = window
        isWindowFullScreen = window.styleMask.contains(.fullScreen)
        for o in fullScreenObservers { NotificationCenter.default.removeObserver(o) }
        let center = NotificationCenter.default
        fullScreenObservers = [
            center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isWindowFullScreen = true }
            },
            center.addObserver(forName: NSWindow.willExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isWindowFullScreen = false }
            },
        ]
    }

    // MARK: Navigation

    func open(_ id: UUID) {
        guard var m = library.minute(id), m.deletedAt == nil else { return }
        detail?.close()
        m.lastOpenedAt = Date()
        library.save(m)
        let d = DetailModel(minute: m, app: self)
        selection = []
        withAnimation(.easeOut(duration: 0.22)) {
            detail = d
            route = .detail(id)
        }
        // Let the transition start before the transcript is parsed and laid out.
        Task {
            try? await Task.sleep(nanoseconds: 70_000_000)
            d.start()
        }
    }

    func backToList() {
        guard let d = detail else { return }
        if d.isVideoFullscreen { d.setFullscreen(false) }
        d.close()
        withAnimation(.easeOut(duration: 0.18)) {
            detail = nil
            route = .list
        }
    }

    // MARK: Folders

    var currentFolderID: UUID? {
        if case .folder(let id) = section { return id }
        return nil
    }

    var sectionTitle: String {
        switch section {
        case .all: return L("全部")
        case .recent: return L("最近打开")
        case .trash: return L("回收站")
        case .folder(let id): return library.userFolder(id)?.name ?? L("文件夹")
        }
    }

    func createFolder() {
        var name = L("新建文件夹")
        var n = 2
        let names = Set(library.folders.map(\.name))
        while names.contains(name) {
            name = L("新建文件夹 {0}", n)
            n += 1
        }
        let f = library.createFolder(named: name)
        section = .folder(f.id)
        selection = []
        renamingFolderID = f.id
    }

    func renameFolder(_ id: UUID, to name: String) {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { library.renameFolder(id, to: t) }
        if renamingFolderID == id { renamingFolderID = nil }
    }

    func requestDeleteFolder(_ id: UUID) {
        guard let f = library.userFolder(id) else { return }
        let count = library.stats(inFolder: id).count
        confirmRequest = ConfirmRequest(
            title: L("删除文件夹「{0}」？", f.name),
            message: count > 0 ? L("文件夹里的 {0} 个妙记不会被删除，仍会保留在「全部」中。", count) : L("这个文件夹是空的。"),
            confirmTitle: L("删除文件夹")
        ) { [weak self] in
            guard let self else { return }
            if self.section == .folder(id) { self.section = .all }
            self.library.deleteFolder(id)
            self.showToast(L("已删除文件夹"))
        }
    }

    func moveMinutes(_ ids: Set<UUID>, toFolder folderID: UUID?) {
        let valid = ids.filter { library.minute($0) != nil }
        guard !valid.isEmpty else { return }
        library.move(valid, toFolder: folderID)
        if let folderID, let f = library.userFolder(folderID) {
            showToast(valid.count == 1 ? L("已移动到「{0}」", f.name) : L("已将 {0} 项移动到「{1}」", valid.count, f.name))
        } else {
            showToast(L("已移出文件夹"))
        }
        selection.subtract(valid)
    }

    func importIntoFolder(_ id: UUID) {
        section = .folder(id)
        presentImportDialog()
    }

    static func byteText(_ bytes: Int64) -> String {
        bytes > 0 ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : "—"
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
        case .folder(let id):
            items = items.filter { $0.deletedAt == nil && $0.folderID == id }
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
        case .all, .folder:
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

    /// Asks first (§ user request: deleting needs a confirmation dialog).
    func requestMoveToTrash(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let title: String
        if ids.count == 1, let id = ids.first, let m = library.minute(id) {
            title = L("将「{0}」移到回收站？", m.title)
        } else {
            title = L("将 {0} 个妙记移到回收站？", ids.count)
        }
        confirmRequest = ConfirmRequest(title: title, message: L("移到回收站后可以随时恢复。"),
                                        confirmTitle: L("移到回收站"), emphasis: L("原始媒体文件不会被删除。")) { [weak self] in
            self?.moveToTrash(ids)
        }
    }

    func moveToTrash(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        if let d = detail, ids.contains(d.minute.id) { backToList() }
        library.moveToTrash(ids)
        selection.subtract(ids)
        showToast(ids.count == 1 ? L("已移到回收站") : L("已将 {0} 项移到回收站", ids.count))
    }

    func restore(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        library.restore(ids)
        selection.subtract(ids)
        showToast(L("已恢复"))
    }

    func deleteForever(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        confirmRequest = ConfirmRequest(title: ids.count == 1 ? L("彻底删除这个妙记？") : L("彻底删除 {0} 个妙记？", ids.count),
                                        message: L("删除后妙记的文字记录和纪要无法恢复。"),
                                        confirmTitle: L("彻底删除"), emphasis: L("原始媒体文件不会被删除。")) { [weak self] in
            guard let self else { return }
            self.library.deletePermanently(ids)
            self.selection.subtract(ids)
        }
    }

    func revealMedia(_ id: UUID) {
        guard let m = library.minute(id), let r = Bookmarks.resolve(m.mediaBookmark) else {
            Alerts.error(L("找不到媒体文件"), L("文件可能已被移动或删除。打开妙记后可以「重新定位」。"))
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
            Alerts.error(L("无法导入字幕"), error.localizedDescription)
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
                Alerts.info(L("请同时选择音视频文件"), L("字幕需要与对应的音视频一起导入。"))
            } else if !files.isEmpty || !urls.isEmpty {
                Alerts.info(L("没有可导入的文件"), L("支持的媒体：mp4 / mov / m4v / mp3 / m4a / wav / aac；字幕：srt。"))
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
                let use = Alerts.confirm(L("使用「{0}」作为字幕？", s.subtitle.lastPathComponent),
                                         L("没有找到与「{0}」同名的 SRT，同一文件夹中只有这一个字幕文件。", s.media.lastPathComponent),
                                         ok: L("使用"), cancel: L("不使用"))
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
                Alerts.info(L("有 {0} 个字幕未能配对", leftovers.count),
                            L("{0}\n\n可以打开对应的妙记，在「··· → 重新导入 SRT」或文字记录空状态中手动指定。", names))
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
        let targetFolder = currentFolderID
        isImporting = true
        defer { isImporting = false }
        var created: [(Minute, Transcript?)] = []
        var failures: [String] = []
        for pair in pairs {
            do {
                created.append(try await createMinute(media: pair.media, subtitle: pair.subtitle, folderID: targetFolder))
            } catch {
                failures.append(L("{0}：{1}", pair.media.lastPathComponent, error.localizedDescription))
            }
        }
        if section == .trash { section = .all }
        if created.count == 1, let first = created.first {
            let (m, tr) = first
            if let tr {
                showToast(Self.importSummaryText(transcript: tr, duration: m.duration))
            } else {
                showToast(L("已导入「{0}」，时长 {1}", m.title, TimeFormat.compactDuration(m.duration)))
            }
        } else if created.count > 1 {
            showToast(L("已导入 {0} 个妙记", created.count))
        }
        if !failures.isEmpty {
            Alerts.error(L("部分文件导入失败"), failures.joined(separator: "\n"))
        }
    }

    struct ImportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func createMinute(media: URL, subtitle: URL?, folderID: UUID?) async throws -> (Minute, Transcript?) {
        let access = ScopedAccess(url: media)
        defer { access.stop() }
        guard let bookmark = Bookmarks.make(for: media) else {
            throw ImportError(message: L("无法访问该文件"))
        }
        let info: MediaInspector.Info
        do {
            info = try await MediaInspector.inspect(url: media)
        } catch {
            throw ImportError(message: L("无法读取媒体：{0}", error.localizedDescription))
        }
        let baseName = media.deletingPathExtension().lastPathComponent
        let title = FilePairing.normalizedTitle(baseName, suffixes: settings.general.filenameSuffixes)
        let now = Date()
        let createdAt = FilePairing.dateFromFileName(baseName, fallback: now) ?? now
        var minute = Minute(title: title, createdAt: createdAt, duration: info.duration, mediaBookmark: bookmark,
                            mediaPath: media.path, mediaFileName: media.lastPathComponent, isAudioOnly: !info.hasVideo)
        minute.folderID = folderID
        minute.mediaSize = Library.fileSize(of: media)
        library.save(minute)

        var transcript: Transcript?
        if let subtitle {
            do {
                transcript = try attachSRT(subtitle, toMinute: minute.id).0
                if let m = library.minute(minute.id) { minute = m }
            } catch {
                Alerts.error(L("字幕「{0}」解析失败", subtitle.lastPathComponent), error.localizedDescription)
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
        return L("已导入 {0} 条字幕，{1} 位发言人，时长 {2}", transcript.cues.count, transcript.speakers.count, TimeFormat.compactDuration(d))
    }

    // MARK: Keyboard (§11)

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let window = event.window, window === mainWindow else { return false }
        if window.attachedSheet != nil || showImportDialog || isDialogOpen { return false }
        let editing = KeyMonitor.isEditingText(in: window)
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad, .capsLock])
        let code = event.keyCode

        if let d = detail {
            switch code {
            case 53: // Esc
                if d.isVideoFullscreen { d.setFullscreen(false); return true }
                // Leave Esc to a text field being edited (e.g. the title, which it restores).
                if editing && !d.searchFieldFocused { return false }
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
            requestMoveToTrash(selection)
            return true
        }
        return false
    }
}
