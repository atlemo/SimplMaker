// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CADCore

/// DXF import and export.
@Suite struct DXFTests {
    private func dxf(_ entities: String, units: Int? = nil) -> Data {
        var s = "0\nSECTION\n2\nHEADER\n"
        if let units { s += "9\n$INSUNITS\n70\n\(units)\n" }
        s += "0\nENDSEC\n0\nSECTION\n2\nENTITIES\n\(entities)0\nENDSEC\n0\nEOF\n"
        return Data(s.utf8)
    }

    @Test func linesAndACircleBecomeASketchCentredOnTheOrigin() throws {
        let r = try DXFImport.sketch(from: dxf("""
            0\nLINE\n8\n0\n10\n0\n20\n0\n11\n40\n21\n0
            0\nLINE\n8\n0\n10\n40\n20\n0\n11\n40\n21\n20
            0\nCIRCLE\n8\n0\n10\n20\n20\n10\n40\n3

            """))
        #expect(r.curveCount == 3)
        #expect(abs(r.width - 40) < 1e-9 && abs(r.height - 20) < 1e-9)
        // The shared corner is one point, not two.
        #expect(r.sketch.points.count == 1 + 3 + 1, "origin, three line ends, one circle centre: \(r.sketch.points.count)")
        let xs = r.sketch.points.dropFirst().map(\.x)
        #expect(abs(xs.min()! + 20) < 1e-9 && abs(xs.max()! - 20) < 1e-9)
    }

    @Test func anArcRunsCounterClockwiseBetweenItsAngles() throws {
        let r = try DXFImport.sketch(from: dxf("0\nARC\n8\n0\n10\n0\n20\n0\n40\n10\n50\n0\n51\n90\n"))
        guard case .arc(let c, let s, let e) = try #require(r.sketch.curves.first).geometry else { Issue.record("not an arc"); return }
        let C = try #require(r.sketch.point(c)), S = try #require(r.sketch.point(s)), E = try #require(r.sketch.point(e))
        #expect(abs((S.x - C.x) - 10) < 1e-9 && abs(S.y - C.y) < 1e-9)
        #expect(abs(E.x - C.x) < 1e-9 && abs((E.y - C.y) - 10) < 1e-9)
    }

    @Test func aPolylineBulgeMakesAnArcThroughTheRightPlace() throws {
        // A half circle (bulge 1) from (0,0) to (10,0) bulges below the chord and has radius 5.
        let r = try DXFImport.sketch(from: dxf("0\nLWPOLYLINE\n8\n0\n90\n2\n70\n0\n10\n0\n20\n0\n42\n1\n10\n10\n20\n0\n"))
        guard case .arc(let c, let s, let e) = try #require(r.sketch.curves.first).geometry else { Issue.record("not an arc"); return }
        let C = try #require(r.sketch.point(c)), S = try #require(r.sketch.point(s)), E = try #require(r.sketch.point(e))
        #expect(abs(vlen(S.position - C.position) - 5) < 1e-9 && abs(vlen(E.position - C.position) - 5) < 1e-9)
        #expect(abs(r.height - 5) < 1e-9, "the half circle is 5 tall: \(r.height)")
        // Counter-clockwise from the left end to the right end passes below the chord.
        #expect(S.x < E.x && abs(C.y - S.y) < 1e-9)
    }

    @Test func aClosedPolylineClosesAndInchesAreScaled() throws {
        let r = try DXFImport.sketch(from: dxf("0\nLWPOLYLINE\n8\n0\n90\n4\n70\n1\n10\n0\n20\n0\n10\n1\n20\n0\n10\n1\n20\n1\n10\n0\n20\n1\n", units: 1))
        #expect(r.curveCount == 4)
        #expect(abs(r.width - 25.4) < 1e-9)
    }

    @Test func thingsThatCannotBecomeCurvesAreReported() throws {
        let r = try DXFImport.sketch(from: dxf("0\nLINE\n10\n0\n20\n0\n11\n1\n21\n1\n0\nTEXT\n10\n0\n20\n0\n1\nhi\n0\nSPLINE\n70\n8\n0\nINSERT\n2\nB\n"))
        #expect(r.skipped == ["blocks", "splines", "text"])
    }

    @Test func notDXFAndBinaryDXFAreRefusedWithAReason() {
        #expect(throws: SVGImportError.self) { try DXFImport.sketch(from: Data("hello".utf8)) }
        #expect(throws: SVGImportError.self) { try DXFImport.sketch(from: Data("AutoCAD Binary DXF\r\n\u{1a}\0".utf8)) }
        #expect(throws: SVGImportError.self) { try DXFImport.sketch(from: dxf("")) }
    }

    @Test func hostileNumbersDoNotCrash() throws {
        _ = try? DXFImport.sketch(from: dxf("0\nLINE\n10\nnan\n20\ninf\n11\n1e999\n21\n-inf\n0\nCIRCLE\n10\n0\n20\n0\n40\n-5\n0\nARC\n10\n0\n20\n0\n40\n1\n50\n0\n51\n0\n0\nLWPOLYLINE\n90\n999999\n10\n1\n"))
        _ = try? DXFImport.sketch(from: Data([0, 255, 10, 48, 10, 0]))
        let huge = dxf("0\nCIRCLE\n10\n1e300\n20\n1e300\n40\n1e300\n0\nLINE\n10\n0\n20\n0\n11\n1e300\n21\n1e300\n")
        _ = try? DXFImport.sketch(from: huge)
    }

    @Test func tooManyCurvesAreRefused() {
        let one = "0\nLINE\n10\n0\n20\n0\n11\n1\n21\n1\n"
        let many = String(repeating: one, count: DXFImport.maxCurves + 5)
        #expect(throws: SVGImportError.self) { try DXFImport.sketch(from: dxf(many)) }
    }

    @Test func exportThenImportKeepsTheShapes() throws {
        var s = Sketch()
        s.addRectangle(0, 0, 30, 20)
        let c = s.addPoint(15, 10)
        s.addCircle(center: c, radius: 4)
        let ctr = s.addPoint(0, 0), a = s.addPoint(10, 0), b = s.addPoint(0, 10)
        s.addArc(center: ctr, start: a, end: b)
        let construction = s.addPoint(100, 100)
        s.addLine(c, construction, construction: true)
        let text = DXFExport.text(s)
        #expect(text.contains("AC1009") && text.hasSuffix("0\nEOF\n"))
        #expect(!text.contains("100.000000"), "construction lines stay out")

        let back = try DXFImport.sketch(from: Data(text.utf8))
        #expect(back.curveCount == 6)
        #expect(back.sketch.curves.filter { if case .line = $0.geometry { true } else { false } }.count == 4)
        #expect(back.sketch.curves.contains { if case .circle(_, let r) = $0.geometry { abs(r - 4) < 1e-6 } else { false } })
        #expect(back.sketch.curves.contains { if case .arc = $0.geometry { true } else { false } })
    }

    @Test func aBezierAndAnEllipseGoOutAsPolylines() throws {
        var s = Sketch()
        let p0 = s.addPoint(0, 0), p1 = s.addPoint(5, 10), p2 = s.addPoint(15, 10), p3 = s.addPoint(20, 0)
        s.addBezier(start: p0, control1: p1, control2: p2, end: p3)
        let text = DXFExport.text(s)
        #expect(text.contains("POLYLINE") && text.contains("SEQEND"))
        let back = try DXFImport.sketch(from: Data(text.utf8))
        #expect(back.curveCount == 48)
        #expect(abs(back.width - 20) < 1e-3)
    }
}

/// Splines, and a file written by FreeCAD.
@Suite struct DXFSplineTests {
    private func spline(degree: Int, knots: [Double], points: [(Double, Double)], extra: String = "") -> Data {
        var s = "0\nSECTION\n2\nENTITIES\n0\nSPLINE\n8\n0\n70\n8\n71\n\(degree)\n72\n\(knots.count)\n73\n\(points.count)\n\(extra)"
        for k in knots { s += "40\n\(k)\n" }
        for p in points { s += "10\n\(p.0)\n20\n\(p.1)\n30\n0\n" }
        return Data((s + "0\nENDSEC\n0\nEOF\n").utf8)
    }

    private func beziers(_ r: DXFImport.Result) -> [[SIMD2<Double>]] {
        r.sketch.curves.compactMap { c in
            guard case .bezier(let a, let c1, let c2, let b) = c.geometry else { return nil }
            return [a, c1, c2, b].compactMap { r.sketch.point($0)?.position }
        }
    }

    @Test func aSingleCubicSpanKeepsItsControlPoints() throws {
        let r = try DXFImport.sketch(from: spline(degree: 3, knots: [0, 0, 0, 0, 1, 1, 1, 1], points: [(0, 0), (10, 15), (30, 15), (40, 0)]))
        let b = try #require(beziers(r).first)
        #expect(beziers(r).count == 1 && abs(r.width - 40) < 1e-9)
        // The sketch is centred on the middle of its box: x - 20, y - the box's middle.
        #expect(abs((b[1] - b[0]).x - 10) < 1e-9 && abs((b[1] - b[0]).y - 15) < 1e-9 && abs((b[3] - b[2]).x - 10) < 1e-9)
    }

    @Test func aTwoSpanCubicSplitsIntoTwoBeziersThatMeet() throws {
        // Uniform cubic B-spline, six control points, one inner knot of multiplicity 1 at 1/3 and 2/3 (two inner knots): three spans.
        let r = try DXFImport.sketch(from: spline(degree: 3, knots: [0, 0, 0, 0, 1, 2, 3, 3, 3, 3],
                                                  points: [(0, 0), (5, 10), (15, 10), (25, -10), (35, -10), (40, 0)]))
        let list = beziers(r)
        #expect(list.count == 3, "\(list.count)")
        for i in 0..<(list.count - 1) { #expect(vlen(list[i][3] - list[i + 1][0]) < 1e-9, "spans meet") }
        // The curve passes through the same middle point as the B-spline: at u = 1 the point is (P1 + 4 P2 + P3)/6-style, checked on the first knot.
        let first = list[0]
        #expect(vlen(first[0] - SIMD2(-20, first[0].y)) < 1e-9, "starts at the first control point")
    }

    @Test func rationalAndPeriodicSplinesAreLeftOutAndSaid() throws {
        let rational = spline(degree: 3, knots: [0, 0, 0, 0, 1, 1, 1, 1], points: [(0, 0), (10, 15), (30, 15), (40, 0)], extra: "41\n1\n41\n2\n")
        #expect(throws: SVGImportError.self) { try DXFImport.sketch(from: rational) }
        let withLine = Data(("0\nSECTION\n2\nENTITIES\n0\nLINE\n10\n0\n20\n0\n11\n5\n21\n5\n0\nSPLINE\n71\n3\n72\n3\n73\n2\n40\n0\n40\n1\n40\n2\n10\n0\n20\n0\n10\n1\n20\n1\n0\nENDSEC\n0\nEOF\n").utf8)
        #expect(try DXFImport.sketch(from: withLine).skipped == ["splines"])
    }

    @Test func aWholeEllipseWrittenWith6_28318IsStillWhole() throws {
        let d = Data("0\nSECTION\n2\nENTITIES\n0\nELLIPSE\n10\n20\n20\n-15\n11\n10\n21\n0\n40\n0.5\n41\n0\n42\n6.28318\n0\nENDSEC\n0\nEOF\n".utf8)
        let r = try DXFImport.sketch(from: d)
        #expect(r.skipped.isEmpty && r.curveCount == 1)
    }

    @Test func aFileWrittenByFreeCADReadsBackWithItsSpline() throws {
        let path = "/private/tmp/claude-501/-Users-atlemo-Vibe-Projects-SimplCAD-SimplCAD/62ec81ef-6e05-4ba4-baff-eadf6a8c3d11/scratchpad/files/fromfreecad.dxf"
        guard FileManager.default.fileExists(atPath: path) else { return }  // only where the sample is
        let r = try DXFImport.sketch(from: Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(r.skipped.isEmpty, "\(r.skipped)")
        #expect(r.curveCount == 4 + 1 + 1 + 1 + 1)
        #expect(abs(r.width - 40) < 1e-6 && abs(r.height - 61.25) < 0.05, "w \(r.width) h \(r.height)")
    }
}
