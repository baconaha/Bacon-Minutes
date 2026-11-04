import AppKit
import SwiftUI

/// SwiftUI wrapper around one TextKit 1 NSTextView holding the whole transcript (§0).
struct TranscriptTextView: NSViewRepresentable {
    let model: DetailModel

    func makeCoordinator() -> TranscriptTextController {
        TranscriptTextController(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        _ = model.documentVersion
        context.coordinator.syncDocument()
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: TranscriptTextController) {
        coordinator.detach()
    }
}

/// Owns the scroll view / text view, applies highlights with temporary attributes
/// (no relayout) and turns clicks into seeks.
@MainActor
final class TranscriptTextController: NSObject {
    let scrollView: TranscriptScrollView
    let textView: TranscriptNSTextView
    weak var model: DetailModel?

    private var docVersion = -1
    private var document: TranscriptDocument?
    private var cueRange: NSRange?
    private var charRange: NSRange?
    private var hitRanges: [NSRange] = []
    private var currentHit: Int?
    private var observers: [NSObjectProtocol] = []

    init(model: DetailModel) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        // Full layout: non-contiguous layout estimates the height of unlaid text, which put
        // far-away scroll targets in the wrong place and left blank gaps after resizing.
        layout.allowsNonContiguousLayout = false
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 480, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)

        let tv = TranscriptNSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 600), textContainer: container)
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.importsGraphics = false
        tv.allowsUndo = false
        tv.usesFindBar = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 20, height: 8)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor]

        let sv = TranscriptScrollView()
        sv.drawsBackground = false
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false
        sv.autohidesScrollers = true
        sv.scrollerStyle = .overlay
        sv.borderType = .noBorder
        sv.documentView = tv
        sv.contentView.postsBoundsChangedNotifications = true

        scrollView = sv
        textView = tv
        self.model = model
        super.init()

        tv.controller = self
        sv.onUserScroll = { [weak self] in self?.userDidScroll() }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: sv, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.userDidScroll() }
        })
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: sv.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateDirection() }
        })

        model.textController = self
        syncDocument()
    }

    func detach() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        if model?.textController === self { model?.textController = nil }
    }

    // MARK: Document

    func syncDocument() {
        guard let model, model.documentVersion != docVersion else { return }
        docVersion = model.documentVersion
        document = model.document
        let clip = scrollView.contentView
        let savedOrigin = clip.bounds.origin
        textView.textStorage?.setAttributedString(document?.attributed ?? NSAttributedString())
        scrollView.syncDocumentWidth()
        if let lm = textView.layoutManager, let tc = textView.textContainer { lm.ensureLayout(for: tc) }
        cueRange = nil
        charRange = nil
        hitRanges = model.searchHits.map(\.range)
        currentHit = model.searchHits.isEmpty ? nil : model.currentHitIndex
        repaintAll()
        if savedOrigin.y > 0 {
            clip.setBoundsOrigin(NSPoint(x: 0, y: savedOrigin.y))
            scrollView.reflectScrolledClipView(clip)
        }
        // Highlight state lives in the observable model; update it outside the SwiftUI view update.
        Task { @MainActor [weak self] in
            self?.model?.refreshHighlight()
        }
    }

    // MARK: Highlights

    private var storageLength: Int { textView.textStorage?.length ?? 0 }

    private func clamp(_ r: NSRange) -> NSRange? {
        let len = storageLength
        guard r.location < len, r.length > 0 else { return nil }
        return NSRange(location: r.location, length: min(r.length, len - r.location))
    }

    func setCurrent(cue: Int?, charOffset: Int?) {
        guard let doc = document else { return }
        var newCue: NSRange?
        if let cue, cue >= 0, cue < doc.cueRanges.count, doc.cueRanges[cue].length > 0 {
            newCue = doc.cueRanges[cue]
        }
        var newChar: NSRange?
        if let r = newCue, let off = charOffset {
            let loc = r.location + min(max(0, off), r.length - 1)
            let ns = doc.attributed.string as NSString
            newChar = loc < ns.length ? ns.rangeOfComposedCharacterSequence(at: loc) : nil
        }
        guard newCue != cueRange || newChar != charRange else { return }
        let dirty = [cueRange, newCue, charRange, newChar].compactMap { $0 }
        cueRange = newCue
        charRange = newChar
        repaint(dirty)
    }

    func setHits(_ ranges: [NSRange], current: Int?) {
        let oldHits = hitRanges
        let oldCurrent = currentHit
        hitRanges = ranges
        currentHit = current
        if oldHits != ranges {
            repaintAll()
        } else if oldCurrent != current {
            var dirty: [NSRange] = []
            if let o = oldCurrent, o < ranges.count { dirty.append(ranges[o]) }
            if let c = current, c < ranges.count { dirty.append(ranges[c]) }
            repaint(dirty)
        }
    }

    private func repaintAll() {
        let len = storageLength
        guard len > 0 else { return }
        repaint([NSRange(location: 0, length: len)])
    }

    private func repaint(_ ranges: [NSRange]) {
        guard let lm = textView.layoutManager else { return }
        for raw in ranges {
            guard let r = clamp(raw) else { continue }
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: r)
            lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: r)
            if let c = cueRange, let i = c.intersection(r), i.length > 0 {
                lm.addTemporaryAttribute(.backgroundColor, value: Palette.currentCue, forCharacterRange: i)
            }
            if !hitRanges.isEmpty {
                var idx = firstHit(endingAfter: r.location)
                while idx < hitRanges.count, hitRanges[idx].location < NSMaxRange(r) {
                    if let i = hitRanges[idx].intersection(r), i.length > 0 {
                        let color = idx == currentHit ? Palette.searchHitCurrent : Palette.searchHit
                        lm.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: i)
                    }
                    idx += 1
                }
            }
            if let ch = charRange, let i = ch.intersection(r), i.length > 0 {
                lm.addTemporaryAttribute(.backgroundColor, value: Palette.brand, forCharacterRange: i)
                lm.addTemporaryAttribute(.foregroundColor, value: NSColor.white, forCharacterRange: i)
            }
        }
    }

    /// Index of the first hit whose end is after `location` (hits are sorted and disjoint).
    private func firstHit(endingAfter location: Int) -> Int {
        var lo = 0, hi = hitRanges.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if NSMaxRange(hitRanges[mid]) <= location { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    // MARK: Scrolling

    func rect(forCharacterRange range: NSRange) -> NSRect? {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return nil }
        let len = storageLength
        guard len > 0, range.location <= len else { return nil }
        var r = range
        if r.length == 0 { r.length = min(1, len - r.location) }
        if r.location >= len { r = NSRange(location: len - 1, length: 1) }
        let glyphs = lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
        let origin = textView.textContainerOrigin
        rect.origin.x += origin.x
        rect.origin.y += origin.y
        return rect
    }

    /// Puts the range about one third from the top of the visible area (§5.5).
    func scroll(toCharacterRange range: NSRange, animated: Bool) {
        guard let rect = rect(forCharacterRange: range) else { return }
        let clip = scrollView.contentView
        let visibleHeight = clip.bounds.height
        var docHeight = textView.frame.height
        if let lm = textView.layoutManager, let tc = textView.textContainer {
            docHeight = max(docHeight, lm.usedRect(for: tc).maxY + textView.textContainerInset.height * 2)
        }
        var y = rect.minY - visibleHeight / 3
        y = max(0, min(y, max(0, docHeight - visibleHeight)))
        let target = NSPoint(x: 0, y: y)
        guard abs(clip.bounds.origin.y - y) > 1 else { return }
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                ctx.allowsImplicitAnimation = true
                clip.animator().setBoundsOrigin(target)
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
                }
            })
        } else {
            clip.setBoundsOrigin(target)
            scrollView.reflectScrolledClipView(clip)
        }
    }

    func scrollToCue(_ id: Int, animated: Bool) {
        guard let doc = document, id >= 0, id < doc.cueRanges.count else { return }
        scroll(toCharacterRange: doc.scrollRange(forCue: id), animated: animated)
    }

    private func userDidScroll() {
        guard let model else { return }
        if model.isFollowing { model.isFollowing = false }
        updateDirection()
    }

    /// Whether the current cue lies above the reading position – decides the button arrow.
    func updateDirection() {
        guard let model, !model.isFollowing, let doc = document, let cue = model.currentCueID,
              cue >= 0, cue < doc.cueRanges.count,
              let rect = rect(forCharacterRange: doc.scrollRange(forCue: cue)) else { return }
        let visible = scrollView.contentView.bounds
        let above = rect.midY < visible.minY + visible.height / 3
        if model.currentCueAbove != above { model.currentCueAbove = above }
    }

    // MARK: Clicks

    /// Single click without drag or selection (§5.4).
    func handleClick(at point: NSPoint) {
        guard let model, let doc = document, let lm = textView.layoutManager, let tc = textView.textContainer,
              let storage = textView.textStorage, storage.length > 0 else { return }
        let origin = textView.textContainerOrigin
        let p = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        var fraction: CGFloat = 0
        let glyph = lm.glyphIndex(for: p, in: tc, fractionOfDistanceThroughGlyph: &fraction)
        let lineRect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        guard p.y >= lineRect.minY - 1, p.y <= lineRect.maxY + 1 else { return }
        let index = lm.characterIndexForGlyph(at: glyph)
        guard index < storage.length else { return }
        let attrs = storage.attributes(at: index, effectiveRange: nil)
        if let cue = attrs[TranscriptAttribute.cue] as? Int, cue >= 0, cue < doc.cueRanges.count {
            let r = doc.cueRanges[cue]
            let offset: Int? = (r.length > 0 && index >= r.location && index < NSMaxRange(r)) ? index - r.location : nil
            model.jump(toCue: cue, charOffset: offset)
        } else if let paragraph = attrs[TranscriptAttribute.timestamp] as? Int {
            model.jump(toParagraph: paragraph)
        }
    }

    func copySelectionAsPlainText() -> Bool {
        let r = textView.selectedRange()
        guard r.length > 0, let storage = textView.textStorage, NSMaxRange(r) <= storage.length else { return false }
        var text = (storage.string as NSString).substring(with: r)
        text = text.replacingOccurrences(of: "\u{FFFC}", with: "")
        text = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        return true
    }
}

/// Reports wheel / trackpad scrolling, which programmatic scrolling never produces.
final class TranscriptScrollView: NSScrollView {
    var onUserScroll: (() -> Void)?

    /// Keeps the text view exactly as wide as the visible area so paragraphs re-wrap on resize
    /// and never scroll sideways.
    func syncDocumentWidth() {
        guard let tv = documentView as? NSTextView else { return }
        let width = contentSize.width
        if width > 0, abs(tv.frame.width - width) > 0.5 {
            tv.setFrameSize(NSSize(width: width, height: tv.frame.height))
        }
        let origin = contentView.bounds.origin
        if origin.x != 0 {
            contentView.setBoundsOrigin(NSPoint(x: 0, y: origin.y))
            reflectScrolledClipView(contentView)
        }
    }

    override func tile() {
        super.tile()
        syncDocumentWidth()
    }

    override func scrollWheel(with event: NSEvent) {
        onUserScroll?()
        super.scrollWheel(with: event)
    }
}

final class TranscriptNSTextView: NSTextView {
    weak var controller: TranscriptTextController?

    override func mouseDown(with event: NSEvent) {
        let downInWindow = event.locationInWindow
        let downPoint = convert(downInWindow, from: nil)
        let clicks = event.clickCount
        // NSTextView runs its own tracking loop here and returns after mouse-up.
        super.mouseDown(with: event)
        guard clicks == 1 else { return }
        let upInWindow = window?.mouseLocationOutsideOfEventStream ?? downInWindow
        let moved = hypot(upInWindow.x - downInWindow.x, upInWindow.y - downInWindow.y) > 3
        guard !moved, selectedRange().length == 0 else { return }
        controller?.handleClick(at: downPoint)
    }

    override func copy(_ sender: Any?) {
        if controller?.copySelectionAsPlainText() != true {
            super.copy(sender)
        }
    }

    override var acceptsFirstResponder: Bool { true }
}
