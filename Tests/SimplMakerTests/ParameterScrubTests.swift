import AppKit
import Testing
@testable import SimplMaker

@Suite struct ParameterScrubTests {
    @Test func stepFollowsTheModifierKeys() {
        #expect(ParameterRow.Scrub.step(unit: .length, []) == 1)
        #expect(ParameterRow.Scrub.step(unit: .length, .shift) == 10)
        #expect(ParameterRow.Scrub.step(unit: .length, .option) == 0.1)
        #expect(ParameterRow.Scrub.step(unit: .angle, []) == 1)
    }

    @Test func expressionIsSnappedAndKeepsItsUnit() {
        #expect(ParameterRow.Scrub(value: 12.3456, unit: .length).expression == "12 mm")
        #expect(ParameterRow.Scrub(value: 45.6, unit: .angle).expression == "46 deg")
        #expect(ParameterRow.Scrub(value: 3.04, unit: .none).expression == "3")
        #expect(ParameterRow.Scrub(value: 12.34, unit: .length, grid: 0.1).expression == "12.3 mm")
    }
}
