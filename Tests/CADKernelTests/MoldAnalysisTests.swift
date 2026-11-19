// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CKernel
import Foundation
import Testing
import simd
@testable import CADKernel

/// Pull-direction analysis, the casting rules built on it, and where vents are suggested.
@Suite struct MoldAnalysisTests {
    private func regen(_ features: [Feature]) -> RegenResult {
        var d = CADDocument()
        d.features = features
        return Regenerator.regenerate(d)
    }

    private func cyl(_ id: String, d: Double, h: Double, u: Double = 0, v: Double = 0, join: String? = nil) -> Feature {
        Feature(id: id, name: id, .primitive(PrimitiveFeature(kind: .cylinder, plane: .xy, u: "\(u) mm", v: "\(v) mm", height: "\(h) mm", diameter: "\(d) mm",
                                                               operation: join == nil ? .newBody : .join, target: join)))
    }

    /// A disc (z 0 to 5, Ø 40) with a stem (Ø 10, up to z 20): parted at z = 10 the disc's top faces up inside the half that is pulled down.
    private func discAndStem() throws -> (KBody, RegenResult) {
        let r = regen([cyl("disc", d: 40, h: 5), cyl("stem", d: 10, h: 20, join: "disc")])
        return (try #require(r.body("disc")), r)
    }

    @Test func aBoxHasNoUndercutsAndItsSidesHaveNoDraft() throws {
        let r = regen([Feature(id: "b", name: "B", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "30 mm", length: "20 mm", height: "20 mm")))])
        let body = try #require(r.body("b"))
        let a = MoldAnalysis.analyse(try body.tessellate(), partingPoint: SIMD3(0, 0, 10), normal: SIMD3(0, 0, 1))
        #expect(!a.hasUndercuts && a.undercutArea == 0)
        #expect(a.faces.values.filter { $0 == .free }.count == 2, "top and bottom: \(a.faces)")
        #expect(a.faces.values.filter { $0 == .noDraft }.count == 4, "the four sides are parallel to the pull")
        #expect(abs(a.totalArea - 2 * (30 * 20 + 30 * 20 + 20 * 20)) < 1e-3, "\(a.totalArea)")
    }

    @Test func aDiscUnderAStemIsAnUndercutWhenPartedAbovIt() throws {
        let (body, _) = try discAndStem()
        let mesh = try body.tessellate()
        let above = MoldAnalysis.analyse(mesh, partingPoint: SIMD3(0, 0, 10), normal: SIMD3(0, 0, 1))
        #expect(above.hasUndercuts && above.undercutFaces.count == 1, "\(above.undercutFaces) \(above.faces)")
        #expect(abs(above.undercutArea - (Double.pi * 20 * 20 - Double.pi * 5 * 5)) < 5, "the disc's top: \(above.undercutArea)")
        // Parted through the disc, everything above the plane is pulled up and nothing hangs back.
        let through = MoldAnalysis.analyse(mesh, partingPoint: SIMD3(0, 0, 2.5), normal: SIMD3(0, 0, 1))
        #expect(!through.hasUndercuts, "\(through.undercutFaces)")
    }

    @Test func aRoundBodyHasNoUndercutsWhereItMeetsThePlane() throws {
        let sphere = try KBody.primitive(.sphere(diameter: 40), on: .xy, featureID: "s")
        for normal in [SIMD3<Double>(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)] {
            let a = MoldAnalysis.analyse(try sphere.tessellate(), partingPoint: .zero, normal: normal)
            #expect(!a.hasUndercuts && a.faces.values.allSatisfy { $0 == .free }, "\(normal): \(a.undercutArea) \(a.noDraftShare)")
        }
    }

    @Test func siliconeOnlyWarnsAboutAnUndercut() throws {
        let (body, r) = try discAndStem()
        let m = MoldBuilder.build(MoldSetup(id: "m", name: "M", body: "disc", parting: .middle(.z)), part: body, in: r)
        #expect(m.isBuilt, "\(m.error ?? "")")
        #expect(m.warnings.contains { $0.contains("undercut") }, "\(m.warnings)")
        #expect(m.analysis?.hasUndercuts == true)
    }

    @Test func aRigidCastRefusesAnUndercutButKeepsTheAnalysis() throws {
        let (body, r) = try discAndStem()
        let m = MoldBuilder.build(MoldSetup(id: "m", name: "M", body: "disc", parting: .middle(.z), casting: .resin), part: body, in: r)
        #expect(!m.isBuilt && m.error?.contains("can not be released") == true, "\(m.error ?? "")")
        #expect(m.analysis?.undercutFaces.count == 1, "the Check view still shows where")
        // Parted through the disc the same body is fine in resin.
        let ok = MoldBuilder.build(MoldSetup(id: "m", name: "M", body: "disc", parting: .middle(.z), partingOffset: "-7.5 mm", casting: .resin), part: body, in: r)
        #expect(ok.isBuilt, "\(ok.error ?? "")")
    }

    @Test func resinWarnsWhenMostOfTheSurfaceHasNoDraft() throws {
        let r = regen([Feature(id: "b", name: "B", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "10 mm", length: "10 mm", height: "60 mm")))])
        let m = MoldBuilder.build(MoldSetup(id: "m", name: "M", body: "b", parting: .middle(.z), casting: .resin), part: try #require(r.body("b")), in: r)
        #expect(m.isBuilt)
        #expect(m.warnings.contains { $0.contains("no draft") }, "\(m.warnings)")
    }

    // MARK: vents

    @Test func theLowerOfTwoPegsGetsTheVent() throws {
        let r = regen([Feature(id: "b", name: "B", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "50 mm", length: "20 mm", height: "10 mm"))),
                       cyl("p1", d: 6, h: 25, u: -12, join: "b"), cyl("p2", d: 6, h: 21, u: 12, join: "b")])
        let body = try #require(r.body("b"))
        let mesh = try body.tessellate()
        let vents = MoldVents.suggest(mesh, up: SIMD3(0, 0, 1), gate: SIMD3(-12, 0, 25), gateRadius: 4)
        #expect(vents.count == 1, "\(vents)")
        let v = try #require(vents.first)
        #expect(abs(v.x - 12) < 0.5 && abs(v.y) < 0.5 && abs(v.z - 21) < 0.1, "in the middle of the lower peg's flat top: \(v)")
        // With the gate put on the lower peg, the tall one is the vent.
        let other = MoldVents.suggest(mesh, up: SIMD3(0, 0, 1), gate: SIMD3(12, 0, 21), gateRadius: 4)
        #expect(other.count == 1 && abs((other.first?.z ?? 0) - 25) < 0.1, "\(other)")
    }

    @Test func aBodyWithOnePeakNeedsNoVents() throws {
        let sphere = try KBody.primitive(.sphere(diameter: 40), on: .xy, featureID: "s")
        #expect(MoldVents.suggest(try sphere.tessellate(), up: SIMD3(0, 0, 1), gate: SIMD3(0, 0, 20), gateRadius: 4).isEmpty)
        let box = try KBody.primitive(.box(width: 30, length: 20, height: 20), on: .xy, featureID: "b")
        #expect(MoldVents.suggest(try box.tessellate(), up: SIMD3(0, 0, 1), gate: SIMD3(0, 0, 20), gateRadius: 4).isEmpty, "a flat top is one peak")
    }

    @Test func theBestAxisLeavesNoUndercutWhereOneExists() throws {
        let (body, _) = try discAndStem()
        let bounds = try #require(body.bounds)
        // Across Z the disc's top hangs back; across X or Y nothing does.
        let axis = MoldAnalysis.bestAxis(try body.tessellate(), bounds: bounds)
        #expect(axis != .z, "\(axis)")
        // A plain box takes its shortest side.
        let box = try KBody.primitive(.box(width: 30, length: 20, height: 10), on: .xy, featureID: "b")
        #expect(MoldAnalysis.bestAxis(try box.tessellate(), bounds: try #require(box.bounds)) == .z)
    }
}
