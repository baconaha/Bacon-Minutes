import SwiftUI

/// "导入音视频文件" sheet (§9.1).
struct ImportDialog: View {
    @Bindable var app: AppModel
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(L("导入音视频文件"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                Button { app.showImportDialog = false } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(IconButtonStyle())
            }

            dropZone

            if let id = app.currentFolderID, let folder = app.library.userFolder(id) {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill").foregroundStyle(Color.brand)
                    Text(L("将导入到「{0}」", folder.name)).foregroundStyle(Color.textSecondary)
                }
                .font(.system(size: 13))
            }

            VStack(spacing: 10) {
                FileSlotRow(title: L("媒体文件"), url: app.importDraft.media, placeholder: L("未选择（必选）")) {
                    if let url = FilePanels.chooseMedia() { app.importDraft.media = url }
                }
                FileSlotRow(title: L("字幕文件"), url: app.importDraft.subtitle, placeholder: L("未选择（可选，之后也能补导）")) {
                    if let url = FilePanels.chooseSRT() { app.importDraft.subtitle = url }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Button {
                    app.importDraft.linkOnly.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: app.importDraft.linkOnly ? "checkmark.square.fill" : "square")
                            .font(.system(size: 15))
                            .foregroundStyle(app.importDraft.linkOnly ? Color.brand : Color.textTertiary)
                        Text(L("只链接文件路径（不复制到应用）"))
                            .font(.system(size: 13))
                            .foregroundStyle(Color.textPrimary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text(app.importDraft.linkOnly
                     ? L("链接后，源文件被移动、改名，或所在的磁盘、NAS 断开时，需要在妙记里「重新检测路径」或重新导入。")
                     : L("默认把源文件复制一份保存到应用内，之后原文件移动、改名或删除，都不影响播放。"))
                    .font(.system(size: 12))
                    .foregroundStyle(app.importDraft.linkOnly ? Color.warningText : Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 23)
            }

            HStack(spacing: 12) {
                Spacer()
                Button(L("取消")) { app.showImportDialog = false }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(L("导入")) { app.importFromDialog() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(app.importDraft.media == nil)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 540)
        .background(Color.card)
    }

    private var dropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Color.brand)
            HStack(spacing: 0) {
                Text(L("将文件拖拽至此区域或 "))
                    .foregroundStyle(Color.textSecondary)
                Button(L("选择文件")) { choose() }
                    .buttonStyle(TextLinkButtonStyle(size: 14))
            }
            .font(.system(size: 14))
            Text(L("媒体：mp4 / mov / m4v / mp3 / m4a / wav / aac　字幕：srt"))
                .font(.system(size: 12))
                .foregroundStyle(Color.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 190)
        .background(RoundedRectangle(cornerRadius: 8).fill(targeted ? Color.selectionFill.opacity(0.5) : Color.searchFill.opacity(0.4)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(targeted ? Color.brand : Color.divider, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
        .dropDestination(for: URL.self) { urls, _ in
            accept(urls)
            return true
        } isTargeted: { targeted = $0 }
    }

    private func choose() {
        let urls = FilePanels.chooseFiles(message: L("选择音视频文件，可同时选择对应的 SRT 字幕"))
        if !urls.isEmpty { accept(urls) }
    }

    private func accept(_ urls: [URL]) {
        let files = FilePanels.expand(urls)
        let media = files.filter(MediaTypes.isMedia)
        let subs = files.filter(MediaTypes.isSubtitle)
        if media.count > 1 || subs.count > 1 {
            // Several files: hand over to the batch importer with automatic pairing.
            app.showImportDialog = false
            app.importURLs(urls)
            return
        }
        if let m = media.first { app.importDraft.media = m }
        if let s = subs.first { app.importDraft.subtitle = s }
    }
}

private struct FileSlotRow: View {
    let title: String
    let url: URL?
    let placeholder: String
    let change: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Color.textTertiary)
                .frame(width: 64, alignment: .leading)
            if let url {
                Image(systemName: MediaTypes.isSubtitle(url) ? "captions.bubble" : "film")
                    .foregroundStyle(Color.brand)
                Text(url.lastPathComponent)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(placeholder)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.textTertiary)
            }
            Spacer()
            Button(url == nil ? L("选择") : L("更换"), action: change)
                .buttonStyle(TextLinkButtonStyle())
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.searchFill.opacity(0.6)))
    }
}
