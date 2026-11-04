import AppKit
import SwiftUI

struct MinuteRow: View {
    let app: AppModel
    let minute: Minute
    let isTrash: Bool
    @State private var hovering = false

    private var isSelected: Bool { app.selection.contains(minute.id) }

    var body: some View {
        HStack(spacing: 12) {
            CheckBox(checked: isSelected) {
                if isSelected { app.selection.remove(minute.id) } else { app.selection.insert(minute.id) }
            }
            .opacity(hovering || !app.selection.isEmpty ? 1 : 0)

            HStack(spacing: 14) {
                MinuteThumbnail(image: app.library.thumbnails[minute.id], isAudio: minute.isAudioOnly)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if minute.hasSummary && !isTrash { TagLabel(text: L("纪要")) }
                        Text(minute.title)
                            .font(.system(size: 14))
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .multilineTextAlignment(.leading)
                    }
                    HStack(spacing: 8) {
                        Text(TimeFormat.duration(minute.duration))
                        if !minute.hasTranscript { Text(L("· 无字幕")) }
                        if app.currentFolderID == nil, let fid = minute.folderID, let folder = app.library.userFolder(fid) {
                            HStack(spacing: 3) {
                                Image(systemName: "folder").font(.system(size: 10))
                                Text(folder.name).lineLimit(1)
                            }
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textTertiary)
                }
                Spacer(minLength: 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isTrash {
                Text(TimeFormat.createdDate(minute.deletedAt ?? Date()))
                    .frame(width: 190, alignment: .leading)
                HStack(spacing: 12) {
                    Button(L("恢复")) { app.restore([minute.id]) }.buttonStyle(TextLinkButtonStyle())
                    Button(L("彻底删除")) { app.deleteForever([minute.id]) }.buttonStyle(TextLinkButtonStyle())
                }
                .lineLimit(1)
                .frame(width: 220, alignment: .leading)
            } else {
                Text(TimeFormat.dateOnly(app.section == .recent || app.sort == .opened
                                         ? (minute.lastOpenedAt ?? minute.createdAt) : minute.createdAt))
                    .frame(width: 170, alignment: .leading)
                actionsMenu.frame(width: 48, alignment: .leading)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Color.textSecondary)
        .padding(.horizontal, 12)
        .frame(height: 96)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.selectionFill.opacity(0.6) : (hovering ? Color.rowHover : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onDrag {
            // Drag to a sidebar folder; dragging a selected row carries the whole selection.
            let ids = isSelected && app.selection.count > 1 ? Array(app.selection) : [minute.id]
            return NSItemProvider(object: ids.map(\.uuidString).joined(separator: "\n") as NSString)
        }
        .onTapGesture {
            if isTrash {
                if isSelected { app.selection.remove(minute.id) } else { app.selection.insert(minute.id) }
            } else {
                app.open(minute.id)
            }
        }
        .contextMenu {
            if isTrash {
                Button(L("恢复")) { app.restore([minute.id]) }
                Button(L("彻底删除")) { app.deleteForever([minute.id]) }
            } else {
                menuItems
            }
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button(L("重命名")) { app.beginRename(minute.id) }
        Button(L("移动到文件夹…")) { app.moveTarget = [minute.id] }
        Button(L("在 Finder 中显示媒体")) { app.revealMedia(minute.id) }
        Button(L("重新导入 SRT…")) { app.reimportSRT(minute.id) }
        Divider()
        Button(L("移到回收站")) { app.requestMoveToTrash([minute.id]) }
    }

    /// Opens on click (not hover) with the flip-down animation.
    private var actionsMenu: some View {
        MoreMenuButton(help: L("操作"), openOnHover: false) {
            var items: [DropdownItem] = [
                .button(L("重命名"), icon: "pencil") { app.beginRename(minute.id) },
                .button(L("移动到文件夹…"), icon: "folder") { app.moveTarget = [minute.id] },
            ]
            if minute.folderID != nil {
                items.append(.button(L("移出文件夹"), icon: "folder.badge.minus") { app.moveMinutes([minute.id], toFolder: nil) })
            }
            items += [
                .button(L("在 Finder 中显示媒体"), icon: "magnifyingglass") { app.revealMedia(minute.id) },
                .button(L("重新导入 SRT…"), icon: "captions.bubble") { app.reimportSRT(minute.id) },
                .divider,
                .button(L("移到回收站"), icon: "trash", destructive: true) { app.requestMoveToTrash([minute.id]) },
            ]
            return items
        }
    }
}

struct MinuteThumbnail: View {
    let image: NSImage?
    let isAudio: Bool

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [.audioCoverTop, .audioCoverBottom], startPoint: .top, endPoint: .bottom)
                Image(systemName: isAudio ? "mic.fill" : "film")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.brand.opacity(0.8))
            }
        }
        .frame(width: 120, height: 68)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.divider.opacity(0.6)))
    }
}
