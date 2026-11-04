import AppKit
import Observation
import SwiftUI

// Feishu-style dropdown menus: a borderless child panel hosting a rounded white card that
// flips down from its button. Most open on hover; some (list rows, folders, form fields) on click.

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

@MainActor
@Observable
final class DropdownVisibility {
    var shown = false
}

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

/// Card plus shadow room and the flip-down transform.
struct DropdownPanelContent: View {
    static let shadowPadding: CGFloat = 16

    let card: DropdownCard
    let placement: DropdownPlacement
    let visibility: DropdownVisibility

    var body: some View {
        let shown = visibility.shown
        card
            .shadow(color: .black.opacity(card.style == .dark ? 0.35 : 0.14), radius: 12, x: 0, y: 4)
            .rotation3DEffect(.degrees(shown ? 0 : (placement == .below ? -78 : 78)),
                              axis: (x: 1, y: 0, z: 0),
                              anchor: placement == .below ? .top : .bottom,
                              perspective: 0.55)
            .scaleEffect(shown ? 1 : 0.97, anchor: placement == .below ? .top : .bottom)
            .opacity(shown ? 1 : 0)
            .padding(Self.shadowPadding)
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
            .animation(.easeOut(duration: 0.1), value: hovering)
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

/// Accepts the first click and reports the pointer entering / leaving the menu.
final class DropdownHostingView: NSHostingView<DropdownPanelContent> {
    var onPointerInside: ((Bool) -> Void)?
    private var area: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onPointerInside?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointerInside?(false)
    }
}

@MainActor
final class DropdownPresenter {
    static let shared = DropdownPresenter()

    private var panel: DropdownPanel?
    private var visibility: DropdownVisibility?
    private weak var anchor: NSView?
    private var hoverMode = false
    private var pointerInAnchor = false
    private var pointerInPanel = false
    private var closeCheck: Task<Void, Never>?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var onClose: (() -> Void)?

    func isShowing(from anchor: NSView?) -> Bool {
        panel != nil && anchor != nil && self.anchor === anchor
    }

    func show(items: [DropdownItem], from anchor: NSView, placement: DropdownPlacement, alignment: DropdownAlignment,
              style: DropdownStyle, minWidth: CGFloat, hoverMode: Bool, onClose: @escaping () -> Void) {
        close(animated: false)
        guard let window = anchor.window else {
            onClose()
            return
        }
        let anchorRect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let visibility = DropdownVisibility()
        let card = DropdownCard(items: items, style: style, minWidth: minWidth) { [weak self] item in
            if case .toggle = item.kind {
                item.action()
            } else {
                self?.close(animated: true)
                item.action()
            }
        }
        let host = DropdownHostingView(rootView: DropdownPanelContent(card: card, placement: placement, visibility: visibility))
        host.onPointerInside = { [weak self] inside in
            MainActor.assumeIsolated { self?.pointer(inPanel: inside) }
        }
        let size = host.fittingSize
        let pad = DropdownPanelContent.shadowPadding
        let cardWidth = size.width - pad * 2
        let cardHeight = size.height - pad * 2
        let gap: CGFloat = 6

        var cardX: CGFloat
        switch alignment {
        case .leading: cardX = anchorRect.minX
        case .trailing: cardX = anchorRect.maxX - cardWidth
        case .center: cardX = anchorRect.midX - cardWidth / 2
        }
        var cardY = placement == .below ? anchorRect.minY - gap - cardHeight : anchorRect.maxY + gap
        var effectivePlacement = placement
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            cardX = min(max(cardX, visible.minX + 4), visible.maxX - cardWidth - 4)
            if placement == .below && cardY < visible.minY + 4 {
                cardY = anchorRect.maxY + gap
                effectivePlacement = .above
            } else if placement == .above && cardY + cardHeight > visible.maxY - 4 {
                cardY = anchorRect.minY - gap - cardHeight
                effectivePlacement = .below
            }
        }
        if effectivePlacement != placement {
            host.rootView = DropdownPanelContent(card: card, placement: effectivePlacement, visibility: visibility)
        }

        let frame = NSRect(x: cardX - pad, y: cardY - pad, width: size.width, height: size.height)
        let panel = DropdownPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = host
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)

        self.panel = panel
        self.visibility = visibility
        self.anchor = anchor
        self.hoverMode = hoverMode
        self.pointerInAnchor = hoverMode
        self.pointerInPanel = false
        self.onClose = onClose

        // Flip down on the next runloop turn so the initial (folded) state is rendered first.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { visibility.shown = true }
            }
        }

        let clicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            let swallow = MainActor.assumeIsolated { () -> Bool in
                guard let self, let panel = self.panel else { return false }
                if event.window === panel { return false }
                var onAnchor = false
                if let anchor = self.anchor, event.window === anchor.window {
                    onAnchor = anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil))
                }
                // Hover menus stay open when their button is clicked; click menus toggle closed.
                if onAnchor && self.hoverMode { return false }
                self.close(animated: true)
                return onAnchor
            }
            return swallow ? nil : event
        }
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.panel != nil, event.keyCode == 53 else { return false }
                self.close(animated: true)
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
                MainActor.assumeIsolated { self?.close(animated: false) }
            })
        }
    }

    func pointer(inAnchor inside: Bool, anchor: NSView?) {
        guard hoverMode, panel != nil, anchor === self.anchor else { return }
        pointerInAnchor = inside
        scheduleHoverCheck()
    }

    private func pointer(inPanel inside: Bool) {
        guard panel != nil else { return }
        pointerInPanel = inside
        if hoverMode { scheduleHoverCheck() }
    }

    /// Hover menus close shortly after the pointer has left both the button and the card.
    private func scheduleHoverCheck() {
        closeCheck?.cancel()
        guard !pointerInAnchor && !pointerInPanel else { return }
        closeCheck = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard let self, !Task.isCancelled, !self.pointerInAnchor, !self.pointerInPanel else { return }
            self.close(animated: true)
        }
    }

    func close(animated: Bool) {
        closeCheck?.cancel()
        closeCheck = nil
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        if let panel {
            let finish = {
                panel.parent?.removeChildWindow(panel)
                panel.orderOut(nil)
            }
            if animated, let visibility {
                panel.ignoresMouseEvents = true
                withAnimation(.easeIn(duration: 0.12)) { visibility.shown = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
                    MainActor.assumeIsolated { finish() }
                }
            } else {
                finish()
            }
        }
        panel = nil
        visibility = nil
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
    /// Open when the pointer rests on the button (Feishu behaviour); click always opens too.
    var openOnHover = true
    var onOpenChange: ((Bool) -> Void)?
    let items: () -> [DropdownItem]
    @ViewBuilder let label: (Bool) -> Label

    @State private var box = DropdownAnchorBox()
    @State private var isOpen = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        Button {
            open()
        } label: {
            label(isOpen)
        }
        .background(DropdownAnchor(box: box))
        .onHover { inside in
            guard openOnHover else { return }
            hoverTask?.cancel()
            DropdownPresenter.shared.pointer(inAnchor: inside, anchor: box.view)
            if inside && !isOpen {
                hoverTask = Task {
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    if !Task.isCancelled { open() }
                }
            }
        }
    }

    private func open() {
        guard let view = box.view else { return }
        if DropdownPresenter.shared.isShowing(from: view) { return }
        isOpen = true
        onOpenChange?(true)
        DropdownPresenter.shared.show(items: items(), from: view, placement: placement, alignment: alignment,
                                      style: style, minWidth: minWidth, hoverMode: openOnHover) {
            isOpen = false
            onOpenChange?(false)
        }
    }
}

/// "···" icon trigger used across the app.
struct MoreMenuButton: View {
    var alignment: DropdownAlignment = .trailing
    var size: CGFloat = 28
    var help: String = L("更多")
    var openOnHover = true
    let items: () -> [DropdownItem]

    var body: some View {
        DropdownButton(alignment: alignment, openOnHover: openOnHover, items: items) { open in
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
