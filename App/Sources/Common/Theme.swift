import AppKit
import SwiftUI

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }

    /// Parses `#RRGGBB`; falls back to the brand colour.
    convenience init(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        let value = UInt32(s, radix: 16) ?? 0x3370FF
        self.init(hex: value)
    }

    static func dynamic(_ light: UInt32, _ dark: UInt32) -> NSColor {
        let l = NSColor(hex: light), d = NSColor(hex: dark)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? d : l
        }
    }
}

/// §10 colours with dark-mode counterparts.
enum Palette {
    static let brand = NSColor.dynamic(0x3370FF, 0x4E83FD)
    static let brandHover = NSColor.dynamic(0x4E83FD, 0x6B97FF)
    static let textPrimary = NSColor.dynamic(0x1F2329, 0xE6E8EB)
    static let textSecondary = NSColor.dynamic(0x646A73, 0xA6ABB3)
    static let textTertiary = NSColor.dynamic(0x8F959E, 0x7A818C)
    static let divider = NSColor.dynamic(0xE5E6EB, 0x373A40)
    static let searchFill = NSColor.dynamic(0xF2F3F5, 0x2E3033)
    static let sidebar = NSColor.dynamic(0xF5F6F7, 0x202124)
    static let card = NSColor.dynamic(0xFFFFFF, 0x252629)
    static let windowTop = NSColor.dynamic(0xEEF2FA, 0x1B1C1F)
    static let windowBottom = NSColor.dynamic(0xF5F6FA, 0x1B1C1F)
    static let currentCue = NSColor.dynamic(0xE1EAFF, 0x24365C)
    static let searchHit = NSColor.dynamic(0xFFF1A8, 0x5E4F14)
    static let searchHitCurrent = NSColor.dynamic(0xFFC53D, 0xA36F00)
    static let aiPurple = NSColor.dynamic(0x7B61FF, 0x9D8BFF)
    static let aiCardTop = NSColor.dynamic(0xF3F0FF, 0x2D2942)
    static let hoverFill = NSColor.dynamic(0xF0F4FF, 0x2A3247)
    static let rowHover = NSColor.dynamic(0xF7F8FA, 0x2B2C30)
    static let trackIdle = NSColor.dynamic(0xF0F1F5, 0x35373C)
    static let skeleton = NSColor.dynamic(0xEFF0F2, 0x303236)
    static let warningFill = NSColor.dynamic(0xFFF7E0, 0x3D3416)
    static let warningText = NSColor.dynamic(0x8A5A00, 0xE8C46A)
    static let errorText = NSColor.dynamic(0xD83931, 0xFF7A70)
    static let audioCoverTop = NSColor.dynamic(0xE8F0FF, 0x1F2A40)
    static let audioCoverBottom = NSColor.dynamic(0xF5F8FF, 0x252629)
}

extension Color {
    static let brand = Color(nsColor: Palette.brand)
    static let brandHover = Color(nsColor: Palette.brandHover)
    static let textPrimary = Color(nsColor: Palette.textPrimary)
    static let textSecondary = Color(nsColor: Palette.textSecondary)
    static let textTertiary = Color(nsColor: Palette.textTertiary)
    static let divider = Color(nsColor: Palette.divider)
    static let searchFill = Color(nsColor: Palette.searchFill)
    static let sidebarFill = Color(nsColor: Palette.sidebar)
    static let card = Color(nsColor: Palette.card)
    static let windowTop = Color(nsColor: Palette.windowTop)
    static let windowBottom = Color(nsColor: Palette.windowBottom)
    static let selectionFill = Color(nsColor: Palette.currentCue)
    static let searchHit = Color(nsColor: Palette.searchHit)
    static let aiPurple = Color(nsColor: Palette.aiPurple)
    static let aiCardTop = Color(nsColor: Palette.aiCardTop)
    static let hoverFill = Color(nsColor: Palette.hoverFill)
    static let rowHover = Color(nsColor: Palette.rowHover)
    static let trackIdle = Color(nsColor: Palette.trackIdle)
    static let skeleton = Color(nsColor: Palette.skeleton)
    static let warningFill = Color(nsColor: Palette.warningFill)
    static let warningText = Color(nsColor: Palette.warningText)
    static let errorText = Color(nsColor: Palette.errorText)
    static let audioCoverTop = Color(nsColor: Palette.audioCoverTop)
    static let audioCoverBottom = Color(nsColor: Palette.audioCoverBottom)

    init(hexString: String) {
        self.init(nsColor: NSColor(hexString: hexString))
    }
}

struct WindowBackground: View {
    var body: some View {
        LinearGradient(colors: [.windowTop, .windowBottom], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}
