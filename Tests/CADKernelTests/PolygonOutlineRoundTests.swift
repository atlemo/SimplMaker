// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import Foundation
import Testing
@testable import CADKernel

/// A curve traced with many short straight lines cannot be rounded (OpenCascade takes the walls for one smooth chain it
/// cannot follow); the error has to say so, and what to do, instead of "size too large".
@Suite struct PolygonOutlineRoundTests {
    private func prism(sides n: Int, radius: Double) -> CADDocument {
        var s = Sketch()
        let pts = (0..<n).map { i -> EntityID in
            let a = 2 * Double.pi * Double(i) / Double(n)
            return s.addPoint(radius * cos(a), radius * sin(a))
        }
        var lines: [EntityID] = []
        for i in 0..<n { lines.append(s.addLine(pts[i], pts[(i + 1) % n], id: "L\(i + 1)")) }
        var doc = CADDocument()
        doc.features = [
            Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s))),
            Feature(id: "ex", name: "Extrude1", .extrude(ExtrudeFeature(sketch: "sk", profiles: [ProfileRef(curves: lines)], extent: .distance("8 mm")))),
        ]
        return doc
    }

    private func round(_ doc: CADDocument, fillet: Bool, size: String) -> String? {
        var d = doc
        let edges = [EdgeRef(body: "ex", edge: "ex.end|ex.side.L1")]
        d.features.append(Feature(id: "fx", name: "Finish", fillet ? .fillet(EdgeFeature(edges: edges, size: size)) : .chamfer(EdgeFeature(edges: edges, size: size))))
        return Regenerator.regenerate(d).errors["fx"]
    }

    @Test func aPolygonOutlineIsNamedAsTheReasonItCannotBeRounded() throws {
        let doc = prism(sides: 151, radius: 100)  // 2.4 degrees at each corner
        let why = try #require(round(doc, fillet: true, size: "0.5 mm"))
        #expect(why.contains("151 short straight pieces") && why.contains("spline"), "\(why)")
        #expect(why.contains("bend 358 degrees"), "it bends all the way round: \(why)")
    }

    @Test func aSmootherOrSharperOutlineIsNotBlamed() throws {
        // 60 sides: 6 degrees at each corner is more than OpenCascade takes for smooth, so each edge is rounded alone.
        #expect(round(prism(sides: 60, radius: 50), fillet: true, size: "0.5 mm") == nil)
        // A box has four sharp corners and no chain at all.
        #expect(round(prism(sides: 4, radius: 30), fillet: true, size: "0.5 mm") == nil)
        let tooBig = round(prism(sides: 4, radius: 30), fillet: true, size: "40 mm")
        #expect(tooBig != nil && tooBig?.contains("short straight pieces") == false, "\(tooBig ?? "ok")")
    }
}
