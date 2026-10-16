// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation
import Testing
@testable import CADCore

@Suite struct SketchEditingTests {
    @Test func lineChainSharesPointsAndInfersAlignment() {
        var s = Sketch()
        let first = s.addLine(from: SketchSnap(SIMD2(0, 0), point: "origin"), to: SketchSnap(SIMD2(40, 0.5)))
        let second = s.addLine(from: SketchSnap(SIMD2(40, 0)), to: SketchSnap(SIMD2(40.4, 25)), startPoint: first.end)
        #expect(s.curves.count == 2)
        #expect(s.points.count == 3)  // origin + 2 new points; the chain shares its corner
        #expect(s.constraints.contains { $0.kind == .horizontal(first.line) })
        #expect(s.constraints.contains { $0.kind == .vertical(second.line) })
        #expect(s.position(first.end) == SIMD2(40, 0))  // snapped exactly horizontal
        #expect(s.curve(first.line).map { s.pointIDs(of: $0) }?.first == "origin")
    }

    @Test func snappingOntoCurveAddsPointOnCurve() {
        var s = Sketch()
        let c = s.addCircle(center: SketchSnap(SIMD2(0, 0), point: "origin"), through: SketchSnap(SIMD2(10, 0)))
        let l = s.addLine(from: SketchSnap(SIMD2(10, 0), curve: c), to: SketchSnap(SIMD2(30, 7)))
        let start = s.pointIDs(of: s.curve(l.line)!)[0]
        #expect(s.constraints.contains { $0.kind == .pointOnCurve(point: start, curve: c) })
    }

    @Test func deleteCascades() {
        var s = Sketch()
        let rect = s.addRectangle(from: SketchSnap(SIMD2(0, 0), point: "origin"), to: SketchSnap(SIMD2(20, 10)))
        s.dimension(.length(rect[0]), "20")
        s.dimension(.length(rect[1]), "10")
        s.delete([rect[0]])
        #expect(s.curves.count == 3)
        #expect(s.dimensions.count == 1)                                             // length of rect[0] went
        #expect(!s.constraints.contains { Sketch.references($0.kind).contains(rect[0]) })
        #expect(s.points.count == 5)                                                 // corners still used by other lines
        s.delete(Set(rect))
        #expect(s.curves.isEmpty && s.dimensions.isEmpty && s.constraints.isEmpty)
        #expect(s.points.map(\.id) == ["origin"])
    }

    @Test func angleFollowsTheWedgeUnderTheCursor() {
        var s = Sketch()
        let a = s.addPoint(0, 0), b = s.addPoint(30, 40), c = s.addPoint(0, 10)
        let l1 = s.addLine(a, b), l2 = s.addLine(a, c)
        func at(_ deg: Double) -> SIMD2<Double> { SIMD2(cos(deg * .pi / 180), sin(deg * .pi / 180)) * 20 }
        // The small wedge (70°, between the two lines) is l1 to l2; the large one (250°) is l2 to l1.
        let small = s.angleChoice(l1, l2, toward: at(70), size: 0.5)
        let large = s.angleChoice(l1, l2, toward: at(250), size: 0.5)
        let wedge = Double.pi / 2 - atan2(40, 30)
        #expect(small?.kind == .angle(l1, l2))
        #expect(abs((small?.value ?? 0) - wedge) < 1e-9)
        #expect(large?.kind == .angle(l2, l1))
        #expect(abs((large?.value ?? 0) - (2 * .pi - wedge)) < 1e-9)
    }

    @Test func suggestedDimensions() {
        var s = Sketch()
        let a = s.addPoint(0, 0), b = s.addPoint(30, 40), c = s.addPoint(0, 10)
        let l1 = s.addLine(a, b), l2 = s.addLine(a, c)
        let circle = s.addCircle(center: a, radius: 5)
        #expect(s.suggestDimension(for: [l1])?.value == 50)
        #expect(s.suggestDimension(for: [circle])?.value == 10)          // diameter
        #expect(s.suggestDimension(for: [b, c])?.value == sqrt(900 + 900))
        let angle = s.suggestDimension(for: [l2, l1])!
        #expect(angle.value <= .pi && abs(angle.value - atan2(30, 40)) < 1e-12)  // measured the short way
        #expect(s.dimensionPickIsComplete([circle]) && !s.dimensionPickIsComplete([l1]))
    }

    @Test func constraintToolsValidateSelection() {
        var s = Sketch()
        let a = s.addPoint(0, 0), b = s.addPoint(10, 1), c = s.addPoint(0, 5), d = s.addPoint(9, 6)
        let l1 = s.addLine(a, b), l2 = s.addLine(c, d)
        let circle = s.addCircle(center: s.addPoint(20, 20), radius: 3)
        #expect(s.constraints(.parallel, for: [l1, l2]) == [.parallel(l1, l2)])
        #expect(s.constraints(.parallel, for: [l1]) == nil)
        #expect(s.constraints(.horizontal, for: [l1, l2])?.count == 2)
        #expect(s.constraints(.tangent, for: [l1, circle]) == [.tangent(l1, circle)])
        #expect(s.constraints(.coincident, for: [a, l2]) == [.pointOnCurve(point: a, curve: l2)])
        #expect(s.constraints(.midpoint, for: [l2, a]) == [.midpoint(point: a, line: l2)])
        #expect(s.constraints(.fix, for: [l1]) == nil)
    }

    @Test func overConstrainingIsRejected() {
        var s = Sketch()
        let a = s.addPoint(0, 0), b = s.addPoint(10, 0)
        let l = s.addLine(a, b)
        let r1 = s.applyConstraints([.horizontal(l)], values: [:])
        #expect(r1)
        let r2 = s.applyDimension(.length(l), expression: "10 mm", value: 10, values: [:])
        #expect(r2)
        let before = s
        let r3 = s.applyConstraints([.vertical(l)], values: s.dimensionValues(ParameterValues()))
        #expect(!r3)
        #expect(s == before)
    }

    @Test func draggingRespectsConstraints() {
        var s = Sketch()
        let a = s.addPoint(0, 0), b = s.addPoint(10, 0)
        let l = s.addLine(a, b)
        s.constrain(.horizontal(l))
        s.constrain(.coincident(a, "origin"))
        let r4 = s.drag(b, to: SIMD2(20, 5), values: [:])
        #expect(r4)
        #expect(abs(s.position(b)!.y) < 1e-6)            // stays horizontal…
        #expect(abs(s.position(b)!.x - 20) < 0.1)        // …but follows the cursor along x
        _ = s.drag(a, to: SIMD2(5, 5), values: [:])
        #expect(vlen(s.position(a)!) < 1e-6)              // pinned to the origin, doesn't move
        let r5 = s.drag("origin", to: SIMD2(1, 1), values: [:])
        #expect(!r5)
        let circle = s.addCircle(center: s.addPoint(30, 30), radius: 2)
        let r6 = s.drag(circle, to: SIMD2(30, 38), values: [:])
        #expect(r6)
        #expect(abs(s.radius(of: s.curve(circle)!)! - 8) < 1e-6)
        #expect(s.constraints.count == 2 && s.dimensions.isEmpty)  // temporary drag constraints removed
    }

    @Test func formatting() {
        #expect(formatDimension(23.4500001, kind: .length) == "23.45 mm")
        #expect(formatDimension(.pi / 6, kind: .angle) == "30 deg")
        #expect(formatDimension(10, kind: .length) == "10 mm")
    }
}
