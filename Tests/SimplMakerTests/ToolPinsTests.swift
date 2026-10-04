// Copyright © 2026 Atle Mo. All rights reserved.
import Testing
@testable import SimplMaker

/// Which tools a toolbar group shows: the defaults until changed, then any of them.
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

    @Test func pinningAndUnpinningIsSavedAndReadBack() {
        var pins = ToolPins(stored: "Extrude,Revolve,Sweep,Loft", available: tools, defaults: [])
        pins.toggle("Rib")
        pins.toggle("Pipe")
        pins.toggle("Sweep")
        #expect(pins.ids == ["Extrude", "Revolve", "Loft", "Rib", "Pipe"])
        #expect(ToolPins(stored: pins.stored, available: tools, defaults: []) == pins)
    }

    @Test func everyToolCanBePinned() {
        let pins = ToolPins(stored: tools.joined(separator: ","), available: tools, defaults: [])
        #expect(pins.ids == tools)
    }
}
