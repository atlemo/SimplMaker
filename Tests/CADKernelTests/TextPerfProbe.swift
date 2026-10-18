// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import Foundation
import Testing
@testable import CADKernel

/// Prints what extruding a text costs, and how many pairs of letters have boxes that overlap (which makes the
/// kernel merge them). Run with TEXT_PROBE=1 swift test --filter TextPerfProbe.
@Suite struct TextPerfProbe {
    @Test func probe() throws {
        guard ProcessInfo.processInfo.environment["TEXT_PROBE"] != nil else { return }
        let strings = ProcessInfo.processInfo.environment["TEXT_PROBE_TEXT"].map { [$0] }
            ?? ["Hi", "Thread Offset Test", "AVATAR To fi 100%", "Left Hull 17 Rev B"]
        for text in strings {
            var s = Sketch()
            let p = s.addPoint(0, 0)
            s.constrain(.fix(p, x: 0, y: 0))
            s.texts = [SketchText(id: "T", text: text, position: p, height: "10 mm")]
            var d = CADDocument()
            d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s)))]
            let r0 = Regenerator.regenerate(d)
            let sk = try #require(r0.sketches["sk"])
            let t = sk.solved.texts[0]
            let ink = sk.letterRegions(of: t, parameters: r0.parameters)
            // Boxes of the ink regions.
            var boxes: [(lo: SIMD2<Double>, hi: SIMD2<Double>)] = []
            for i in ink {
                let m = sk.regionMeshes[i]
                var lo = SIMD2(Double.infinity, .infinity), hi = SIMD2(-Double.infinity, -Double.infinity)
                for v in stride(from: 0, to: m.positions.count, by: 3) {
                    let q = SIMD2(Double(m.positions[v]), Double(m.positions[v + 1]))
                    lo = pointwiseMin(lo, q); hi = pointwiseMax(hi, q)
                }
                boxes.append((lo, hi))
            }
            var pairs = 0
            for a in boxes.indices { for b in (a + 1)..<max(boxes.count, a + 1) {
                if boxes[a].lo.x <= boxes[b].hi.x + 1e-6 && boxes[b].lo.x <= boxes[a].hi.x + 1e-6
                    && boxes[a].lo.y <= boxes[b].hi.y + 1e-6 && boxes[b].lo.y <= boxes[a].hi.y + 1e-6 { pairs += 1 }
            } }
            d.features.append(Feature(id: "e", name: "Extrude1", .extrude(ExtrudeFeature(
                sketch: "sk", profiles: ink.map { i in
                    let r = sk.regions[i]
                    return ProfileRef(curves: r.tags.split(separator: ",").map(String.init), hintU: r.sample.x, hintV: r.sample.y)
                }, extent: .distance("1 mm")))))
            var times: [Double] = []
            var names = ""
            var volume = 0.0
            for _ in 0..<4 {
                let t0 = Date()
                let r = Regenerator.regenerate(d)
                times.append(Date().timeIntervalSince(t0) * 1000)
                #expect(r.errors.isEmpty, "\(r.errors)")
                if let b = r.body("e") {
                    volume = b.volume
                    names = String(b.faceNames.sorted().joined(separator: ",").utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }, radix: 16)
                }
            }
            print("TEXTPROBE \"\(text)\": \(ink.count) ink regions, \(pairs) overlapping box pairs, ms \(times.map { String(format: "%.0f", $0) }), volume \(volume), digest \(names)")
        }
    }
}
