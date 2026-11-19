// The panel material setting: the choices, their stored names, and the default.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import SimplMaker

@Suite struct PanelMaterialTests {
    @Test func offersThinRegularAndThickByTheirStoredNames() {
        #expect(Preferences.PanelMaterial.allCases.map(\.rawValue) == ["thin", "regular", "thick"])
        #expect(Preferences.PanelMaterial.allCases.map(\.title) == ["Thin", "Regular", "Thick"])
    }

    @Test func anUnknownStoredNameIsNotAChoice() {
        #expect(Preferences.PanelMaterial(rawValue: "glass") == nil)
        #expect(Preferences.PanelMaterial(rawValue: "thick") == .thick)
    }
}

@Suite struct PanelStyleTests {
    @Test func offersTheBlurAndLiquidGlassByTheirStoredNames() {
        #expect(Preferences.PanelStyle.allCases.map(\.rawValue) == ["blur", "glass"])
        #expect(Preferences.PanelStyle.allCases.map(\.title) == ["System blur", "Liquid Glass"])
        #expect(Preferences.PanelStyle.choices.contains(.blur), "the blur is offered on every system")
    }
}

@Suite struct PanelDefaultsTests {
    @Test func panelsStartAsRegularLiquidGlass() {
        #expect(Preferences.defaultPanelStyle == .glass)
        #expect(Preferences.defaultPanelMaterial == .regular)
    }
}
