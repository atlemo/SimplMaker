import AppKit
import Testing
@testable import SimplMaker

@Suite struct ParameterScrubTests {
    @Test func stepFollowsTheModifierKeys() {
        #expect(ParameterRow.Scrub.step(unit: .length, []) == 0.1)
        #expect(ParameterRow.Scrub.step(unit: .length, .shift) == 1)
        #expect(ParameterRow.Scrub.step(unit: .length, .option) == 0.01)
        #expect(ParameterRow.Scrub.step(unit: .angle, []) == 0.5)
    }

    @Test func expressionIsSnappedAndKeepsItsUnit() {
        #expect(ParameterRow.Scrub(value: 12.3456, unit: .length).expression == "12.3 mm")
        #expect(ParameterRow.Scrub(value: 45.26, unit: .angle, grid: 0.5).expression == "45.5 deg")
        #expect(ParameterRow.Scrub(value: 3.04, unit: .none).expression == "3")
    }
}
