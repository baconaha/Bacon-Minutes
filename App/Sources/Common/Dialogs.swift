import AppKit
import SwiftUI

// In-app dialogs that flip down from the top, replacing NSAlert for confirmations.

// MARK: - Button styles

/// Red confirm button; lighter on hover.
struct DangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DangerBody(configuration: configuration)
    }

    private struct DangerBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(minWidth: 88)
                .frame(height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: NSColor(hex: configuration.isPressed ? 0xD9403B : (hovering ? 0xF77B76 : 0xF54A45))))
                )
                .animation(.easeOut(duration: 0.12), value: hovering)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// White bordered cancel button; turns gray on hover.
struct DialogCancelButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CancelBody(configuration: configuration)
    }

    private struct CancelBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 14))
                .foregroundStyle(Color.textPrimary)
                .padding(.horizontal, 18)
                .frame(minWidth: 88)
                .frame(height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(configuration.isPressed ? Color.divider : (hovering ? Color.searchFill : Color.card))
                )
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.divider))
                .animation(.easeOut(duration: 0.12), value: hovering)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - Shell

/// Dimmed backdrop + card that flips down on appear and folds up on close.
struct FlipDialog<Content: View>: View {
    var width: CGFloat = 440
    /// Called after the close animation; `closeRequest` starts it.
    let onClosed: () -> Void
    @Binding var closeRequest: Bool
    @ViewBuilder let content: Content

    @State private var shown = false

    var body: some View {
        ZStack {
            Color.black
                .opacity(shown ? 0.32 : 0)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { closeRequest = true }
            content
                .frame(width: width, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.card))
                .shadow(color: .black.opacity(0.18), radius: 28, x: 0, y: 10)
                .rotation3DEffect(.degrees(shown ? 0 : -62), axis: (x: 1, y: 0, z: 0), anchor: .top, perspective: 0.5)
                .scaleEffect(shown ? 1 : 0.96, anchor: .top)
                .offset(y: shown ? 0 : -10)
                .opacity(shown ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.8)) { shown = true }
        }
        .onChange(of: closeRequest) {
            guard closeRequest else { return }
            withAnimation(.easeIn(duration: 0.14)) { shown = false }
            Task {
                try? await Task.sleep(nanoseconds: 150_000_000)
                onClosed()
            }
        }
    }
}

// MARK: - Confirm

struct ConfirmDialogView: View {
    let request: ConfirmRequest
    /// Runs after the close animation with the user's choice and the checkbox state.
    let finish: (_ confirmed: Bool, _ checked: Bool) -> Void
    @State private var closing = false
    @State private var confirmed = false
    @State private var checked = false

    var body: some View {
        FlipDialog(onClosed: { finish(confirmed, checked) }, closeRequest: $closing) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Color(nsColor: request.destructive ? NSColor(hex: 0xF08A24) : Palette.brand))
                            .frame(width: 24, height: 24)
                        Text(request.destructive ? "!" : "i")
                            .font(.system(size: 15, weight: .heavy, design: request.destructive ? .default : .serif))
                            .foregroundStyle(.white)
                    }
                    .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(request.title)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(request.message)
                            .font(.system(size: 14))
                            .foregroundStyle(Color.textSecondary)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                        if let emphasis = request.emphasis {
                            Text(emphasis)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(Color.textPrimary)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let box = request.checkbox {
                            Button {
                                checked.toggle()
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                                        .font(.system(size: 15))
                                        .foregroundStyle(checked ? Color.brand : Color.textTertiary)
                                    Text(box)
                                        .font(.system(size: 14))
                                        .foregroundStyle(Color.textPrimary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 4)
                        }
                    }
                }
                HStack(spacing: 12) {
                    Spacer()
                    Button(request.cancelTitle) { closing = true }
                        .buttonStyle(DialogCancelButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    if request.destructive {
                        Button(confirmTitle) {
                            confirmed = true
                            closing = true
                        }
                        .buttonStyle(DangerButtonStyle())
                        .keyboardShortcut(.defaultAction)
                    } else {
                        Button(confirmTitle) {
                            confirmed = true
                            closing = true
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(.top, 30)
            }
            .padding(EdgeInsets(top: 28, leading: 28, bottom: 24, trailing: 26))
        }
    }

    /// With the checkbox ticked the next step is another confirmation, so the button says so.
    private var confirmTitle: String {
        checked && request.onConfirmChecked != nil ? L("下一步") : request.confirmTitle
    }
}

// MARK: - Folder properties

struct FolderInfoDialog: View {
    let app: AppModel
    let folderID: UUID
    @State private var closing = false

    var body: some View {
        let folder = app.library.userFolder(folderID)
        let stats = app.library.stats(inFolder: folderID)
        FlipDialog(width: 380, onClosed: { app.folderInfoTarget = nil }, closeRequest: $closing) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(Color.brand)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(folder?.name ?? L("文件夹"))
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(2)
                        Text(L("属性")).font(.system(size: 12)).foregroundStyle(Color.textTertiary)
                    }
                }
                Rectangle().fill(Color.divider).frame(height: 1)
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                    infoRow(L("妙记数量"), L("{0} 个", stats.count))
                    infoRow(L("总时长"), stats.count > 0 ? TimeFormat.duration(stats.duration) : "—")
                    infoRow(L("总大小"), AppModel.byteText(stats.bytes))
                    infoRow(L("创建时间"), folder.map { TimeFormat.createdDate($0.createdAt) } ?? "—")
                }
                HStack {
                    Spacer()
                    Button(L("好")) { closing = true }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 4)
            }
            .padding(24)
        }
    }

    private func infoRow(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).font(.system(size: 13)).foregroundStyle(Color.textTertiary)
            Text(v).font(.system(size: 13).monospacedDigit()).foregroundStyle(Color.textPrimary).textSelection(.enabled)
        }
    }
}

// MARK: - Move to folder

struct MoveToFolderDialog: View {
    let app: AppModel
    let ids: Set<UUID>
    @State private var closing = false
    @State private var choice: UUID?
    @State private var chosen = false
    @State private var applied = false

    var body: some View {
        FlipDialog(width: 400, onClosed: finish, closeRequest: $closing) {
            VStack(alignment: .leading, spacing: 16) {
                Text(ids.count == 1 ? L("移动到文件夹") : L("将 {0} 个妙记移动到文件夹", ids.count))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                if app.library.folders.isEmpty {
                    Text(L("还没有文件夹。可以在左侧边栏「文件夹」旁点 + 新建。"))
                        .font(.system(size: 13))
                        .foregroundStyle(Color.textTertiary)
                } else {
                    ScrollView {
                        VStack(spacing: 2) {
                            option(nil, title: L("不放入文件夹"), icon: "tray")
                            ForEach(app.library.folders) { f in option(f.id, title: f.name, icon: "folder") }
                        }
                    }
                    .frame(maxHeight: 260)
                }
                HStack(spacing: 12) {
                    Spacer()
                    Button(L("取消")) { closing = true }
                        .buttonStyle(DialogCancelButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    Button(L("移动")) {
                        applied = true
                        closing = true
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(app.library.folders.isEmpty || !chosen)
                }
            }
            .padding(24)
        }
        .onAppear {
            if ids.count == 1, let id = ids.first, let current = app.library.minute(id)?.folderID {
                choice = current
            }
        }
    }

    private func option(_ id: UUID?, title: String, icon: String) -> some View {
        let selected = chosen && choice == id
        return Button {
            choice = id
            chosen = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(selected ? Color.brand : Color.textSecondary).frame(width: 18)
                Text(title).foregroundStyle(selected ? Color.brand : Color.textPrimary).lineLimit(1)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(Color.brand) }
            }
            .font(.system(size: 14))
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.selectionFill : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func finish() {
        let target = choice
        let moving = ids
        app.moveTarget = nil
        if applied { app.moveMinutes(moving, toFolder: target) }
    }
}
