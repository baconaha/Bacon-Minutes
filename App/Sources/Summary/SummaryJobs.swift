import Foundation

/// One running or failed summary generation. Jobs belong to the app, not to the detail page,
/// so a summary keeps generating after the user goes back to the list.
struct SummaryJob: Equatable {
    enum Phase: Equatable {
        /// Waiting in the batch queue.
        case queued
        case running(String)
        case failed(String)
    }

    var phase: Phase
    /// Model the job runs on.
    var modelName: String

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var isQueued: Bool { phase == .queued }

    /// Running or waiting its turn.
    var isActive: Bool { isRunning || isQueued }
}

/// One minute waiting in the batch queue, with the model picked for the batch.
struct QueuedSummary {
    var minuteID: UUID
    var favorite: FavoriteModel?
}

extension AppModel {
    func summaryJob(_ id: UUID) -> SummaryJob? { summaryJobs[id] }

    func isGeneratingSummary(_ id: UUID) -> Bool { summaryJobs[id]?.isRunning ?? false }

    func isSummaryQueued(_ id: UUID) -> Bool { summaryJobs[id]?.isQueued ?? false }

    // MARK: Batch

    /// At most this many batch summaries run at once, to stay within providers' rate limits.
    static let batchConcurrency = 2

    /// Queues summaries for several minutes; they run in the background a couple at a time.
    /// Returns how many were queued.
    @discardableResult
    func queueSummaries(_ ids: [UUID], favorite: FavoriteModel?, includeExisting: Bool) -> Int {
        let modelName = favorite?.model ?? settings.llm.model
        var count = 0
        for id in ids {
            guard let m = library.minute(id), m.deletedAt == nil, m.hasTranscript else { continue }
            if m.hasSummary && !includeExisting { continue }
            if summaryJobs[id]?.isActive == true { continue }
            summaryJobs[id] = SummaryJob(phase: .queued, modelName: modelName)
            summaryQueue.append(QueuedSummary(minuteID: id, favorite: favorite))
            count += 1
        }
        pumpSummaryQueue()
        return count
    }

    /// Starts queued summaries while fewer than `batchConcurrency` are running.
    func pumpSummaryQueue() {
        while summaryJobs.values.filter(\.isRunning).count < Self.batchConcurrency, !summaryQueue.isEmpty {
            let next = summaryQueue.removeFirst()
            guard summaryJobs[next.minuteID]?.isQueued == true else { continue }
            launchQueued(next)
        }
    }

    private func launchQueued(_ q: QueuedSummary) {
        let id = q.minuteID
        guard let m = library.minute(id), m.deletedAt == nil, let tr = library.loadTranscript(id) else {
            summaryJobs[id] = nil
            return
        }
        var config = settings.llm
        var apiKey = settings.apiKey
        if let fav = q.favorite {
            config = fav.applied(to: config)
            apiKey = settings.apiKey(forPreset: fav.presetID)
        }
        guard config.isConfigured else {
            summaryJobs[id] = SummaryJob(phase: .failed(L("请先在 API 设置中填写 Base URL 与模型")), modelName: config.model)
            return
        }
        // Same input as the detail page builds (§8): paragraphs with the current settings.
        let paragraphs = ParagraphBuilder.build(cues: tr.cues)
        let input = SummaryInput.make(title: m.title, duration: m.duration, transcript: tr, paragraphs: paragraphs,
                                      insertComma: settings.general.insertComma, language: config.outputLanguage)
        startSummary(minuteID: id, input: input, config: config, apiKey: apiKey,
                     transcriptHash: tr.contentHash, cuesHash: tr.cuesHash)
    }

    /// Starts (or restarts) generation for one minute.
    func startSummary(minuteID: UUID, input: SummaryInput, config: LLMConfig, apiKey: String,
                      transcriptHash: String, cuesHash: String) {
        summaryTasks[minuteID]?.cancel()
        summaryJobs[minuteID] = SummaryJob(phase: .running(L("正在生成…")), modelName: config.model)
        let generator = SummaryGenerator(client: LLMClient(compat: settings.compatStore))
        let app = self
        summaryTasks[minuteID] = Task {
            do {
                let draft = try await generator.generate(input: input, config: config, apiKey: apiKey, progress: { p in
                    Task { @MainActor in app.updateSummaryProgress(minuteID, p) }
                })
                if Task.isCancelled { return }
                app.finishSummary(minuteID, draft: draft, config: config, transcriptHash: transcriptHash, cuesHash: cuesHash)
            } catch {
                if Task.isCancelled { return }
                app.failSummary(minuteID, error)
            }
        }
    }

    func cancelSummary(_ id: UUID) {
        summaryTasks[id]?.cancel()
        summaryTasks[id] = nil
        summaryJobs[id] = nil
        summaryQueue.removeAll { $0.minuteID == id }
        pumpSummaryQueue()
    }

    /// Forgets a failed job (e.g. before retrying or once the error was seen).
    func clearSummaryFailure(_ id: UUID) {
        if let job = summaryJobs[id], case .failed = job.phase { summaryJobs[id] = nil }
    }

    private func updateSummaryProgress(_ id: UUID, _ p: SummaryProgress) {
        guard var job = summaryJobs[id], job.isRunning else { return }
        switch p {
        case .single: job.phase = .running(L("正在生成…"))
        case .part(let i, let n): job.phase = .running(L("正在生成… 第 {0}/{1} 部分", i, n))
        case .merging: job.phase = .running(L("正在合并各部分…"))
        }
        summaryJobs[id] = job
    }

    private func finishSummary(_ id: UUID, draft: SummaryDraft, config: LLMConfig, transcriptHash: String, cuesHash: String) {
        summaryTasks[id] = nil
        summaryJobs[id] = nil
        let s = Summary(draft: draft, model: config.model, generatedAt: Date(), transcriptHash: transcriptHash,
                        cuesHash: cuesHash, parameters: config.summaryParameters)
        addSummary(s, to: id)
        if detail?.minute.id != id, let m = library.minute(id) {
            showToast(L("「{0}」的智能纪要已生成", m.title))
        }
        pumpSummaryQueue()
    }

    private func failSummary(_ id: UUID, _ error: Error) {
        summaryTasks[id] = nil
        defer { pumpSummaryQueue() }
        if let e = error as? LLMError, e == .cancelled {
            summaryJobs[id] = nil
            return
        }
        if error is CancellationError {
            summaryJobs[id] = nil
            return
        }
        let model = summaryJobs[id]?.modelName ?? ""
        summaryJobs[id] = SummaryJob(phase: .failed(error.localizedDescription), modelName: model)
        if detail?.minute.id != id, let m = library.minute(id) {
            showToast(L("「{0}」的智能纪要生成失败", m.title))
        }
    }

    /// Stores a new version (generated or imported) and shows it.
    func addSummary(_ s: Summary, to id: UUID) {
        guard let list = library.appendSummary(s, to: id) else { return }
        if let d = detail, d.minute.id == id {
            d.summariesChanged(list, select: s.id)
        } else {
            library.update(id) { m in
                m.hasSummary = true
                m.activeSummaryID = s.id
            }
        }
    }
}
