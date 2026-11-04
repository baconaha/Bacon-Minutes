import AppKit
import Foundation
import Security
import UniformTypeIdentifiers

// MARK: - Paths

enum AppPaths {
    /// `~/Library/Application Support/BaconMinutes` (inside the sandbox container).
    /// Builds from before the rename used "LocalMinutes"; that folder is moved over once.
    static let support: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("BaconMinutes", isDirectory: true)
        let legacy = base.appendingPathComponent("LocalMinutes", isDirectory: true)
        if !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: legacy.path) {
            try? fm.moveItem(at: legacy, to: dir)
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}

// MARK: - API keys

/// API keys, one per provider preset, in a private file inside the app's sandbox container.
/// They used to live in the Keychain, where every new unsigned build made macOS ask for the login
/// password; keys still there are moved over once, without any prompt.
enum SecretStore {
    private static var fileURL: URL { AppPaths.support.appendingPathComponent("api-keys.json") }
    /// Accounts already looked up in the Keychain, so the lookup runs once each.
    private static let migratedKey = "secrets.keychainChecked"
    private static let lock = NSLock()

    static func read(account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        var all = load()
        if let value = all[account], !value.isEmpty { return value }
        let defaults = UserDefaults.standard
        var checked = Set(defaults.stringArray(forKey: migratedKey) ?? [])
        guard !checked.contains(account) else { return nil }
        checked.insert(account)
        defaults.set(Array(checked), forKey: migratedKey)
        guard let old = LegacyKeychain.take(account: account) else { return nil }
        all[account] = old
        save(all)
        return old
    }

    static func write(_ value: String, account: String) {
        lock.lock()
        defer { lock.unlock() }
        var all = load()
        all[account] = value.isEmpty ? nil : value
        save(all)
    }

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }

    private static func save(_ all: [String: String]) {
        guard let data = try? JSONEncoder().encode(all) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            NSLog("BaconMinutes: failed to save API keys: \(error)")
        }
    }
}

/// Reads (and then removes) keys saved by earlier builds, never showing a password dialog:
/// if macOS would ask, the lookup just fails and the key has to be entered again.
private enum LegacyKeychain {
    private static let services = ["BaconMinutes.LLM", "LocalMinutes.LLM"]

    static func take(account: String) -> String? {
        var found: String?
        for service in services {
            var query = baseQuery(service: service, account: account)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data, let value = String(data: data, encoding: .utf8) else { continue }
            if found == nil, !value.isEmpty { found = value }
            _ = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        }
        return found
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
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
        panel.message = L("选择包含音视频与 SRT 字幕的文件夹")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("导入")
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseMedia() -> URL? {
        let panel = NSOpenPanel()
        panel.message = L("选择音视频文件（mp4 / mov / m4v / mp3 / m4a / wav / aac）")
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = mediaTypes
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseSRT() -> URL? {
        let panel = NSOpenPanel()
        panel.message = L("选择 SRT 字幕文件")
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
            Alerts.error(L("导出失败"), error.localizedDescription)
            return false
        }
    }

    static func sanitize(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = name.components(separatedBy: bad).joined(separator: "_").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? L("妙记") : String(cleaned.prefix(120))
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
        a.addButton(withTitle: L("好"))
        a.runModal()
    }

    static func info(_ title: String, _ message: String) {
        let a = NSAlert()
        a.alertStyle = .informational
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: L("好"))
        a.runModal()
    }

    static func confirm(_ title: String, _ message: String, ok: String, cancel: String = L("取消"), destructive: Bool = false) -> Bool {
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
