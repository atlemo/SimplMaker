// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CKernel
import Foundation
import Testing
import simd
@testable import CADKernel

/// The split builder: how many pieces it takes, where the cuts go, and that every connector kind gives sound pieces.
@Suite struct PrintSplitBuilderTests {
    /// A box standing on the XY plane, centred on the Z axis.
    private func box(_ w: Double, _ l: Double, _ h: Double) throws -> KBody {
        try KBody.primitive(.box(width: w, length: l, height: h), on: Frame(origin: .zero, normal: SIMD3(0, 0, 1), xAxis: SIMD3(1, 0, 0)), featureID: "part")
    }

    private func setup(_ change: (inout PrintSplit) -> Void = { _ in }) -> PrintSplit {
        var s = PrintSplit(id: "s", name: "Split", body: "part")
        change(&s)
        return s
    }

    private func build(_ part: KBody, _ change: (inout PrintSplit) -> Void = { _ in }) -> PrintSplitResult {
        PrintSplitBuilder.build(setup(change), part: part, in: RegenResult())
    }

    @Test func aPartThatFitsIsNotCut() throws {
        let r = build(try box(100, 80, 60))
        #expect(r.isBuilt, "\(r.error ?? "")")
        #expect(r.pieces.count == 1 && r.connectorCount == 0 && r.allFit)
        #expect(r.counts == [1, 1, 1])
    }

    @Test func aLongPartIsCutAcrossItsLengthAndEveryPieceFits() throws {
        let part = try box(300, 100, 50)
        let r = build(part)
        #expect(r.isBuilt, "\(r.error ?? "")")
        #expect(r.pieces.count == 2 && r.allFit, "\(r.pieces.map(\.size))")
        #expect(r.counts == [2, 1, 1])
        #expect(abs(r.cutPositions[0][0]) < 1e-6, "an even cut through the middle: \(r.cutPositions)")
        #expect(r.pieces.allSatisfy { $0.body.isValid })
        #expect(r.connectorCount > 0 && r.pieces.map(\.connectors) == [r.connectorCount, r.connectorCount])
        #expect(r.pieces.map(\.id) == ["split~s~1", "split~s~2"])
    }

    @Test func aPinStandsOutOfOnePieceAndSinksIntoTheOther() throws {
        let part = try box(300, 100, 50)
        let r = build(part) { $0.choose(.pin) }
        // The piece behind the cut (x < 0) carries the pins: it is longer than its half of the body by the pin's length.
        let behind = try #require(r.pieces.first), front = try #require(r.pieces.last)
        #expect(abs(behind.size.x - (150 + 8)) < 0.01, "\(behind.size)")
        #expect(abs(front.size.x - 150) < 0.01, "\(front.size)")
        // Pins add volume to one piece, sockets take it from the other; the sockets are a little the bigger (the clearance).
        #expect(behind.volume > 150 * 100 * 50)
        #expect(front.volume < 150 * 100 * 50)
        let balance = behind.volume + front.volume - part.volume
        #expect(abs(balance) < part.volume * 0.01, "\(balance)")
    }

    @Test func theCutsLeaveRoomForAConnectorThatSticksOut() throws {
        // A 256 mm bed less the margin leaves 250: a 250 mm part fits whole, but with an 8 mm pin on one end it has to be cut when it is 255.
        let fits = build(try box(250, 100, 50))
        #expect(fits.pieces.count == 1)
        let cut = build(try box(300, 100, 50))
        #expect(cut.pieces.count == 2)
        // Three pieces when two cuts are needed: 520 mm on a 250 mm bed (less pins) takes three.
        let long = build(try box(520, 100, 50))
        #expect(long.pieces.count == 3 && long.allFit, "\(long.pieces.map(\.size))")
    }

    @Test func aWholeCustomVolumeAndTurningDecideThePieces() throws {
        let part = try box(250, 90, 40)
        // A 100 mm cube: 3 pieces along the length when it may not be turned.
        let r = build(part) { $0.printer = PrinterPreset.customID; $0.customVolume = ["100 mm", "100 mm", "100 mm"]; $0.margin = "0 mm"; $0.connector = .none }
        #expect(r.counts == [3, 1, 1] && r.allFit && r.pieces.count == 3, "\(r.counts) \(r.error ?? "")")
        // A tall narrow volume: with turning the length can stand upright, which needs fewer pieces than lying down.
        let upright = build(part) { $0.printer = PrinterPreset.customID; $0.customVolume = ["60", "60", "300"].map { "\($0) mm" }; $0.margin = "0 mm"; $0.connector = .none; $0.turn = true }
        #expect(upright.pieces.count == 2 && upright.allFit, "\(upright.counts) \(upright.pieces.map(\.size))")
        let lying = build(part) { $0.printer = PrinterPreset.customID; $0.customVolume = ["60", "60", "300"].map { "\($0) mm" }; $0.margin = "0 mm"; $0.connector = .none; $0.turn = false }
        #expect(lying.pieces.count > upright.pieces.count)
    }

    @Test func countsByHandOverrideTheAutomaticOnes() throws {
        let r = build(try box(100, 80, 60)) { $0.counts = [2, 2, 1]; $0.connector = .none }
        #expect(r.pieces.count == 4 && r.counts == [2, 2, 1], "\(r.counts)")
        let volume = r.pieces.reduce(0) { $0 + $1.volume }
        #expect(abs(volume - 100 * 80 * 60) < 1)
    }

    @Test func cutsByHandAreWhereTheyAreSaid() throws {
        let r = build(try box(300, 100, 50)) {
            $0.cuts = [PrintSplitCut(axis: .x, position: "-50 mm"), PrintSplitCut(axis: .x, position: "70"), PrintSplitCut(axis: .z, position: "99 mm")]
            $0.connector = .none
        }
        #expect(r.pieces.count == 3)
        #expect(r.cutPositions[0] == [-50, 70])
        #expect(r.warnings.contains { $0.contains("outside the body") }, "a cut beyond the body is dropped with a note: \(r.warnings)")
        #expect(r.cuts.map(\.position) == ["-50 mm", "70 mm"])
    }

    @Test func everyConnectorKindGivesSoundPieces() throws {
        let part = try box(300, 100, 60)
        for kind in ConnectorKind.allCases {
            let r = build(part) { $0.choose(kind) }
            let name = kind.rawValue
            #expect(r.isBuilt, "\(name): \(r.error ?? "")")
            #expect(r.pieces.count == 2, "\(name)")
            #expect(r.pieces.allSatisfy { $0.body.isValid && !$0.body.isEmpty }, "\(name)")
            #expect(r.connectorCount > 0 || kind == .none, "\(name): \(r.warnings)")
            #expect(!r.warnings.contains { $0.contains("could not") }, "\(name): \(r.warnings)")
            let total = r.pieces.reduce(0) { $0 + $1.volume }
            switch kind {
            case .none: #expect(abs(total - part.volume) < 1, "\(name)")
            case .magnet, .dowel: #expect(total < part.volume - 1, "pockets only take material: \(name) \(total) \(part.volume)")
            default: #expect(abs(total - part.volume) < part.volume * 0.01, "\(name) \(total) \(part.volume)")
            }
        }
    }

    @Test func aDowelCutsASocketInBothPiecesAndMakesOneLooseDowelForEach() throws {
        let r = build(try box(300, 100, 60)) { $0.choose(.dowel) }
        #expect(r.dowels.count == r.connectorCount && r.connectorCount > 0)
        #expect(r.dowels.allSatisfy { $0.body.isValid })
        let d = try #require(r.dowels.first?.body.bounds)
        #expect(abs((d.max.z - d.min.z) - 16) < 0.01 && abs((d.max.x - d.min.x) - 6) < 0.01)
        // Neither piece sticks out: they are exactly their halves long.
        #expect(r.pieces.allSatisfy { abs($0.size.x - 150) < 0.01 })
    }

    @Test func aSeparatePinIsAPartOfItsOwnAndSticksOutOfNeitherPiece() throws {
        let part = try box(300, 100, 60)
        let r = build(part) { $0.choose(.pin); $0.separate = true }
        #expect(r.isBuilt && r.connectorCount > 0, "\(r.error ?? "") \(r.warnings)")
        #expect(r.dowels.count == r.connectorCount && r.dowels.allSatisfy { $0.body.isValid })
        let d = try #require(r.dowels.first?.body.bounds)
        #expect(abs((d.max.z - d.min.z) - 16) < 0.01 && abs((d.max.x - d.min.x) - 6) < 0.01, "2 × the 8 mm depth, 6 mm across: \(d)")
        #expect(r.pieces.allSatisfy { abs($0.size.x - 150) < 0.01 }, "no pin on either piece: \(r.pieces.map(\.size))")
        // Sockets only take material away.
        #expect(r.pieces.reduce(0) { $0 + $1.volume } < part.volume - 1)
        #expect(r.pieces.allSatisfy { $0.body.isValid })
        #expect(r.setup.looseName == "pin")
    }

    @Test func aSeparateKeyIsASquareBarInSquareSockets() throws {
        let r = build(try box(300, 100, 60)) { $0.choose(.key); $0.separate = true }
        #expect(r.isBuilt && r.dowels.count == r.connectorCount && r.connectorCount > 0, "\(r.error ?? "")")
        let d = try #require(r.dowels.first?.body.bounds)
        #expect(abs((d.max.x - d.min.x) - 6) < 0.01 && abs((d.max.y - d.min.y) - 6) < 0.01 && abs((d.max.z - d.min.z) - 16) < 0.01)
        #expect(r.pieces.allSatisfy { abs($0.size.x - 150) < 0.01 && $0.body.isValid })
    }

    @Test func separatePinsLeaveRoomInThePlanForNothingThatSticksOut() {
        // With the pin on the piece, 8 mm of each piece's length goes to it; as a part of its own it takes none.
        let s = PrintSplit(name: "s", body: "x", connector: .pin, separate: true)
        #expect(s.hasLooseParts)
        #expect(!PrintSplit(name: "s", body: "x", connector: .pin).hasLooseParts)
        #expect(PrintSplit(name: "s", body: "x", connector: .dowel).hasLooseParts)
        #expect(!PrintSplit(name: "s", body: "x", connector: .magnet, separate: true).hasLooseParts)
    }

    @Test func aDovetailLocksTheTabIntoTheSlot() throws {
        let part = try box(300, 100, 60)
        let r = build(part) { $0.choose(.dovetail) }
        #expect(r.isBuilt && r.connectorCount >= 1, "\(r.error ?? "") \(r.warnings)")
        let behind = try #require(r.pieces.first), front = try #require(r.pieces.last)
        #expect(behind.volume > 150 * 100 * 60 && front.volume < 150 * 100 * 60, "\(behind.volume) \(front.volume)")
        // The tab stands out of the piece behind by its depth.
        #expect(abs(behind.size.x - (150 + 6)) < 0.01, "\(behind.size)")
    }

    @Test func theClearanceIsTheGapBetweenAPinAndItsSocket() throws {
        let part = try box(300, 100, 60)
        func gap(_ fit: SplitFit) -> Double {
            let r = build(part) { $0.fit = fit; $0.connector = .pin }
            return part.volume - r.pieces.reduce(0) { $0 + $1.volume }
        }
        // A looser fit takes more material out of the socket than the pin puts back.
        #expect(gap(.loose) > gap(.standard) && gap(.standard) > gap(.tight))
        let custom = build(part) { $0.fit = .custom; $0.customClearance = "0.4 mm" }
        #expect(custom.isBuilt)
        #expect(part.volume - custom.pieces.reduce(0) { $0 + $1.volume } > gap(.loose))
    }

    @Test func aCutThatIsTooSmallForTheConnectorSaysSoAndStillCuts() throws {
        let r = build(try box(300, 5, 5)) { $0.connectorSize = "6 mm" }
        #expect(r.isBuilt && r.pieces.count == 2 && r.connectorCount == 0)
        #expect(r.warnings.contains { $0.contains("No room") }, "\(r.warnings)")
    }

    @Test func aPartThatIsNotAValidSolidIsRefused() throws {
        let r = build(try box(0.0001, 0.0001, 0.0001))
        #expect(!r.isBuilt)
    }

    @Test func aMarginThatLeavesNoBedIsRefused() throws {
        let r = build(try box(300, 100, 50)) { $0.margin = "200 mm" }
        #expect(r.error?.contains("margin") == true, "\(r.error ?? "")")
    }

    @Test func aPartCutIntoTooManyPiecesIsRefused() throws {
        let r = build(try box(300, 100, 50)) { $0.counts = [10, 10, 10] }
        #expect(r.error?.contains("pieces") == true, "\(r.error ?? "")")
    }

    @Test func connectorsStayInsideASectionThatIsNotAFullRectangle() throws {
        // An L: a long bar with a short bar on one end. The cut through the long arm only has material in half of the cell, and the
        // connectors have to stay on it.
        let long = try box(300, 40, 40)
        let leg = try KBody.primitive(.box(width: 40, length: 120, height: 40), on: Frame(origin: SIMD3(-130, 20, 0), normal: SIMD3(0, 0, 1), xAxis: SIMD3(1, 0, 0)), featureID: "leg")
        let l = try long.boolean(leg, SK_FUSE)
        let r = build(l) { $0.spacing = "30 mm" }
        #expect(r.isBuilt, "\(r.error ?? "")")
        #expect(r.pieces.allSatisfy { $0.body.isValid })
        let total = r.pieces.reduce(0) { $0 + $1.volume }
        #expect(abs(total - l.volume) < l.volume * 0.01)
    }

    @Test func aPartNeverSticksOutOfThePrinterWhenItIsLaidOut() throws {
        let r = build(try box(520, 100, 50)) { $0.choose(.dowel) }
        let layout = PrintSplitBuilder.printLayout(r)
        #expect(layout.bodies.count == r.pieces.count + r.dowels.count)
        #expect(layout.plates >= 1)
        for placed in layout.bodies {
            let b = try #require(placed.body.bounds)
            #expect(abs(b.min.z) < 1e-6, "\(placed.name) stands on the bed")
        }
        // The pieces do not overlap each other on a plate: their footprints are apart.
        var boxes: [(SIMD3<Double>, SIMD3<Double>)] = []
        for placed in layout.bodies { if let b = placed.body.bounds { boxes.append((b.min, b.max)) } }
        for i in boxes.indices { for j in boxes.indices where j > i {
            let apart = boxes[i].1.x <= boxes[j].0.x + 1e-6 || boxes[j].1.x <= boxes[i].0.x + 1e-6
                || boxes[i].1.y <= boxes[j].0.y + 1e-6 || boxes[j].1.y <= boxes[i].0.y + 1e-6
            #expect(apart, "\(i) and \(j) overlap")
        } }
    }

    @Test func aPieceIsTurnedOnTheBedWhenThatIsWhatMakesItFit() throws {
        // A 40 × 40 × 280 post: it cannot lie in a 100 × 100 × 100 volume whole, but pieces of 100 can; with no cuts allowed by hand it stays in one
        // piece and is flagged as too big, and the layout still places it.
        let post = try box(40, 40, 280)
        let r = build(post) { $0.printer = PrinterPreset.customID; $0.customVolume = ["300 mm", "100 mm", "100 mm"]; $0.margin = "0 mm"; $0.counts = [1, 1, 1]; $0.connector = .none }
        #expect(r.pieces.count == 1 && r.allFit, "turned to lie along X it fits: \(r.pieces.map(\.size))")
        let layout = PrintSplitBuilder.printLayout(r)
        let b = try #require(layout.bodies.first?.body.bounds)
        #expect(abs((b.max.x - b.min.x) - 280) < 0.01, "the post is laid down along X: \(b)")
    }

    @Test func theAutomaticCountsAreTheFewestThatFit() {
        #expect(PrintSplitBuilder.automaticCounts(extent: SIMD3(100, 100, 100), usable: SIMD3(250, 250, 250), protrusion: 8, turn: true) == [1, 1, 1])
        #expect(PrintSplitBuilder.automaticCounts(extent: SIMD3(300, 100, 100), usable: SIMD3(250, 250, 250), protrusion: 8, turn: false) == [2, 1, 1])
        // Turned, the 300 mm length goes along the tall axis of a 150 × 150 × 320 printer: one piece.
        #expect(PrintSplitBuilder.automaticCounts(extent: SIMD3(300, 100, 100), usable: SIMD3(150, 150, 320), protrusion: 8, turn: true) == [1, 1, 1])
        #expect(PrintSplitBuilder.automaticCounts(extent: SIMD3(300, 100, 100), usable: SIMD3(150, 150, 320), protrusion: 8, turn: false) == [3, 1, 1])
        // A pin longer than the volume leaves no room at all.
        #expect(PrintSplitBuilder.automaticCounts(extent: SIMD3(300, 100, 100), usable: SIMD3(10, 10, 10), protrusion: 20, turn: false) == nil)
    }

    @Test func theProbeKnowsInsideFromOutsideOnAFineMesh() throws {
        // A UV sphere of 100 mm radius with 100 000 triangles: the grid must give the same answers as a plain ray cast, in no time.
        let n = 224, m = 224
        var pos: [Float] = [], idx: [UInt32] = []
        for i in 0...n { for j in 0..<m {
            let th = Float.pi * Float(i) / Float(n), ph = 2 * Float.pi * Float(j) / Float(m)
            pos += [100 * sin(th) * cos(ph), 100 * sin(th) * sin(ph), 100 * cos(th)]
        } }
        for i in 0..<n { for j in 0..<m {
            let a = UInt32(i * m + j), b = UInt32(i * m + (j + 1) % m), c = UInt32((i + 1) * m + j), d = UInt32((i + 1) * m + (j + 1) % m)
            idx += [a, c, b, b, c, d]
        } }
        let probe = SolidProbe(Mesh(positions: pos, normals: [], indices: idx, triangleFace: [], segments: [], segmentEdge: [], faceNames: [], edgeNames: []))
        let started = Date()
        var wrong = 0
        for k in 0..<2000 {
            let p = SIMD3(Double(k % 41) * 5 - 100, Double(k % 37) * 5.7 - 100, Double(k % 31) * 6.5 - 100)
            let expected = simd_length(p) < 99.5 ? true : (simd_length(p) > 100.5 ? false : nil)
            if let expected, probe.contains(p) != expected { wrong += 1 }
        }
        #expect(wrong == 0)
        #expect(Date().timeIntervalSince(started) < 2, "2000 queries on 100 000 triangles")
    }
}
