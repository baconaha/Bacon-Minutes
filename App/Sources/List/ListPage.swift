import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Library home (§9.5): sidebar with folders and stats + searchable, sortable list with multi-select and trash.
struct ListPage: View {
    @Bindable var app: AppModel
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            ListSidebar(app: app)
                .frame(width: 240)
            Rectangle().fill(Color.divider).frame(width: 1)
            ListContent(app: app)
                .background(Color.card)
        }
        // The sidebar runs up under the window buttons, like Finder.
        .ignoresSafeArea(.container, edges: .top)
        .dropDestination(for: URL.self) { urls, _ in
            app.importURLs(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.brand, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.brand.opacity(0.06)))
                    .overlay(Text(dropText).font(.system(size: 15, weight: .medium)).foregroundStyle(Color.brand))
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .alert(L("重命名"), isPresented: Binding(get: { app.renameTarget != nil },
                                            set: { if !$0 { app.renameTarget = nil } })) {
            TextField(L("标题"), text: $app.renameText)
            Button(L("确定")) { app.commitRename() }
            Button(L("取消"), role: .cancel) { app.renameTarget = nil }
        }
    }

    private var dropText: String {
        if let id = app.currentFolderID, let f = app.library.userFolder(id) { return L("松开以导入到「{0}」", f.name) }
        return L("松开以导入")
    }
}

// MARK: - Sidebar

private struct ListSidebar: View {
    @Bindable var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                AppLogo(size: 28)
                Text(L("培根妙记"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
            }
            .padding(.horizontal, 4)
            .padding(.top, app.isWindowFullScreen ? 18 : 44)
            .padding(.bottom, 18)

            ForEach(ListSection.allCases) { s in
                SidebarItem(title: s.title, icon: s.icon, selected: app.section == s.scope) {
                    app.section = s.scope
                    app.selection = []
                    app.folderSelection = []
                }
            }

            HStack {
                Text(L("文件夹"))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textTertiary)
                Spacer()
                Button { app.createFolder() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(IconButtonStyle(size: 22, foreground: .textSecondary, hoverFill: .card))
                .help(L("新建文件夹"))
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .padding(.top, 16)
            .padding(.bottom, 2)

            FolderList(app: app)

            LibraryStatsView(stats: app.library.stats())
                .padding(.top, 10)
            Rectangle().fill(Color.divider).frame(height: 1).padding(.vertical, 8)
            SettingsLink {
                SidebarItemLabel(title: L("设置"), icon: "gearshape", selected: false)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 14)
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.sidebarFill)
    }
}

private struct SidebarItem: View {
    let title: String
    let icon: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SidebarItemLabel(title: title, icon: icon, selected: selected)
        }
        .buttonStyle(.plain)
    }
}

private struct SidebarItemLabel: View {
    let title: String
    let icon: String
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .frame(width: 18)
            Text(title).font(.system(size: 14))
            Spacer()
        }
        .foregroundStyle(selected ? Color.brand : Color.textPrimary)
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color.selectionFill : (hovering ? Color.rowHover : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// Folder rows with drag-to-select: a drag that starts on empty space draws a selection
/// rectangle, and every folder it touches turns gray and is selected for batch actions.
private struct FolderList: View {
    @Bindable var app: AppModel
    static let space = "folderList"
    @State private var frames: [UUID: CGRect] = [:]
    @State private var marquee: CGRect?
    @State private var dragIgnored = false
    @State private var baseSelection: Set<UUID> = []

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(app.library.folders) { folder in
                        FolderRow(app: app, folder: folder)
                    }
                }
                // Fill the visible height so the empty space below the folders takes clicks and drags.
                .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .top)
                .contentShape(Rectangle())
                .coordinateSpace(.named(Self.space))
                .onPreferenceChange(FolderFramesKey.self) { frames = $0 }
                .overlay(alignment: .topLeading) {
                    if let r = marquee {
                        RoundedRectangle(cornerRadius: min(3, r.width / 2, r.height / 2))
                            .fill(Color.brand.opacity(0.08))
                            .overlay(RoundedRectangle(cornerRadius: min(3, r.width / 2, r.height / 2))
                                .strokeBorder(Color.brand.opacity(0.5), lineWidth: 1))
                            .frame(width: r.width, height: r.height)
                            .offset(x: r.minX, y: r.minY)
                            .allowsHitTesting(false)
                    }
                }
                .gesture(marqueeGesture)
                // A click on empty space clears the selection.
                .onTapGesture { app.folderSelection = [] }
            }
            .scrollIndicators(.never)
        }
    }

    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .onChanged { g in
                if marquee == nil && !dragIgnored {
                    // Only from empty space: a drag that starts on a folder belongs to that folder.
                    if frames.values.contains(where: { $0.contains(g.startLocation) }) {
                        dragIgnored = true
                        return
                    }
                    baseSelection = NSEvent.modifierFlags.contains(.command) ? app.folderSelection : []
                    app.selection = []
                }
                guard !dragIgnored else { return }
                let r = Self.marqueeRect(from: g.startLocation, to: g.location)
                marquee = r
                let touched = Set(frames.filter { Self.touches($0.value, r) }.map(\.key))
                let next = baseSelection.union(touched)
                if next != app.folderSelection { app.folderSelection = next }
            }
            .onEnded { _ in
                marquee = nil
                dragIgnored = false
            }
    }

    /// At least 2 pt each way, so a straight vertical or horizontal drag still draws a visible
    /// box and still selects what it crosses.
    static func marqueeRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        let minSide: CGFloat = 2
        let w = max(abs(b.x - a.x), minSide)
        let h = max(abs(b.y - a.y), minSide)
        let x = b.x >= a.x ? a.x : a.x - w
        let y = b.y >= a.y ? a.y : a.y - h
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Overlap test that counts touching edges (`CGRect.intersects` is false for thin rects).
    static func touches(_ f: CGRect, _ r: CGRect) -> Bool {
        r.minX <= f.maxX && r.maxX >= f.minX && r.minY <= f.maxY && r.maxY >= f.minY
    }
}

private struct FolderFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct FolderRow: View {
    @Bindable var app: AppModel
    let folder: Folder
    @State private var hovering = false
    @State private var dropTargeted = false

    private var selected: Bool { app.section == .folder(folder.id) }
    private var editing: Bool { app.renamingFolderID == folder.id }
    /// Part of a drag / ⌘-click selection.
    private var inBatch: Bool { app.folderSelection.contains(folder.id) }
    private var batchActions: Bool { inBatch && app.folderSelection.count > 1 }

    private var fill: Color {
        if dropTargeted { return .selectionFill }
        if inBatch { return .divider }
        if selected { return .selectionFill }
        return hovering ? .rowHover : .clear
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: selected ? "folder.fill" : "folder")
                .font(.system(size: 14))
                .frame(width: 18)
            if editing {
                FolderNameField(app: app, folder: folder, selected: selected)
            } else {
                Text(folder.name)
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if hovering {
                MoreMenuButton(size: 22, help: L("文件夹操作"), openOnHover: false) { batchActions ? batchItems : menuItems }
            } else {
                Text("\(app.library.stats(inFolder: folder.id).count)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Color.textTertiary)
            }
        }
        .foregroundStyle(selected ? Color.brand : Color.textPrimary)
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(fill)
                .animation(.easeOut(duration: 0.1), value: inBatch)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(dropTargeted ? Color.brand : Color.clear, lineWidth: 1.5)
        )
        .background(GeometryReader { g in
            Color.clear.preference(key: FolderFramesKey.self, value: [folder.id: g.frame(in: .named(FolderList.space))])
        })
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) {
                // ⌘-click adds or removes one folder from the selection.
                if inBatch { app.folderSelection.remove(folder.id) } else { app.folderSelection.insert(folder.id) }
                return
            }
            app.folderSelection = []
            app.section = .folder(folder.id)
            app.selection = []
        }
        .onDrop(of: [.utf8PlainText], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
        .contextMenu {
            if batchActions {
                Button(L("取消选择")) { app.folderSelection = [] }
                Divider()
                Button(L("删除 {0} 个文件夹", app.folderSelection.count)) { app.requestDeleteFolders(app.folderSelection) }
            } else {
                Button(L("属性")) { app.folderInfoTarget = folder.id }
                Button(L("重命名")) { app.renamingFolderID = folder.id }
                Button(L("导入到此文件夹…")) { app.importIntoFolder(folder.id) }
                Divider()
                Button(L("删除文件夹")) { app.requestDeleteFolder(folder.id) }
            }
        }
    }

    /// Menu for a multi-folder selection.
    private var batchItems: [DropdownItem] {
        [
            .button(L("取消选择"), icon: "xmark.circle") { app.folderSelection = [] },
            .divider,
            .button(L("删除 {0} 个文件夹", app.folderSelection.count), icon: "trash", destructive: true) {
                app.requestDeleteFolders(app.folderSelection)
            },
        ]
    }

    private var menuItems: [DropdownItem] {
        [
            .button(L("属性"), icon: "info.circle") { app.folderInfoTarget = folder.id },
            .button(L("重命名"), icon: "pencil") { app.renamingFolderID = folder.id },
            .button(L("导入到此文件夹…"), icon: "square.and.arrow.down") { app.importIntoFolder(folder.id) },
            .divider,
            .button(L("删除文件夹"), icon: "trash", destructive: true) { app.requestDeleteFolder(folder.id) },
        ]
    }

    /// Minute rows are dragged as their id strings (one per line).
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        let target = folder.id
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String else { return }
            let ids = Set(text.split(whereSeparator: \.isNewline).compactMap { UUID(uuidString: String($0)) })
            Task { @MainActor in
                app.moveMinutes(ids, toFolder: target)
            }
        }
        return true
    }
}

/// Inline name editor for a folder: starts with the name selected; Return or a click anywhere
/// else saves, Esc keeps the old name.
private struct FolderNameField: View {
    let app: AppModel
    let folder: Folder
    let selected: Bool
    @State private var draft: String

    init(app: AppModel, folder: Folder, selected: Bool) {
        self.app = app
        self.folder = folder
        self.selected = selected
        _draft = State(initialValue: folder.name)
    }

    var body: some View {
        InlineTextField(text: $draft, font: .systemFont(ofSize: 14),
                        textColor: selected ? Palette.brand : Palette.textPrimary,
                        placeholder: L("文件夹名称"), autoFocus: true) { cancelled in
            if cancelled {
                app.renamingFolderID = nil
            } else {
                app.renameFolder(folder.id, to: draft)
            }
        }
        .frame(height: 20)
    }
}

private struct LibraryStatsView: View {
    let stats: Library.Stats

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row(L("妙记"), L("{0} 个", stats.count))
            row(L("总时长"), stats.count > 0 ? TimeFormat.roughDuration(stats.duration) : "—")
            row(L("总大小"), AppModel.byteText(stats.bytes))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.card.opacity(0.7)))
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundStyle(Color.textTertiary)
            Spacer()
            Text(v).foregroundStyle(Color.textSecondary).monospacedDigit()
        }
        .font(.system(size: 12))
    }
}

// MARK: - Content

private struct ListContent: View {
    @Bindable var app: AppModel
    @FocusState private var searchFocused: Bool

    private var items: [Minute] { app.visibleMinutes }
    private var isTrash: Bool { app.section == .trash }

    var body: some View {
        let items = self.items
        VStack(spacing: 0) {
            searchBar
            Rectangle().fill(Color.divider).frame(height: 1)
            titleRow
            headerRow(items: items)
            Rectangle().fill(Color.divider).frame(height: 1).padding(.horizontal, 24)
            if app.library.isLoading {
                skeleton
            } else if items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { m in
                            MinuteRow(app: app, minute: m, isTrash: isTrash)
                            Rectangle().fill(Color.divider).frame(height: 1).padding(.leading, 24)
                        }
                    }
                    .padding(.horizontal, 24)
                }
            }
        }
        .onChange(of: app.listSearchFocusToken) { searchFocused = true }
        // Checking recordings ends a folder selection, so ⌫ acts on what was picked last.
        .onChange(of: app.selection) { if !app.selection.isEmpty { app.folderSelection = [] } }
        .onChange(of: app.listQuery) {
            if !app.listQuery.isEmpty { app.library.ensureSearchIndex() }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.textTertiary)
            TextField(L("搜索妙记"), text: $app.listQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
            if !app.listQuery.isEmpty {
                Button { app.listQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(searchFocused ? Color.brand : Color.divider))
        .padding(.horizontal, 24)
        // Below the title-bar strip in a window; at the top in full screen.
        .padding(.top, app.isWindowFullScreen ? 20 : 36)
        .padding(.bottom, 14)
    }

    private var importingText: String {
        guard let p = app.importProgress else { return L("正在导入…") }
        var text = p.total > 1 ? L("正在导入 {0}/{1}", p.index, p.total) : L("正在导入…")
        if let f = p.fraction { text += L(" · 复制到应用 {0}%", Int((f * 100).rounded())) }
        return text
    }

    private var titleRow: some View {
        HStack(spacing: 8) {
            if app.currentFolderID != nil {
                Image(systemName: "folder.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.brand)
            }
            Text(app.sectionTitle)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
            if app.isImporting {
                ProgressView().controlSize(.small).padding(.leading, 6)
                Text(importingText).font(.system(size: 12).monospacedDigit()).foregroundStyle(Color.textTertiary)
            }
            Spacer()
            if !isTrash { ImportMenuButton(app: app) }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func headerRow(items: [Minute]) -> some View {
        let ids = Set(items.map(\.id))
        let selectedHere = app.selection.intersection(ids)
        HStack(spacing: 12) {
            CheckBox(checked: !ids.isEmpty && selectedHere.count == ids.count,
                     mixed: !selectedHere.isEmpty && selectedHere.count < ids.count) {
                if selectedHere.count == ids.count { app.selection.subtract(ids) } else { app.selection.formUnion(ids) }
            }
            .opacity(items.isEmpty ? 0 : 1)
            if !selectedHere.isEmpty {
                Text(L("已选 {0} 项", selectedHere.count)).font(.system(size: 13)).foregroundStyle(Color.textPrimary)
                Text("·").foregroundStyle(Color.textTertiary)
                if isTrash {
                    Button(L("恢复")) { app.restore(selectedHere) }.buttonStyle(TextLinkButtonStyle())
                    Text("·").foregroundStyle(Color.textTertiary)
                    Button(L("彻底删除")) { app.deleteForever(selectedHere) }.buttonStyle(TextLinkButtonStyle())
                } else {
                    Button(L("生成纪要")) {
                        // In list order, so the queue runs top to bottom.
                        app.batchSummaryTarget = items.map(\.id).filter { selectedHere.contains($0) }
                    }
                    .buttonStyle(TextLinkButtonStyle())
                    Text("·").foregroundStyle(Color.textTertiary)
                    Button(L("移动到文件夹")) { app.moveTarget = selectedHere }.buttonStyle(TextLinkButtonStyle())
                    Text("·").foregroundStyle(Color.textTertiary)
                    Button(L("移到回收站")) { app.requestMoveToTrash(selectedHere) }.buttonStyle(TextLinkButtonStyle())
                }
                Text("·").foregroundStyle(Color.textTertiary)
                Button(L("取消")) { app.selection = [] }.buttonStyle(TextLinkButtonStyle())
                Spacer()
            } else {
                Text(L("文件")).frame(maxWidth: .infinity, alignment: .leading)
                if isTrash {
                    Text(L("删除时间 ↓")).frame(width: 190, alignment: .leading)
                    Text(L("操作")).frame(width: 220, alignment: .leading)
                } else {
                    sortMenu.frame(width: 170, alignment: .leading)
                    Text(L("操作")).frame(width: 48, alignment: .leading)
                }
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Color.textTertiary)
        .lineLimit(1)
        .padding(.horizontal, 36)
        .frame(height: 40)
    }

    @ViewBuilder
    private var sortMenu: some View {
        if app.section != .recent {
            DropdownButton(minWidth: 140, items: {
                ListSort.allCases.map { sort in
                    DropdownItem.button(sort.title, selected: app.sort == sort) { app.sort = sort }
                }
            }) { _ in
                HStack(spacing: 4) {
                    Text(app.sort.headerTitle)
                    Image(systemName: "chevron.down").font(.system(size: 9))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
        } else {
            Text(L("最近打开"))
        }
    }

    private var skeleton: some View {
        VStack(spacing: 0) {
            ForEach(0..<5, id: \.self) { _ in
                HStack(spacing: 16) {
                    SkeletonBlock(width: 120, height: 68, radius: 6)
                    VStack(alignment: .leading, spacing: 10) {
                        SkeletonBlock(width: 260, height: 14)
                        SkeletonBlock(width: 120, height: 10)
                    }
                    Spacer()
                    SkeletonBlock(width: 110, height: 12)
                    SkeletonBlock(width: 30, height: 12)
                }
                .padding(.horizontal, 36)
                .frame(height: 96)
            }
            Spacer()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            ZStack {
                Circle().fill(Color.selectionFill).frame(width: 120, height: 120)
                Image(systemName: isTrash ? "trash" : (app.currentFolderID != nil ? "folder" : "tray"))
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Color.brand)
            }
            Text(emptyText)
                .font(.system(size: 14))
                .foregroundStyle(Color.textTertiary)
            if !isTrash && app.listQuery.isEmpty && app.section != .recent {
                Button(L("导入")) { app.presentImportDialog() }
                    .buttonStyle(PrimaryButtonStyle())
                Text(app.currentFolderID != nil ? L("也可以把文件拖到这里，或把左侧「全部」里的妙记拖到这个文件夹")
                                               : L("也可以把音视频与 SRT 文件直接拖到这里"))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textTertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyText: String {
        if !app.listQuery.isEmpty { return L("没有找到相关妙记") }
        switch app.section {
        case .trash: return L("回收站为空")
        case .recent: return L("还没有打开过妙记")
        case .all: return L("暂无妙记文件")
        case .folder: return L("这个文件夹还是空的")
        }
    }
}

private struct ImportMenuButton: View {
    let app: AppModel

    var body: some View {
        DropdownButton(alignment: .trailing, minWidth: 200, items: {
            [
                .button(L("导入音视频与字幕…"), icon: "doc.badge.plus") { app.presentImportDialog() },
                .button(L("批量导入文件夹…"), icon: "folder.badge.plus") { app.importFolder() },
            ]
        }) { _ in
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                Text(L("导入"))
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            }
        }
        .buttonStyle(PrimaryButtonStyle())
        .fixedSize()
    }
}

// MARK: - Checkbox

struct CheckBox: View {
    let checked: Bool
    var mixed = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: checked ? "checkmark.square.fill" : (mixed ? "minus.square.fill" : "square"))
                .font(.system(size: 15))
                .foregroundStyle(checked || mixed ? Color.brand : Color.textTertiary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
