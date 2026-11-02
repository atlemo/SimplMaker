// Picks a foreground colour that reads on a background, by WCAG contrast instead of by guessing.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

@MainActor enum ContrastColor {
    /// WCAG's bar for normal-size text and for icons and other graphics: 4.5 and 3.
    static let textRatio: CGFloat = 4.5
    static let graphicRatio: CGFloat = 3

    /// The colour as plain sRGB, as it looks in `appearance` (dynamic colours such as the accent colour
    /// and the window background resolve differently in light and dark). Nil if it has no sRGB form.
    static func resolve(_ color: NSColor, in appearance: NSAppearance = NSApp.effectiveAppearance) -> NSColor? {
        var result: NSColor?
        appearance.performAsCurrentDrawingAppearance { result = color.usingColorSpace(.sRGB) }
        return result
    }

    /// Black and white in sRGB (`NSColor.white` is a grayscale colour, which has no red component to read).
    static let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    static let black = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)

    /// WCAG relative luminance, 0 (black) to 1 (white). The colour must be in sRGB (see `resolve`).
    static func luminance(_ color: NSColor) -> CGFloat {
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
    }

    /// WCAG contrast ratio between two opaque colours, 1 (none) to 21 (black on white).
    static func ratio(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Black or white for something drawn on `background`. White is what bars in a saturated colour
    /// conventionally carry, and what the rest of the toolbar was designed in, so it is kept while it still
    /// clears the 3:1 bar for graphics and large text; on anything paler it is black, which then
    /// contrasts at 4.5:1 or better. (An unresolvable colour counts as light.)
    static func foreground(on background: NSColor, in appearance: NSAppearance = NSApp.effectiveAppearance) -> NSColor {
        prefersWhite(on: background, in: appearance) ? white : black
    }

    /// True when white is the one to use on `background`.
    static func prefersWhite(on background: NSColor, in appearance: NSAppearance = NSApp.effectiveAppearance) -> Bool {
        guard let bg = resolve(background, in: appearance) else { return false }
        let w = ratio(white, bg)
        return w >= graphicRatio || w > ratio(black, bg)
    }

    /// The foreground at `alpha` (for secondary text), or fully opaque if softening it would drop its
    /// contrast with `background` below `minimum`.
    static func foreground(on background: NSColor, alpha: CGFloat, minimum: CGFloat = textRatio,
                           in appearance: NSAppearance = NSApp.effectiveAppearance) -> NSColor {
        guard let bg = resolve(background, in: appearance) else { return black }
        let base = foreground(on: bg, in: appearance)
        guard alpha < 1, let softened = blend(base, over: bg, alpha: alpha), ratio(softened, bg) >= minimum else { return base }
        return base.withAlphaComponent(alpha)
    }

    private static func blend(_ fg: NSColor, over bg: NSColor, alpha: CGFloat) -> NSColor? {
        guard let f = fg.usingColorSpace(.sRGB), let b = bg.usingColorSpace(.sRGB) else { return nil }
        func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x * alpha + y * (1 - alpha) }
        return NSColor(srgbRed: mix(f.redComponent, b.redComponent), green: mix(f.greenComponent, b.greenComponent),
                       blue: mix(f.blueComponent, b.blueComponent), alpha: 1)
    }

    /// `foreground(on:)` as a SwiftUI colour.
    static func ink(on background: NSColor, in appearance: NSAppearance = NSApp.effectiveAppearance) -> Color {
        Color(nsColor: foreground(on: background, in: appearance))
    }

    /// The window appearance whose controls and labels contrast with `background`: dark (white symbols)
    /// on a deep colour, light (black symbols) on a pale one.
    static func appearance(for background: NSColor, in appearance: NSAppearance = NSApp.effectiveAppearance) -> NSAppearance? {
        NSAppearance(named: prefersWhite(on: background, in: appearance) ? .darkAqua : .aqua)
    }
}
