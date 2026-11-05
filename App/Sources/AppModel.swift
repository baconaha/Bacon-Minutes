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
    /// Red confirm button and warning icon; false for a neutral (blue) confirmation.
    var destructive = true
    /// Optional checkbox under the message; when it is ticked, `onConfirmChecked` runs instead.
    var checkbox: String? = nil
    var onConfirmChecked: (() -> Void)? = nil
    var onConfirm: () -> Void
}

enum ListSort: String, CaseIterable, Identifiable {
    case created, opened, name
    var id: String { rawValue }

    /// Menu entry.
    var title: String {
        switch self {
        case .created: return L("最近创建")
        case .opened: return L("最近打开")
        case .name: return L("名称")
        }
    }

    /// Column header while this sort is active.
    var headerTitle: String {
        switch self {
        case .created: return L("创建时间")
        case .opened: return L("最近打开")
        case .name: return L("名称")
        }
    }
}

struct ImportDraft: Equatable {
    var media: URL?
    var subtitle: URL?
    /// Link to the file instead of copying it into the app.
    var linkOnly = false
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
    /// Folders picked with a drag across the sidebar (or ⌘-click), for batch actions.
    var folderSelection: Set<UUID> = []

    /// Batch import waiting for review.
    var importReview: ImportReview?
    var importProgress: ImportProgress?
    /// Media being copied into the app for "导入到应用", with progress 0…1.
    var copyingMedia: [UUID: Double] = [:]

    /// Summary generation per minute; it keeps running when the detail page closes.
    var summaryJobs: [UUID: SummaryJob] = [:]
    @ObservationIgnored var summaryTasks: [UUID: Task<Void, Never>] = [:]
    /// Batch summaries waiting for a free slot.
    @ObservationIgnored var summaryQueue: [QueuedSummary] = []
    /// Minutes picked for "生成纪要" from the list selection.
    var batchSummaryTarget: [UUID]?
    @ObservationIgnored private var importChain: Task<Void, Never>?

    var isDialogOpen: Bool {
        confirmRequest != nil || moveTarget != nil || folderInfoTarget != nil || importReview != nil || batchSummaryTarget != nil
    }

    @ObservationIgnored weak var mainWindow: NSWindow?
    /// Traffic-light buttons are hidden in full screen, so top bars can start at the left edge.
    var isWindowFullScreen = false
    @ObservationIgnored private var fullScreenObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var closeInterceptor: WindowCloseInterceptor?
    @ObservationIgnored private var hideAfterFullScreen = false
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
                self?.detail?.persistState()
            }
        }
        Task { await library.load() }
    }

    func attachWindow(_ window: NSWindow?) {
        guard let window, window !== mainWindow else { return }
        mainWindow = window
        MainWindowRegistry.window = window
        isWindowFullScreen = window.styleMask.contains(.fullScreen)
        // The close button (and ⌘W) only hides the window; the app keeps running, with any
        // summaries still generating, until ⌘Q. Clicking the Dock icon brings it back.
        let interceptor = WindowCloseInterceptor(original: window.delegate) { [weak self] w in
            MainActor.assumeIsolated { self?.hideMainWindow(w) }
        }
        closeInterceptor = interceptor
        window.delegate = interceptor
        for o in fullScreenObservers { NotificationCenter.default.removeObserver(o) }
        let center = NotificationCenter.default
        fullScreenObservers = [
            center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isWindowFullScreen = true }
            },
            center.addObserver(forName: NSWindow.willExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isWindowFullScreen = false }
            },
            center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, self.hideAfterFullScreen else { return }
                    self.hideAfterFullScreen = false
                    (note.object as? NSWindow)?.orderOut(nil)
                }
            },
        ]
    }

    /// Close button: pause playback, keep everything else, and hide the window.
    func hideMainWindow(_ window: NSWindow) {
        if let d = detail {
            d.player.pause()
            d.persistState()
        }
        MainWindowRegistry.hidden = true
        if window.styleMask.contains(.fullScreen) {
            // Hiding a full-screen window leaves an empty Space behind; leave full screen first.
            hideAfterFullScreen = true
            window.toggleFullScreen(nil)
            return
        }
        window.orderOut(nil)
    }

    // MARK: Navigation

    func open(_ id: UUID) {
        guard var m = library.minute(id), m.deletedAt == nil else { return }
        detail?.close()
        m.lastOpenedAt = Date()
        library.save(m)
        let d = DetailModel(minute: m, app: self)
        d.prepare()
        selection = []
        withAnimation(.easeOut(duration: 0.16)) {
            detail = d
            route = .detail(id)
        }
        // Media and the transcript text start once the page has settled, so the fade itself
        // never stalls.
        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            d.start()
        }
    }

    func backToList() {
        guard let d = detail else { return }
        if d.isVideoFullscreen { d.setFullscreen(false) }
        d.close()
        withAnimation(.easeOut(duration: 0.16)) {
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
        folderSelection = []
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
            confirmTitle: L("删除文件夹"),
            checkbox: count > 0 ? L("同时删除文件夹内的 {0} 个妙记", count) : nil,
            onConfirmChecked: { [weak self] in self?.requestDeleteFoldersWithMinutes([id]) }
        ) { [weak self] in
            guard let self else { return }
            if self.section == .folder(id) { self.section = .all }
            self.library.deleteFolder(id)
            self.folderSelection.remove(id)
            self.showToast(L("已删除文件夹"))
        }
    }

    /// Several folders at once (sidebar drag-select); one folder uses the single-folder wording.
    func requestDeleteFolders(_ ids: Set<UUID>) {
        let targets = library.folders.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return }
        if targets.count == 1 {
            requestDeleteFolder(targets[0].id)
            return
        }
        let count = targets.reduce(0) { $0 + library.stats(inFolder: $1.id).count }
        confirmRequest = ConfirmRequest(
            title: L("删除 {0} 个文件夹？", targets.count),
            message: count > 0 ? L("这些文件夹里的 {0} 个妙记不会被删除，仍会保留在「全部」中。", count) : L("这些文件夹都是空的。"),
            confirmTitle: L("删除文件夹"),
            checkbox: count > 0 ? L("同时删除文件夹内的 {0} 个妙记", count) : nil,
            onConfirmChecked: { [weak self] in self?.requestDeleteFoldersWithMinutes(Set(targets.map(\.id))) }
        ) { [weak self] in
            self?.deleteFolders(Set(targets.map(\.id)))
        }
    }

    private func deleteFolders(_ ids: Set<UUID>) {
        let targets = library.folders.filter { ids.contains($0.id) }
        if case .folder(let current) = section, ids.contains(current) { section = .all }
        for f in targets { library.deleteFolder(f.id) }
        folderSelection.subtract(ids)
        showToast(targets.count == 1 ? L("已删除文件夹") : L("已删除 {0} 个文件夹", targets.count))
    }

    /// Second step after "同时删除文件夹内的妙记": the same confirmation as deleting minutes.
    private func requestDeleteFoldersWithMinutes(_ folderIDs: Set<UUID>) {
        let targets = library.folders.filter { folderIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        let minuteIDs = Set(library.minutes.filter { m in
            m.deletedAt == nil && m.folderID.map { folderIDs.contains($0) } == true
        }.map(\.id))
        let title = targets.count == 1
            ? L("删除文件夹「{0}」，并将其中 {1} 个妙记移到回收站？", targets[0].name, minuteIDs.count)
            : L("删除 {0} 个文件夹，并将其中 {1} 个妙记移到回收站？", targets.count, minuteIDs.count)
        confirmRequest = ConfirmRequest(title: title, message: L("移到回收站后可以随时恢复。"),
                                        confirmTitle: L("删除并移到回收站"),
                                        emphasis: sourceFileNote(minuteIDs, forever: false)) { [weak self] in
            guard let self else { return }
            self.moveToTrash(minuteIDs)
            self.deleteFolders(folderIDs)
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
            switch sort {
            case .opened:
                items.sort { ($0.lastOpenedAt ?? .distantPast, $0.createdAt) > ($1.lastOpenedAt ?? .distantPast, $1.createdAt) }
            case .created:
                items.sort { $0.createdAt > $1.createdAt }
            case .name:
                // Finder order: "第2讲" before "第10讲", case and width ignored.
                items.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
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
                                        confirmTitle: L("移到回收站"), emphasis: sourceFileNote(ids, forever: false)) { [weak self] in
            self?.moveToTrash(ids)
        }
    }

    /// What happens to the media files: copies inside the app go with the minute, linked
    /// originals are never touched.
    func sourceFileNote(_ ids: Set<UUID>, forever: Bool) -> String {
        let ms = ids.compactMap { library.minute($0) }
        let imported = ms.filter { $0.storage == .imported }.count
        let linked = ms.count - imported
        if imported == 0 { return L("只删除妙记，链接的原始媒体文件不会被删除。") }
        if forever {
            if linked == 0 {
                return ms.count == 1 ? L("这个妙记的源文件保存在应用内，会和妙记一起删除。")
                                     : L("这些妙记的源文件保存在应用内，会和妙记一起删除。")
            }
            return L("其中 {0} 个妙记的源文件保存在应用内，会一起删除；另外 {1} 个只链接了路径，原始媒体文件不会被删除。", imported, linked)
        }
        if linked == 0 {
            return ms.count == 1 ? L("这个妙记的源文件保存在应用内，在回收站彻底删除时会一起删除。")
                                 : L("这些妙记的源文件保存在应用内，在回收站彻底删除时会一起删除。")
        }
        return L("其中 {0} 个妙记的源文件保存在应用内，彻底删除时会一起删除；另外 {1} 个只链接了路径，原始媒体文件不会被删除。", imported, linked)
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
                                        confirmTitle: L("彻底删除"), emphasis: sourceFileNote(ids, forever: true)) { [weak self] in
            guard let self else { return }
            for id in ids { self.cancelSummary(id) }
            self.library.deletePermanently(ids)
            self.selection.subtract(ids)
        }
    }

    /// Finder never mounts or waits on an unreachable volume from here.
    func revealMedia(_ id: UUID) {
        guard let m = library.minute(id) else { return }
        Task {
            let outcome: MediaLocator.Outcome
            if m.storage == .imported {
                outcome = await MediaLocator.locateLocal(library.importedMediaURL(m))
            } else {
                outcome = await MediaLocator.locate(bookmark: m.mediaBookmark, path: m.mediaPath, allowMounting: false)
            }
            switch outcome {
            case .found(let url, _):
                let access = ScopedAccess(url: url)
                FilePanels.reveal(url)
                access.stop()
            case .missing:
                Alerts.error(L("找不到媒体文件"), L("文件可能已被移动或删除。打开妙记后可以「重新检测路径」或「重新定位」。"))
            case .unreachable:
                Alerts.error(L("无法访问源文件所在位置"), L("所在的磁盘或网络位置（如 NAS）暂时没有响应。"))
            }
        }
    }

    // MARK: Import into the app

    /// Copies a linked minute's media into the app. One way: it cannot become a link again.
    func requestImportIntoApp(_ id: UUID) {
        guard let m = library.minute(id), m.storage == .linked else { return }
        let size = (m.mediaSize ?? 0) > 0 ? L("（{0}）", AppModel.byteText(m.mediaSize ?? 0)) : ""
        confirmRequest = ConfirmRequest(
            title: L("将「{0}」的源文件导入应用？", m.title),
            message: L("会把源文件复制一份{0}保存在应用内。之后原文件移动、改名，或所在的磁盘、NAS 断开，都不影响播放。", size),
            confirmTitle: L("导入到应用"),
            emphasis: L("导入后不能再改回链接路径，只能连同妙记一起删除。"),
            destructive: false
        ) { [weak self] in
            self?.importIntoApp(id)
        }
    }

    private func importIntoApp(_ id: UUID) {
        guard let m = library.minute(id), m.storage == .linked, copyingMedia[id] == nil else { return }
        copyingMedia[id] = 0
        Task {
            let outcome = await MediaLocator.locate(bookmark: m.mediaBookmark, path: m.mediaPath, allowMounting: true)
            guard case .found(let url, _) = outcome else {
                copyingMedia[id] = nil
                Alerts.error(L("找不到源文件"), L("请先在妙记里「重新检测路径」或「重新定位」，再导入应用。"))
                return
            }
            let access = ScopedAccess(url: url)
            defer { access.stop() }
            let dest = library.mediaDirectory(id).appendingPathComponent(url.lastPathComponent)
            do {
                try await MediaCopier.copy(from: url, to: dest) { [weak self] p in
                    if self?.copyingMedia[id] != nil { self?.copyingMedia[id] = p }
                }
                copyingMedia[id] = nil
                guard library.minute(id) != nil else {
                    try? FileManager.default.removeItem(at: dest)
                    return
                }
                library.update(id) { m in
                    m.storage = .imported
                    m.mediaPath = dest.path
                    m.mediaFileName = dest.lastPathComponent
                    m.mediaBookmark = Data()
                    if m.mediaSize == nil { m.mediaSize = Library.fileSize(of: dest) }
                }
                if let d = detail, d.minute.id == id { d.mediaMovedIntoApp() }
                showToast(L("已将源文件导入应用"))
            } catch {
                copyingMedia[id] = nil
                Alerts.error(L("导入应用失败"), error.localizedDescription)
            }
        }
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

    /// Files and/or folders from drag-and-drop or panels. Media is paired with SRTs and shown
    /// in the review dialog before anything is imported.
    func importURLs(_ urls: [URL]) {
        let files = FilePanels.expand(urls)
        let summaryFiles = files.filter(MediaTypes.isSummaryFile)
        let media = files.filter(MediaTypes.isMedia)
        let subtitles = files.filter(MediaTypes.isSubtitle)
        let unsupported = files.filter(MediaTypes.isUnsupported)

        if !summaryFiles.isEmpty {
            importSummaryFiles(summaryFiles)
            if media.isEmpty { return }
        }

        if media.isEmpty {
            if subtitles.count == 1, let srt = subtitles.first {
                if let d = detail {
                    d.importSRT(from: srt)
                } else {
                    presentImportDialog(prefillSubtitle: srt)
                }
            } else if !subtitles.isEmpty {
                Alerts.info(L("请同时选择音视频文件"), L("字幕需要与对应的音视频一起导入。"))
            } else if !unsupported.isEmpty {
                Alerts.info(L("没有可导入的文件"),
                            L("这些文件的格式不受支持：{0}\n\n支持的媒体：mp4 / mov / m4v / mp3 / m4a / wav / aac；字幕：srt。",
                              unsupported.prefix(5).map(\.lastPathComponent).joined(separator: "\n")))
            } else if !files.isEmpty || !urls.isEmpty {
                Alerts.info(L("没有可导入的文件"), L("支持的媒体：mp4 / mov / m4v / mp3 / m4a / wav / aac；字幕：srt。"))
            }
            return
        }

        let suffixes = settings.general.filenameSuffixes
        var rows: [ImportReviewRow] = []
        if media.count == 1 && subtitles.count <= 1 {
            let m = media[0]
            let guessed = subtitles.first.map {
                FilePairing.pairingKey($0, suffixes: suffixes) != FilePairing.pairingKey(m, suffixes: suffixes)
            } ?? false
            rows = [ImportReviewRow(media: m, subtitle: subtitles.first, guessed: guessed,
                                    hasVideo: MediaTypes.kind(of: m) == .video)]
        } else {
            let result = FilePairing.pair(media: media, subtitles: subtitles, suffixes: suffixes)
            rows = result.pairs.map {
                ImportReviewRow(media: $0.media, subtitle: $0.subtitle, hasVideo: MediaTypes.kind(of: $0.media) == .video)
            }
            rows += result.suggestions.map {
                ImportReviewRow(media: $0.media, subtitle: $0.subtitle, guessed: true,
                                hasVideo: MediaTypes.kind(of: $0.media) == .video)
            }
            rows.sort { $0.media.path.localizedStandardCompare($1.media.path) == .orderedAscending }
        }
        var sourceName: String?
        if urls.count == 1, let only = urls.first {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: only.path, isDirectory: &isDir), isDir.boolValue {
                sourceName = only.lastPathComponent
            }
        }
        let review = ImportReview(rows: rows, subtitles: subtitles, skipped: unsupported, sourceName: sourceName,
                                  folderID: currentFolderID)
        importReview = review
        review.loadDetails()
    }

    /// "导入" in the review dialog.
    func confirmImportReview(_ review: ImportReview) {
        let items = review.includedRows.map { ImportItem(media: $0.media, subtitle: $0.subtitle, cover: $0.thumbnailJPEG) }
        let storage: MediaStorage = review.linkOnly ? .linked : .imported
        enqueueImport(items, storage: storage, folderID: review.folderID)
    }

    func importFromDialog() {
        guard let media = importDraft.media else { return }
        let item = ImportItem(media: media, subtitle: importDraft.subtitle, cover: nil)
        let storage: MediaStorage = importDraft.linkOnly ? .linked : .imported
        showImportDialog = false
        enqueueImport([item], storage: storage, folderID: currentFolderID)
    }

    /// Imports run one batch after another, so a second drop waits for the first.
    private func enqueueImport(_ items: [ImportItem], storage: MediaStorage, folderID: UUID?) {
        let previous = importChain
        importChain = Task {
            await previous?.value
            await runImport(items, storage: storage, folderID: folderID)
        }
    }

    private func runImport(_ items: [ImportItem], storage: MediaStorage, folderID: UUID?) async {
        guard !items.isEmpty else { return }
        isImporting = true
        defer {
            isImporting = false
            importProgress = nil
        }
        var created: [(Minute, Transcript?)] = []
        var failures: [String] = []
        for (i, item) in items.enumerated() {
            importProgress = ImportProgress(index: i + 1, total: items.count, fraction: storage == .imported ? 0 : nil)
            do {
                created.append(try await createMinute(item, storage: storage, folderID: folderID))
            } catch {
                failures.append(L("{0}：{1}", item.media.lastPathComponent, error.localizedDescription))
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

    private func createMinute(_ item: ImportItem, storage: MediaStorage, folderID: UUID?) async throws -> (Minute, Transcript?) {
        let media = item.media
        let access = ScopedAccess(url: media)
        defer { access.stop() }
        let info: MediaInspector.Info
        do {
            info = try await MediaInspector.inspect(url: media)
        } catch {
            throw ImportError(message: L("无法读取媒体：{0}", error.localizedDescription))
        }
        let id = UUID()
        var bookmark = Data()
        var path = media.path
        if storage == .imported {
            let dest = library.mediaDirectory(id).appendingPathComponent(media.lastPathComponent)
            do {
                try await MediaCopier.copy(from: media, to: dest) { [weak self] p in
                    guard let self, var progress = self.importProgress else { return }
                    progress.fraction = p
                    self.importProgress = progress
                }
            } catch {
                try? FileManager.default.removeItem(at: library.folder(id))
                throw ImportError(message: L("复制到应用失败：{0}", error.localizedDescription))
            }
            path = dest.path
        } else {
            guard let b = Bookmarks.make(for: media) else { throw ImportError(message: L("无法访问该文件")) }
            bookmark = b
        }
        let baseName = media.deletingPathExtension().lastPathComponent
        let title = FilePairing.normalizedTitle(baseName, suffixes: settings.general.filenameSuffixes)
        let now = Date()
        let createdAt = FilePairing.dateFromFileName(baseName, fallback: now) ?? now
        var minute = Minute(id: id, title: title, createdAt: createdAt, duration: info.duration, mediaBookmark: bookmark,
                            mediaPath: path, mediaFileName: media.lastPathComponent, isAudioOnly: !info.hasVideo)
        minute.folderID = folderID
        minute.storage = storage
        minute.mediaSize = Library.fileSize(of: media)
        library.save(minute)

        var transcript: Transcript?
        if let subtitle = item.subtitle {
            do {
                transcript = try attachSRT(subtitle, toMinute: minute.id).0
                if let m = library.minute(minute.id) { minute = m }
            } catch {
                Alerts.error(L("字幕「{0}」解析失败", subtitle.lastPathComponent), error.localizedDescription)
            }
        }
        if info.hasVideo {
            if let cover = item.cover {
                library.setThumbnail(cover, id: minute.id)
            } else if let jpeg = await MediaInspector.coverJPEG(url: URL(fileURLWithPath: path), duration: info.duration) {
                library.setThumbnail(jpeg, id: minute.id)
            }
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

        // Folders selected in the sidebar: ⌫ deletes them (after confirming), Esc clears.
        if !folderSelection.isEmpty, !editing {
            if code == 53 {
                folderSelection = []
                return true
            }
            if code == 51 || code == 117, mods.isEmpty || mods == .command {
                requestDeleteFolders(folderSelection)
                return true
            }
        }
        if code == 51, mods == .command, !editing, !selection.isEmpty, section != .trash {
            requestMoveToTrash(selection)
            return true
        }
        return false
    }
}
