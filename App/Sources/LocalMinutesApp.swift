import AppKit
import SwiftUI

@main
struct LocalMinutesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var app = AppModel()

    var body: some Scene {
        Window("本地妙记", id: "main") {
            RootView(app: app)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        .commands { AppCommands(app: app) }

        Settings {
            SettingsView(settings: app.settings)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppIconStore.shared.applyToDock() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct RootView: View {
    @Bindable var app: AppModel

    var body: some View {
        ZStack {
            WindowBackground()
            switch app.route {
            case .list:
                ListPage(app: app)
                    .transition(.opacity)
            case .detail:
                if let detail = app.detail {
                    DetailView(model: detail, app: app)
                        .id(detail.minute.id)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.985)).combined(with: .offset(y: 6)),
                            removal: .opacity))
                }
            }

            if let request = app.confirmRequest {
                ConfirmDialogView(request: request) { confirmed in
                    app.confirmRequest = nil
                    if confirmed { request.onConfirm() }
                }
                .id(request.id)
                .zIndex(10)
            }
            if let ids = app.moveTarget {
                MoveToFolderDialog(app: app, ids: ids)
                    .zIndex(10)
            }
            if let folderID = app.folderInfoTarget {
                FolderInfoDialog(app: app, folderID: folderID)
                    .id(folderID)
                    .zIndex(10)
            }
        }
        .overlay(alignment: .top) {
            if let toast = app.toast {
                ToastView(text: toast)
                    .padding(.top, 36)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: app.toast)
        .sheet(isPresented: $app.showImportDialog) {
            ImportDialog(app: app)
        }
        .background(WindowAccessor { window in
            app.attachWindow(window)
            window?.isMovableByWindowBackground = false
            window?.titlebarAppearsTransparent = true
        })
        .frame(minWidth: 1024, minHeight: 700)
    }
}

struct AppCommands: Commands {
    let app: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("导入…") { app.presentImportDialog() }
                .keyboardShortcut("o", modifiers: .command)
            Button("批量导入文件夹…") { app.importFolder() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .textEditing) {
            Button("搜索") { app.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
        }
        CommandMenu("妙记") {
            Button("返回列表") { app.backToList() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(app.detail == nil)
            Divider()
            Button("智能纪要") { app.detail?.rightTab = .summary }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(app.detail == nil)
            Button("文字记录") { app.detail?.rightTab = .transcript }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(app.detail == nil)
            Divider()
            Button("播放 / 暂停（空格）") { app.detail?.player.togglePlay() }
                .disabled(app.detail == nil)
            Button("后退 15 秒（←）") { app.detail?.player.skip(by: -15) }
                .disabled(app.detail == nil)
            Button("前进 15 秒（→）") { app.detail?.player.skip(by: 15) }
                .disabled(app.detail == nil)
            Divider()
            Button("生成智能纪要") { app.detail?.generateSummary() }
                .disabled(app.detail?.transcript == nil)
        }
    }
}
