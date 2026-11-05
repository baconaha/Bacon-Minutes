import Foundation

/// One running or failed summary generation. Jobs belong to the app, not to the detail page,
/// so a summary keeps generating after the user goes back to the list.
struct SummaryJob: Equatable {
    enum Phase: Equatable {
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
}

extension AppModel {
    func summaryJob(_ id: UUID) -> SummaryJob? { summaryJobs[id] }

    func isGeneratingSummary(_ id: UUID) -> Bool { summaryJobs[id]?.isRunning ?? false }

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
    }

    /// Forgets a failed job (e.g. before retrying or once the error was seen).
    func clearSummaryFailure(_ id: UUID) {
        if let job = summaryJobs[id], !job.isRunning { summaryJobs[id] = nil }
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
    }

    private func failSummary(_ id: UUID, _ error: Error) {
        summaryTasks[id] = nil
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
