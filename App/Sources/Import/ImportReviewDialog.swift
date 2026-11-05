import AppKit
import SwiftUI

/// Batch import review: every detected video with its subtitle, one pair per row, and the
/// choice between copying the files into the app (default) and only linking to them.
struct ImportReviewDialog: View {
    let app: AppModel
    @Bindable var review: ImportReview
    @State private var closing = false
    @State private var confirmed = false

    private var included: Int { review.includedRows.count }

    var body: some View {
        FlipDialog(width: 720, onClosed: finish, closeRequest: $closing) {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 26)
                    .padding(.top, 24)
                    .padding(.bottom, 16)
                Rectangle().fill(Color.divider).frame(height: 1)
                rows
                Rectangle().fill(Color.divider).frame(height: 1)
                footer
                    .padding(.horizontal, 26)
                    .padding(.top, 16)
                    .padding(.bottom, 22)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.selectionFill)
                    .frame(width: 40, height: 40)
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.brand)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(review.rows.count == 1 ? L("导入妙记") : L("导入 {0} 个妙记", review.rows.count))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Text(subtitleText)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textTertiary)
                    .lineLimit(2)
            }
            Spacer()
            if review.rows.count > 1 {
                Button(review.allIncluded ? L("全不选") : L("全选")) { review.setAll(!review.allIncluded) }
                    .buttonStyle(TextLinkButtonStyle())
                    .padding(.top, 4)
            }
        }
    }

    private var subtitleText: String {
        let counts = L("检测到 {0} 个媒体文件、{1} 个字幕", review.rows.count, review.subtitles.count)
        var parts: [String] = []
        if let name = review.sourceName { parts.append(L("来自「{0}」", name)) }
        parts.append(counts)
        if let id = review.folderID, let f = app.library.userFolder(id) { parts.append(L("将导入到「{0}」", f.name)) }
        return parts.joined(separator: " · ")
    }

    // MARK: Rows

    private var rows: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(review.rows) { row in
                    ImportReviewRowView(row: row, subtitles: review.subtitles, usedElsewhere: usedSubtitles(except: row.id),
                                        toggle: { review.toggle(row.id) },
                                        pick: { review.setSubtitle($0, forRow: row.id) })
                }
                if !review.unclaimedSubtitles.isEmpty {
                    note(icon: "captions.bubble", text: L("{0} 个字幕没有配对：{1}。可以在右侧为视频指定。",
                                                         review.unclaimedSubtitles.count, names(review.unclaimedSubtitles)))
                }
                if !review.skipped.isEmpty {
                    note(icon: "nosign", text: L("已跳过 {0} 个不支持的文件：{1}", review.skipped.count, names(review.skipped)))
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .frame(maxHeight: 400)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func usedSubtitles(except id: UUID) -> Set<URL> {
        Set(review.rows.filter { $0.id != id && $0.included }.compactMap(\.subtitle))
    }

    private func names(_ urls: [URL]) -> String {
        let shown = urls.prefix(4).map(\.lastPathComponent).joined(separator: Localizer.shared.language.listSeparator)
        return urls.count > 4 ? shown + L(" 等") : shown
    }

    private func note(icon: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Color.textTertiary)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Color.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 2)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: review.linkOnly ? "link" : "internaldrive")
                        .font(.system(size: 15))
                        .foregroundStyle(review.linkOnly ? Color.warningText : Color.brand)
                        .frame(width: 20)
                        .padding(.top, 1)
                    Text(storageText)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.textSecondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    review.linkOnly.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: review.linkOnly ? "checkmark.square.fill" : "square")
                            .font(.system(size: 15))
                            .foregroundStyle(review.linkOnly ? Color.brand : Color.textTertiary)
                        Text(L("只链接文件路径（不复制到应用）"))
                            .font(.system(size: 13))
                            .foregroundStyle(Color.textPrimary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 30)
                if review.linkOnly {
                    Text(L("链接后，源文件被移动、改名，或所在的磁盘、NAS 断开时，需要在妙记里「重新检测路径」或重新导入。"))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.warningText)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 30)
                        .transition(.opacity)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(review.linkOnly ? Color.warningFill.opacity(0.6) : Color.searchFill.opacity(0.6)))
            .animation(.easeOut(duration: 0.15), value: review.linkOnly)

            HStack(spacing: 12) {
                Spacer()
                Button(L("取消")) { closing = true }
                    .buttonStyle(DialogCancelButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(included == 1 ? L("导入") : L("导入 {0} 个", included)) {
                    confirmed = true
                    closing = true
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(included == 0)
            }
        }
    }

    private var storageText: String {
        if review.linkOnly {
            return L("妙记只记住源文件的位置，不会另外复制一份。")
        }
        let bytes = review.totalBytes
        let size = bytes > 0 ? L("（共 {0}）", AppModel.byteText(bytes)) : ""
        return L("默认把源文件复制一份保存到应用内{0}。之后原文件移动、改名或删除，都不影响播放。", size)
    }

    private func finish() {
        app.importReview = nil
        review.cancel()
        if confirmed { app.confirmImportReview(review) }
    }
}

private struct ImportReviewRowView: View {
    let row: ImportReviewRow
    let subtitles: [URL]
    let usedElsewhere: Set<URL>
    let toggle: () -> Void
    let pick: (URL?) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 14) {
            CheckBox(checked: row.included, action: toggle)
            thumbnail
            VStack(alignment: .leading, spacing: 6) {
                Text(row.media.lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(detailText)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Color.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.textTertiary.opacity(row.subtitle == nil ? 0.4 : 1))
            subtitlePicker
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hovering ? Color.rowHover : Color.searchFill.opacity(0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.divider.opacity(0.7))
        )
        .opacity(row.included ? 1 : 0.5)
        .animation(.easeOut(duration: 0.12), value: row.included)
        .onHover { hovering = $0 }
    }

    private var detailText: String {
        guard row.inspected else { return L("正在读取…") }
        var parts: [String] = []
        if let d = row.duration, d > 0 { parts.append(TimeFormat.duration(d)) }
        if let s = row.size, s > 0 { parts.append(AppModel.byteText(s)) }
        if !row.hasVideo { parts.append(L("音频")) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private var thumbnail: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                if let image = row.thumbnail {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(colors: [.audioCoverTop, .audioCoverBottom], startPoint: .top, endPoint: .bottom)
                    if row.inspected {
                        Image(systemName: row.hasVideo ? "film" : "waveform")
                            .font(.system(size: 20))
                            .foregroundStyle(Color.brand.opacity(0.75))
                    } else {
                        SkeletonBlock(width: 112, height: 63, radius: 0)
                    }
                }
            }
            .frame(width: 112, height: 63)
            .clipped()
            if let d = row.duration, d > 0 {
                Text(TimeFormat.compactDuration(d))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.6)))
                    .padding(4)
            }
        }
        .frame(width: 112, height: 63)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.divider.opacity(0.6)))
    }

    private var subtitlePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            DropdownButton(alignment: .trailing, minWidth: 240, openOnHover: false, items: { pickerItems }) { open in
                HStack(spacing: 8) {
                    Image(systemName: row.subtitle == nil ? "captions.bubble" : "captions.bubble.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(row.subtitle == nil ? Color.textTertiary : Color.brand)
                    Text(row.subtitle?.lastPathComponent ?? L("无字幕"))
                        .font(.system(size: 13))
                        .foregroundStyle(row.subtitle == nil ? Color.textTertiary : Color.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.textTertiary)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .padding(.horizontal, 10)
                .frame(width: 230, height: 32)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.card))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(open ? Color.brand : (row.guessed ? Color.warningText.opacity(0.6) : Color.divider)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!row.included)
            if row.guessed {
                Text(L("按文件夹推测，请确认"))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.warningText)
                    .padding(.leading, 2)
            }
        }
    }

    private var pickerItems: [DropdownItem] {
        var items: [DropdownItem] = [
            .button(L("不使用字幕"), icon: "nosign", selected: row.subtitle == nil) { pick(nil) },
        ]
        if !subtitles.isEmpty { items.append(.divider) }
        for s in subtitles {
            let title = usedElsewhere.contains(s) ? L("{0}（已用于其他视频）", s.lastPathComponent) : s.lastPathComponent
            items.append(.button(title, icon: "captions.bubble", selected: row.subtitle == s) { pick(s) })
        }
        return items
    }
}
