import AppKit
import SwiftUI

// Feishu-style dropdown menus: a borderless child panel hosting a rounded white card,
// used instead of the native NSMenu look for every "▾" / "···" button.

struct DropdownItem: Identifiable {
    enum Kind {
        case action
        case toggle(Bool)
        case divider
    }

    let id = UUID()
    var kind: Kind = .action
    var title: String = ""
    var icon: String?
    var isSelected = false
    var isDestructive = false
    var isDisabled = false
    var action: () -> Void = {}

    static func button(_ title: String, icon: String? = nil, selected: Bool = false, destructive: Bool = false,
                       disabled: Bool = false, action: @escaping () -> Void) -> DropdownItem {
        DropdownItem(kind: .action, title: title, icon: icon, isSelected: selected, isDestructive: destructive,
                     isDisabled: disabled, action: action)
    }

    /// Stays open when clicked; the row flips its own switch.
    static func toggle(_ title: String, icon: String? = nil, isOn: Bool, action: @escaping () -> Void) -> DropdownItem {
        DropdownItem(kind: .toggle(isOn), title: title, icon: icon, action: action)
    }

    static var divider: DropdownItem { DropdownItem(kind: .divider) }
}

enum DropdownStyle { case light, dark }
enum DropdownPlacement { case below, above }
enum DropdownAlignment { case leading, center, trailing }

// MARK: - Card

struct DropdownCard: View {
    let items: [DropdownItem]
    let style: DropdownStyle
    let minWidth: CGFloat
    let select: (DropdownItem) -> Void

    private var background: Color { style == .dark ? Color(white: 0.11, opacity: 0.96) : Color.card }
    private var border: Color { style == .dark ? Color.white.opacity(0.08) : Color.divider }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                if case .divider = item.kind {
                    Rectangle()
                        .fill(style == .dark ? Color.white.opacity(0.12) : Color.divider)
                        .frame(height: 1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                } else {
                    DropdownRow(item: item, style: style) { select(item) }
                }
            }
        }
        .padding(4)
        .frame(minWidth: minWidth, alignment: .leading)
        .fixedSize()
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(background))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(border, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct DropdownRow: View {
    let item: DropdownItem
    let style: DropdownStyle
    let action: () -> Void
    @State private var hovering = false
    @State private var isOn = false

    private var dark: Bool { style == .dark }

    private var textColor: Color {
        if item.isDisabled { return dark ? Color.white.opacity(0.35) : Color.textTertiary }
        if item.isDestructive { return Color.errorText }
        if item.isSelected { return dark ? Color(nsColor: NSColor(hex: 0x6B97FF)) : Color.brand }
        return dark ? Color.white : Color.textPrimary
    }

    private var iconColor: Color {
        if item.isDisabled { return dark ? Color.white.opacity(0.35) : Color.textTertiary }
        if item.isDestructive { return Color.errorText }
        return dark ? Color.white.opacity(0.8) : Color.textSecondary
    }

    var body: some View {
        Button {
            if case .toggle = item.kind { isOn.toggle() }
            action()
        } label: {
            HStack(spacing: 8) {
                if let icon = item.icon {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                        .foregroundStyle(iconColor)
                        .frame(width: 18)
                }
                Text(item.title)
                    .font(.system(size: 14))
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                Spacer(minLength: 16)
                if case .toggle = item.kind {
                    MiniSwitch(on: isOn)
                } else if item.isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(textColor)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering && !item.isDisabled ? (dark ? Color.white.opacity(0.12) : Color.searchFill) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(item.isDisabled)
        .onHover { hovering = $0 }
        .onAppear {
            if case .toggle(let on) = item.kind { isOn = on }
        }
    }
}

private struct MiniSwitch: View {
    let on: Bool

    var body: some View {
        Capsule()
            .fill(on ? Color.brand : Color.gray.opacity(0.45))
            .frame(width: 28, height: 16)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle().fill(Color.white).frame(width: 12, height: 12).padding(2)
            }
            .animation(.easeInOut(duration: 0.15), value: on)
    }
}

// MARK: - Presenter

final class DropdownPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class DropdownHostingView: NSHostingView<DropdownCard> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class DropdownPresenter {
    static let shared = DropdownPresenter()

    private var panel: DropdownPanel?
    private weak var anchor: NSView?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var onClose: (() -> Void)?

    func show(items: [DropdownItem], from anchor: NSView, placement: DropdownPlacement, alignment: DropdownAlignment,
              style: DropdownStyle, minWidth: CGFloat, onClose: @escaping () -> Void) {
        close()
        guard let window = anchor.window else {
            onClose()
            return
        }
        let anchorRect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let host = DropdownHostingView(rootView: DropdownCard(items: items, style: style, minWidth: minWidth) { _ in })
        host.rootView = DropdownCard(items: items, style: style, minWidth: minWidth) { [weak self] item in
            if case .toggle = item.kind {
                item.action()
            } else {
                self?.close()
                item.action()
            }
        }
        let size = host.fittingSize
        let gap: CGFloat = 6

        var x: CGFloat
        switch alignment {
        case .leading: x = anchorRect.minX
        case .trailing: x = anchorRect.maxX - size.width
        case .center: x = anchorRect.midX - size.width / 2
        }
        var y = placement == .below ? anchorRect.minY - gap - size.height : anchorRect.maxY + gap
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            x = min(max(x, visible.minX + 4), visible.maxX - size.width - 4)
            if placement == .below && y < visible.minY + 4 { y = anchorRect.maxY + gap }
            if placement == .above && y + size.height > visible.maxY - 4 { y = anchorRect.minY - gap - size.height }
        }

        let panel = DropdownPanel(contentRect: NSRect(x: x, y: y, width: size.width, height: size.height),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = host
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        panel.invalidateShadow()

        self.panel = panel
        self.anchor = anchor
        self.onClose = onClose

        let clicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            let swallow = MainActor.assumeIsolated { () -> Bool in
                guard let self, let panel = self.panel else { return false }
                if event.window === panel { return false }
                // A click on the button that opened the menu just closes it (no reopen).
                var onAnchor = false
                if let anchor = self.anchor, event.window === anchor.window {
                    let p = anchor.convert(event.locationInWindow, from: nil)
                    onAnchor = anchor.bounds.contains(p)
                }
                self.close()
                return onAnchor
            }
            return swallow ? nil : event
        }
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.panel != nil, event.keyCode == 53 else { return false }
                self.close()
                return true
            }
            return handled ? nil : event
        }
        monitors = [clicks, keys].compactMap { $0 }
        let center = NotificationCenter.default
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResizeNotification, NSWindow.willCloseNotification,
                     NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            let object: AnyObject? = name == NSApplication.didResignActiveNotification ? nil : window
            observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            })
        }
    }

    func close() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
        anchor = nil
        let callback = onClose
        onClose = nil
        callback?()
    }
}

// MARK: - Button

final class DropdownAnchorBox {
    weak var view: NSView?
}

private final class DropdownAnchorNSView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct DropdownAnchor: NSViewRepresentable {
    let box: DropdownAnchorBox

    func makeNSView(context: Context) -> NSView {
        let v = DropdownAnchorNSView()
        box.view = v
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        box.view = nsView
    }
}

/// A button that opens a dropdown card. Style the button from outside with `.buttonStyle(...)`.
struct DropdownButton<Label: View>: View {
    var placement: DropdownPlacement = .below
    var alignment: DropdownAlignment = .leading
    var style: DropdownStyle = .light
    var minWidth: CGFloat = 160
    var onOpenChange: ((Bool) -> Void)?
    let items: () -> [DropdownItem]
    @ViewBuilder let label: (Bool) -> Label

    @State private var box = DropdownAnchorBox()
    @State private var isOpen = false

    var body: some View {
        Button {
            open()
        } label: {
            label(isOpen)
        }
        .background(DropdownAnchor(box: box))
    }

    private func open() {
        guard let view = box.view else { return }
        isOpen = true
        onOpenChange?(true)
        DropdownPresenter.shared.show(items: items(), from: view, placement: placement, alignment: alignment,
                                      style: style, minWidth: minWidth) {
            isOpen = false
            onOpenChange?(false)
        }
    }
}

/// "···" icon trigger used across the app.
struct MoreMenuButton: View {
    var alignment: DropdownAlignment = .trailing
    var size: CGFloat = 28
    var help: String = "更多"
    let items: () -> [DropdownItem]

    var body: some View {
        DropdownButton(alignment: alignment, items: items) { open in
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.textSecondary)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: 6).fill(open ? Color.searchFill : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
