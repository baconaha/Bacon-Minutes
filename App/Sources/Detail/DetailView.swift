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
                    .overlay(Text(L("松开以导入（SRT 将导入到当前妙记）")).font(.system(size: 14, weight: .medium)).foregroundStyle(Color.brand))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            if model.isVideoFullscreen { model.isVideoFullscreen = false }
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
                SummaryPanel(model: model)
                    .opacity(model.rightTab == .summary ? 1 : 0)
                    .allowsHitTesting(model.rightTab == .summary)
                    .zIndex(model.rightTab == .summary ? 1 : 0)
                TranscriptPanel(model: model)
                    .opacity(model.rightTab == .transcript ? 1 : 0)
                    .allowsHitTesting(model.rightTab == .transcript)
                    .zIndex(model.rightTab == .transcript ? 1 : 0)
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
    @State private var editingTitle = false
    @State private var titleDraft = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Button { app.backToList() } label: {
                Image(systemName: "chevron.left").font(.system(size: 15, weight: .medium))
            }
            .buttonStyle(IconButtonStyle(size: 30, foreground: .textPrimary))
            .help(L("返回列表（⌘[）"))

            AppLogo(size: 32)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if editingTitle {
                        TextField(L("标题"), text: $titleDraft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 16, weight: .semibold))
                            .focused($titleFocused)
                            .frame(maxWidth: 420)
                            .onSubmit { commitTitle() }
                            .onExitCommand { editingTitle = false }
                            .onChange(of: titleFocused) { if !titleFocused && editingTitle { commitTitle() } }
                    } else {
                        Text(model.minute.title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .onTapGesture(count: 2) { beginTitleEdit() }
                            .help(L("双击修改标题"))
                    }
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
                [
                    .button(L("重新导入 SRT…"), icon: "captions.bubble") { model.chooseAndImportSRT() },
                    .button(L("更换媒体文件…"), icon: "film") { model.relocateMedia() },
                    .button(L("在 Finder 中显示"), icon: "folder") { model.revealMedia() },
                    .divider,
                    .button(L("移到回收站"), icon: "trash", destructive: true) { app.requestMoveToTrash([model.minute.id]) },
                ]
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

    private func beginTitleEdit() {
        titleDraft = model.minute.title
        editingTitle = true
        titleFocused = true
    }

    private func commitTitle() {
        editingTitle = false
        model.renameTitle(titleDraft)
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
    ]
}
