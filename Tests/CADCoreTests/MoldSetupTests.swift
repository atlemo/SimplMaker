// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CADCore

/// Molds are stored beside the features, optional like folders: old files are untouched and new settings can be added later.
@Suite struct MoldSetupTests {
    @Test func aMoldSurvivesAFileRoundTrip() throws {
        var d = CADDocument()
        d.molds = [MoldSetup(id: "m1", name: "Cup mold", body: "cup", parting: .plane(.plane("pl")), partingOffset: "1 mm", up: .minusY,
                             wall: "wall", gatePoint: MoldPoint(1, 2, 3), vents: [MoldPoint(4, 5, 6)], keys: false)]
        let data = try JSONEncoder().encode(d)
        let back = try JSONDecoder().decode(CADDocument.self, from: data)
        #expect(back.molds == d.molds)
    }

    @Test func aPartWithoutMoldsWritesNoMoldKey() throws {
        let data = try JSONEncoder().encode(CADDocument())
        #expect(!String(decoding: data, as: UTF8.self).contains("molds"))
    }

    @Test func anOlderFileOpensWithNoMolds() throws {
        let json = #"{"version":1,"parameters":[],"features":[]}"#
        #expect(try JSONDecoder().decode(CADDocument.self, from: Data(json.utf8)).molds.isEmpty)
    }

    @Test func aMoldWithOnlyItsBodyGetsTheDefaults() throws {
        let json = #"{"version":1,"features":[],"molds":[{"id":"a","body":"b"}]}"#
        let m = try #require(try JSONDecoder().decode(CADDocument.self, from: Data(json.utf8)).molds.first)
        #expect(m.body == "b" && m.keys && m.parting == .middle(.z) && m.up == .plusZ && m.wall == "10 mm")
    }

    @Test func changingAMoldNeedsNoRebuildOfTheFeatures() {
        var a = CADDocument()
        var b = a
        b.molds = [MoldSetup(name: "m", body: "x")]
        a.molds = []
        #expect(a != b)
        #expect(a.ignoringPresentation == b.ignoringPresentation)
    }

    @Test func theHalvesHaveIdsOfTheirOwn() {
        #expect(MoldSetup(id: "q", name: "m", body: "x").halfIDs == ("mold~q~behind", "mold~q~front"))
        #expect(MoldSetup(id: "q", name: "m", body: "x").pieceIDs == ["mold~q~behind", "mold~q~front"])
    }

    @Test func fourPiecesHaveIdsThatSayWhichSideOfBothPlanesTheyAreOn() {
        let m = MoldSetup(id: "q", name: "m", body: "x", pieces: 4)
        #expect(m.pieceIDs == ["mold~q~behind~a", "mold~q~behind~b", "mold~q~front~a", "mold~q~front~b"])
        #expect(m.pieceIDs.allSatisfy(MoldSetup.isPiece))
        #expect(!MoldSetup.isPiece("mold~q~gate") && !MoldSetup.isPiece("mold~q~vent0") && !MoldSetup.isPiece("box"))
    }

    @Test func thePieceCountAndTheSecondPlaneSurviveAFile() throws {
        var d = CADDocument()
        d.molds = [MoldSetup(id: "q", name: "m", body: "x", pieces: 4, cross: .y)]
        let back = try JSONDecoder().decode(CADDocument.self, from: try d.encoded())
        #expect(back.molds.first?.pieces == 4 && back.molds.first?.cross == .y)
        // Two halves are the default and are not written; a made-up count falls back to two.
        d.molds = [MoldSetup(id: "q", name: "m", body: "x")]
        #expect(!String(decoding: try d.encoded(), as: UTF8.self).contains("pieces"))
        let odd = #"{"version":1,"features":[],"molds":[{"id":"a","body":"b","pieces":3}]}"#
        #expect(try JSONDecoder().decode(CADDocument.self, from: Data(odd.utf8)).molds.first?.pieces == 2)
        #expect(MoldSetup(name: "m", body: "x", pieces: 7).pieces == 2)
    }
}

/// Writes a part with a body (and no mold) for trying the Mold workspace by hand:
///   SIMPLMAKER_WRITE_MOLD_SAMPLE=/path/sample.simplmaker swift test --filter writeSample
@Suite struct MoldSampleFile {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SIMPLMAKER_WRITE_MOLD_SAMPLE"] != nil))
    func writeSample() throws {
        var d = CADDocument()
        d.features = [
            Feature(id: "box", name: "Block", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "50 mm", length: "34 mm", height: "26 mm"))),
            Feature(id: "knob", name: "Knob", .primitive(PrimitiveFeature(kind: .cylinder, plane: .xy, v: "0 mm", height: "36 mm", diameter: "12 mm", operation: .join, target: "box"))),
        ]
        let path = ProcessInfo.processInfo.environment["SIMPLMAKER_WRITE_MOLD_SAMPLE"]!
        try d.encoded().write(to: URL(fileURLWithPath: path))
        // A disc with a stem (an undercut when parted across Z) and a block with two pegs of different heights (a vent for the lower one).
        var disc = CADDocument()
        disc.features = [
            Feature(id: "disc", name: "Disc", .primitive(PrimitiveFeature(kind: .cylinder, plane: .xy, height: "6 mm", diameter: "44 mm"))),
            Feature(id: "stem", name: "Stem", .primitive(PrimitiveFeature(kind: .cylinder, plane: .xy, height: "30 mm", diameter: "12 mm", operation: .join, target: "disc"))),
        ]
        try disc.encoded().write(to: URL(fileURLWithPath: path + ".disc"))
        var pegs = CADDocument()
        pegs.features = [
            Feature(id: "b", name: "Base", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "60 mm", length: "24 mm", height: "10 mm"))),
            Feature(id: "p1", name: "Peg 1", .primitive(PrimitiveFeature(kind: .cylinder, plane: .xy, u: "-16 mm", height: "30 mm", diameter: "8 mm", operation: .join, target: "b"))),
            Feature(id: "p2", name: "Peg 2", .primitive(PrimitiveFeature(kind: .cylinder, plane: .xy, u: "16 mm", height: "24 mm", diameter: "8 mm", operation: .join, target: "b"))),
        ]
        try pegs.encoded().write(to: URL(fileURLWithPath: path + ".pegs"))
        // A block with a groove across its +X face, high up: an undercut for two halves parted across Z, none for four pieces.
        var groove = CADDocument()
        groove.features = [
            Feature(id: "b", name: "Block", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "40 mm", length: "30 mm", height: "24 mm"))),
            Feature(id: "g", name: "Groove", .primitive(PrimitiveFeature(kind: .box, plane: .xz, u: "18 mm", v: "17 mm", width: "8 mm", length: "4 mm", height: "60 mm",
                                                                         operation: .cut, target: "b"))),
        ]
        try groove.encoded().write(to: URL(fileURLWithPath: path + ".groove"))
    }
}

@Suite struct MoldCastingTests {
    @Test func castingIsKeptAndDefaultsToSilicone() throws {
        var d = CADDocument()
        d.molds = [MoldSetup(id: "a", name: "A", body: "x", casting: .resin), MoldSetup(id: "b", name: "B", body: "x")]
        let back = try JSONDecoder().decode(CADDocument.self, from: JSONEncoder().encode(d))
        #expect(back.molds.map(\.casting) == [.resin, .silicone])
        let json = String(decoding: try JSONEncoder().encode(MoldSetup(id: "b", name: "B", body: "x")), as: UTF8.self)
        #expect(!json.contains("casting"), "the default is not written")
    }
}
