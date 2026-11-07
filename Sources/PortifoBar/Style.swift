import AppKit
import PortifoBarCore

@MainActor
enum Style {
    // Portifo's gain and loss colours (design-system/tokens.css,
    // --ds-positive and --ds-negative), light and dark.
    static let positive = dynamic(light: 0x16734B, dark: 0x72D3A6)
    static let negative = dynamic(light: 0xB44145, dark: 0xFB9297)

    // The rest of what Portifo's line charts are drawn in: the price line
    // (--ds-accent), and volume and baseline (--ds-muted).
    static let accent = dynamic(light: 0x245CE8, dark: 0x81A5FF)
    static let muted = dynamic(light: 0x929BAA, dark: 0x708094)

    // Guides (--ds-line) and the ground under extended hours (--ds-subtle).
    // Portifo's are solid tints of its page, which over the popover's glass
    // stood out as white bars and slabs; these are washes of the text colour
    // instead, so they sit as lightly on whatever shows through.
    static let line = wash(light: 0.1, dark: 0.12)
    static let subtle = wash(light: 0.035, dark: 0.045)

    // The SMA bands: the average in ink (--ds-text), the bands above it teal
    // (--ds-band-above) and those below orange (--ds-band-below), and the
    // lines' names (--ds-secondary).
    static let ink = dynamic(light: 0x162239, dark: 0xEEF2F8)
    static let bandAbove = dynamic(light: 0x008F8F, dark: 0x00A9A2)
    static let bandBelow = dynamic(light: 0xBB6212, dark: 0xD27830)
    static let secondary = dynamic(light: 0x657084, dark: 0x9AA8BA)

    // The menu bar's own size, with digits of one width so a price doesn't
    // jostle its neighbours as it ticks.
    static var barFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
    }

    static var menuFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .regular)
    }

    static func color(for move: Double?, decimals: Int = 2) -> NSColor? {
        guard let move, (abs(move) * pow(10, Double(decimals))).rounded() != 0 else { return nil }
        return move > 0 ? positive : negative
    }

    // A sunrise for pre-market, a moon for after hours, a moon and stars
    // overnight; nothing for the regular session.
    static func symbolName(for session: Session) -> String? {
        switch session {
        case .pre: "sunrise.fill"
        case .post: "moon.fill"
        case .overnight: "moon.stars.fill"
        case .regular: nil
        }
    }

    // The session's symbol, sized and centred to sit among `font`'s digits.
    // Left a template, with no colour of its own, so the menu bar draws it
    // as it draws the text beside it: a fixed grey turned to a dim smudge
    // over a colourful wallpaper.
    static func icon(for session: Session, font: NSFont) -> NSAttributedString? {
        guard let name = symbolName(for: session) else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: font.pointSize * 0.75, weight: .regular)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: session.label)?
            .withSymbolConfiguration(config)
        else { return nil }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(
            x: 0,
            y: ((font.capHeight - image.size.height) / 2).rounded(),
            width: image.size.width,
            height: image.size.height
        )
        let icon = NSMutableAttributedString(attachment: attachment)
        icon.append(NSAttributedString(string: " ", attributes: [.font: font]))
        return icon
    }

    // Black over light surfaces and white over dark ones, this transparent.
    private static func wash(light: CGFloat, dark: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            isDark(appearance) ? NSColor(white: 1, alpha: dark) : NSColor(white: 0, alpha: light)
        }
    }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        [.darkAqua, .vibrantDark].contains(appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark]))
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = isDark(appearance) ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        }
    }
}
