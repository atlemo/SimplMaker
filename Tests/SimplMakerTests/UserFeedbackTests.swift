// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import Testing
@testable import SimplMaker

/// Things a user asked for in feedback (2026-11-12): the shortcut key keeps the mode, a size becomes a parameter in one
/// click, Dimension starts with the selected line, and a draw tool's click goes through the dimension labels.
@Suite @MainActor struct UserFeedbackTests {
    @Test func aShortcutKeyFromAnotherToolGoesToTheModeUsedLast() {
        // From Select (or any tool outside the family) the key picks what was used last, not the family's first.
        #expect(SketchTool.forKey("r", current: .select, lastMode: { _ in .centerRectangle }) == .centerRectangle)
        // Pressing it again inside the family still goes on to the next way of drawing.
        #expect(SketchTool.forKey("r", current: .centerRectangle, lastMode: { _ in .centerRectangle }) == .rectangle3Point)
        // And the session remembers the last way: draw with the centre rectangle, switch away, press R.
        let s = SketchSession(featureID: "sk", frame: .xy, sketch: Sketch(), parameters: ParameterValues())
        s.setTool(.centerRectangle)
        s.setTool(.line)
        #expect(SketchTool.forKey("r", current: s.tool, lastMode: s.mode(of:)) == .centerRectangle)
    }

    @Test func aPlainValueCanBecomeAParameter() throws {
        let length = try #require(DocumentModel.parameterSeed(from: " 19,5 ", fallback: .length))
        #expect(length.expression == "19.5 mm" && length.unit == .length)
        let inches = try #require(DocumentModel.parameterSeed(from: "2 in", fallback: .length))
        #expect(inches.expression == "2 in" && inches.unit == .length)
        let angle = try #require(DocumentModel.parameterSeed(from: "30", fallback: .angle))
        #expect(angle.expression == "30 deg" && angle.unit == .angle)
        let count = try #require(DocumentModel.parameterSeed(from: "4", fallback: .none))
        #expect(count.expression == "4" && count.unit == UnitKind.none)
        #expect(DocumentModel.parameterSeed(from: "width / 2", fallback: .length) == nil, "an expression is more than a value")
        #expect(DocumentModel.parameterSeed(from: "width", fallback: .length) == nil)
        #expect(DocumentModel.parameterSeed(from: "", fallback: .length) == nil)

        let model = DocumentModel(document: CADDocument())
        #expect(model.addParameter(from: "26", named: "width") == "width")
        #expect(model.addParameter(from: "18 mm", named: "width") == "width2", "a taken name gets a number")
        #expect(model.addParameter(from: "a+b", named: "width") == nil)
        let p = model.document.parameters.first { $0.name == "width" }
        #expect(p?.expression == "26 mm" && p?.unit == .length)
    }

    @Test func dimensionStartsWithTheSelectedLinePicked() {
        var sk = Sketch()
        sk.addRectangle(0, 0, 20, 10, lineIDs: ["B", "R", "T", "L"])
        let s = SketchSession(featureID: "sk", frame: .xy, sketch: sk, parameters: ParameterValues())
        s.selection = ["B"]
        s.setTool(.dimension)
        #expect(s.pendingLineLength == 20, "the line is already picked: one click on empty space places its length")
        // Two lines selected: nothing is picked for the user.
        s.setTool(.select)
        s.selection = ["B", "L"]
        s.setTool(.dimension)
        #expect(s.pendingLineLength == nil)
    }

    @Test func theOriginCanBePickedInsideAFilledShape() {
        var sk = Sketch()
        sk.addRectangle(-10, -5, 10, 5, lineIDs: ["B", "R", "T", "L"])  // the origin lies in the middle of its fill
        let s = SketchSession(featureID: "sk", frame: .xy, sketch: sk, parameters: ParameterValues())
        s.setTool(.select)
        let uv = SIMD2<Double>(0.1, 0.1)
        _ = s.handle(SketchMouse(phase: .moved, uv: uv, pick: nil, tolerance: 0.5, gridStep: nil))
        _ = s.handle(SketchMouse(phase: .down, uv: uv, pick: nil, tolerance: 0.5, gridStep: nil))
        #expect(s.selection == ["origin"])
    }

    @Test func twoLinesCanHaveTheirMiddlesLinedUp() {
        var sk = Sketch()
        sk.addRectangle(0, 0, 36, 10, lineIDs: ["B1", "R1", "T1", "L1"])
        sk.addRectangle(4, -20, 24, -10, lineIDs: ["B2", "R2", "T2", "L2"])
        let s = SketchSession(featureID: "sk", frame: .xy, sketch: sk, parameters: ParameterValues())
        s.selection = ["B1", "T2"]
        #expect(s.canApply(.midpoint), "two lines: their middles line up")
        #expect(s.apply(.midpoint) == "Midpoint")
        func middleX(_ id: String) -> Double? { s.sketch.lineEnds(id).map { ($0.0.x + $0.1.x) / 2 } }
        let a = middleX("B1"), b = middleX("T2")
        #expect(a != nil && b != nil && abs(a! - b!) < 1e-6, "the middles are on one upright")
        #expect(s.sketch.curves.contains { $0.construction }, "joined by a construction line")
        // A point and a line still does what it did; one line alone has nothing to line up with.
        s.selection = ["B1"]
        #expect(!s.canApply(.midpoint))
    }

    @Test func aConstraintRowSelectsWhatItHolds() throws {
        var sk = Sketch()
        sk.addRectangle(0, 0, 20, 10, lineIDs: ["B", "R", "T", "L"])
        sk.constrain(.parallel("B", "T"))
        let s = SketchSession(featureID: "sk", frame: .xy, sketch: sk, parameters: ParameterValues())
        let c = try #require(s.sketch.constraints.last { $0.kind == .parallel("B", "T") })
        #expect(c.kind.entities == ["B", "T"])
        _ = s.selectConstrained(by: c.id)
        #expect(s.selection == ["B", "T"])
    }
}
