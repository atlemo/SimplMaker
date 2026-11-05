// How far apart the grid lines are at a zoom. Shared by the Mac and the iPad app.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum GridSteps {
    /// Grid spacing for a zoom: minor lines about 40 px apart (1, 2 or 5 × 10ⁿ mm) or the square chosen in
    /// Settings (stepped up when it would be under 12 px wide), a major line every fifth (fourth in
    /// inches), and the snapping step, which lands on the minor lines too.
    static func steps(mmPerPixel: Double) -> (minor: Double, major: Double, snap: Double) {
        let fixed = Preferences.gridSizeMM
        if fixed > 0 {
            let us = Preferences.unitSystemSetting.isUS
            var minor = fixed
            while minor < 12 * mmPerPixel, minor.isFinite { minor *= us ? 4 : 10 }
            return (minor, minor * (us ? 4 : 5), minor)
        }
        let minor = niceStep(40 * mmPerPixel)
        let twos = abs(minor / pow(10, floor(log10(minor))) - 2) < 1e-9
        return (minor, minor * 5, minor / (twos ? 4 : 5))
    }

    /// The smallest of 1, 2 or 5 × 10ⁿ mm that is at least `minimum`.
    nonisolated static func niceStep(_ minimum: Double) -> Double {
        guard minimum > 0, minimum.isFinite else { return 1 }
        let base = pow(10, floor(log10(minimum)))
        for m in [1.0, 2, 5, 10] where base * m >= minimum { return base * m }
        return base * 10
    }
}
