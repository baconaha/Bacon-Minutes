import Foundation

extension AppModel {
    /// "Bacon Minutes 1.0 (macOS)", recorded in exported summary files.
    static var appIdentity: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "Bacon Minutes \(version) (macOS)"
    }

    func readSummaryFile(_ url: URL) throws -> SummaryFile {
        let access = ScopedAccess(url: url)
        defer { access.stop() }
        let data = try Data(contentsOf: url)
        return try SummaryFile.decode(data)
    }

    /// Summary files dropped on the app. On a minute's page they go to that minute; on the list
    /// each is matched to the minute it was made for.
    func importSummaryFiles(_ urls: [URL]) {
        if let d = detail, let first = urls.first {
            d.importSummaryFile(first)
            return
        }
        Task {
            for url in urls { await importSummaryFileFromList(url) }
        }
    }

    private func importSummaryFileFromList(_ url: URL) async {
        let file: SummaryFile
        do {
            file = try readSummaryFile(url)
        } catch {
            Alerts.error(L("无法导入纪要"), L("{0}：{1}", url.lastPathComponent, error.localizedDescription))
            return
        }
        let candidates = library.minutes.filter { $0.deletedAt == nil }
        if let hash = file.source.cuesHash {
            let root = library.root
            let ids = candidates.filter { $0.cueCount == file.source.cueCount }.map(\.id)
            let match = await Task.detached(priority: .userInitiated) { () -> UUID? in
                let decoder = Library.decoder()
                for id in ids {
                    let u = Library.folder(root: root, id: id).appendingPathComponent("transcript.json")
                    guard let data = try? Data(contentsOf: u), let t = try? decoder.decode(Transcript.self, from: data) else { continue }
                    if t.cuesHash == hash { return id }
                }
                return nil
            }.value
            if let id = match {
                confirmAndImport(file, into: id)
                return
            }
        }
        let name = file.source.mediaFileName.lowercased()
        if !name.isEmpty, let m = candidates.first(where: { $0.mediaFileName.lowercased() == name }) {
            confirmAndImport(file, into: m.id)
            return
        }
        Alerts.info(L("没有找到对应的妙记"),
                    L("「{0}」不属于资料库里的任何妙记。请打开要导入的妙记，再把纪要文件拖到妙记页面里。", url.lastPathComponent))
    }

    /// Checks the file's recording and subtitle details against the minute and asks before
    /// importing when they differ.
    func confirmAndImport(_ file: SummaryFile, into id: UUID) {
        guard let m = library.minute(id) else { return }
        let open = detail?.minute.id == id
        let transcript = open ? detail?.transcript : library.loadTranscript(id)
        let problems = file.mismatches(minute: m, transcript: transcript)
        let apply = { [weak self] in
            guard let self else { return }
            self.addSummary(file.makeSummary(), to: id)
            self.showToast(open ? L("已导入纪要") : L("已将纪要导入「{0}」", m.title))
        }
        if problems.isEmpty {
            apply()
            return
        }
        confirmRequest = ConfirmRequest(
            title: L("纪要文件与「{0}」的信息不符", m.title),
            message: problems.map { "· " + $0.text }.joined(separator: "\n"),
            confirmTitle: L("仍要导入"),
            emphasis: L("这份纪要可能不是根据这个妙记生成的。仍要导入吗？"),
            destructive: false,
            onConfirm: apply
        )
    }
}
