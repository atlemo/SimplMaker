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
}
