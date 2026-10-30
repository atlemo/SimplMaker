// Copyright © 2026 Atle Mo. All rights reserved.
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
