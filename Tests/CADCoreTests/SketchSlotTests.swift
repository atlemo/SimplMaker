// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import simd
import Testing

/// A slot drawn in a sketch keeps its width and centre-to-centre length when the solver is given new values.
@Suite struct SketchSlotTests {
    @Test func aSlotSolvesToItsWidthAndLengthAndStaysRound() {
        var s = Sketch()
        let slot = s.addSlot(from: SketchSnap(SIMD2(0, 0)), to: SketchSnap(SIMD2(20, 3)), width: 8)
        s.dimension(.diameter(slot.ends[0]), "8", id: "w")
        s.dimension(.distance(slot.centers[0], slot.centers[1]), "30", id: "l")
        let r = SketchSolver.solve(&s, dimensionValues: ["w": 8, "l": 30])
        #expect(r.status == .solved)
        for end in slot.ends {
            let radius = s.curve(end).flatMap { s.radius(of: $0) } ?? 0
            #expect(abs(radius - 4) < 1e-6, "both ends are round with the slot's width")
        }
        let a = s.position(slot.centers[0]) ?? .zero, b = s.position(slot.centers[1]) ?? .zero
        #expect(abs(simd_length(b - a) - 30) < 1e-6, "the centers are the typed length apart")
    }

    @Test func aSlotSolvesToANewWidth() {
        var s = Sketch()
        let slot = s.addSlot(from: SketchSnap(SIMD2(0, 0)), to: SketchSnap(SIMD2(20, 0)), width: 8)
        s.dimension(.diameter(slot.ends[0]), "8", id: "w")
        #expect(SketchSolver.solve(&s, dimensionValues: ["w": 12]).status == .solved)
        for end in slot.ends {
            let radius = s.curve(end).flatMap { s.radius(of: $0) } ?? 0
            #expect(abs(radius - 6) < 1e-6)
        }
    }

    @Test func dimensionOfASlotEndAndALineMeasuresFromItsCenter() {
        var s = Sketch()
        let a = s.addPoint(-50, 19), b = s.addPoint(50, 19)
        let line = s.addLine(a, b, construction: true)
        let slot = s.addSlot(from: SketchSnap(SIMD2(0, 0)), to: SketchSnap(SIMD2(20, -27)), width: 12)
        for pick in [[slot.ends[0], line], [line, slot.ends[0]]] {
            let d = s.suggestDimension(for: pick)
            #expect(d?.kind == .pointLineDistance(point: slot.centers[0], line: line))
            #expect(abs((d?.value ?? 0) - 19) < 1e-6)
        }
    }

    /// A circular edge seen edge-on comes into the sketch as a fixed, straight Bézier: a distance to it works like one to a line.
    @Test func aSlotEndCanBeDimensionedToAStraightProjectedBezier() {
        var s = Sketch()
        let ids = [-50.0, -17, 17, 50].map { x -> EntityID in
            let id = s.addPoint(x, 19)
            if let i = s.points.firstIndex(where: { $0.id == id }) { s.points[i].fixed = true }
            return id
        }
        let bez = s.addBezier(start: ids[0], control1: ids[1], control2: ids[2], end: ids[3])
        // The piece of a circle's chain that runs out and back: its ends are the same point, its line still counts.
        let back = s.addPoint(-15, 19), out = s.addPoint(-33, 19)
        for id in [back, out] { if let i = s.points.firstIndex(where: { $0.id == id }) { s.points[i].fixed = true } }
        let loop = s.addBezier(start: back, control1: out, control2: out, end: back)
        #expect(s.isStraightProjectedBezier(loop))
        let slot = s.addSlot(from: SketchSnap(SIMD2(0, 0)), to: SketchSnap(SIMD2(20, -27)), width: 12)
        s.dimension(.diameter(slot.ends[0]), "12", id: "w")
        for pick in [[slot.centers[0], bez], [bez, slot.centers[0]], [slot.ends[0], bez], [bez, slot.ends[0]],
                     [slot.centers[0], loop], [loop, slot.ends[0]]] {
            for d in [s.suggestDimension(for: pick), s.suggestDistance(for: pick).flatMap { pick.contains(slot.centers[0]) ? $0 : nil }] {
                guard let d else { continue }
                #expect(abs(d.value - 19) < 1e-6)
                var t = s
                let applied = t.applyDimension(d.kind, expression: "19", value: 19, values: ["w": 12], id: "d")
                #expect(applied)
                _ = SketchSolver.solve(&t, dimensionValues: ["w": 12, "d": 25])
                #expect(abs((t.position(slot.centers[0])?.y ?? 0) - (19 - 25)) < 1e-6 || abs((t.position(slot.centers[0])?.y ?? 0) - 44) < 1e-6)
            }
        }
        #expect(s.suggestDimension(for: [slot.centers[0], bez]) != nil)
    }
}
