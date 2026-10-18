// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import Foundation
import simd
import Testing
@testable import CADKernel

/// A sketch can follow a straight model edge: geometry tied to it moves when the model does.
@Suite struct ProjectedEdgeTests {
    private let topEdge = EdgeRef(body: "box", edge: "box.right|box.top")

    private func document(height: String, sketch: Sketch) -> CADDocument {
        var d = CADDocument()
        d.features = [
            Feature(id: "box", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "20 mm", length: "20 mm", height: height))),
            Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .face(FaceRef(body: "box", face: "box.right")), sketch: sketch))),
        ]
        return d
    }

    /// The top edge of the right face, in that face's sketch coordinates.
    private func topEdgeModel(_ height: String) throws -> (ModelSnap, Frame) {
        let r = Regenerator.regenerate(document(height: height, sketch: Sketch()))
        let frame = try #require(r.sketches["sk"]?.frame)
        let ends = try #require(r.body("box")).edgeEnds(topEdge.edge)
        func uv(_ p: SIMD3<Double>) -> SIMD2<Double> { SIMD2(simd_dot(p - frame.origin, frame.xAxis), simd_dot(p - frame.origin, frame.yAxis)) }
        return (ModelSnap(edge: topEdge, start: uv(ends.start), end: uv(ends.end)), frame)
    }

    /// A rectangle hanging from the top edge: its top-left corner snapped onto the edge.
    private func notch(_ height: String) throws -> Sketch { try notchAndCorners(height).sketch }

    private func notchAndCorners(_ height: String) throws -> (sketch: Sketch, first: SIMD2<Double>, opposite: SIMD2<Double>) {
        let (model, _) = try topEdgeModel(height)
        let mid = (model.start + model.end) / 2
        var s = Sketch()
        let onEdge = SketchSnap(mid, model: model)
        // The rectangle's other corner is 6 mm along the edge and 8 mm below it (towards the body).
        let along = simd_normalize(model.end - model.start)
        var normal = SIMD2(-along.y, along.x)
        let bodySide = SIMD2(10.0, 10.0)  // somewhere inside the face; picks the side of the edge it lies on
        if simd_dot(normal, bodySide - mid) < 0 { normal = -normal }
        let opposite = mid + 6 * along + 8 * normal
        s.addRectangle(from: onEdge, to: SketchSnap(opposite))
        return (s, mid, opposite)
    }

    @Test func snappingToAModelEdgeMakesAProjectionAndTiesTheCorner() throws {
        let s = try notch("20 mm")
        #expect(s.projections.count == 1 && s.projections[0].edge == topEdge)
        let p = s.projections[0]
        #expect(s.point(p.start)?.fixed == true && s.point(p.end)?.fixed == true)
        #expect(s.curve(p.line)?.construction == true)
        #expect(s.constraints.contains { if case .pointOnCurve(_, let c) = $0.kind { return c == p.line } else { return false } })
        // Snapping to the same edge again reuses the projection.
        var again = s
        _ = again.concrete(SketchSnap(.zero, model: try topEdgeModel("20 mm").0))
        #expect(again.projections.count == 1)
    }

    @Test func geometryTiedToTheEdgeFollowsWhenTheBoxGrows() throws {
        let s = try notch("20 mm")
        let corner = try #require(s.constraints.compactMap { c -> EntityID? in
            if case .pointOnCurve(let p, _) = c.kind { return p } else { return nil } }.first)
        let r0 = Regenerator.regenerate(document(height: "20 mm", sketch: s))
        #expect(r0.errors.isEmpty, "\(r0.errors)")
        let r1 = Regenerator.regenerate(document(height: "22 mm", sketch: s))
        #expect(r1.errors.isEmpty, "\(r1.errors)")
        let before = try #require(r0.sketches["sk"]?.solved), after = try #require(r1.sketches["sk"]?.solved)
        let p = s.projections[0]
        let a = try #require(after.position(p.start)), b = try #require(after.position(p.end))
        let c = try #require(after.position(corner))
        // The corner is on the line through the edge, wherever the edge is now…
        let d = simd_normalize(b - a)
        #expect(abs(d.x * (c.y - a.y) - d.y * (c.x - a.x)) < 1e-6)
        // …and the edge really moved: by the 2 mm the box grew.
        let a0 = try #require(before.position(p.start))
        #expect(abs(simd_length(a - a0) - 2) < 1e-6, "\(a0) -> \(a)")
        let c0 = try #require(before.position(corner))
        #expect(abs(simd_length(c - c0) - 2) < 1e-6, "the corner moved with it: \(c0) -> \(c)")
    }

    @Test func aSketchWithoutTheTieStaysPut() throws {
        // The same rectangle drawn at the same place without snapping: the old behaviour.
        let (_, first, opposite) = try notchAndCorners("20 mm")
        var loose = Sketch()
        loose.addRectangle(first.x, first.y, opposite.x, opposite.y)
        let r1 = Regenerator.regenerate(document(height: "22 mm", sketch: loose))
        #expect(r1.errors.isEmpty, "\(r1.errors)")
        let solved = try #require(r1.sketches["sk"]?.solved)
        #expect(solved.points.contains { abs($0.x - first.x) < 1e-6 && abs($0.y - first.y) < 1e-6 }, "nothing moved")
    }

    @Test func deletingTheProjectedLineDropsTheProjection() throws {
        var s = try notch("20 mm")
        let p = s.projections[0]
        s.delete([p.line])
        #expect(s.projections.isEmpty)
        #expect(s.point(p.start) == nil && s.point(p.end) == nil)
    }

    @Test func aMissingEdgeFailsTheSketchWithAClearReason() throws {
        var s = try notch("20 mm")
        s.projections[0].edge = EdgeRef(body: "box", edge: "box.nothing|box.here")
        let r = Regenerator.regenerate(document(height: "20 mm", sketch: s))
        #expect(r.errors["sk"]?.contains("projected edge not found") == true, "\(r.errors)")
    }

    @Test func anEdgeOffTheSketchPlaneProjectsAndFollowsTheBox() throws {
        // The top edge of the left face: the far side of the box, so it is off the right face's sketch plane.
        let far = EdgeRef(body: "box", edge: "box.left|box.top")
        let r0 = Regenerator.regenerate(document(height: "20 mm", sketch: Sketch()))
        let frame = try #require(r0.sketches["sk"]?.frame)
        let ends = try #require(r0.body("box")).edgeEnds(far.edge)
        #expect(abs(simd_dot(ends.start - frame.origin, frame.normal)) > 1, "the edge really is off the plane")
        func uv(_ p: SIMD3<Double>) -> SIMD2<Double> { SIMD2(simd_dot(p - frame.origin, frame.xAxis), simd_dot(p - frame.origin, frame.yAxis)) }
        var s = Sketch()
        s.project(ModelSnap(edge: far, start: uv(ends.start), end: uv(ends.end)))
        #expect(s.projections.map(\.edge) == [far])
        let p = s.projections[0]
        #expect(s.point(p.start)?.fixed == true && s.point(p.end)?.fixed == true)

        // Growing the box in height moves the top edge up by 2 mm; its flattened ends move with it.
        let r1 = Regenerator.regenerate(document(height: "22 mm", sketch: s))
        #expect(r1.errors.isEmpty, "\(r1.errors)")
        let solved0 = try #require(Regenerator.regenerate(document(height: "20 mm", sketch: s)).sketches["sk"]?.solved)
        let solved1 = try #require(r1.sketches["sk"]?.solved)
        for id in [p.start, p.end] {
            let a = try #require(solved0.position(id)), b = try #require(solved1.position(id))
            #expect(abs(simd_length(b - a) - 2) < 1e-6, "\(a) -> \(b)")
        }
    }

    @Test func projectionsSurviveSavingAndOldFilesStillLoad() throws {
        let s = try notch("20 mm")
        let back = try JSONDecoder().decode(Sketch.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        let plain = try JSONDecoder().decode(Sketch.self, from: JSONEncoder().encode(Sketch()))
        #expect(plain.projections.isEmpty)
    }

    // MARK: circular edges

    private func cylinder(diameter: String, sketch: Sketch) -> CADDocument {
        var d = CADDocument()
        d.features = [
            Feature(id: "c", name: "Cylinder1", .primitive(PrimitiveFeature(kind: .cylinder, plane: .xy, height: "10", diameter: diameter))),
            Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: sketch))),
        ]
        return d
    }

    /// The cylinder's two circles, as they land on the XY sketch plane (one lies in it, one 10 mm above).
    private func circles(_ diameter: String) throws -> [ModelSnap] {
        let r = Regenerator.regenerate(cylinder(diameter: diameter, sketch: Sketch()))
        let frame = try #require(r.sketches["sk"]?.frame)
        let body = try #require(r.body("c"))
        let found = body.edgeNames.compactMap { Regenerator.roundEdgeSnap(body, edge: EdgeRef(body: "c", edge: $0), frame: frame) }
        #expect(found.count == 2, "a cylinder has a circle at each end")
        return found
    }

    @Test func aCircularEdgeFacingTheSketchProjectsAsAFixedCircle() throws {
        for snap in try circles("20") {
            #expect(snap.isFullCircle && snap.center != nil)
            #expect(abs(simd_length(snap.start - snap.center!) - 10) < 1e-6)
            var s = Sketch()
            s.project(snap)
            let p = try #require(s.projections.first)
            #expect(p.center != nil && p.start == p.end)
            #expect(s.point(p.center!)?.fixed == true && s.point(p.start)?.fixed == true)
            let curve = try #require(s.curve(p.line))
            #expect(curve.construction)
            guard case .circle = curve.geometry else { Issue.record("expected a circle"); continue }
            // Projecting it again reuses it.
            s.project(snap)
            #expect(s.projections.count == 1 && s.curves.count == 1)
        }
    }

    @Test func aProjectedCircleFollowsTheBodyAndSurvivesSaving() throws {
        var s = Sketch()
        let top = try #require(try circles("20").max { $0.start.x < $1.start.x } ?? nil)
        s.project(top)
        let p = s.projections[0]
        // Doubling the diameter changes the radius to 20 and the sketch still solves.
        let r = Regenerator.regenerate(cylinder(diameter: "40", sketch: s))
        #expect(r.errors.isEmpty, "\(r.errors)")
        let solved = try #require(r.sketches["sk"]?.solved)
        guard case .circle(let c, let radius) = try #require(solved.curve(p.line)).geometry else { Issue.record("expected a circle"); return }
        #expect(abs(radius - 20) < 1e-6)
        let centre = try #require(solved.position(c))
        #expect(simd_length(centre) < 1e-6, "the circle is still around the origin")
        #expect(try JSONDecoder().decode(Sketch.self, from: JSONEncoder().encode(s)) == s)
    }

    @Test func anArcProjectsAsAnArcFromItsStartToItsEnd() throws {
        // A quarter arc to the left of the XY origin, as the cylinder edge would deliver it.
        let edge = EdgeRef(body: "c", edge: "c.arc")
        var s = Sketch()
        s.project(ModelSnap(edge: edge, start: SIMD2(10, 0), end: SIMD2(0, 10), center: .zero))
        let p = try #require(s.projections.first)
        guard case .arc(let c, let a, let b) = try #require(s.curve(p.line)).geometry else { Issue.record("expected an arc"); return }
        #expect(c == p.center && a == p.start && b == p.end)
        #expect(s.curve(p.line)?.construction == true)
        #expect(s.point(c)?.fixed == true && s.point(a)?.fixed == true && s.point(b)?.fixed == true)
    }

    @Test func aCircleSeenEdgeOnIsNotProjected() throws {
        // The cylinder's circles seen from a plane standing on edge land as lines, not circles.
        var d = cylinder(diameter: "20", sketch: Sketch())
        d.features[1] = Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xz, sketch: Sketch())))
        let r = Regenerator.regenerate(d)
        let frame = try #require(r.sketches["sk"]?.frame)
        let body = try #require(r.body("c"))
        #expect(body.edgeNames.allSatisfy { Regenerator.roundEdgeSnap(body, edge: EdgeRef(body: "c", edge: $0), frame: frame) == nil })
    }
}
