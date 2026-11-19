// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CADCore

/// Splits are stored beside the features, optional like molds: old files are untouched and new settings can be added later.
@Suite struct PrintSplitSetupTests {
    @Test func aSplitSurvivesAFileRoundTrip() throws {
        var d = CADDocument()
        d.printSplits = [PrintSplit(id: "s1", name: "Hull split", body: "hull", printer: PrinterPreset.customID, customVolume: ["180 mm", "180 mm", "200 mm"],
                                    margin: "4 mm", turn: false, counts: [3, 0, 1], cuts: [PrintSplitCut(axis: .y, position: "12 mm")], connector: .pin, separate: true,
                                    fit: .custom, customClearance: "0.25 mm", spacing: "50 mm")]
        let back = try JSONDecoder().decode(CADDocument.self, from: try JSONEncoder().encode(d))
        #expect(back.printSplits == d.printSplits)
    }

    @Test func aPartWithoutSplitsWritesNoSplitKey() throws {
        #expect(!String(decoding: try JSONEncoder().encode(CADDocument()), as: UTF8.self).contains("printSplits"))
    }

    @Test func anOlderFileOpensWithNoSplits() throws {
        let json = #"{"version":1,"parameters":[],"features":[]}"#
        #expect(try JSONDecoder().decode(CADDocument.self, from: Data(json.utf8)).printSplits.isEmpty)
    }

    @Test func aSplitWithOnlyItsBodyGetsTheDefaults() throws {
        let json = #"{"version":1,"features":[],"printSplits":[{"id":"a","body":"b"}]}"#
        let s = try #require(try JSONDecoder().decode(CADDocument.self, from: Data(json.utf8)).printSplits.first)
        #expect(s.body == "b" && s.printer == PrinterPreset.defaultID && s.turn && s.cuts == nil && s.connector == .pin)
        #expect(s.connectorSize == "6 mm" && s.connectorLength == "8 mm" && s.fit == .standard && s.counts == [0, 0, 0])
    }

    @Test func changingASplitNeedsNoRebuildOfTheFeatures() {
        var a = CADDocument()
        var b = a
        b.printSplits = [PrintSplit(name: "s", body: "x")]
        a.printSplits = []
        #expect(a != b)
        #expect(a.ignoringPresentation == b.ignoringPresentation)
    }

    @Test func choosingAConnectorBringsItsOwnSizes() {
        var s = PrintSplit(name: "s", body: "x")
        s.choose(.magnet)
        #expect(s.connector == .magnet && s.connectorSize == "6 mm" && s.connectorLength == "3 mm")
        s.choose(.dovetail)
        #expect(s.connectorSize == "10 mm" && s.connectorLength == "6 mm")
        // A flat cut keeps the sizes, so going back to a connector is not a fresh start.
        s.choose(.none)
        #expect(s.connectorSize == "10 mm")
    }

    @Test func thePrinterCatalogHasUniqueIdsAndSaneVolumes() {
        let ids = PrinterPreset.catalog.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(PrinterPreset.preset(PrinterPreset.defaultID) != nil)
        for p in PrinterPreset.catalog { #expect(p.volume.x >= 100 && p.volume.y >= 100 && p.volume.z >= 100 && p.volume.x <= 500, "\(p.title)") }
        #expect(PrinterPreset.makers.count >= 8)
    }

    @Test func theFitsAreTheUsualGaps() {
        #expect(SplitFit.tight.clearance == 0.1 && SplitFit.standard.clearance == 0.2 && SplitFit.loose.clearance == 0.3 && SplitFit.custom.clearance == nil)
    }
}
