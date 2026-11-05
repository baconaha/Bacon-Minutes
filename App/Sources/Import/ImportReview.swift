import AppKit
import Foundation
import Observation

/// One media file in the batch import dialog and the subtitle picked for it.
struct ImportReviewRow: Identifiable {
    let id = UUID()
    let media: URL
    var subtitle: URL?
    /// Picked because it is the only subtitle in the folder, not by its name.
    var guessed = false
    var included = true
    var duration: Double?
    var hasVideo: Bool
    var size: Int64?
    var thumbnail: NSImage?
    var thumbnailJPEG: Data?
    /// Duration, size and thumbnail have been read.
    var inspected = false
}

/// What a drop or a chosen folder would import, shown for review before anything is copied.
@MainActor
@Observable
final class ImportReview: Identifiable {
    let id = UUID()
    var rows: [ImportReviewRow]
    /// Every subtitle found, for the per-row picker.
    let subtitles: [URL]
    /// Files in formats the app cannot use (mkv, ass, …).
    let skipped: [URL]
    /// Name of the folder that was dropped or chosen, when there was exactly one.
    let sourceName: String?
    let folderID: UUID?
    /// Off by default: media is copied into the app unless the user asks for links.
    var linkOnly = false
    @ObservationIgnored private var task: Task<Void, Never>?

    init(rows: [ImportReviewRow], subtitles: [URL], skipped: [URL], sourceName: String?, folderID: UUID?) {
        self.rows = rows
        self.subtitles = subtitles
        self.skipped = skipped
        self.sourceName = sourceName
        self.folderID = folderID
    }

    var includedRows: [ImportReviewRow] { rows.filter(\.included) }

    var totalBytes: Int64 { includedRows.reduce(0) { $0 + ($1.size ?? 0) } }

    /// Subtitles not attached to any included row.
    var unclaimedSubtitles: [URL] {
        let used = Set(includedRows.compactMap(\.subtitle))
        return subtitles.filter { !used.contains($0) }
    }

    func setSubtitle(_ url: URL?, forRow id: UUID) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].subtitle = url
        rows[i].guessed = false
    }

    func toggle(_ id: UUID) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].included.toggle()
    }

    var allIncluded: Bool { rows.allSatisfy(\.included) }

    func setAll(_ on: Bool) {
        for i in rows.indices { rows[i].included = on }
    }

    /// Reads duration, size and a cover frame for each row, one after another.
    func loadDetails() {
        task?.cancel()
        let items = rows.map { ($0.id, $0.media) }
        task = Task { [weak self] in
            for (id, url) in items {
                if Task.isCancelled { return }
                let size = await Task.detached(priority: .utility) { Library.fileSize(of: url) }.value
                let info = try? await MediaInspector.inspect(url: url)
                let isVideo = info?.hasVideo ?? (MediaTypes.kind(of: url) == .video)
                var jpeg: Data?
                if isVideo { jpeg = await MediaInspector.coverJPEG(url: url, duration: info?.duration ?? 0) }
                if Task.isCancelled { return }
                guard let self, let i = self.rows.firstIndex(where: { $0.id == id }) else { return }
                self.rows[i].size = size
                self.rows[i].duration = info?.duration
                self.rows[i].hasVideo = isVideo
                self.rows[i].thumbnailJPEG = jpeg
                self.rows[i].thumbnail = jpeg.flatMap { NSImage(data: $0) }
                self.rows[i].inspected = true
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

/// One file to import, after review.
struct ImportItem {
    var media: URL
    var subtitle: URL?
    /// Cover frame already made for the review dialog.
    var cover: Data?
}

/// Shown in the list title row while files are being imported.
struct ImportProgress: Equatable {
    var index: Int
    var total: Int
    /// Copy progress of the current file (0…1); nil when only linking.
    var fraction: Double?
}
