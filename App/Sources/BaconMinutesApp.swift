import AppKit
import SwiftUI

@main
struct BaconMinutesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var app: AppModel

    init() {
        // Before any model or view builds text.
        LanguagePreference.applyAtLaunch()
        _app = State(initialValue: AppModel())
    }

    var body: some Scene {
        Window(L("培根妙记"), id: "main") {
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

    /// Closing the window keeps the app running (like most Mac apps); ⌘Q quits.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Dock icon click with the window hidden: show it again.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if flag { return true }
        MainActor.assumeIsolated { MainWindowRegistry.show() }
        return false
    }
}

/// The one main window, for bringing it back from the Dock after it was closed (hidden).
@MainActor
enum MainWindowRegistry {
    static weak var window: NSWindow?
    /// Set when the close button hid the window (rather than SwiftUI closing it).
    static var hidden = false
    /// Opens the window scene again if it was really closed.
    static var reopen: (() -> Void)?

    static func show() {
        if hidden, let w = window {
            hidden = false
            w.makeKeyAndOrderFront(nil)
        } else {
            reopen?()
        }
        NSApp.activate()
    }
}

/// Sits in front of SwiftUI's window delegate: turns "close" into "hide" and forwards
/// everything else unchanged.
final class WindowCloseInterceptor: NSObject {
    private weak var original: NSWindowDelegate?
    private let onClose: (NSWindow) -> Void

    init(original: NSWindowDelegate?, onClose: @escaping (NSWindow) -> Void) {
        self.original = original
        self.onClose = onClose
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return original?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let original, original.responds(to: aSelector) { return original }
        return super.forwardingTarget(for: aSelector)
    }
}

extension WindowCloseInterceptor: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onClose(sender)
        return false
    }
}

struct RootView: View {
    @Bindable var app: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack {
            WindowBackground()
            switch app.route {
            case .list:
                ListPage(app: app)
                    .transition(.opacity)
            case .detail:
                if let detail = app.detail {
                    // A plain cross-fade: scaling or moving a page that holds AppKit views
                    // (the video layer, the transcript text view) re-renders them every frame,
                    // which flickered and stalled.
                    DetailView(model: detail, app: app)
                        .id(detail.minute.id)
                        .transition(.opacity)
                }
            }

            if let ids = app.batchSummaryTarget {
                BatchSummaryDialog(app: app, ids: ids)
                    .zIndex(10)
            }
            if let review = app.importReview {
                ImportReviewDialog(app: app, review: review)
                    .id(review.id)
                    .zIndex(10)
            }
            if let request = app.confirmRequest {
                ConfirmDialogView(request: request) { confirmed, checked in
                    // A follow-up dialog may set a new request from the handler.
                    if app.confirmRequest?.id == request.id { app.confirmRequest = nil }
                    guard confirmed else { return }
                    if checked, let next = request.onConfirmChecked {
                        next()
                    } else {
                        request.onConfirm()
                    }
                }
                .id(request.id)
                .zIndex(11)
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
        .onAppear {
            let open = openWindow
            MainWindowRegistry.reopen = { open(id: "main") }
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
            Button(L("导入…")) { app.presentImportDialog() }
                .keyboardShortcut("o", modifiers: .command)
            Button(L("批量导入文件夹…")) { app.importFolder() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .textEditing) {
            Button(L("搜索")) { app.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
        }
        CommandMenu(L("妙记")) {
            Button(L("返回列表")) { app.backToList() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(app.detail == nil)
            Divider()
            Button(L("智能纪要")) { app.detail?.rightTab = .summary }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(app.detail == nil)
            Button(L("文字记录")) { app.detail?.rightTab = .transcript }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(app.detail == nil)
            Divider()
            Button(L("播放 / 暂停（空格）")) { app.detail?.player.togglePlay() }
                .disabled(app.detail == nil)
            Button(L("后退 15 秒（←）")) { app.detail?.player.skip(by: -15) }
                .disabled(app.detail == nil)
            Button(L("前进 15 秒（→）")) { app.detail?.player.skip(by: 15) }
                .disabled(app.detail == nil)
            Divider()
            Button(L("生成智能纪要")) { app.detail?.generateSummary() }
                .disabled(app.detail?.transcript == nil)
        }
    }
}
