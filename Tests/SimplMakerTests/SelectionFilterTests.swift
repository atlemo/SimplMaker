// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import Testing
@testable import SimplMaker

/// Feedback: select only points or only edges in a sketch (Fusion's selection filter), for clicks, drag-select and Select All.
@Suite @MainActor struct SelectionFilterTests {
    /// A 20 × 10 rectangle from (5, 5), and a loose point at (40, 8).
    private func session() -> SketchSession {
        var s = Sketch()
        s.addRectangle(5, 5, 25, 15, lineIDs: ["B", "R", "T", "L"])
        _ = s.addPoint(40, 8, id: "loose")
        let session = SketchSession(featureID: "sk", frame: .xy, sketch: s, parameters: ParameterValues())
        session.setTool(.select)
        return session
    }

    private func click(_ s: SketchSession, _ x: Double, _ y: Double) {
        let at = SIMD2(x, y)
        _ = s.handle(SketchMouse(phase: .moved, uv: at, pick: nil, tolerance: 0.5, gridStep: nil))
        _ = s.handle(SketchMouse(phase: .down, uv: at, pick: nil, tolerance: 0.5, gridStep: nil))
        _ = s.handle(SketchMouse(phase: .up, uv: at, pick: nil, tolerance: 0.5))
    }

    private let everything: [SIMD2<Double>] = [SIMD2(1, 1), SIMD2(50, 1), SIMD2(50, 30), SIMD2(1, 30)]  // not round the origin

    @Test func aClickKeepsToWhatTheFilterTakes() {
        let s = session()
        click(s, 5.2, 5.2)  // at the corner: the point comes first
        #expect(s.selection.count == 1 && s.sketch.kind(of: s.selection[0]) == .point)
        s.selection = []
        s.selectionFilter = .curves
        click(s, 5.2, 5.2)  // the same click now reaches a line
        #expect(s.selection.count == 1 && s.sketch.kind(of: s.selection[0]) == .line, "\(s.selection)")
        s.selection = []
        s.selectionFilter = .points
        click(s, 15, 5.1)  // the middle of the bottom line: no point there
        #expect(s.selection.isEmpty, "a line is not picked with the Points filter")
        click(s, 40.1, 8.1)
        #expect(s.selection == ["loose"])
    }

    @Test func dragSelectTakesEveryPointWithThePointsFilter() {
        let s = session()
        s.marqueeSelect(everything, crossing: false, additive: false)
        #expect(s.selection.count == 5 && s.selection.allSatisfy { s.sketch.kind(of: $0) == .line || $0 == "loose" }, "all: the lines and the loose point")
        s.selectionFilter = .points
        s.marqueeSelect(everything, crossing: false, additive: false)
        #expect(s.selection.count == 5 && s.selection.allSatisfy { s.sketch.kind(of: $0) == .point }, "points: the four corners and the loose one, not the origin: \(s.selection)")
        #expect(!s.selection.contains("origin"))
        s.selectionFilter = .curves
        s.marqueeSelect(everything, crossing: false, additive: false)
        #expect(s.selection.count == 4 && s.selection.allSatisfy { s.sketch.kind(of: $0) == .line })
    }

    @Test func selectAllFollowsTheFilterAndChangingItDropsWhatItDoesNotTake() {
        let s = session()
        s.selectionFilter = .points
        s.selectEverything()
        #expect(s.selection.count == 5 && s.selection.allSatisfy { s.sketch.kind(of: $0) == .point })
        s.selectionFilter = .curves
        #expect(s.selection.isEmpty, "points are let go when only curves are taken")
        s.selectEverything()
        #expect(s.selection.count == 4)
        s.selectionFilter = .all
        #expect(s.selection.count == 4, "going back to All keeps what is picked")
    }

    @Test func theStatusBarSaysWhatIsBeingPicked() {
        let s = session()
        #expect(!s.statusText.contains("only"))
        s.selectionFilter = .points
        #expect(s.statusText.contains("Selecting points only"), Comment(rawValue: s.statusText))
    }
}
