// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import simd
import Testing
@testable import CADKernel

/// Intersect: where a sketch's plane cuts a body comes into the sketch as projections that follow the body.
@Suite struct IntersectProjectionTests {
    /// A cylinder (axis z, 10 high) and a sketch on a plane `offset` above (or tilted off) the floor.
    private func document(diameter: String = "20", height: String = "10", offset: String = "5 mm", angle: String = "0 deg",
                          sketch: Sketch = Sketch()) -> CADDocument {
        var d = CADDocument()
        d.features = [
            Feature(id: "c", name: "Cylinder1", .primitive(PrimitiveFeature(kind: .cylinder, plane: .xy, height: height, diameter: diameter))),
            Feature(id: "pl", name: "Plane1", .plane(PlaneFeature(base: .xy, offset: offset, angle: angle))),
            Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .plane("pl"), sketch: sketch))),
        ]
        return d
    }

    private func snaps(_ d: CADDocument) throws -> (snaps: [ModelSnap], frame: Frame) {
        let r = Regenerator.regenerate(d)
        let frame = try #require(r.sketches["sk"]?.frame)
        return (Regenerator.sectionSnaps(of: try #require(r.body("c")), id: "c", frame: frame), frame)
    }

    @Test func aFlatCutThroughACylinderIsOneCircle() throws {
        let (snaps, _) = try snaps(document())
        #expect(snaps.count == 1, "\(snaps)")
        let c = try #require(snaps.first)
        #expect(c.isFullCircle && c.center != nil)
        #expect(abs(simd_length(c.start - c.center!) - 10) < 1e-6)
        #expect(c.edge.edge.hasPrefix(Regenerator.sectionPrefix) && c.edge.body == "c")
    }

    @Test func theCircleFollowsTheBodyWhenItGrows() throws {
        let (snaps, _) = try snaps(document())
        var s = Sketch()
        let p = s.project(try #require(snaps.first))
        let doc = document(diameter: "40", sketch: s)
        let r = Regenerator.regenerate(doc)
        #expect(r.errors.isEmpty, "\(r.errors)")
        let solved = try #require(r.sketches["sk"]?.solved)
        guard case .circle(_, let radius) = try #require(solved.curve(p.line)).geometry else { Issue.record("expected a circle"); return }
        #expect(abs(radius - 20) < 1e-6)
        let frame = try #require(r.sketches["sk"]?.frame)
        #expect(Regenerator.staleProjections(solved, frame: frame, r).isEmpty)
    }

    @Test func projectingTheSameCutTwiceReusesTheProjection() throws {
        let (snaps, _) = try snaps(document())
        var s = Sketch()
        s.project(snaps[0]); s.project(snaps[0])
        #expect(s.projections.count == 1 && s.curves.count == 1)
    }

    @Test func aCutThroughTheAxisIsFourLinesAndNamedByTheirFaces() throws {
        var d = document()
        d.features[2] = Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xz, sketch: Sketch())))
        let (snaps, _) = try snaps(d)
        #expect(snaps.count == 4, "\(snaps.map(\.edge.edge))")
        #expect(Set(snaps.map(\.edge.edge)).count == 4, "every piece has a name of its own")
        #expect(snaps.allSatisfy { $0.projectionKind == .straight })
        let lengths = snaps.map { simd_distance($0.start, $0.end) }.sorted()
        #expect(abs(lengths[0] - 10) < 1e-6 && abs(lengths[1] - 10) < 1e-6 && abs(lengths[2] - 20) < 1e-6 && abs(lengths[3] - 20) < 1e-6, "\(lengths)")
    }

    @Test func linesFollowTheBodyWhenItChangesHeight() throws {
        var d = document()
        d.features[2] = Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xz, sketch: Sketch())))
        let (snaps, _) = try snaps(d)
        var s = Sketch()
        for snap in snaps { s.project(snap) }
        d.features[2] = Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xz, sketch: s)))
        d.features[0] = Feature(id: "c", name: "Cylinder1", .primitive(PrimitiveFeature(kind: .cylinder, plane: .xy, height: "14", diameter: "20")))
        let r = Regenerator.regenerate(d)
        #expect(r.errors.isEmpty, "\(r.errors)")
        let solved = try #require(r.sketches["sk"]?.solved)
        // The side lines are 14 long now, found again by the face they lie on.
        let lengths = s.projections.compactMap { p -> Double? in
            guard let a = solved.position(p.start), let b = solved.position(p.end) else { return nil }
            return simd_distance(a, b)
        }.sorted()
        #expect(lengths.count == 4)
        #expect(abs(lengths[0] - 14) < 1e-6 && abs(lengths[1] - 14) < 1e-6 && abs(lengths[2] - 20) < 1e-6, "\(lengths)")
    }

    @Test func aTiltedCutIsACurveFollowedAsPieces() throws {
        let (snaps, _) = try snaps(document(angle: "30 deg"))
        #expect(!snaps.isEmpty)
        // The wall is cut in a slanted ellipse (curved pieces), and a cap in a chord (a straight line).
        #expect(snaps.contains { $0.projectionKind == .curve } && snaps.contains { $0.projectionKind == .straight }, "\(snaps.map(\.projectionKind))")
        var s = Sketch()
        for snap in snaps { s.project(snap) }
        let r = Regenerator.regenerate(document(diameter: "24", angle: "30 deg", sketch: s))
        #expect(r.errors.isEmpty, "\(r.errors)")
        let frame = try #require(r.sketches["sk"]?.frame)
        let solved = try #require(r.sketches["sk"]?.solved)
        #expect(Regenerator.staleProjections(solved, frame: frame, r).isEmpty)
    }

    @Test func projectionsGoStaleWhenThePlaneNoLongerCutsTheBody() throws {
        let (snaps, _) = try snaps(document())
        var s = Sketch()
        let p = s.project(snaps[0])
        // Only 4 mm high: the plane at 5 mm misses it.
        let r = Regenerator.regenerate(document(height: "4", sketch: s))
        #expect(r.errors["sk"] != nil, "the sketch can't follow it any more")
        let frame = try #require(r.sketches["sk"]?.frame ?? Regenerator.regenerate(document()).sketches["sk"]?.frame)
        #expect(Regenerator.staleProjections(s, frame: frame, r) == [p.id])
    }

    @Test func aPlaneAlongAFaceBringsInThatFacesOutline() throws {
        // The sketch plane is the cylinder's floor: its circle is what the plane cuts out.
        let (snaps, _) = try snaps(document(offset: "0 mm"))
        #expect(snaps.contains { $0.projectionKind == .circle && abs(simd_length($0.start - $0.center!) - 10) < 1e-6 }, "\(snaps)")
    }

    @Test func aPlaneThatMissesTheBodyGivesNothing() throws {
        let (snaps, _) = try snaps(document(offset: "30 mm"))
        #expect(snaps.isEmpty)
    }
}
