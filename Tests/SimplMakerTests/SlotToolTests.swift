// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import Testing
@testable import SimplMaker

/// The Slot sketch tool: two centers and a width draw a stadium. The width is always a dimension (it makes the ends
/// round); the length is dimensioned only when it is typed.
@Suite @MainActor struct SlotToolTests {
    private func session() -> SketchSession {
        SketchSession(featureID: IDs.make(), frame: .xy, sketch: Sketch(), parameters: ParameterEvaluator.evaluate([]))
    }

    private func click(_ s: SketchSession, _ x: Double, _ y: Double) -> String? {
        _ = s.handle(SketchMouse(phase: .moved, uv: SIMD2(x, y), pick: nil))
        let down = s.handle(SketchMouse(phase: .down, uv: SIMD2(x, y), pick: nil))
        let up = s.handle(SketchMouse(phase: .up, uv: SIMD2(x, y), pick: nil))
        return down.commit ?? up.commit
    }

    private func arcs(_ s: SketchSession) -> [SketchCurve] {
        s.sketch.curves.filter { if case .arc = $0.geometry { return true } else { return false } }
    }

    private func diameters(_ s: SketchSession) -> [SketchDimension] {
        s.sketch.dimensions.filter { if case .diameter = $0.kind { return true } else { return false } }
    }

    private func distances(_ s: SketchSession) -> [SketchDimension] {
        s.sketch.dimensions.filter { if case .distance = $0.kind { return true } else { return false } }
    }

    @Test func twoCentersMakeASlotOfTheTypedWidth() {
        let s = session()
        s.setTool(.slot)
        s.setTyped(.width, "8")
        _ = click(s, 0, 0)
        #expect(s.sketch.curves.isEmpty, "the first center alone draws nothing")
        _ = click(s, 20, 0)
        #expect(s.sketch.curves.count == 4, "two sides and two round ends")
        #expect(arcs(s).count == 2)
        for end in arcs(s) {
            #expect(abs((s.sketch.radius(of: end) ?? 0) - 4) < 1e-6, "each end's radius is half the width")
        }
        #expect(diameters(s).count == 1 && diameters(s)[0].expression == s.slotWidth)
        #expect(s.slotWidthValue == 8)
        #expect(distances(s).isEmpty, "the length is not dimensioned unless typed")
    }

    @Test func theWidthIsTenMillimetresUnlessTyped() {
        let s = session()
        s.setTool(.slot)
        #expect(s.slotWidthValue == 10)
        _ = click(s, 0, 0)
        _ = click(s, 20, 0)
        #expect(diameters(s).count == 1 && diameters(s)[0].expression == "10 mm")
    }

    @Test func theWidthIsKeptForTheNextSlot() {
        let s = session()
        s.setTool(.slot)
        s.setTyped(.width, "8")
        _ = click(s, 0, 0)
        _ = click(s, 20, 0)
        _ = click(s, 40, 0)
        _ = click(s, 60, 0)
        #expect(diameters(s).count == 2)
        #expect(diameters(s).allSatisfy { $0.expression == s.slotWidth })
    }

    @Test func aTypedLengthSetsTheDistanceBetweenCenters() {
        let s = session()
        s.setTool(.slot)
        _ = click(s, 0, 0)
        s.setTyped(.length, "30")
        _ = click(s, 20, 0)
        #expect(distances(s).count == 1)
        #expect(distances(s).first?.expression.hasPrefix("30") == true)
    }

    @Test func sameCenterTwiceDrawsNothing() {
        let s = session()
        s.setTool(.slot)
        _ = click(s, 5, 5)
        _ = click(s, 5, 5)
        #expect(s.sketch.curves.isEmpty)
    }

    @Test func typingTheWidthAloneDoesNotPlaceAPoint() {
        let s = session()
        s.setTool(.slot)
        s.setTyped(.width, "6")
        #expect(s.commitTyped() == nil)
        #expect(s.sketch.curves.isEmpty)
        #expect(s.slotWidthValue == 6)
    }

    @Test func previewShowsTheSlotToTheCursor() {
        let s = session()
        s.setTool(.slot)
        s.setTyped(.width, "8")
        _ = click(s, 0, 0)
        _ = s.handle(SketchMouse(phase: .moved, uv: SIMD2(20, 0), pick: nil))
        let points = s.previewPolylines().flatMap { $0 }
        #expect(abs((points.map(\.x).max() ?? 0) - 24) < 1e-6, "the far end reaches 4 mm past the far center")
        #expect(abs((points.map(\.x).min() ?? 0) + 4) < 1e-6, "the near end reaches 4 mm before the first center")
        #expect(abs((points.map(\.y).max() ?? 0) - 4) < 1e-6)
    }

    @Test func overallLengthPlacesTheCentersARadiusInside() {
        let s = session()
        s.setTool(.overallSlot)
        s.setTyped(.width, "10")
        _ = click(s, 0, 0)
        _ = click(s, 36, 0)
        #expect(s.sketch.curves.count == 4)
        #expect(diameters(s).first?.expression == s.slotWidth)
        // The centers are 36 - 10 = 26 mm apart, so the outside of the ends is 36 mm.
        let centers = s.sketch.points.map(\.position).filter { abs($0.y) < 1e-9 }.map(\.x).sorted()
        #expect(centers.contains { abs($0 - 5) < 1e-6 } && centers.contains { abs($0 - 31) < 1e-6 })
    }

    @Test func aTypedOverallLengthIsDimensionedLessTheWidth() {
        let s = session()
        s.setTool(.overallSlot)
        _ = click(s, 0, 0)
        s.setTyped(.length, "36")
        _ = click(s, 20, 0)
        #expect(distances(s).count == 1)
        #expect(distances(s).first?.expression.hasPrefix("(36") == true)
        #expect(distances(s).first?.expression.hasSuffix(") - (\(s.slotWidth))") == true)
    }

    @Test func anOverallLengthShorterThanTheWidthDrawsNothing() {
        let s = session()
        s.setTool(.overallSlot)
        _ = click(s, 0, 0)
        _ = click(s, 8, 0)
        #expect(s.sketch.curves.isEmpty)
        #expect(s.message != nil)
    }

    @Test func overallSlotIsTheOtherModeOfTheSlotKey() {
        #expect(SketchTool.overallSlot.family == [.slot, .overallSlot, .slotCenterPoint, .arcSlot3Point, .arcSlotCenter])
        #expect(SketchTool.forKey("o", current: .slot) == .overallSlot)
        #expect(SketchTool.forKey("o", current: .arcSlotCenter) == .slot, "the last way goes round to the first")
    }

    @Test func previewDrawsTheWholeOutlineIncludingBothSides() throws {
        let s = session()
        s.setTool(.slot)
        _ = click(s, 0, 0)
        _ = s.handle(SketchMouse(phase: .moved, uv: SIMD2(20, 0), pick: nil))
        let outline = try #require(s.previewPolylines().first)
        // The outline closes: its last point is its first, so the side back to the start is drawn too.
        // (A polyline draws only the segments between neighbouring points, so without this the top side is missing.)
        #expect(outline.first == outline.last)
    }
}
