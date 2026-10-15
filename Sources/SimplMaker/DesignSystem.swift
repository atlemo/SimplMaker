// Layout tokens from the "macOS Design System" (Claude Design), so custom-drawn UI here uses the
// same spacing, radius and timing scale as the rest of the design system rather than ad hoc numbers.
// Copyright © 2026 Atle Mo. All rights reserved.
import AppKit
import Foundation
import SwiftUI

/// Design-system tokens. Native SwiftUI/AppKit controls already draw with the real system colors,
/// materials and fonts, so this only covers the numeric scale (spacing, radii, control heights,
/// motion) that hand-built views need to line up with.
enum DS {
    /// SimplMaker's own accent colour (#EB5729). What the UI actually uses is `\.accent` (below), which is this
    /// or the system's, by the setting, and always the system's while sketching.
    static let brand = Color(red: 0xEB / 255, green: 0x57 / 255, blue: 0x29 / 255)
    static let brandNS = NSColor(srgbRed: 0xEB / 255, green: 0x57 / 255, blue: 0x29 / 255, alpha: 1)

    /// The 8-step spacing scale, in points.
    enum Spacing {
        static let space0: CGFloat = 0
        static let space1: CGFloat = 2
        static let space2: CGFloat = 4
        static let space3: CGFloat = 6
        static let space4: CGFloat = 8
        static let space5: CGFloat = 12
        static let space6: CGFloat = 16
        static let space7: CGFloat = 20
        static let space8: CGFloat = 24
        static let space9: CGFloat = 32
        static let space10: CGFloat = 40

        /// Window content margin.
        static let windowMargin: CGFloat = 20
        /// Between controls in the same group (a toolbar, a button row).
        static let controlGap: CGFloat = 8
        /// Between distinct groups.
        static let groupGap: CGFloat = 20
        /// Between a control and its label.
        static let labelGap: CGFloat = 6
    }

    /// Standard control heights (mini / small / regular / large / extra-large).
    enum ControlHeight {
        static let mini: CGFloat = 16
        static let small: CGFloat = 20
        static let regular: CGFloat = 24
        static let large: CGFloat = 28
        static let xlarge: CGFloat = 36

        static let titlebar: CGFloat = 28
        static let toolbar: CGFloat = 52
        static let sidebarWidth: CGFloat = 220
        static let sidebarRow: CGFloat = 28
        static let tableRow: CGFloat = 24
    }

    /// Corner radii — concentric: an inner radius is an outer radius minus its padding.
    enum Radius {
        static let xs: CGFloat = 3
        static let sm: CGFloat = 5
        static let md: CGFloat = 6
        static let lg: CGFloat = 8
        static let xl: CGFloat = 10
        static let xl2: CGFloat = 12
        static let xl3: CGFloat = 16

        static let control: CGFloat = 6
        static let checkbox: CGFloat = 4
        static let menu: CGFloat = 10
        static let menuItem: CGFloat = 5
        static let popover: CGFloat = 12
        static let sidebarItem: CGFloat = 6
        static let window: CGFloat = 16
        static let groupbox: CGFloat = 8
    }

    /// Motion durations, in seconds. Short and eased; springy only for switch-knob-style moves.
    enum Duration {
        static let instant: Double = 0.08
        static let fast: Double = 0.15
        static let base: Double = 0.25
        static let slow: Double = 0.4
    }

    static let opacityDisabled: Double = 0.4
    static let opacityPressed: Double = 0.75
}

extension EnvironmentValues {
    /// The highlight colour of the app's own UI (active tools, selections, small details of icons); see
    /// `AccentScope`.
    @Entry var accent: Color = DS.brand
}

extension Preferences {
    /// Which accent colour the UI uses: SimplMaker's orange, or the one set in System Settings.
    enum AccentSource: String, CaseIterable, Identifiable {
        case simplMaker, system
        var id: String { rawValue }
        var title: String { self == .simplMaker ? "SimplMaker orange" : "Same as system" }
    }
    static let accentSource = "accentSource"
    static var accentSourceSetting: AccentSource {
        AccentSource(rawValue: UserDefaults.standard.string(forKey: accentSource) ?? "") ?? .simplMaker
    }

    /// Sketch mode never uses the orange: the sketch paper and its toolbar are tones of the system's colour.
    static func accent(_ source: AccentSource, sketching: Bool) -> Color {
        source == .simplMaker && !sketching ? DS.brand : Color(nsColor: .controlAccentColor)
    }
    static func nsAccent(sketching: Bool) -> NSColor {
        accentSourceSetting == .simplMaker && !sketching ? DS.brandNS : .controlAccentColor
    }
}

/// Gives a window's content the accent colour (the `\.accent` environment value, and the tint of its native
/// controls), following the Settings choice and whether a sketch is open.
struct AccentScope: ViewModifier {
    var sketching = false
    @AppStorage(Preferences.accentSource) private var source = Preferences.AccentSource.simplMaker

    func body(content: Content) -> some View {
        let color = Preferences.accent(source, sketching: sketching)
        content.environment(\.accent, color).tint(color)
    }
}

extension View {
    /// Liquid Glass on macOS 26; on older systems the system's thin material with a hairline edge,
    /// which is the nearest look the older SDK offers.
    @ViewBuilder
    func panelGlass<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self
                .background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
        }
    }
}

extension ToolbarContent {
    /// Drops the glass pill macOS 26 draws behind a toolbar item; older systems draw none.
    @ToolbarContentBuilder
    func withoutSharedBackground() -> some ToolbarContent {
        if #available(macOS 26.0, *) {
            self.sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

extension DS {
    /// The window and under-page greys as macOS 26 draws them for an app built for 26. A binary whose
    /// deployment target is older gets the pre-26 values for the system's own colours even on 26
    /// (light mode: window 236 instead of 255, under-page 159 instead of 246), so the welcome window
    /// asks for the 26 values by hand there. Dark mode and older systems keep the system's colours.
    static let windowBackground = lightOverride(white: 1.0, system: .windowBackgroundColor)
    static let underPageBackground = lightOverride(white: 246 / 255, system: .underPageBackgroundColor)

    private static func lightOverride(white: CGFloat, system: NSColor) -> Color {
        guard #available(macOS 26.0, *) else { return Color(nsColor: system) }
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua ? NSColor(white: white, alpha: 1) : system
        })
    }
}
