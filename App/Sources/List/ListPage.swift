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
        .alert("重命名", isPresented: Binding(get: { app.renameTarget != nil },
                                            set: { if !$0 { app.renameTarget = nil } })) {
            TextField("标题", text: $app.renameText)
            Button("确定") { app.commitRename() }
            Button("取消", role: .cancel) { app.renameTarget = nil }
        }
    }

    private var dropText: String {
        if let id = app.currentFolderID, let f = app.library.folder(id) { return "松开以导入到「\(f.name)」" }
        return "松开以导入"
    }
}

// MARK: - Sidebar

private struct ListSidebar: View {
    @Bindable var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                AppLogo(size: 28)
                Text("本地妙记")
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
                }
            }

            HStack {
                Text("文件夹")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textTertiary)
                Spacer()
                Button { app.createFolder() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(IconButtonStyle(size: 22, foreground: .textSecondary))
                .help("新建文件夹")
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .padding(.top, 16)
            .padding(.bottom, 2)

            ScrollView {
                VStack(spacing: 2) {
                    if app.library.folders.isEmpty {
                        Text("把妙记拖到文件夹里，或在文件夹中直接导入")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.textTertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(app.library.folders) { folder in
                        FolderRow(app: app, folder: folder)
                    }
                }
            }
            .scrollIndicators(.never)

            LibraryStatsView(stats: app.library.stats())
                .padding(.top, 10)
            Rectangle().fill(Color.divider).frame(height: 1).padding(.vertical, 8)
            SettingsLink {
                SidebarItemLabel(title: "设置", icon: "gearshape", selected: false)
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

private struct FolderRow: View {
    @Bindable var app: AppModel
    let folder: Folder
    @State private var hovering = false
    @State private var dropTargeted = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var selected: Bool { app.section == .folder(folder.id) }
    private var editing: Bool { app.renamingFolderID == folder.id }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: selected ? "folder.fill" : "folder")
                .font(.system(size: 14))
                .frame(width: 18)
            if editing {
                TextField("文件夹名称", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onSubmit { commit() }
                    .onExitCommand { app.renamingFolderID = nil }
                    .onChange(of: focused) { if !focused && editing { commit() } }
                    .onAppear {
                        draft = folder.name
                        focused = true
                    }
            } else {
                Text(folder.name)
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if hovering {
                MoreMenuButton(size: 22, help: "文件夹操作", openOnHover: false) { menuItems }
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
                .fill(dropTargeted ? Color.selectionFill : (selected ? Color.selectionFill : (hovering ? Color.rowHover : Color.clear)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(dropTargeted ? Color.brand : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            app.section = .folder(folder.id)
            app.selection = []
        }
        .onDrop(of: [.utf8PlainText], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
        .contextMenu {
            Button("属性") { app.folderInfoTarget = folder.id }
            Button("重命名") { app.renamingFolderID = folder.id }
            Button("导入到此文件夹…") { app.importIntoFolder(folder.id) }
            Divider()
            Button("删除文件夹") { app.requestDeleteFolder(folder.id) }
        }
    }

    private var menuItems: [DropdownItem] {
        [
            .button("属性", icon: "info.circle") { app.folderInfoTarget = folder.id },
            .button("重命名", icon: "pencil") { app.renamingFolderID = folder.id },
            .button("导入到此文件夹…", icon: "square.and.arrow.down") { app.importIntoFolder(folder.id) },
            .divider,
            .button("删除文件夹", icon: "trash", destructive: true) { app.requestDeleteFolder(folder.id) },
        ]
    }

    private func commit() {
        app.renameFolder(folder.id, to: draft)
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

private struct LibraryStatsView: View {
    let stats: Library.Stats

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("妙记", "\(stats.count) 个")
            row("总时长", stats.count > 0 ? AppModel.shortDuration(stats.duration) : "—")
            row("总大小", AppModel.byteText(stats.bytes))
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
        .onChange(of: app.listQuery) {
            if !app.listQuery.isEmpty { app.library.ensureSearchIndex() }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.textTertiary)
            TextField("搜索妙记", text: $app.listQuery)
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
                Text("正在导入…").font(.system(size: 12)).foregroundStyle(Color.textTertiary)
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
                Text("已选 \(selectedHere.count) 项").font(.system(size: 13)).foregroundStyle(Color.textPrimary)
                Text("·").foregroundStyle(Color.textTertiary)
                if isTrash {
                    Button("恢复") { app.restore(selectedHere) }.buttonStyle(TextLinkButtonStyle())
                    Text("·").foregroundStyle(Color.textTertiary)
                    Button("彻底删除") { app.deleteForever(selectedHere) }.buttonStyle(TextLinkButtonStyle())
                } else {
                    Button("移动到文件夹") { app.moveTarget = selectedHere }.buttonStyle(TextLinkButtonStyle())
                    Text("·").foregroundStyle(Color.textTertiary)
                    Button("移到回收站") { app.requestMoveToTrash(selectedHere) }.buttonStyle(TextLinkButtonStyle())
                }
                Text("·").foregroundStyle(Color.textTertiary)
                Button("取消") { app.selection = [] }.buttonStyle(TextLinkButtonStyle())
                Spacer()
            } else {
                Text("文件").frame(maxWidth: .infinity, alignment: .leading)
                if isTrash {
                    Text("删除时间").frame(width: 150, alignment: .leading)
                    Text("剩余时间 ↓").frame(width: 90, alignment: .leading)
                    Text("操作").frame(width: 130, alignment: .leading)
                } else {
                    sortMenu.frame(width: 170, alignment: .leading)
                    Text("操作").frame(width: 48, alignment: .leading)
                }
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Color.textTertiary)
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
                    Text(app.sort == .created ? "创建时间" : "最近打开")
                    Image(systemName: "chevron.down").font(.system(size: 9))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
        } else {
            Text("最近打开")
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
                Button("导入") { app.presentImportDialog() }
                    .buttonStyle(PrimaryButtonStyle())
                Text(app.currentFolderID != nil ? "也可以把文件拖到这里，或把左侧「全部」里的妙记拖到这个文件夹"
                                               : "也可以把音视频与 SRT 文件直接拖到这里")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textTertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyText: String {
        if !app.listQuery.isEmpty { return "没有找到相关妙记" }
        switch app.section {
        case .trash: return "回收站为空"
        case .recent: return "还没有打开过妙记"
        case .all: return "暂无妙记文件"
        case .folder: return "这个文件夹还是空的"
        }
    }
}

private struct ImportMenuButton: View {
    let app: AppModel

    var body: some View {
        DropdownButton(alignment: .trailing, minWidth: 200, items: {
            [
                .button("导入音视频与字幕…", icon: "doc.badge.plus") { app.presentImportDialog() },
                .button("批量导入文件夹…", icon: "folder.badge.plus") { app.importFolder() },
            ]
        }) { _ in
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                Text("导入")
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
