// The grid-size and unit-system settings.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
import Foundation
@testable import SimplMaker

@Suite(.serialized) struct GridSizeSettingTests {
    private func reset() {
        for k in [Preferences.unitSystem, Preferences.gridSizeMetric, Preferences.gridSizeUS] {
            UserDefaults.standard.removeObject(forKey: k)
        }
    }

    @Test func fixedSizeFollowsTheUnitSystem() {
        reset(); defer { reset() }
        #expect(Preferences.gridSizeMM == 0)  // automatic by default
        UserDefaults.standard.set(5.0, forKey: Preferences.gridSizeMetric)
        UserDefaults.standard.set(0.25 * 25.4, forKey: Preferences.gridSizeUS)
        UserDefaults.standard.set("metric", forKey: Preferences.unitSystem)
        #expect(Preferences.gridSizeMM == 5)
        UserDefaults.standard.set("us", forKey: Preferences.unitSystem)
        #expect(abs(Preferences.gridSizeMM - 6.35) < 1e-9)
    }

    @Test func rulerLabelsUseTheGridUnits() {
        #expect(Preferences.rulerText(25, us: false) == "25")
        #expect(Preferences.rulerText(25.4, us: true) == "1")
        #expect(Preferences.rulerText(6.35, us: true) == "0.25")
    }
}
