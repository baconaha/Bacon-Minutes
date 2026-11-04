import AppKit
import SwiftUI

// MARK: - Logo

struct AppLogo: View {
    var size: CGFloat = 32

    var body: some View {
        Image(nsImage: AppIconStore.shared.artwork)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fill)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
    }
}

// MARK: - Avatar

enum AvatarText {
    /// Generic speaker words in every UI language ("说话人", "Speaker", "話者" …).
    private static let genericPrefixes: [String] = {
        var out = ["说话人", "Speaker", "speaker"]
        for lang in AppLanguage.allCases {
            let word = L("说话人 {0}", in: lang, "").trimmingCharacters(in: .whitespaces)
            if !word.isEmpty, !out.contains(word) { out.append(word) }
        }
        return out
    }()

    /// "说话人 3" / "Speaker 3" → "3"; otherwise the first character.
    static func initial(for name: String) -> String {
        let t = name.trimmingCharacters(in: .whitespaces)
        for prefix in genericPrefixes where t.hasPrefix(prefix) {
            let rest = t.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty, rest.allSatisfy({ $0.isNumber }) { return String(rest.prefix(2)) }
        }
        guard let first = t.first else { return "?" }
        return String(first).uppercased()
    }
}

struct SpeakerAvatar: View {
    let name: String
    let colorHex: String
    var size: CGFloat = 22

    var body: some View {
        Circle()
            .fill(Color(hexString: colorHex))
            .frame(width: size, height: size)
            .overlay(
                Text(AvatarText.initial(for: name))
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            )
    }
}

/// Avatar bitmap for NSTextAttachment, cached per text+colour.
@MainActor
enum AvatarImageCache {
    private static var cache: [String: NSImage] = [:]

    static func image(name: String, colorHex: String, size: CGFloat = 22) -> NSImage {
        let text = AvatarText.initial(for: name)
        let key = "\(text)|\(colorHex)|\(size)"
        if let img = cache[key] { return img }
        let color = NSColor(hexString: colorHex)
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            let font = NSFont.systemFont(ofSize: size * 0.5, weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            let str = NSAttributedString(string: text, attributes: attrs)
            let s = str.size()
            str.draw(at: NSPoint(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2))
            return true
        }
        cache[key] = img
        return img
    }
}

// MARK: - Tags

struct TagLabel: View {
    let text: String
    var warning = false

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(warning ? Color.warningText : Color.brand)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 2).fill(warning ? Color.warningFill : Color.selectionFill))
    }
}

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration, compact: compact)
    }

    private struct PrimaryButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let compact: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, compact ? 12 : 16)
                .frame(height: compact ? 28 : 32)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(hovering && isEnabled ? Color.brandHover : Color.brand)
                )
                .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SecondaryButtonBody(configuration: configuration)
    }

    private struct SecondaryButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13))
                .foregroundStyle(Color.textPrimary)
                .padding(.horizontal, 16)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.rowHover : Color.card))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.divider))
                .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// Blue text button ("取消", "展开", "重新生成").
struct TextLinkButtonStyle: ButtonStyle {
    var size: CGFloat = 13

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size))
            .foregroundStyle(Color.brand)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}

/// Square icon button with a hover background.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    var foreground: Color = .textSecondary
    /// Hover background; pass `.card` on the gray sidebar, where `.rowHover` is barely visible.
    var hoverFill: Color = .rowHover

    func makeBody(configuration: Configuration) -> some View {
        IconBody(configuration: configuration, size: size, foreground: foreground, hoverFill: hoverFill)
    }

    private struct IconBody: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        let foreground: Color
        let hoverFill: Color
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 14))
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? hoverFill : Color.clear))
                .animation(.easeOut(duration: 0.12), value: hovering)
                .opacity(configuration.isPressed ? 0.7 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - Tabs

/// Text tab with a 2pt underline as wide as the text (§10). Hovering turns the title blue
/// and shows the pointing hand.
struct UnderlineTab: View {
    let title: String
    let selected: Bool
    var fontSize: CGFloat = 15
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: fontSize, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected || hovering ? Color.brand : Color.textSecondary)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .padding(.bottom, 10)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(selected ? Color.brand : Color.clear)
                        .frame(height: 2)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor { hovering = $0 }
    }
}

extension View {
    /// Shows the pointing hand while the pointer is over the view.
    func pointingHandCursor(_ onHover: ((Bool) -> Void)? = nil) -> some View {
        onContinuousHover { phase in
            switch phase {
            case .active:
                NSCursor.pointingHand.set()
                onHover?(true)
            case .ended:
                NSCursor.arrow.set()
                onHover?(false)
            }
        }
    }
}

// MARK: - Skeleton & toast

struct SkeletonBlock: View {
    var width: CGFloat?
    var height: CGFloat = 12
    var radius: CGFloat = 4
    @State private var dim = false

    var body: some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(Color.skeleton)
            .frame(width: width, height: height)
            .opacity(dim ? 0.55 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

struct ToastView: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.brand)
            Text(text).font(.system(size: 13)).foregroundStyle(Color.textPrimary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.card))
        .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 4)
    }
}

/// The ✦ mark used on AI cards.
struct AISparkle: View {
    var size: CGFloat = 14

    var body: some View {
        Image(systemName: "sparkle")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(LinearGradient(colors: [Color.aiPurple, Color.brand], startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}

/// Dashed vertical line, used for the chapter timeline.
struct VerticalLine: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return p
    }
}

// MARK: - Window access

/// Hands the hosting NSWindow to SwiftUI code (for full screen and key handling).
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowTrackingView {
        let v = WindowTrackingView()
        v.onWindow = onWindow
        return v
    }

    func updateNSView(_ nsView: WindowTrackingView, context: Context) {}
}

final class WindowTrackingView: NSView {
    var onWindow: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindow?(window)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
