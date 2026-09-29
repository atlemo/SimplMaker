// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import SimplCAD

/// Which tools a toolbar group shows: the defaults until changed, at most `ToolPins.limit`.
@Suite struct ToolPinsTests {
    let tools = ["Extrude", "Revolve", "Sweep", "Loft", "Rib", "Pipe"]

    @Test func nothingSavedMeansTheDefaults() {
        let pins = ToolPins(stored: nil, available: tools, defaults: ["Extrude", "Revolve"])
        #expect(pins.ids == ["Extrude", "Revolve"])
    }

    @Test func anEmptySaveMeansNoneAreShown() {
        let pins = ToolPins(stored: "", available: tools, defaults: ["Extrude"])
        #expect(pins.ids.isEmpty)
    }

    @Test func savedPinsDropToolsTheGroupNoLongerHasAndRepeats() {
        let pins = ToolPins(stored: "Loft,Gone,Loft,Rib", available: tools, defaults: [])
        #expect(pins.ids == ["Loft", "Rib"])
    }

    @Test func aFullGroupTakesNoMoreUntilOneIsUnpinned() {
        var pins = ToolPins(stored: "Extrude,Revolve,Sweep,Loft", available: tools, defaults: [])
        #expect(pins.isFull)
        pins.toggle("Rib")
        #expect(!pins.contains("Rib"))
        pins.toggle("Sweep")
        pins.toggle("Rib")
        #expect(pins.ids == ["Extrude", "Revolve", "Loft", "Rib"])
        #expect(ToolPins(stored: pins.stored, available: tools, defaults: []) == pins)
    }

    @Test func savesAreCappedAtTheLimit() {
        let pins = ToolPins(stored: tools.joined(separator: ","), available: tools, defaults: [])
        #expect(pins.ids.count == ToolPins.limit)
    }
}
