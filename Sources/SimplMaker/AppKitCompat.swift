// The few AppKit names the shared SwiftUI code uses for colours, given their UIKit meanings on the iPad, so a view written for both
// compiles for both. Nothing here exists on the Mac.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
#if !os(macOS)
import SwiftUI
import UIKit

typealias NSColor = UIColor

/// Stands in for AppKit's colour space argument: every iPad colour is read as sRGB.
enum NSColorSpace { case sRGB }

extension UIColor {
    convenience init(srgbRed r: CGFloat, green g: CGFloat, blue b: CGFloat, alpha a: CGFloat) { self.init(red: r, green: g, blue: b, alpha: a) }
    static var controlAccentColor: UIColor { .tintColor }
    static var windowBackgroundColor: UIColor { .systemBackground }
    static var controlBackgroundColor: UIColor { .secondarySystemBackground }
    static var textBackgroundColor: UIColor { .systemBackground }
    static var textColor: UIColor { .label }
    static var secondaryLabelColor: UIColor { .secondaryLabel }
    static var tertiaryLabelColor: UIColor { .tertiaryLabel }
    static var separatorColor: UIColor { .separator }
    static var selectedTextBackgroundColor: UIColor { .tintColor }
    static var selectedTextColor: UIColor { .white }
    func usingColorSpace(_ space: NSColorSpace) -> UIColor? { self }
    var redComponent: CGFloat { var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0; getRed(&r, green: &g, blue: &b, alpha: &a); return r }
    var greenComponent: CGFloat { var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0; getRed(&r, green: &g, blue: &b, alpha: &a); return g }
    var blueComponent: CGFloat { var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0; getRed(&r, green: &g, blue: &b, alpha: &a); return b }
    /// A mix of this colour and `other`: `fraction` of the other.
    func blended(withFraction fraction: CGFloat, of other: UIColor) -> UIColor? {
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        guard getRed(&ar, green: &ag, blue: &ab, alpha: &aa), other.getRed(&br, green: &bg, blue: &bb, alpha: &ba) else { return nil }
        let f = fraction
        return UIColor(red: ar * (1 - f) + br * f, green: ag * (1 - f) + bg * f, blue: ab * (1 - f) + bb * f, alpha: aa)
    }
}

/// The modifier keys, under the AppKit name the shared code reads them by.
enum NSEvent {
    /// The iPad has no global view of the keyboard's modifier keys; a gesture or a key press carries its own.
    static var modifierFlags: ModifierFlags { [] }
    struct ModifierFlags: OptionSet {
        let rawValue: Int
        static let shift = ModifierFlags(rawValue: 1)
        static let option = ModifierFlags(rawValue: 2)
        static let control = ModifierFlags(rawValue: 4)
        static let command = ModifierFlags(rawValue: 8)
    }
}

/// Whether a window is the one being worked in: always, on the iPad (its scenes are not "inactive" in the Mac's sense).
enum ControlActiveState { case key, active, inactive }

extension EnvironmentValues {
    var controlActiveState: ControlActiveState { .key }
}

extension Color {
    init(nsColor: UIColor) { self.init(uiColor: nsColor) }
}
#endif
