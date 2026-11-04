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
                        if minute.hasSummary && !isTrash { TagLabel(text: "纪要") }
                        Text(minute.title)
                            .font(.system(size: 14))
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .multilineTextAlignment(.leading)
                    }
                    HStack(spacing: 8) {
                        Text(TimeFormat.durationCN(minute.duration))
                        if !minute.hasTranscript { Text("· 无字幕") }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textTertiary)
                }
                Spacer(minLength: 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isTrash {
                Text(TimeFormat.createdDate(minute.deletedAt ?? Date()))
                    .frame(width: 150, alignment: .leading)
                Text(remainingText)
                    .frame(width: 90, alignment: .leading)
                HStack(spacing: 12) {
                    Button("恢复") { app.restore([minute.id]) }.buttonStyle(TextLinkButtonStyle())
                    Button("彻底删除") { app.deleteForever([minute.id]) }.buttonStyle(TextLinkButtonStyle())
                }
                .frame(width: 130, alignment: .leading)
            } else {
                Text(TimeFormat.dateOnly(app.sort == .opened && app.section == .all || app.section == .recent
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
        .onTapGesture {
            if isTrash {
                if isSelected { app.selection.remove(minute.id) } else { app.selection.insert(minute.id) }
            } else {
                app.open(minute.id)
            }
        }
        .contextMenu {
            if isTrash {
                Button("恢复") { app.restore([minute.id]) }
                Button("彻底删除") { app.deleteForever([minute.id]) }
            } else {
                menuItems
            }
        }
    }

    private var remainingText: String {
        guard let deleted = minute.deletedAt else { return "" }
        let expiry = deleted.addingTimeInterval(Double(Library.trashRetentionDays) * 86_400)
        let days = Int(ceil(expiry.timeIntervalSinceNow / 86_400))
        return days <= 1 ? "1 天" : "\(days) 天"
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("重命名") { app.beginRename(minute.id) }
        Button("在 Finder 中显示媒体") { app.revealMedia(minute.id) }
        Button("重新导入 SRT…") { app.reimportSRT(minute.id) }
        Divider()
        Button("移到回收站") { app.moveToTrash([minute.id]) }
    }

    private var actionsMenu: some View {
        MoreMenuButton(help: "操作") {
            [
                .button("重命名", icon: "pencil") { app.beginRename(minute.id) },
                .button("在 Finder 中显示媒体", icon: "folder") { app.revealMedia(minute.id) },
                .button("重新导入 SRT…", icon: "captions.bubble") { app.reimportSRT(minute.id) },
                .divider,
                .button("移到回收站", icon: "trash", destructive: true) { app.moveToTrash([minute.id]) },
            ]
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
