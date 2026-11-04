import SwiftUI

/// Library home (§9.5): sidebar + searchable, sortable list with multi-select and trash.
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
        .dropDestination(for: URL.self) { urls, _ in
            app.importURLs(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.brand, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.brand.opacity(0.06)))
                    .overlay(Text("松开以导入").font(.system(size: 15, weight: .medium)).foregroundStyle(Color.brand))
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
            .padding(.horizontal, 16)
            .padding(.top, app.isWindowFullScreen ? 18 : 40)
            .padding(.bottom, 20)

            ForEach(ListSection.allCases) { s in
                SidebarItem(title: s.title, icon: s.icon, selected: app.section == s) {
                    app.section = s
                    app.selection = []
                }
            }
            Spacer()
            SettingsLink {
                SidebarItemLabel(title: "设置", icon: "gearshape", selected: false)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 16)
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
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    private var titleRow: some View {
        HStack {
            Text(app.section.title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
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
                    Button("移到回收站") { app.moveToTrash(selectedHere) }.buttonStyle(TextLinkButtonStyle())
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
        if app.section == .all {
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
                Image(systemName: isTrash ? "trash" : "tray")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Color.brand)
            }
            Text(emptyText)
                .font(.system(size: 14))
                .foregroundStyle(Color.textTertiary)
            if !isTrash && app.listQuery.isEmpty {
                Button("导入") { app.presentImportDialog() }
                    .buttonStyle(PrimaryButtonStyle())
                Text("也可以把音视频与 SRT 文件直接拖到这里")
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
        }
    }
}

private struct ImportMenuButton: View {
    let app: AppModel

    var body: some View {
        DropdownButton(alignment: .trailing, minWidth: 200, items: {
            [
                .button("导入音视频与字幕…", icon: "doc.badge.plus") { app.presentImportDialog() },
                .button("批量导入文件夹…", icon: "folder") { app.importFolder() },
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
