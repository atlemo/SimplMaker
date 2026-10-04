// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation
import Testing
@testable import CADCore

/// SVG files become sketches: shapes, paths, transforms and units.
@Suite struct SVGImportTests {
    private func svg(_ body: String, attrs: String = "width=\"100mm\" height=\"100mm\" viewBox=\"0 0 100 100\"") -> Data {
        Data("<svg xmlns=\"http://www.w3.org/2000/svg\" \(attrs)>\(body)</svg>".utf8)
    }

    private func load(_ body: String, attrs: String = "width=\"100mm\" height=\"100mm\" viewBox=\"0 0 100 100\"") throws -> SVGImport.Result {
        try SVGImport.sketch(from: svg(body, attrs: attrs))
    }

    private func position(_ s: Sketch, _ id: EntityID) -> SIMD2<Double> { s.point(id)!.position }

    @Test func aRectangleIsFourLinesWithSharedCorners() throws {
        let r = try load("<rect x=\"10\" y=\"20\" width=\"30\" height=\"40\"/>")
        #expect(r.curveCount == 4 && r.sketch.points.count == 5, "origin plus four corners")
        #expect(abs(r.width - 30) < 1e-9 && abs(r.height - 40) < 1e-9)
        // Centred on the origin, y up.
        let xs = r.sketch.points.dropFirst().map(\.x), ys = r.sketch.points.dropFirst().map(\.y)
        #expect(xs.min()! == -15 && xs.max()! == 15 && ys.min()! == -20 && ys.max()! == 20)
    }

    @Test func yPointsUp() throws {
        // A line that goes down the page (increasing y) goes down in the sketch.
        let r = try load("<line x1=\"0\" y1=\"0\" x2=\"0\" y2=\"10\"/>")
        guard case .line(let a, let b)? = r.sketch.curves.first?.geometry else { Issue.record("expected a line"); return }
        #expect(position(r.sketch, a).y > position(r.sketch, b).y)
    }

    @Test func unitsAndViewBoxScale() throws {
        // 200 user units across 50 mm: 4 units per mm.
        let r = try load("<rect width=\"200\" height=\"100\"/>", attrs: "width=\"50mm\" height=\"25mm\" viewBox=\"0 0 200 100\"")
        #expect(abs(r.width - 50) < 1e-9 && abs(r.height - 25) < 1e-9)
        // Without a size a user unit is a pixel: 96 to the inch.
        let px = try load("<rect width=\"96\" height=\"48\"/>", attrs: "")
        #expect(abs(px.width - 25.4) < 1e-9 && abs(px.height - 12.7) < 1e-9)
        let inch = try load("<rect width=\"1\" height=\"1\"/>", attrs: "width=\"1in\" height=\"1in\" viewBox=\"0 0 1 1\"")
        #expect(abs(inch.width - 25.4) < 1e-9)
    }

    @Test func circlesStayCircles() throws {
        let r = try load("<circle cx=\"50\" cy=\"50\" r=\"10\"/>")
        guard case .circle(let c, let radius)? = r.sketch.curves.first?.geometry else { Issue.record("expected a circle"); return }
        #expect(abs(radius - 10) < 1e-9 && vlen(position(r.sketch, c)) < 1e-9)
    }

    @Test func anEllipseIsBezierPieces() throws {
        let r = try load("<ellipse cx=\"50\" cy=\"50\" rx=\"20\" ry=\"10\"/>")
        #expect(r.curveCount == 4)
        #expect(abs(r.width - 40) < 1e-6 && abs(r.height - 20) < 1e-6)
        // Closed: every end is shared with a neighbour.
        #expect(r.sketch.points.count == 1 + 4 + 8)
    }

    @Test func pathCommandsAbsoluteRelativeAndImplicit() throws {
        let r = try load("<path d=\"M10 10 h20 v20 H10 z\"/>")
        #expect(r.curveCount == 4 && r.sketch.points.count == 5)
        let compact = try load("<path d=\"m10,10 20,0 0,20 -20,0z\"/>")
        #expect(compact.curveCount == 4, "extra pairs after m are lines")
        let packed = try load("<path d=\"M10-10L20-20.5.5-.5\"/>")
        #expect(packed.curveCount == 2, "numbers run together: 20 -20.5 .5")
    }

    @Test func curvesAndSmoothCurves() throws {
        let r = try load("<path d=\"M0 0 C10 0 20 10 20 20 S30 40 40 40 Q50 40 50 30 T60 20\"/>")
        #expect(r.curveCount == 4)
        // The smooth curve's first handle mirrors the previous one about the join at (20, 20): (30, 30).
        let beziers = r.sketch.curves.compactMap { c -> [SIMD2<Double>]? in
            guard case .bezier(let a, let b, let c2, let d) = c.geometry else { return nil }
            return [a, b, c2, d].map { position(r.sketch, $0) }
        }
        let first = beziers[0], second = beziers[1]
        #expect(vlen((second[1] - second[0]) + (first[2] - first[3])) < 1e-9)
    }

    @Test func aSemicircleArcStaysAnArc() throws {
        // Half a circle of radius 10 from (0,0) to (20,0), bulging up the page.
        let r = try load("<path d=\"M0 0 A10 10 0 0 1 20 0\"/>")
        guard case .arc(let c, let s, let e)? = r.sketch.curves.first?.geometry else { Issue.record("expected an arc"); return }
        let center = position(r.sketch, c), start = position(r.sketch, s), end = position(r.sketch, e)
        #expect(abs(vlen(start - center) - 10) < 1e-9 && abs(vlen(end - center) - 10) < 1e-9)
        // Counter-clockwise from start to end, and it bulges toward +y (up the sketch, up the page? no: sweep=1 in SVG's
        // y-down space bulges up the page, which is +y in the sketch).
        let mid = center + SIMD2(0, 10)
        let a0 = atan2(start.y - center.y, start.x - center.x)
        var sweep = atan2(end.y - center.y, end.x - center.x) - a0
        if sweep <= 0 { sweep += 2 * .pi }
        let m = a0 + sweep / 2
        #expect(vlen((center + 10 * SIMD2(cos(m), sin(m))) - mid) < 1e-9)
    }

    @Test func aFlippedArcBulgesTheOtherWay() throws {
        let r = try load("<path d=\"M0 0 A10 10 0 0 0 20 0\"/>")
        guard case .arc(let c, let s, let e)? = r.sketch.curves.first?.geometry else { Issue.record("expected an arc"); return }
        let center = position(r.sketch, c), start = position(r.sketch, s), end = position(r.sketch, e)
        let a0 = atan2(start.y - center.y, start.x - center.x)
        var sweep = atan2(end.y - center.y, end.x - center.x) - a0
        if sweep <= 0 { sweep += 2 * .pi }
        let m = a0 + sweep / 2
        #expect((center + 10 * SIMD2(cos(m), sin(m))).y < center.y, "the middle of the arc is below its ends")
    }

    @Test func anEllipticalArcBecomesCurves() throws {
        let r = try load("<path d=\"M0 0 A20 10 0 0 1 40 0\"/>")
        #expect(r.curveCount == 2)
        #expect(abs(r.height - 10) < 1e-6 && abs(r.width - 40) < 1e-6)
    }

    @Test func transformsApply() throws {
        let r = try load("<g transform=\"translate(10 0) scale(2)\"><rect width=\"5\" height=\"5\"/></g>")
        #expect(abs(r.width - 10) < 1e-9 && abs(r.height - 10) < 1e-9)
        let turned = try load("<rect width=\"10\" height=\"20\" transform=\"rotate(90)\"/>")
        #expect(abs(turned.width - 20) < 1e-9 && abs(turned.height - 10) < 1e-9)
        // A circle survives an even scale but not a stretch.
        let stretched = try load("<circle r=\"5\" transform=\"scale(2 1)\"/>")
        #expect(stretched.sketch.curves.allSatisfy { if case .circle = $0.geometry { return false } else { return true } })
        #expect(abs(stretched.width - 20) < 1e-6 && abs(stretched.height - 10) < 1e-6)
    }

    @Test func roundedRectangleHasArcCorners() throws {
        let r = try load("<rect width=\"40\" height=\"20\" rx=\"5\"/>")
        let arcs = r.sketch.curves.filter { if case .arc = $0.geometry { return true } else { return false } }
        #expect(arcs.count == 4 && r.curveCount == 8)
        #expect(abs(r.width - 40) < 1e-9 && abs(r.height - 20) < 1e-9)
        // Every arc end is shared with its neighbouring line.
        #expect(r.sketch.points.count == 1 + 8 + 4, "origin, eight ends, four centres")
    }

    @Test func polygonsClosePolylinesDontAndHiddenThingsAreSkipped() throws {
        #expect(try load("<polygon points=\"0,0 10,0 10,10\"/>").curveCount == 3)
        #expect(try load("<polyline points=\"0,0 10,0 10,10\"/>").curveCount == 2)
        let r = try load("<g display=\"none\"><rect width=\"9\" height=\"9\"/></g><rect width=\"5\" height=\"5\" style=\"display:none\"/><circle r=\"3\"/>")
        #expect(r.curveCount == 1)
    }

    @Test func defsAreOnlyDrawnThroughUse() throws {
        let r = try load("<defs><rect id=\"a\" width=\"5\" height=\"5\"/></defs><use href=\"#a\" x=\"20\"/><use xlink:href=\"#a\" x=\"40\" xmlns:xlink=\"http://www.w3.org/1999/xlink\"/>")
        #expect(r.curveCount == 8)
        #expect(abs(r.width - 25) < 1e-9, "\(r.width)")
    }

    @Test func textIsReportedNotImported() throws {
        let r = try load("<text x=\"0\" y=\"10\">Hi</text><rect width=\"5\" height=\"5\"/>")
        #expect(r.skipped == ["text"] && r.curveCount == 4)
    }

    @Test func badFilesSayWhy() {
        #expect(throws: SVGImportError.self) { try SVGImport.sketch(from: Data("not xml".utf8)) }
        #expect(throws: SVGImportError.self) { try SVGImport.sketch(from: Data("<html/>".utf8)) }
        #expect(throws: SVGImportError.self) { try SVGImport.sketch(from: self.svg("<g/>")) }
    }

    @Test func aTooDetailedDrawingIsRefused() {
        let d = (0..<(SVGImport.maxCurves + 5)).map { "l\($0 % 2 == 0 ? 1 : -1) 1" }.joined()
        #expect(throws: SVGImportError.self) { try self.load("<path d=\"M0 0\(d)\"/>") }
    }

    @Test func mergingKeepsBothSketchesIntact() throws {
        var target = Sketch()
        let a = target.addPoint(1, 1), b = target.addPoint(5, 1)
        target.addLine(a, b)
        let imported = try load("<rect width=\"10\" height=\"10\"/>").sketch
        target.merge(imported)
        #expect(target.curves.count == 5 && target.points.count == 3 + 4)
        #expect(Set(target.points.map(\.id)).count == target.points.count)
        #expect(Set(target.curves.map(\.id)).count == target.curves.count)
        for c in target.curves { if case .line(let s, let e) = c.geometry { #expect(target.point(s) != nil && target.point(e) != nil) } }
    }

    @Test func idsStayUniqueInABigDrawing() throws {
        let d = (0..<5000).map { "M\($0) 0l1 1" }.joined()
        let r = try load("<path d=\"\(d)\"/>")
        let ids = r.sketch.points.map(\.id) + r.sketch.curves.map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}
