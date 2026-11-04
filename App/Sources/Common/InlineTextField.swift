import AppKit
import SwiftUI

/// Single-line text field that edits in place and saves the way a Google Docs title does:
/// Return or a click anywhere outside it ends editing and saves; Esc cancels. A SwiftUI
/// TextField keeps focus when the user clicks empty space, so it never got a chance to save.
struct InlineTextField: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    var textColor: NSColor = Palette.textPrimary
    var placeholder: String?
    /// Takes focus with all text selected as soon as it is on screen (a new folder's name).
    var autoFocus = false
    var onFocus: () -> Void = {}
    let onEnd: (_ cancelled: Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> FocusReportingTextField {
        let field = FocusReportingTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.textColor = textColor
        field.placeholderString = placeholder
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.stringValue = text
        field.delegate = context.coordinator
        field.onFocus = { [weak coordinator = context.coordinator] in
            MainActor.assumeIsolated { coordinator?.began() }
        }
        context.coordinator.field = field
        field.focusWhenAttached = autoFocus
        return field
    }

    func updateNSView(_ field: FocusReportingTextField, context: Context) {
        context.coordinator.parent = self
        if field.textColor != textColor { field.textColor = textColor }
        if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }
    }

    static func dismantleNSView(_ field: FocusReportingTextField, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InlineTextField
        weak var field: NSTextField?
        private var active = false
        private var monitor: Any?

        init(parent: InlineTextField) {
            self.parent = parent
        }

        func began() {
            guard !active else { return }
            active = true
            parent.onFocus()
            // A click anywhere outside the field ends editing and saves; the click still goes through.
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, let field = self.field else { return }
                    let inside = event.window === field.window
                        && field.bounds.contains(field.convert(event.locationInWindow, from: nil))
                    if !inside { self.finish(cancelled: false) }
                }
                return event
            }
        }

        func finish(cancelled: Bool) {
            guard active else { return }
            active = false
            removeMonitor()
            if let field, field.currentEditor() != nil {
                field.window?.makeFirstResponder(nil)
            }
            parent.onEnd(cancelled)
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            finish(cancelled: false)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                finish(cancelled: true)
                return true
            }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                finish(cancelled: false)
                return true
            }
            return false
        }
    }
}

/// Tells its owner when it takes focus (a click), before any typing.
final class FocusReportingTextField: NSTextField {
    var onFocus: (() -> Void)?
    var focusWhenAttached = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusWhenAttached, let window else { return }
        focusWhenAttached = false
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.window === window else { return }
                window.makeFirstResponder(self)
                self.currentEditor()?.selectAll(nil)
            }
        }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?() }
        return ok
    }
}
