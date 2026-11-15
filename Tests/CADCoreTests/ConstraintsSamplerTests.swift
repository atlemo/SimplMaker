// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CADCore

/// The Constraints Sampler example part: twelve cells, one per constraint, each already satisfied and otherwise free.
@Suite struct ConstraintsSamplerTests {
    private func sketch() throws -> Sketch {
        let doc = CADDocument.constraintsSamplerDemo()
        guard case .sketch(let sf)? = doc.features.first?.kind else { throw CocoaError(.fileReadCorruptFile) }
        return sf.sketch
    }

    @Test func everyConstraintToolAppearsOnceAndTheSketchAlreadyHoldsAllOfThem() throws {
        var s = try sketch()
        var names: [String] = []
        for c in s.constraints {
            switch c.kind {
            case .coincident: names.append("coincident")
            case .pointOnCurve: names.append("pointOnCurve")
            case .horizontal: names.append("horizontal")
            case .vertical: names.append("vertical")
            case .parallel: names.append("parallel")
            case .perpendicular: names.append("perpendicular")
            case .tangent: names.append("tangent")
            case .equal: names.append("equal")
            case .midpoint: names.append("midpoint")
            case .symmetric: names.append("symmetric")
            case .fix: names.append("fix")
            }
        }
        // Concentric is a coincident constraint on two centres, so Coincident shows up twice.
        #expect(names.filter { $0 == "coincident" }.count == 2)
        for n in ["pointOnCurve", "horizontal", "vertical", "parallel", "perpendicular", "tangent", "equal", "midpoint", "symmetric", "fix"] {
            #expect(names.filter { $0 == n }.count == (n == "vertical" ? 2 : 1), "\(n)")
        }
        // The shapes already sit where the constraints want them, so solving moves nothing.
        let before = s.points.map(\.position)
        let r = SketchSolver.solve(&s, dimensionValues: [:])
        #expect(r.status == .solved)
        for (p, old) in zip(s.points, before) { #expect(vlen(p.position - old) < 1e-6, "\(p.id)") }
    }

    @Test func draggingAPointInACellMovesTheRestOfThatCellAndNothingElse() throws {
        var s = try sketch()
        let before = Dictionary(uniqueKeysWithValues: s.points.map { ($0.id, $0.position) })
        // Drag the right end of the horizontal line up: the line stays level, so the left end follows.
        let end = "horizontal-line.b"
        let r = SketchSolver.solve(&s, dimensionValues: [:], soft: [.point(end, SIMD2(before[end]!.x, before[end]!.y + 10))])
        #expect(r.status == .solved)
        #expect(abs(s.point("horizontal-line.a")!.y - s.point(end)!.y) < 1e-6)
        for p in s.points where !p.id.hasPrefix("horizontal") { #expect(vlen(p.position - before[p.id]!) < 1e-6, "\(p.id)") }
    }

    @Test func theFixedPointStaysPutWhenItsLineIsDragged() throws {
        var s = try sketch()
        let origin = s.point("fix-line.a")!.position
        let r = SketchSolver.solve(&s, dimensionValues: [:], soft: [.point("fix-line.b", SIMD2(origin.x + 40, origin.y + 5))])
        #expect(r.status == .solved)
        #expect(vlen(s.point("fix-line.a")!.position - origin) < 1e-6)
    }

    @Test func theSamplerSurvivesSavingAndOpening() throws {
        let doc = CADDocument.constraintsSamplerDemo()
        let back = try CADDocument.decode(try doc.encoded())
        guard case .sketch(let sf)? = back.features.first?.kind else { Issue.record("no sketch"); return }
        #expect(sf.sketch.constraints.count == (try sketch()).constraints.count)
    }
}
