import AppKit
import Combine
import SwiftUI

/// Detail page layout (§1): top bar, video + speakers on the left, summary / transcript card on the right.
struct DetailView: View {
    @Bindable var model: DetailModel
    let app: AppModel
    @State private var dropTargeted = false
    /// Split while the divider is being dragged; persisted once on release.
    @State private var liveSplit: Double?

    var body: some View {
        Group {
            if model.isVideoFullscreen {
                PlayerArea(model: model)
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 0) {
                    DetailTopBar(model: model, app: app)
                        .frame(height: 64)
                    columns
                        .padding([.horizontal, .bottom], 8)
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted && !model.isVideoFullscreen {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.brand, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .overlay(Text(L("松开以导入（SRT 或纪要文件将导入到当前妙记）")).font(.system(size: 14, weight: .medium)).foregroundStyle(Color.brand))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            if model.isVideoFullscreen { model.isVideoFullscreen = false }
        }
        // Back from Finder, where the file may have been moved back: look again, quietly.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if model.mediaState == .missing { model.recheckMedia(silent: true) }
        }
        .onChange(of: model.settings.general.insertComma) { model.rebuildDocument() }
    }

    private static let columnSpace = "detailColumns"

    private static func clampSplit(_ v: Double) -> Double { min(max(v, 0.38), 0.7) }

    private var columns: some View {
        GeometryReader { geo in
            let total = geo.size.width
            let split = liveSplit ?? Self.clampSplit(app.settings.general.detailSplit)
            let leftWidth = ((total - 1) * split).rounded()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    PlayerArea(model: model)
                        .frame(width: leftWidth, height: min((leftWidth * 9 / 16).rounded(), max(220, geo.size.height - 160)))
                    LeftBottomPanel(model: model)
                }
                .frame(width: leftWidth)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 0))

                SplitHandle()
                    .gesture(
                        // Measured in the fixed column space, not relative to the moving handle,
                        // so the divider follows the pointer without feedback jitter.
                        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.columnSpace))
                            .onChanged { g in
                                liveSplit = Self.clampSplit(Double(g.location.x / max(total, 1)))
                            }
                            .onEnded { _ in
                                if let s = liveSplit { app.settings.general.detailSplit = s }
                                liveSplit = nil
                            }
                    )

                RightCard(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .transaction { $0.animation = nil }
        }
        .coordinateSpace(.named(Self.columnSpace))
    }

    private func handleDrop(_ urls: [URL]) {
        let files = FilePanels.expand(urls)
        if let summaryFile = files.first(where: MediaTypes.isSummaryFile), !files.contains(where: MediaTypes.isMedia) {
            model.importSummaryFile(summaryFile)
            return
        }
        if let srt = files.first(where: MediaTypes.isSubtitle), !files.contains(where: MediaTypes.isMedia) {
            model.importSRT(from: srt)
        } else {
            app.importURLs(urls)
        }
    }
}

private struct SplitHandle: View {
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(hovering ? Color.brand.opacity(0.5) : Color.divider)
            .frame(width: 1)
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
            .padding(.horizontal, -3)
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    if !hovering { hovering = true }
                    NSCursor.resizeLeftRight.set()
                case .ended:
                    hovering = false
                    NSCursor.arrow.set()
                }
            }
    }
}

private struct RightCard: View {
    @Bindable var model: DetailModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 28) {
                UnderlineTab(title: L("智能纪要"), selected: model.rightTab == .summary) { model.rightTab = .summary }
                UnderlineTab(title: L("文字记录"), selected: model.rightTab == .transcript) { model.rightTab = .transcript }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            Rectangle().fill(Color.divider).frame(height: 1)

            ZStack {
                // The transcript stays alive (its text layout is expensive) and is only hidden.
                TranscriptPanel(model: model)
                    .opacity(model.rightTab == .transcript ? 1 : 0)
                    .allowsHitTesting(model.rightTab == .transcript)
                // The summary is built only while its tab is showing, after (so above) the
                // transcript's AppKit views. Kept alive and hidden, it sometimes came back blank.
                if model.rightTab == .summary {
                    SummaryPanel(model: model)
                        .background(Color.card)
                }
            }
        }
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 0, topTrailingRadius: 8)
                .fill(Color.card)
        )
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0, topTrailingRadius: 8))
    }
}

// MARK: - Top bar (§2)

private struct DetailTopBar: View {
    @Bindable var model: DetailModel
    let app: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Button { app.backToList() } label: {
                Image(systemName: "chevron.left").font(.system(size: 15, weight: .medium))
            }
            .buttonStyle(IconButtonStyle(size: 30, foreground: .textPrimary, pointingHand: true))
            .help(L("返回列表（⌘[）"))

            AppLogo(size: 32)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    EditableTitle(title: model.minute.title) { model.renameTitle($0) }
                    StorageTag(model: model, app: app)
                    ForEach(Array(model.tags.enumerated()), id: \.offset) { _, tag in
                        TagLabel(text: tag.0, warning: tag.1)
                    }
                }
                HStack(spacing: 8) {
                    Text(TimeFormat.createdDate(model.minute.createdAt))
                    Rectangle().fill(Color.divider).frame(width: 1, height: 10)
                    Text(TimeFormat.duration(model.duration))
                }
                .font(.system(size: 12))
                .foregroundStyle(Color.textTertiary)
            }

            Spacer(minLength: 20)

            DropdownButton(alignment: .trailing, items: { exportMenuItems(for: model) }) { _ in
                Label(L("导出"), systemImage: "square.and.arrow.up")
            }
            .buttonStyle(PrimaryButtonStyle())
            .fixedSize()

            DropdownButton(alignment: .trailing, items: {
                var items: [DropdownItem] = [
                    .button(L("重新导入 SRT…"), icon: "captions.bubble") { model.chooseAndImportSRT() },
                    .button(L("导入纪要文件…"), icon: "doc.badge.plus") { model.chooseAndImportSummaryFile() },
                    .button(L("更换媒体文件…"), icon: "film") { model.relocateMedia() },
                    .button(L("在 Finder 中显示"), icon: "folder") { model.revealMedia() },
                ]
                if model.minute.storage == .linked {
                    items.append(.button(L("将源文件导入应用…"), icon: "internaldrive",
                                         disabled: app.copyingMedia[model.minute.id] != nil) {
                        app.requestImportIntoApp(model.minute.id)
                    })
                }
                items += [
                    .divider,
                    .button(L("移到回收站"), icon: "trash", destructive: true) { app.requestMoveToTrash([model.minute.id]) },
                ]
                return items
            }) { open in
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 6).fill(open ? Color.searchFill : Color.clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("更多"))
        }
        // The window buttons sit in their own strip above this bar, so it can start at the edge.
        .padding(.leading, 12)
        .padding(.trailing, 16)
    }
}

// MARK: - Editable title

/// Title that edits in place, like a Google Docs title: I-beam on hover, a click puts the caret
/// there, and Return or a click anywhere else saves. Esc restores the old title.
private struct EditableTitle: View {
    let title: String
    let commit: (String) -> Void
    @State private var draft = ""
    @State private var editing = false
    @State private var hovering = false

    private static let font = NSFont.systemFont(ofSize: 16, weight: .semibold)
    private static let maxWidth: CGFloat = 520

    private var width: CGFloat {
        let text = draft.isEmpty ? title : draft
        let w = (text as NSString).size(withAttributes: [.font: Self.font]).width
        return min(max(ceil(w) + 6, 40), Self.maxWidth)
    }

    var body: some View {
        InlineTextField(text: $draft, font: Self.font,
                       onFocus: { editing = true },
                       onEnd: { cancelled in
                           editing = false
                           if cancelled {
                               draft = title
                           } else {
                               let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                               if t.isEmpty { draft = title } else { commit(t) }
                           }
                       })
            .frame(width: width, height: 24)
            .padding(.horizontal, 5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(editing ? Color.brand : (hovering ? Color.divider : Color.clear), lineWidth: editing ? 1.5 : 1)
            )
            // Line the text up with the date row below while keeping room for the outline.
            .padding(.leading, -5)
            .onHover { hovering = $0 }
            .onAppear { draft = title }
            .onChange(of: title) { if !editing { draft = title } }
            .help(editing ? "" : L("点击修改标题"))
    }
}

/// Shared by the top bar "导出" button and the transcript "···" menu (§2, §5.1).
@MainActor
func exportMenuItems(for model: DetailModel) -> [DropdownItem] {
    let noTranscript = model.transcript == nil
    return [
        .button(L("导出 SRT"), icon: "captions.bubble", disabled: noTranscript) { model.export(.srt) },
        .button(L("导出 TXT（带时间戳与发言人）"), icon: "doc.plaintext", disabled: noTranscript) { model.export(.txt) },
        .button(L("导出 Markdown（纪要 + 文字记录）"), icon: "doc.richtext") { model.export(.markdown) },
        .divider,
        .button(L("导出纪要文件（.{0}）", SummaryFile.fileExtension), icon: "sparkles.rectangle.stack",
                disabled: model.summary == nil) { model.exportSummaryFile() },
    ]
}

// MARK: - Storage tag

/// "应用内" or "链接": where the media lives. The link tag opens a menu with the path and
/// "导入到应用".
private struct StorageTag: View {
    let model: DetailModel
    let app: AppModel

    var body: some View {
        let id = model.minute.id
        if let p = app.copyingMedia[id] {
            StorageBadge(icon: "arrow.down.circle", text: L("正在导入应用 {0}%", Int((p * 100).rounded())), accent: true)
        } else if model.minute.storage == .imported {
            StorageBadge(icon: "internaldrive", text: L("应用内"), accent: true)
                .help(L("源文件已复制到应用内，原文件移动或删除都不影响播放。"))
        } else {
            DropdownButton(minWidth: 280, openOnHover: false, items: { linkItems }) { open in
                StorageBadge(icon: "link", text: L("链接"), accent: false, open: open)
            }
            .buttonStyle(.plain)
            .help(L("只链接了源文件的路径，点击查看"))
        }
    }

    private var linkItems: [DropdownItem] {
        [
            .button(model.minute.mediaPath.isEmpty ? model.minute.mediaFileName : model.minute.mediaPath,
                    icon: "doc", disabled: true) {},
            .divider,
            .button(L("在 Finder 中显示"), icon: "folder") { model.revealMedia() },
            .button(L("将源文件导入应用…"), icon: "internaldrive") { app.requestImportIntoApp(model.minute.id) },
        ]
    }
}

struct StorageBadge: View {
    let icon: String
    let text: String
    var accent: Bool
    var open = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9, weight: .semibold))
            Text(text).font(.system(size: 11))
            if !accent {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
        }
        .foregroundStyle(accent ? Color.brand : Color.textSecondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 3).fill(accent ? Color.selectionFill : Color.searchFill))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(open ? Color.brand.opacity(0.6) : Color.clear))
        .fixedSize()
    }
}
