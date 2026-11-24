// A ring of pattern copies held tangent to each other, through the regenerator and with a parameter driving the size.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import simd
import Testing
@testable import CADKernel

@Suite struct PatternCopyTangentTests {
    static func document(diameter: String) -> CADDocument {
        var s = Sketch()
        let c = s.addPoint(-8, 6)
        s.addCircle(center: c, radius: 2.5, id: "src")
        s.dimension(.diameter("src"), "dia", id: "d")
        s.patterns = [SketchPatternDef(id: "pat", kind: .circular, sources: ["src"], count: "12", angle: "360 deg", center: "origin")]
        s.refreshGenerated(ParameterValues())
        s.constrain(.tangent("src", "pat~11~src"))
        var doc = CADDocument()
        doc.parameters = [Parameter("dia", diameter)]
        doc.features = [Feature(id: "sk", name: "sk", .sketch(SketchFeature(plane: .xy, sketch: s)))]
        return doc
    }

    static func centre(_ s: Sketch, _ id: EntityID) -> SIMD2<Double> {
        guard case .circle(let m, _)? = s.curve(id)?.geometry, let p = s.position(m) else { return .zero }
        return p
    }

    @Test func theRingStaysTangentWhenTheSizeParameterChanges() throws {
        for dia in ["5 mm", "4 mm", "7 mm"] {
            let r = Regenerator.regenerate(Self.document(diameter: dia))
            #expect(r.errors.isEmpty, "\(dia): \(r.errors)")
            let solved = try #require(r.sketches["sk"]).solved
            let d = Double(dia.dropLast(3))!
            #expect(abs(simd_length(Self.centre(solved, "src")) - (d / 2) / sin(Double.pi / 12)) < 1e-6, "\(dia): ring radius")
            for k in 1...10 {
                let gap = simd_length(Self.centre(solved, "pat~\(k)~src") - Self.centre(solved, "pat~\(k + 1)~src"))
                #expect(abs(gap - d) < 1e-6, "\(dia): copy \(k) touches the next")
            }
            // Touching circles also close off the gap in the middle of the ring (and the sliver between neighbours): more regions than circles.
            #expect(try #require(r.sketches["sk"]).regions.count >= 12, "at least the twelve circles")
        }
    }
}
