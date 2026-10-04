// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation
import Testing
@testable import CADCore

/// Move, rotate and scale of sketch geometry.
@Suite struct SketchTransformTests {
    private let none = ParameterValues()

    /// A dimensioned 10 × 4 rectangle with a corner on the origin, and a separate circle of radius 2.
    private func sample() -> (Sketch, rect: [EntityID], circle: EntityID) {
        var s = Sketch()
        let (lines, corners) = s.addRectangle(20, 20, 30, 24)
        s.dimension(.length(lines[0]), "10 mm", id: "w")
        s.dimension(.length(lines[1]), "4 mm", id: "h")
        s.constrain(.fix(corners[0], x: 20, y: 20))
        let circle = s.addCircle(center: s.addPoint(0, 50), radius: 2)
        s.dimension(.radius(circle), "2 mm", id: "r")
        return (s, corners, circle)
    }

    @Test func moveShiftsOnlyTheSelectionAndItsFixedTarget() throws {
        var (s, corners, circle) = sample()
        let lines = s.curves.filter { if case .line = $0.geometry { return true } else { return false } }.map(\.id)
        let applied490 = s.apply(.move(dx: 5, dy: -2), to: lines, parameters: none)
        #expect(applied490)
        #expect(s.point(corners[0])!.position == SIMD2(25, 18) && s.point(corners[2])!.position == SIMD2(35, 22))
        #expect(s.point(s.curve(circle).map { s.pointIDs(of: $0)[0] }!)!.position == SIMD2(0, 50), "the circle stays")
        guard case .fix(_, let x, let y)? = s.constraints.first(where: { if case .fix = $0.kind { return true } else { return false } })?.kind
        else { Issue.record("expected a fix"); return }
        #expect(x == 25 && y == 18, "the anchor moves with its point")
    }

    @Test func nothingSelectedMeansEverythingButTheOrigin() {
        var (s, corners, _) = sample()
        let applied1516 = s.apply(.move(dx: 1, dy: 1), to: [], parameters: none)
        #expect(applied1516)
        #expect(s.point("origin")!.position == .zero, "the origin is fixed")
        #expect(s.point(corners[0])!.position == SIMD2(21, 21))
    }

    @Test func rotateTurnsCounterClockwiseAboutAPoint() {
        var s = Sketch()
        let a = s.addPoint(2, 0), b = s.addPoint(3, 0)
        s.addLine(a, b)
        let applied1944 = s.apply(.rotate(angle: .pi / 2, about: .zero), to: [], parameters: none)
        #expect(applied1944)
        #expect(vlen(s.point(a)!.position - SIMD2(0, 2)) < 1e-12 && vlen(s.point(b)!.position - SIMD2(0, 3)) < 1e-12)
        #expect(vlen(s.transformCenter([])! - SIMD2(0, 2.5)) < 1e-9)
    }

    @Test func scaleGrowsRadiiAndTheDimensionsInsideWhatGrows() {
        var (s, corners, circle) = sample()
        let lines = s.curves.filter { if case .line = $0.geometry { return true } else { return false } }.map(\.id)
        let centre = s.transformCenter(lines)!
        #expect(centre == SIMD2(25, 22))
        let applied2987 = s.apply(.scale(factor: 2, about: centre), to: lines, parameters: none)
        #expect(applied2987)
        #expect(s.point(corners[0])!.position == SIMD2(15, 18) && s.point(corners[2])!.position == SIMD2(35, 26))
        let dims = Dictionary(uniqueKeysWithValues: s.dimensions.map { ($0.id, $0.expression) })
        let values = s.dimensionValues(none)
        #expect(abs(values["w"]! - 20) < 1e-9 && abs(values["h"]! - 8) < 1e-9, "\(dims)")
        #expect(abs(values["r"]! - 2) < 1e-9, "the circle wasn't selected")
        if case .circle(_, let r)? = s.curve(circle)?.geometry { #expect(r == 2) }

        // Scaling the circle grows its radius and its dimension.
        let applied7507 = s.apply(.scale(factor: 3, about: SIMD2(0, 50)), to: [circle], parameters: none)
        #expect(applied7507)
        if case .circle(_, let r)? = s.curve(circle)?.geometry { #expect(abs(r - 6) < 1e-12) }
        #expect(abs(s.dimensionValues(none)["r"]! - 6) < 1e-9)
    }

    @Test func aDistanceFromTheOriginGrowsOnlyWhenScalingAboutIt() {
        var s = Sketch()
        let p = s.addPoint(10, 0)
        s.dimension(.horizontalDistance("origin", p), "10 mm", id: "d")
        var about = s
        let applied4344 = about.apply(.scale(factor: 2, about: .zero), to: [p], parameters: none)
        #expect(applied4344)
        #expect(abs(about.dimensionValues(none)["d"]! - 20) < 1e-9)
        let applied5013 = s.apply(.scale(factor: 2, about: SIMD2(10, 0)), to: [p], parameters: none)
        #expect(applied5013)
        #expect(abs(s.dimensionValues(none)["d"]! - 10) < 1e-9, "left for the solver to object to")
    }

    @Test func aTextTurnsWithItsAnchor() throws {
        var s = Sketch()
        let anchor = s.addPoint(10, 0)
        s.texts.append(SketchText(text: "Hi", position: anchor, height: "8 mm"))
        let ok1 = s.apply(.rotate(angle: .pi / 2, about: .zero), to: [], parameters: none)
        #expect(ok1)
        let p = try #require(s.point(anchor)?.position)
        #expect(vlen(p - SIMD2(0, 10)) < 1e-12, "the anchor swings round")
        #expect(abs(s.texts[0].angle - .pi / 2) < 1e-12, "and the baseline turns with it")
        let ok2 = s.apply(.move(dx: 5, dy: 0), to: [], parameters: none)
        #expect(ok2)
        #expect(abs(s.texts[0].angle - .pi / 2) < 1e-12, "a move leaves the angle alone")
        // Only texts that move turn.
        var t = Sketch()
        let a = t.addPoint(0, 0), b = t.addPoint(5, 5)
        t.texts = [SketchText(text: "A", position: a), SketchText(text: "B", position: b)]
        let ok3 = t.apply(.rotate(angle: 1, about: .zero), to: [b], parameters: none)
        #expect(ok3)
        #expect(t.texts[0].angle == 0 && t.texts[1].angle == 1)
    }

    @Test func aTextsAngleIsSavedOnlyWhenItIsTurned() throws {
        let level = try JSONEncoder().encode(SketchText(text: "Hi", position: "p"))
        #expect(!String(decoding: level, as: UTF8.self).contains("angle"), "files without turned text don't change")
        #expect(try JSONDecoder().decode(SketchText.self, from: level).angle == 0)
        let turned = try JSONEncoder().encode(SketchText(text: "Hi", position: "p", angle: 0.5))
        #expect(try JSONDecoder().decode(SketchText.self, from: turned).angle == 0.5)
    }

    @Test func textsScaleAndBeziersKeepTheirShape() {
        var s = Sketch()
        let anchor = s.addPoint(0, 0)
        s.texts.append(SketchText(text: "Hi", position: anchor, height: "8 mm"))
        let a = s.addPoint(0, 10), c1 = s.addPoint(5, 20), c2 = s.addPoint(15, 20), b = s.addPoint(20, 10)
        let curve = s.addBezier(start: a, control1: c1, control2: c2, end: b)
        let before = Bezier.point([SIMD2(0, 10), SIMD2(5, 20), SIMD2(15, 20), SIMD2(20, 10)], 0.3)
        let applied5145 = s.apply(.scale(factor: 0.5, about: .zero), to: [], parameters: none)
        #expect(applied5145)
        #expect(s.texts[0].height == "4 mm")
        guard case .bezier(let a2, let c12, let c22, let b2)? = s.curve(curve)?.geometry else { Issue.record("expected a Bézier"); return }
        let now = Bezier.point([a2, c12, c22, b2].map { s.point($0)!.position }, 0.3)
        #expect(vlen(now - before * 0.5) < 1e-12)
    }

    @Test func emptySketchHasNothingToTransform() {
        var s = Sketch()
        let applied4726 = s.apply(.move(dx: 1, dy: 0), to: [], parameters: none)
        #expect(!applied4726)
        #expect(s.transformCenter([]) == nil)
    }

    @Test func aQuarterTurnSwapsHorizontalAndVerticalConstraints() {
        var s = Sketch()
        let (lines, _) = s.addRectangle(0, 0, 10, 4)
        let applied = s.apply(.rotate(angle: .pi / 2, about: .zero), to: [], parameters: none)
        #expect(applied)
        var horizontal = 0, vertical = 0
        for c in s.constraints {
            if case .horizontal = c.kind { horizontal += 1 }
            if case .vertical = c.kind { vertical += 1 }
        }
        #expect(horizontal == 2 && vertical == 2)
        // The bottom edge, horizontal before, is vertical now.
        #expect(s.constraints.contains { $0.kind == .vertical(lines[0]) })
        // Half a turn changes nothing about which is which.
        var t = s
        let half = t.apply(.rotate(angle: .pi, about: .zero), to: [], parameters: none)
        #expect(half && t.constraints == s.constraints)
    }
}
