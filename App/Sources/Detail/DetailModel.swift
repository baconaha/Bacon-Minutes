import AppKit
import Foundation
import Observation
import SwiftUI

enum RightTab {
    case summary, transcript

    /// Stored in `Minute.lastTab`.
    var key: String { self == .summary ? "summary" : "transcript" }
}
enum LeftTab { case speakers, fileInfo }
enum MediaState {
    case loading, ready
    /// Not at its last location (moved, renamed, deleted).
    case missing
    /// Its disk or network volume did not answer (e.g. a NAS after leaving the network).
    case unreachable
}

enum SummaryState: Equatable {
    case idle
    case generating(String)
    case failed(String)
}

enum ExportKind { case srt, txt, markdown }

struct SearchHit: Equatable {
    let range: NSRange
    let cueID: Int
    let time: Double
}

/// State of one open minute (§2–§6).
@MainActor
@Observable
final class DetailModel {
    unowned let app: AppModel
    var settings: AppSettings { app.settings }
    var library: Library { app.library }

    var minute: Minute
    private(set) var transcript: Transcript?
    private(set) var paragraphs: [Paragraph] = []
    private(set) var percentages: [String: Int] = [:]
    private(set) var speakerIntervals: [String: [ClosedRange<Double>]] = [:]
    private(set) var transcriptHash = ""
    @ObservationIgnored private(set) var timeline = CueTimeline(cues: [])

    private(set) var document: TranscriptDocument?
    private(set) var documentVersion = 0

    /// Every summary version of this minute, oldest first.
    private(set) var summaries: [Summary] = []
    /// Problem found before a request was sent (no subtitles, API not set up).
    private(set) var summaryNotice: String?
    /// Model picked in the summary tab: a favorite's id, or nil for the default in Settings.
    var chosenModelID: String?

    var rightTab: RightTab = .transcript
    var leftTab: LeftTab = .speakers

    let player: PlayerController
    private(set) var mediaState: MediaState = .loading
    private(set) var mediaURL: URL?
    private(set) var thumbnails: ThumbnailProvider?
    @ObservationIgnored private var mediaAccess: ScopedAccess?
    /// "重新检测路径" in progress, and whether the last one found nothing.
    private(set) var isRechecking = false
    private(set) var recheckFailed = false

    // Search (§5.1)
    var searchQuery = ""
    private(set) var searchHits: [SearchHit] = []
    private(set) var currentHitIndex = 0
    var searchFocusToken = 0
    var searchFieldFocused = false
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    // Playback position in the transcript (§5.3, §5.5)
    var isFollowing = true
    var currentCueID: Int?
    /// Cue under the playhead, nil inside gaps (drives CC subtitles).
    private(set) var activeCueID: Int?
    var currentCueAbove = false
    @ObservationIgnored weak var textController: TranscriptTextController?
    @ObservationIgnored private var lastCharOffset: Int?

    var isVideoFullscreen = false
    /// False until `prepare()` has loaded the transcript; empty states stay hidden until then.
    private(set) var isLoaded = false
    /// The transcript text view fills (a full TextKit layout) only after the page transition.
    private(set) var transcriptRevealed = false
    @ObservationIgnored private var closed = false

    @ObservationIgnored private var autosaveTask: Task<Void, Never>?

    init(minute: Minute, app: AppModel) {
        self.minute = minute
        self.app = app
        self.player = PlayerController()
    }

    // MARK: Lifecycle

    /// Loads transcript and summary before the page is shown, so it appears with its content in
    /// place instead of popping in mid-transition.
    func prepare() {
        transcript = library.loadTranscript(minute.id)
        summaries = library.loadSummaries(minute.id)
        if minute.hasSummary != !summaries.isEmpty {
            minute.hasSummary = !summaries.isEmpty
            library.save(minute)
        }
        rebuildDerived()
        isLoaded = true
        // Back on the tab this minute was left on.
        rightTab = minute.lastTab == RightTab.summary.key ? .summary : .transcript
    }

    /// Media, playback and the transcript layout; called once the page transition has finished.
    func start() {
        guard !closed else { return }
        transcriptRevealed = true
        Task { await loadMedia() }
        autosaveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self else { return }
                self.persistPosition()
            }
        }
    }

    func close() {
        closed = true
        persistState()
        autosaveTask?.cancel()
        // Summary generation is not cancelled: it belongs to the app and finishes in the background.
        searchTask?.cancel()
        thumbnails?.cancel()
        player.teardown()
        mediaAccess?.stop()
        mediaAccess = nil
    }

    /// Playback position and the open tab, for the next time this minute opens.
    func persistState() {
        if minute.lastTab != rightTab.key {
            minute.lastTab = rightTab.key
            library.save(minute)
        }
        persistPosition()
    }

    func persistPosition() {
        guard mediaState == .ready else { return }
        let t = player.currentTime
        guard abs(t - minute.lastPlaybackPosition) > 0.5 else { return }
        minute.lastPlaybackPosition = t
        library.save(minute)
    }

    // MARK: Media

    var duration: Double {
        let d = player.duration > 0 ? player.duration : minute.duration
        if d > 0 { return d }
        return transcript?.cues.map(\.end).max() ?? 0
    }

    var useHours: Bool { TimeFormat.usesHours(totalDuration: duration) }

    /// Finds the media off the main thread (never mounting a network volume unless asked)
    /// and starts the player.
    func loadMedia(allowMounting: Bool = false, showLoading: Bool = true) async {
        if showLoading { mediaState = .loading }
        let outcome = await locateMedia(allowMounting: allowMounting)
        guard !closed else { return }
        switch outcome {
        case .missing:
            mediaState = .missing
        case .unreachable:
            mediaState = .unreachable
        case .found(let url, let fresh):
            attach(url: url, freshBookmark: fresh, resumeAt: nil)
        }
    }

    private func locateMedia(allowMounting: Bool) async -> MediaLocator.Outcome {
        if minute.storage == .imported {
            return await MediaLocator.locateLocal(library.importedMediaURL(minute))
        }
        return await MediaLocator.locate(bookmark: minute.mediaBookmark, path: minute.mediaPath, allowMounting: allowMounting)
    }

    private func wirePlayer() {
        player.onTick = { [weak self] t in self?.handleTick(t) }
        player.onSeekFinished = { [weak self] t in self?.refreshHighlight(at: t) }
    }

    private func attach(url: URL, freshBookmark: Data?, resumeAt: Double?) {
        if minute.storage == .linked {
            var changed = false
            if let fresh = freshBookmark {
                minute.mediaBookmark = fresh
                changed = true
            }
            if url.path != minute.mediaPath {
                minute.mediaPath = url.path
                minute.mediaFileName = url.lastPathComponent
                changed = true
            }
            if changed { library.save(minute) }
        }
        mediaAccess?.stop()
        mediaAccess = ScopedAccess(url: url)
        mediaURL = url
        wirePlayer()
        let g = settings.general
        player.load(url: url, knownDuration: minute.duration, rate: g.playbackRate, volume: g.volume)
        mediaState = .ready
        recheckFailed = false
        if !minute.isAudioOnly { thumbnails = ThumbnailProvider(url: url) }
        let resume = resumeAt ?? minute.lastPlaybackPosition
        if resume > 1 && (minute.duration <= 0 || resume < minute.duration - 2) {
            player.seek(to: resume)
        }
        refreshHighlight(at: resume)
    }

    /// "重新检测路径": looks again at the last known location (mounting its volume if needed),
    /// so a file moved back where it was comes back. `silent` is the automatic check when the
    /// app becomes active again.
    func recheckMedia(silent: Bool = false) {
        guard !isRechecking, mediaState == .missing || mediaState == .unreachable else { return }
        isRechecking = true
        if !silent { recheckFailed = false }
        Task {
            await loadMedia(allowMounting: !silent, showLoading: false)
            isRechecking = false
            if mediaState == .ready {
                if !silent { app.showToast(L("已重新找到源文件")) }
            } else if !silent {
                recheckFailed = true
            }
        }
    }

    /// The media was copied into the app ("导入到应用"): play from the copy, same position.
    func mediaMovedIntoApp() {
        guard let m = library.minute(minute.id) else { return }
        minute.storage = m.storage
        minute.mediaPath = m.mediaPath
        minute.mediaFileName = m.mediaFileName
        minute.mediaBookmark = m.mediaBookmark
        minute.mediaSize = m.mediaSize
        let wasPlaying = player.isPlaying
        let position = mediaState == .ready ? player.currentTime : minute.lastPlaybackPosition
        player.teardown()
        thumbnails?.cancel()
        thumbnails = nil
        mediaAccess?.stop()
        mediaAccess = nil
        Task {
            let outcome = await MediaLocator.locateLocal(library.importedMediaURL(minute))
            guard !closed else { return }
            if case .found(let url, _) = outcome {
                attach(url: url, freshBookmark: nil, resumeAt: position)
                if wasPlaying { player.play() }
            } else {
                mediaState = .missing
            }
        }
    }

    /// "重新定位" / "更换媒体文件". A linked minute links to the new file; a minute whose media
    /// is in the app gets a copy of the new file instead.
    func relocateMedia() {
        guard let url = FilePanels.chooseMedia() else { return }
        if minute.storage == .imported {
            replaceImportedMedia(with: url)
            return
        }
        let access = ScopedAccess(url: url)
        defer { access.stop() }
        guard let bookmark = Bookmarks.make(for: url) else {
            Alerts.error(L("无法访问该文件"), url.path)
            return
        }
        player.teardown()
        mediaAccess?.stop()
        mediaAccess = nil
        thumbnails = nil
        minute.mediaBookmark = bookmark
        minute.mediaPath = url.path
        minute.mediaFileName = url.lastPathComponent
        minute.isAudioOnly = MediaTypes.kind(of: url) == .audio
        minute.mediaSize = Library.fileSize(of: url)
        Task {
            if let info = try? await MediaInspector.inspect(url: url) {
                minute.duration = info.duration
                minute.isAudioOnly = !info.hasVideo
            }
            library.save(minute)
            await loadMedia()
            if !minute.isAudioOnly, let jpeg = await MediaInspector.coverJPEG(url: url, duration: minute.duration) {
                library.setThumbnail(jpeg, id: minute.id)
            }
        }
    }

    private func replaceImportedMedia(with url: URL) {
        let id = minute.id
        guard app.copyingMedia[id] == nil else { return }
        player.teardown()
        thumbnails = nil
        mediaAccess?.stop()
        mediaAccess = nil
        mediaState = .loading
        app.copyingMedia[id] = 0
        let old = library.importedMediaURL(minute)
        let dest = library.mediaDirectory(id).appendingPathComponent(url.lastPathComponent)
        Task {
            let access = ScopedAccess(url: url)
            defer { access.stop() }
            do {
                try await MediaCopier.copy(from: url, to: dest) { [weak self] p in
                    self?.app.copyingMedia[id] = p
                }
                app.copyingMedia[id] = nil
                if old.path != dest.path { try? FileManager.default.removeItem(at: old) }
                minute.mediaFileName = dest.lastPathComponent
                minute.mediaPath = dest.path
                minute.mediaSize = Library.fileSize(of: dest)
                minute.isAudioOnly = MediaTypes.kind(of: url) == .audio
                if let info = try? await MediaInspector.inspect(url: dest) {
                    minute.duration = info.duration
                    minute.isAudioOnly = !info.hasVideo
                }
                library.save(minute)
                await loadMedia()
                if !minute.isAudioOnly, let jpeg = await MediaInspector.coverJPEG(url: dest, duration: minute.duration) {
                    library.setThumbnail(jpeg, id: minute.id)
                }
            } catch {
                app.copyingMedia[id] = nil
                Alerts.error(L("导入应用失败"), error.localizedDescription)
                await loadMedia()
            }
        }
    }

    func revealMedia() {
        app.revealMedia(minute.id)
    }

    // MARK: Transcript

    private func rebuildDerived() {
        guard let tr = transcript else {
            paragraphs = []
            timeline = CueTimeline(cues: [])
            percentages = [:]
            speakerIntervals = [:]
            transcriptHash = ""
            document = nil
            documentVersion += 1
            textController?.syncDocument()
            return
        }
        paragraphs = ParagraphBuilder.build(cues: tr.cues)
        timeline = CueTimeline(cues: tr.cues)
        percentages = SpeakerStats.percentages(cues: tr.cues)
        var intervals: [String: [ClosedRange<Double>]] = [:]
        for s in tr.speakers { intervals[s.id] = SpeakerStats.intervals(cues: tr.cues, speakerID: s.id) }
        speakerIntervals = intervals
        transcriptHash = tr.contentHash
        rebuildDocument()
    }

    func rebuildDocument() {
        guard let tr = transcript else { return }
        currentCueID = nil
        document = TranscriptDocumentBuilder.build(transcript: tr, paragraphs: paragraphs,
                                                   insertComma: settings.general.insertComma, useHours: useHours)
        recomputeHits(resetIndex: false)
        documentVersion += 1
        textController?.syncDocument()
    }

    func importSRT(from url: URL) {
        do {
            let (tr, _) = try app.attachSRT(url, toMinute: minute.id)
            if let m = library.minute(minute.id) { minute = m }
            transcript = tr
            rebuildDerived()
            rightTab = .transcript
            app.showToast(AppModel.importSummaryText(transcript: tr, duration: duration))
        } catch {
            Alerts.error(L("无法导入字幕"), error.localizedDescription)
        }
    }

    func chooseAndImportSRT() {
        guard let url = FilePanels.chooseSRT() else { return }
        importSRT(from: url)
    }

    func renameSpeaker(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var tr = transcript, let i = tr.speakers.firstIndex(where: { $0.id == id }),
              tr.speakers[i].name != trimmed else { return }
        tr.speakers[i].name = trimmed
        transcript = tr
        library.saveTranscript(tr, id: minute.id)
        transcriptHash = tr.contentHash
        rebuildDocument()
    }

    func renameTitle(_ title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != minute.title else { return }
        minute.title = t
        library.save(minute)
    }

    func speakerName(_ id: String) -> String { transcript?.speakerName(id) ?? id }

    func cue(_ id: Int?) -> Cue? {
        guard let id, let cues = transcript?.cues, id >= 0, id < cues.count else { return nil }
        return cues[id]
    }

    // MARK: Playback ↔ transcript

    private func handleTick(_ t: Double) {
        let g = settings.general
        if g.skipBlankEnabled, player.isPlaying, !timeline.isEmpty,
           let target = timeline.skipTarget(at: t, threshold: max(0.5, g.skipBlankThreshold)) {
            player.seek(to: target)
            return
        }
        refreshHighlight(at: t)
    }

    func refreshHighlight() {
        refreshHighlight(at: player.currentTime)
    }

    func refreshHighlight(at t: Double, forcedCue: Int? = nil) {
        guard let tr = transcript, !tr.cues.isEmpty else { return }
        let active = forcedCue ?? timeline.activeCue(at: t)
        if activeCueID != active { activeCueID = active }
        let cue = active ?? currentCueID
        var charOffset: Int?
        if let cue, cue == active, settings.general.perCharHighlight, let doc = document {
            let c = tr.cues[cue]
            let len = doc.cueRanges[cue].length
            if c.duration > 0, len > 0 {
                let ratio = min(max((t - c.start) / c.duration, 0), 1)
                charOffset = min(len - 1, Int(ratio * Double(len)))
            }
        }
        if cue != currentCueID {
            currentCueID = cue
            if isFollowing, let cue { textController?.scrollToCue(cue, animated: true) }
            textController?.updateDirection()
        }
        lastCharOffset = charOffset
        textController?.setCurrent(cue: cue, charOffset: charOffset)
    }

    /// Click on transcript text: seek to the cue (or the estimated character) and play (§5.4).
    func jump(toCue id: Int, charOffset: Int?) {
        guard let tr = transcript, id >= 0, id < tr.cues.count else { return }
        let cue = tr.cues[id]
        var t = cue.start
        if settings.general.perCharHighlight, let off = charOffset, let doc = document {
            let len = doc.cueRanges[id].length
            if len > 0, cue.duration > 0 { t = cue.start + cue.duration * Double(off) / Double(len) }
        }
        isFollowing = true
        player.seek(to: t)
        refreshHighlight(at: t, forcedCue: id)
        player.play()
    }

    func jump(toParagraph index: Int) {
        guard index >= 0, index < paragraphs.count else { return }
        let p = paragraphs[index]
        isFollowing = true
        player.seek(to: p.start)
        refreshHighlight(at: p.start, forcedCue: p.cueIDs.first)
        player.play()
    }

    /// Chapter titles and todo timestamps: seek and play (§6.1).
    func jump(toTime t: Double, play: Bool = true) {
        isFollowing = true
        player.seek(to: t)
        refreshHighlight(at: t)
        // Bring the target text into view even when the highlighted cue did not change
        // (e.g. the user had scrolled the transcript away).
        if let cue = currentCueID { textController?.scrollToCue(cue, animated: true) }
        if play { player.play() }
    }

    func resumeFollowing() {
        isFollowing = true
        if let cue = currentCueID { textController?.scrollToCue(cue, animated: true) }
    }

    // MARK: Search

    func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }
            self?.performSearch()
        }
    }

    func performSearch() {
        recomputeHits(resetIndex: true)
        textController?.setHits(searchHits.map(\.range), current: searchHits.isEmpty ? nil : currentHitIndex)
        if let hit = searchHits.first {
            isFollowing = false
            textController?.scroll(toCharacterRange: hit.range, animated: true)
            textController?.updateDirection()
        }
    }

    private func recomputeHits(resetIndex: Bool) {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let doc = document, let tr = transcript else {
            searchHits = []
            currentHitIndex = 0
            return
        }
        let needle = TextFold.fold(q)
        var hits: [SearchHit] = []
        for (pi, body) in doc.bodies.enumerated() {
            for offset in TextFold.occurrences(of: needle, in: body.folded) {
                let loc = body.range.location + offset
                guard let cue = doc.cueID(at: loc, inParagraph: pi) else { continue }
                hits.append(SearchHit(range: NSRange(location: loc, length: needle.count), cueID: cue, time: tr.cues[cue].start))
            }
        }
        searchHits = hits
        if resetIndex || currentHitIndex >= hits.count { currentHitIndex = 0 }
    }

    func nextHit() { moveHit(by: 1) }
    func previousHit() { moveHit(by: -1) }

    private func moveHit(by delta: Int) {
        guard !searchHits.isEmpty else { return }
        currentHitIndex = (currentHitIndex + delta + searchHits.count) % searchHits.count
        focusCurrentHit()
    }

    /// Scrolls to the current hit and moves the video to its cue without changing play/pause (§5.1).
    private func focusCurrentHit() {
        let hit = searchHits[currentHitIndex]
        textController?.setHits(searchHits.map(\.range), current: currentHitIndex)
        isFollowing = true
        player.seek(to: hit.time)
        refreshHighlight(at: hit.time, forcedCue: hit.cueID)
        textController?.scroll(toCharacterRange: hit.range, animated: true)
    }

    func clearSearch() {
        searchTask?.cancel()
        searchQuery = ""
        searchHits = []
        currentHitIndex = 0
        textController?.setHits([], current: nil)
    }

    func search(keyword: String) {
        searchQuery = keyword
        performSearch()
    }

    func focusSearch() {
        rightTab = .transcript
        searchFocusToken += 1
    }

    // MARK: Summary (§6)

    var isSummaryStale: Bool {
        guard let s = summary, transcript != nil else { return false }
        return s.transcriptHash != transcriptHash
    }

    var isGenerating: Bool { app.isGeneratingSummary(minute.id) }

    /// Shown version: the one picked last, else the newest.
    var summary: Summary? {
        summaries.first { $0.id == minute.activeSummaryID } ?? summaries.last
    }

    var summaryState: SummaryState {
        if let job = app.summaryJob(minute.id) {
            switch job.phase {
            case .queued: return .generating(L("排队中，前面的纪要生成完就开始…"))
            case .running(let text): return .generating(text)
            case .failed(let message): return .failed(message)
            }
        }
        if let notice = summaryNotice { return .failed(notice) }
        return .idle
    }

    /// Model of the generation in progress.
    var generatingModelName: String? { app.summaryJob(minute.id)?.modelName }

    var chosenFavorite: FavoriteModel? {
        guard let id = chosenModelID else { return nil }
        return settings.favorites.first { $0.id == id }
    }

    var chosenModelName: String { chosenFavorite?.model ?? settings.llm.model }

    var chapterStarts: [Double] { summary?.chapters.map(\.time) ?? [] }

    func chapterTitle(at t: Double) -> String? { summary?.chapter(at: t)?.title }

    /// Generates a new version with the model picked in the summary tab. It runs in the
    /// background (`AppModel.startSummary`), so leaving the page does not stop it.
    func generateSummary() {
        summaryNotice = nil
        app.clearSummaryFailure(minute.id)
        guard let tr = transcript else {
            summaryNotice = L("请先导入 SRT 字幕，再生成智能纪要")
            return
        }
        var config = settings.llm
        var apiKey = settings.apiKey
        if let fav = chosenFavorite {
            config = fav.applied(to: config)
            apiKey = settings.apiKey(forPreset: fav.presetID)
        }
        guard config.isConfigured else {
            summaryNotice = L("请先在 API 设置中填写 Base URL 与模型")
            return
        }
        let input = SummaryInput.make(title: minute.title, duration: duration, transcript: tr, paragraphs: paragraphs,
                                      insertComma: settings.general.insertComma, language: config.outputLanguage)
        app.startSummary(minuteID: minute.id, input: input, config: config, apiKey: apiKey,
                         transcriptHash: transcriptHash, cuesHash: tr.cuesHash)
        rightTab = .summary
    }

    func cancelGeneration() {
        app.cancelSummary(minute.id)
    }

    /// A version was added (generated or imported) while this page is open.
    func summariesChanged(_ list: [Summary], select id: UUID?) {
        summaries = list
        if let id { minute.activeSummaryID = id }
        minute.hasSummary = !list.isEmpty
        library.save(minute)
    }

    func selectSummary(_ id: UUID) {
        guard summaries.contains(where: { $0.id == id }), minute.activeSummaryID != id else { return }
        minute.activeSummaryID = id
        library.save(minute)
    }

    func requestDeleteSummary(_ id: UUID) {
        guard let s = summaries.first(where: { $0.id == id }) else { return }
        app.confirmRequest = ConfirmRequest(
            title: L("删除这份纪要？"),
            message: L("{0} · {1} 生成的纪要会被删除，其他版本不受影响。", s.model, TimeFormat.createdDate(s.generatedAt)),
            confirmTitle: L("删除")
        ) { [weak self] in
            self?.deleteSummary(id)
        }
    }

    private func deleteSummary(_ id: UUID) {
        summaries.removeAll { $0.id == id }
        library.saveSummaries(summaries, id: minute.id)
        if minute.activeSummaryID == id { minute.activeSummaryID = summaries.last?.id }
        minute.hasSummary = !summaries.isEmpty
        library.save(minute)
        app.showToast(L("已删除纪要"))
    }

    // MARK: Summary files

    func exportSummaryFile() {
        guard let s = summary else { return }
        let file = SummaryFile.make(summary: s, minute: minute, transcript: transcript, app: AppModel.appIdentity)
        do {
            let data = try file.encoded()
            FilePanels.saveData(data, suggestedName: "\(minute.title) · \(s.model)", fileExtension: SummaryFile.fileExtension)
        } catch {
            Alerts.error(L("导出失败"), error.localizedDescription)
        }
    }

    func chooseAndImportSummaryFile() {
        guard let url = FilePanels.chooseSummaryFile() else { return }
        importSummaryFile(url)
    }

    /// Checks the file against this minute and asks before importing when they differ.
    func importSummaryFile(_ url: URL) {
        do {
            let file = try app.readSummaryFile(url)
            app.confirmAndImport(file, into: minute.id)
            rightTab = .summary
        } catch {
            Alerts.error(L("无法导入纪要"), L("{0}：{1}", url.lastPathComponent, error.localizedDescription))
        }
    }

    func copySummaryMarkdown() {
        guard let s = summary else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(Exporter.summaryMarkdown(s, useHours: useHours), forType: .string)
        app.showToast(L("已复制为 Markdown"))
    }

    // MARK: Export (§2)

    func export(_ kind: ExportKind) {
        let title = minute.title
        switch kind {
        case .srt:
            guard let tr = transcript else { return }
            FilePanels.saveText(Exporter.srt(transcript: tr), suggestedName: title, fileExtension: "srt")
        case .txt:
            guard let tr = transcript else { return }
            FilePanels.saveText(Exporter.txt(transcript: tr, paragraphs: paragraphs,
                                             insertComma: settings.general.insertComma, useHours: useHours),
                                suggestedName: title, fileExtension: "txt")
        case .markdown:
            let md = Exporter.markdown(title: title, createdAt: minute.createdAt, duration: duration, summary: summary,
                                       transcript: transcript, paragraphs: paragraphs,
                                       insertComma: settings.general.insertComma)
            FilePanels.saveText(md, suggestedName: title, fileExtension: "md")
        }
    }

    // MARK: Tags (§2)

    var tags: [(String, Bool)] {
        var out: [(String, Bool)] = []
        guard isLoaded else { return out }
        if mediaState == .missing { out.append((L("媒体缺失"), true)) }
        if mediaState == .unreachable { out.append((L("无法访问源文件"), true)) }
        if transcript == nil { out.append((L("无字幕"), true)) }
        if summaries.count > 1 {
            out.append((L("{0} 份纪要", summaries.count), false))
        } else if !summaries.isEmpty {
            out.append((L("已生成纪要"), false))
        }
        return out
    }

    // MARK: Full screen

    func toggleFullscreen() {
        setFullscreen(!isVideoFullscreen)
    }

    func setFullscreen(_ on: Bool) {
        isVideoFullscreen = on
        guard let window = app.mainWindow else { return }
        let isFull = window.styleMask.contains(.fullScreen)
        if on != isFull { window.toggleFullScreen(nil) }
    }
}
