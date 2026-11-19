// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CKernel
import Foundation
import Testing
import simd
@testable import CADKernel

/// A mold in four pieces: each half cut again across a second plane, which lets go of shapes two halves can not.
@Suite struct MoldFourPieceTests {
    private func box(_ w: Double, _ l: Double, _ h: Double, at origin: SIMD3<Double> = .zero) throws -> KBody {
        try KBody.primitive(.box(width: w, length: l, height: h), on: Frame(origin: origin, normal: SIMD3(0, 0, 1), xAxis: SIMD3(1, 0, 0)), featureID: "part")
    }

    private func setup(_ change: (inout MoldSetup) -> Void = { _ in }) -> MoldSetup {
        var s = MoldSetup(id: "m", name: "Mold", body: "part", pieces: 4)
        change(&s)
        return s
    }

    /// A block with a groove across its +X face, high up: the groove's upper wall looks down, so a top piece pulled up is stuck on it.
    private func grooved() throws -> KBody {
        try box(30, 30, 20).boolean(try box(8, 40, 4, at: SIMD3(15, 0, 14)), SK_CUT)
    }

    @Test func aBoxGetsFourValidPiecesThatAccountForTheCavity() throws {
        let part = try box(30, 20, 20)
        let r = MoldBuilder.build(setup(), part: part, in: RegenResult())
        #expect(r.isBuilt, "\(r.error ?? "") \(r.warnings)")
        #expect(r.pieces.count == 4)
        #expect(r.pieces.allSatisfy { $0.body.isValid && !$0.body.isEmpty })
        #expect(r.halves.map(\.id) == ["mold~m~behind~a", "mold~m~behind~b", "mold~m~front~a", "mold~m~front~b"])
        // Parted across Z and poured up Z, so the second plane is across the longer of the other two (X): left and right, bottom and top.
        #expect(r.halves.map(\.name) == ["Mold bottom left", "Mold bottom right", "Mold top left", "Mold top right"])
        #expect(r.crossNormal == SIMD3(1, 0, 0), "\(String(describing: r.crossNormal))")
        // Each piece is on its own side of both planes (the order of `pieceIDs`).
        for piece in r.pieces {
            let b = try #require(piece.body.bounds)
            let mid = (b.min + b.max) / 2
            #expect((mid.z > 10 ? 1 : -1) == piece.side, "\(piece.id) \(mid)")
            #expect((mid.x > 0 ? 1 : -1) == piece.crossSide, "\(piece.id) \(mid)")
        }
        // Nothing is lost: the pieces are the block, less the cavity, plus the pegs less the sockets.
        let block = r.blockSize.x * r.blockSize.y * r.blockSize.z
        let total = r.pieces.reduce(0) { $0 + $1.body.volume }
        #expect(abs(total + r.cavityVolume - block) < block * 0.003, "\(total) \(r.cavityVolume) \(block)")
        #expect(r.cavityVolume > part.volume && r.cavityVolume < part.volume * 1.2, "\(r.cavityVolume) vs \(part.volume)")
    }

    @Test func theSecondPlaneContainsThePourDirection() throws {
        // Parted across X and poured up Z: the second plane is the one across Y (it holds Z), never across Z.
        let r = MoldBuilder.build(setup { $0.parting = .middle(.x) }, part: try box(30, 20, 20), in: RegenResult())
        #expect(r.isBuilt, "\(r.error ?? "")")
        #expect(r.crossNormal == SIMD3(0, 1, 0), "\(String(describing: r.crossNormal))")
        #expect(r.halves.map(\.name) == ["Mold left front", "Mold left back", "Mold right front", "Mold right back"])
    }

    @Test func theSecondPlaneCanBeNamed() throws {
        let r = MoldBuilder.build(setup { $0.cross = .y }, part: try box(30, 20, 20), in: RegenResult())
        #expect(r.isBuilt, "\(r.error ?? "")")
        #expect(r.crossNormal == SIMD3(0, 1, 0))
        // The parting plane's own axis is not a choice: the body's own pick is used instead.
        let same = MoldBuilder.build(setup { $0.cross = .z }, part: try box(30, 20, 20), in: RegenResult())
        #expect(same.isBuilt && same.crossNormal != SIMD3(0, 0, 1))
    }

    @Test func aGrooveIsAnUndercutForTwoHalvesButNotForFour() throws {
        let part = try grooved()
        let mesh = try part.tessellate()
        let two = MoldAnalysis.analyse(mesh, partingPoint: SIMD3(0, 0, 10), normal: SIMD3(0, 0, 1))
        #expect(two.hasUndercuts, "\(two.undercutShare)")
        let four = MoldAnalysis.analyse(mesh, partingPoint: SIMD3(0, 0, 10), normal: SIMD3(0, 0, 1), cross: (SIMD3(0, 0, 10), SIMD3(1, 0, 0)))
        #expect(!four.hasUndercuts, "\(four.undercutShare) \(four.undercutFaces)")
        #expect(four.undercutArea < two.undercutArea)
    }

    @Test func rigidResinIsRefusedForTwoHalvesAndAllowedForFour() throws {
        let part = try grooved()
        let twoHalves = MoldBuilder.build(MoldSetup(id: "m", name: "Mold", body: "part", casting: .resin), part: part, in: RegenResult())
        #expect(!twoHalves.isBuilt)
        #expect(twoHalves.error?.contains("four pieces") == true, "\(twoHalves.error ?? "")")
        let fourPieces = MoldBuilder.build(setup { $0.casting = .resin; $0.cross = .x }, part: part, in: RegenResult())
        #expect(fourPieces.isBuilt, "\(fourPieces.error ?? "") \(fourPieces.warnings)")
        #expect(fourPieces.pieces.count == 4)
    }

    @Test func fourPiecesAroundASphereSeamAreSound() throws {
        // The figurine's spheres have a seam in the XZ plane; parted there, with a second plane through their poles.
        let ball = try KBody.primitive(.sphere(diameter: 40), on: Frame(origin: SIMD3(0, 0, 20), normal: SIMD3(0, 0, 1), xAxis: SIMD3(1, 0, 0)), featureID: "ball")
        let r = MoldBuilder.build(setup { $0.parting = .middle(.y) }, part: ball, in: RegenResult())
        #expect(r.isBuilt, "\(r.error ?? "")")
        #expect(r.pieces.count == 4 && r.pieces.allSatisfy { $0.body.isValid })
        // The cavity of a ball is a ball (plus the gate): none of the four may have come back whole.
        #expect(r.cavityVolume > ball.volume * 0.95, "\(r.cavityVolume) vs \(ball.volume)")
    }

    @Test func thePiecesAreLaidOutOnTheFloorForPrinting() throws {
        let r = MoldBuilder.build(setup(), part: try box(30, 20, 20), in: RegenResult())
        let placed = MoldBuilder.printLayout(r)
        #expect(placed.count == 4)
        #expect(placed.map(\.id) == r.pieces.map(\.id))
        for piece in placed { #expect(abs((piece.body.bounds?.min.z ?? 9) - 0) < 1e-6, "\(piece.name)") }
        // Side by side: no two overlap along X.
        let spans = placed.compactMap { $0.body.bounds }.map { ($0.min.x, $0.max.x) }.sorted { $0.0 < $1.0 }
        for (a, b) in zip(spans, spans.dropFirst()) { #expect(a.1 <= b.0 + 1e-6) }
    }

    @Test func noKeysMeansNoPegsOnEitherPlane() throws {
        let with = MoldBuilder.build(setup(), part: try box(30, 20, 20), in: RegenResult())
        let without = MoldBuilder.build(setup { $0.keys = false }, part: try box(30, 20, 20), in: RegenResult())
        #expect(with.isBuilt && without.isBuilt)
        let faces = { (r: MoldResult) in r.pieces.reduce(0) { $0 + $1.body.faceNames.count } }
        #expect(faces(without) < faces(with))
    }
}
