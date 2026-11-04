import AppKit
import Foundation
import Observation

enum RightTab { case summary, transcript }
enum LeftTab { case speakers, fileInfo }
enum MediaState { case loading, ready, missing }

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

    var summary: Summary?
    var summaryState: SummaryState = .idle

    var rightTab: RightTab = .transcript
    var leftTab: LeftTab = .speakers

    let player: PlayerController
    private(set) var mediaState: MediaState = .loading
    private(set) var mediaURL: URL?
    private(set) var thumbnails: ThumbnailProvider?
    @ObservationIgnored private var mediaAccess: ScopedAccess?

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

    @ObservationIgnored private var generationTask: Task<Void, Never>?
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?

    init(minute: Minute, app: AppModel) {
        self.minute = minute
        self.app = app
        self.player = PlayerController()
    }

    // MARK: Lifecycle

    func start() {
        transcript = library.loadTranscript(minute.id)
        summary = library.loadSummary(minute.id)
        rebuildDerived()
        rightTab = .transcript
        player.onTick = { [weak self] t in self?.handleTick(t) }
        player.onSeekFinished = { [weak self] t in self?.refreshHighlight(at: t) }
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
        persistPosition()
        autosaveTask?.cancel()
        generationTask?.cancel()
        searchTask?.cancel()
        thumbnails?.cancel()
        player.teardown()
        mediaAccess?.stop()
        mediaAccess = nil
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

    func loadMedia() async {
        mediaState = .loading
        guard let resolved = Bookmarks.resolve(minute.mediaBookmark) else {
            mediaState = .missing
            return
        }
        let url = resolved.url
        let access = ScopedAccess(url: url)
        guard FileManager.default.fileExists(atPath: url.path) else {
            access.stop()
            mediaState = .missing
            return
        }
        if resolved.isStale || url.path != minute.mediaPath {
            if let fresh = Bookmarks.make(for: url) { minute.mediaBookmark = fresh }
            minute.mediaPath = url.path
            minute.mediaFileName = url.lastPathComponent
            library.save(minute)
        }
        mediaAccess = access
        mediaURL = url
        let g = settings.general
        player.load(url: url, knownDuration: minute.duration, rate: g.playbackRate, volume: g.volume)
        mediaState = .ready
        if !minute.isAudioOnly { thumbnails = ThumbnailProvider(url: url) }
        let resume = minute.lastPlaybackPosition
        if resume > 1 && (minute.duration <= 0 || resume < minute.duration - 2) {
            player.seek(to: resume)
        }
        refreshHighlight(at: resume)
    }

    /// "重新定位" / "更换媒体文件".
    func relocateMedia() {
        guard let url = FilePanels.chooseMedia() else { return }
        let access = ScopedAccess(url: url)
        defer { access.stop() }
        guard let bookmark = Bookmarks.make(for: url) else {
            Alerts.error("无法访问该文件", url.path)
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
        Task {
            if let info = try? await MediaInspector.inspect(url: url) {
                minute.duration = info.duration
                minute.isAudioOnly = !info.hasVideo
            }
            library.save(minute)
            player.onTick = { [weak self] t in self?.handleTick(t) }
            player.onSeekFinished = { [weak self] t in self?.refreshHighlight(at: t) }
            await loadMedia()
            if !minute.isAudioOnly, let jpeg = await MediaInspector.coverJPEG(url: url, duration: minute.duration) {
                library.setThumbnail(jpeg, id: minute.id)
            }
        }
    }

    func revealMedia() {
        if let url = mediaURL {
            FilePanels.reveal(url)
        } else if let r = Bookmarks.resolve(minute.mediaBookmark) {
            let a = ScopedAccess(url: r.url)
            FilePanels.reveal(r.url)
            a.stop()
        }
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
            Alerts.error("无法导入字幕", error.localizedDescription)
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

    var isGenerating: Bool {
        if case .generating = summaryState { return true }
        return false
    }

    var chapterStarts: [Double] { summary?.chapters.map(\.time) ?? [] }

    func chapterTitle(at t: Double) -> String? { summary?.chapter(at: t)?.title }

    func generateSummary() {
        guard let tr = transcript else {
            summaryState = .failed("请先导入 SRT 字幕，再生成智能纪要")
            return
        }
        let config = settings.llm
        guard config.isConfigured else {
            summaryState = .failed("请先在 API 设置中填写 Base URL 与模型")
            return
        }
        generationTask?.cancel()
        let input = SummaryInput.make(title: minute.title, duration: duration, transcript: tr, paragraphs: paragraphs,
                                      insertComma: settings.general.insertComma, language: config.outputLanguage)
        let apiKey = settings.apiKey
        let hash = transcriptHash
        let generator = SummaryGenerator(client: LLMClient(compat: settings.compatStore))
        summaryState = .generating("正在生成…")
        rightTab = .summary
        let model = self
        generationTask = Task {
            do {
                let draft = try await generator.generate(input: input, config: config, apiKey: apiKey, progress: { p in
                    Task { @MainActor in model.updateProgress(p) }
                })
                if Task.isCancelled { return }
                model.finishGeneration(draft, modelName: config.model, hash: hash)
            } catch {
                if Task.isCancelled { return }
                model.failGeneration(error)
            }
        }
    }

    private func updateProgress(_ p: SummaryProgress) {
        guard isGenerating else { return }
        switch p {
        case .single: summaryState = .generating("正在生成…")
        case .part(let i, let n): summaryState = .generating("正在生成… 第 \(i)/\(n) 部分")
        case .merging: summaryState = .generating("正在合并各部分…")
        }
    }

    private func finishGeneration(_ draft: SummaryDraft, modelName: String, hash: String) {
        let s = Summary(draft: draft, model: modelName, generatedAt: Date(), transcriptHash: hash)
        summary = s
        summaryState = .idle
        library.saveSummary(s, id: minute.id)
        minute.hasSummary = true
        library.save(minute)
    }

    private func failGeneration(_ error: Error) {
        if let e = error as? LLMError, e == .cancelled {
            summaryState = .idle
            return
        }
        if error is CancellationError {
            summaryState = .idle
            return
        }
        summaryState = .failed(error.localizedDescription)
    }

    func cancelGeneration() {
        generationTask?.cancel()
        generationTask = nil
        summaryState = .idle
    }

    func setFeedback(_ value: Int, chapters: Bool) {
        guard var s = summary else { return }
        if chapters {
            s.chaptersFeedback = s.chaptersFeedback == value ? nil : value
        } else {
            s.feedback = s.feedback == value ? nil : value
        }
        summary = s
        library.saveSummary(s, id: minute.id)
    }

    func copySummaryMarkdown() {
        guard let s = summary else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(Exporter.summaryMarkdown(s, useHours: useHours), forType: .string)
        app.showToast("已复制为 Markdown")
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
        if mediaState == .missing { out.append(("媒体缺失", true)) }
        if transcript == nil { out.append(("无字幕", true)) }
        if summary != nil { out.append(("已生成纪要", false)) }
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
