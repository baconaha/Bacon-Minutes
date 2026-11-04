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
        TitleTextField(text: $draft, font: Self.font,
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

private struct TitleTextField: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    let onFocus: () -> Void
    let onEnd: (_ cancelled: Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> FocusReportingTextField {
        let field = FocusReportingTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.textColor = Palette.textPrimary
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.stringValue = text
        field.delegate = context.coordinator
        field.onFocus = { [weak coordinator = context.coordinator] in
            MainActor.assumeIsolated { coordinator?.began() }
        }
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: FocusReportingTextField, context: Context) {
        context.coordinator.parent = self
        if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }
    }

    static func dismantleNSView(_ field: FocusReportingTextField, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TitleTextField
        weak var field: NSTextField?
        private var active = false
        private var monitor: Any?

        init(parent: TitleTextField) {
            self.parent = parent
        }

        func began() {
            guard !active else { return }
            active = true
            parent.onFocus()
            // A click anywhere outside the field ends editing and saves; the click still goes through.
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, let field = self.field else { return }
                    let inside = event.window === field.window
                        && field.bounds.contains(field.convert(event.locationInWindow, from: nil))
                    if !inside { self.finish(cancelled: false) }
                }
                return event
            }
        }

        func finish(cancelled: Bool) {
            guard active else { return }
            active = false
            removeMonitor()
            if let field, field.currentEditor() != nil {
                field.window?.makeFirstResponder(nil)
            }
            parent.onEnd(cancelled)
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            finish(cancelled: false)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                finish(cancelled: true)
                return true
            }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                finish(cancelled: false)
                return true
            }
            return false
        }
    }
}

/// Tells its owner when it takes focus (a click), before any typing.
final class FocusReportingTextField: NSTextField {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?() }
        return ok
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
