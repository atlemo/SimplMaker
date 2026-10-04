// Layout tokens from the "macOS Design System" (Claude Design), so custom-drawn UI here uses the
// same spacing, radius and timing scale as the rest of the design system rather than ad hoc numbers.
// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation

/// Design-system tokens. Native SwiftUI/AppKit controls already draw with the real system colors,
/// materials and fonts, so this only covers the numeric scale (spacing, radii, control heights,
/// motion) that hand-built views need to line up with.
enum DS {
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
