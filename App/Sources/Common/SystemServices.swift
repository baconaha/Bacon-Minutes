import AppKit
import Foundation
import Security
import UniformTypeIdentifiers

// MARK: - Keychain

enum Keychain {
    static let service = "LocalMinutes.LLM"

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if value.isEmpty {
            _ = SecItemDelete(base as CFDictionary)
            return
        }
        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            _ = SecItemAdd(add as CFDictionary, nil)
        }
    }
}

// MARK: - Bookmarks

enum Bookmarks {
    /// Security-scoped (read-only) bookmark, with a plain bookmark as fallback outside the sandbox.
    static func make(for url: URL) -> Data? {
        if let data = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                            includingResourceValuesForKeys: nil, relativeTo: nil) {
            return data
        }
        return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func resolve(_ data: Data) -> (url: URL, isStale: Bool)? {
        guard !data.isEmpty else { return nil }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil,
                              bookmarkDataIsStale: &stale) {
            return (url, stale)
        }
        stale = false
        if let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
            return (url, stale)
        }
        return nil
    }
}

/// Keeps a security-scoped resource open until `stop()`.
final class ScopedAccess {
    let url: URL
    private var active: Bool

    init(url: URL) {
        self.url = url
        active = url.startAccessingSecurityScopedResource()
    }

    func stop() {
        if active {
            url.stopAccessingSecurityScopedResource()
            active = false
        }
    }
}

// MARK: - File panels

@MainActor
enum FilePanels {
    static var mediaTypes: [UTType] {
        MediaTypes.mediaExtensions.sorted().compactMap { UTType(filenameExtension: $0) }
    }

    static var subtitleTypes: [UTType] {
        [UTType(filenameExtension: "srt")].compactMap { $0 }
    }

    static func chooseFiles(message: String) -> [URL] {
        let panel = NSOpenPanel()
        panel.message = message
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = mediaTypes + subtitleTypes
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.message = "选择包含音视频与 SRT 字幕的文件夹"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "导入"
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseMedia() -> URL? {
        let panel = NSOpenPanel()
        panel.message = "选择音视频文件（mp4 / mov / m4v / mp3 / m4a / wav / aac）"
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = mediaTypes
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseSRT() -> URL? {
        let panel = NSOpenPanel()
        panel.message = "选择 SRT 字幕文件"
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = subtitleTypes
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Asks for a destination and writes UTF-8 text. Returns false if cancelled or failed.
    @discardableResult
    static func saveText(_ text: String, suggestedName: String, fileExtension: String) -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = sanitize(suggestedName) + "." + fileExtension
        if let type = UTType(filenameExtension: fileExtension) { panel.allowedContentTypes = [type] }
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            return true
        } catch {
            Alerts.error("导出失败", error.localizedDescription)
            return false
        }
    }

    static func sanitize(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = name.components(separatedBy: bad).joined(separator: "_").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "妙记" : String(cleaned.prefix(120))
    }

    /// Recursively lists files under folders; plain files are passed through.
    static func expand(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                    for case let f as URL in e {
                        let k = MediaTypes.kind(of: f)
                        if k != .other { out.append(f) }
                    }
                }
            } else {
                out.append(url)
            }
        }
        return out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - Alerts

@MainActor
enum Alerts {
    static func error(_ title: String, _ message: String) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: "好")
        a.runModal()
    }

    static func info(_ title: String, _ message: String) {
        let a = NSAlert()
        a.alertStyle = .informational
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: "好")
        a.runModal()
    }

    static func confirm(_ title: String, _ message: String, ok: String, cancel: String = "取消", destructive: Bool = false) -> Bool {
        let a = NSAlert()
        a.alertStyle = destructive ? .critical : .informational
        a.messageText = title
        a.informativeText = message
        let okButton = a.addButton(withTitle: ok)
        if destructive { okButton.hasDestructiveAction = true }
        a.addButton(withTitle: cancel)
        return a.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - Key events

/// One local key-down monitor for the whole app; the handler returns true to swallow the event.
@MainActor
final class KeyMonitor {
    private var token: Any?
    var handler: ((NSEvent) -> Bool)?

    func start() {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                self?.handler?(event) ?? false
            }
            return handled ? nil : event
        }
    }

    /// True while a text field (or any editable text view) has keyboard focus.
    static func isEditingText(in window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        if let tv = responder as? NSTextView { return tv.isEditable }
        return responder is NSTextField
    }
}
