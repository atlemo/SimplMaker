// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import Foundation
import Testing
@testable import SimplMaker

/// The Gear sketch tool: a stored gear drawn by one click, whose fields keep changing it afterwards.
@Suite @MainActor struct GearToolTests {
    private func session(_ params: [Parameter] = []) -> SketchSession {
        SketchSession(featureID: IDs.make(), frame: .xy, sketch: Sketch(), parameters: ParameterEvaluator.evaluate(params))
    }

    private func click(_ s: SketchSession, _ x: Double, _ y: Double) -> String? {
        _ = s.handle(SketchMouse(phase: .moved, uv: SIMD2(x, y), pick: nil))
        let down = s.handle(SketchMouse(phase: .down, uv: SIMD2(x, y), pick: nil))
        let up = s.handle(SketchMouse(phase: .up, uv: SIMD2(x, y), pick: nil))
        return down.commit ?? up.commit
    }

    private func generatedCurves(_ s: SketchSession) -> Int { s.sketch.curves.filter { Sketch.isGenerated($0.id) }.count }

    private func placed(teeth: String? = nil) -> SketchSession {
        let s = session()
        s.setTool(.gear)
        if let teeth { s.setTyped(.teeth, teeth) }
        _ = click(s, 10, 5)
        return s
    }

    @Test func onlyTheGearIsMarkedExperimental() {
        #expect(SketchTool.allCases.filter(\.isExperimental) == [.gear])
        #expect(SketchTool.gear.help.contains("Experimental"))
    }

    @Test func sizeFieldsComeBeforeTheClick() {
        let s = session()
        s.setTool(.gear)
        #expect(s.inputFields == [.teeth, .module, .pressureAngle, .backlash, .bore])
        #expect(s.liveValue(.teeth) == 20 && s.liveValue(.module) == 1.5 && s.liveValue(.bore) == 0)
    }

    @Test func typedValuesBeforeTheClickBecomeTheNextGear() throws {
        let s = session()
        s.setTool(.gear)
        s.setTyped(.teeth, "12")
        s.setTyped(.module, "2")
        s.setTyped(.pressureAngle, "25")
        s.setTyped(.backlash, "0.1")
        s.setTyped(.bore, "6")
        #expect(s.commitTyped() == nil && s.typed.isEmpty, "Return only sets the size")
        #expect(s.liveValue(.teeth) == 12, "the fields show the values again")
        #expect(click(s, 10, 5) == "Gear")
        let spec = try #require(s.activeGear).spec(s.parameters)
        #expect(spec.teeth == 12 && spec.module == 2 && spec.backlash == 0.1 && spec.boreDiameter == 6)
        #expect(abs(spec.pressureAngle - 25 * .pi / 180) < 1e-9)
    }

    @Test func valuesOutOfRangeAreRefusedAndIgnored() {
        let s = session()
        s.setTool(.gear)
        for (field, text) in [(SketchInput.teeth, "3"), (.teeth, "12.5"), (.teeth, "500"), (.module, "0"), (.pressureAngle, "50"), (.bore, "-1")] {
            s.setTyped(field, text)
            #expect(s.typedIsInvalid(field), "\(field) \(text)")
        }
        #expect(s.gearDefaults.teeth == "20" && s.gearDefaults.module == "1.5 mm" && s.gearDefaults.bore == "0 mm")
    }

    @Test func oneClickDrawsAGeneratedGearAroundANewCentre() throws {
        let s = placed(teeth: "16")
        let gear = try #require(s.activeGear)
        #expect(s.sketch.gears == [gear] && gear.ownsCenter)
        #expect(s.sketch.point(gear.center)?.position == SIMD2(10, 5))
        #expect(generatedCurves(s) == 128)
        #expect(s.clicks.isEmpty && s.gearActive == gear.id)
        // Nothing drawn by hand: the only free point is the centre.
        #expect(s.sketch.points.filter { !$0.fixed }.map(\.id) == [gear.center])
    }

    @Test func aGearPlacedOnAnExistingPointUsesItAndLeavesItBehindWhenDeleted() throws {
        let s = session()
        s.setTool(.gear)
        #expect(click(s, 0, 0) == "Gear")
        let gear = try #require(s.activeGear)
        #expect(gear.center == "origin" && !gear.ownsCenter)
        #expect(s.deleteSelection() == "Delete Gear")
        #expect(s.sketch.gears.isEmpty && generatedCurves(s) == 0 && s.sketch.point("origin") != nil)
    }

    @Test func theFieldsKeepChangingTheGearAfterItIsPlaced() throws {
        let s = placed(teeth: "20")
        let before = generatedCurves(s)
        s.setTyped(.teeth, "10")
        #expect(try #require(s.activeGear).spec(s.parameters).teeth == 10)
        #expect(generatedCurves(s) < before, "the outline was made again at once")
        s.setTyped(.module, "3")
        #expect(abs(try #require(s.activeGear).spec(s.parameters).tipRadius - 3 * 6) < 1e-9)
        #expect(s.commitTyped() == "Edit Gear" && s.typed.isEmpty)
        #expect(s.commitTyped() == nil, "nothing more to keep")
        #expect(s.liveValue(.teeth) == 10, "the fields show this gear's values")
    }

    @Test func theNextGearStartsFromTheLastValues() throws {
        let s = placed(teeth: "14")
        s.setTyped(.bore, "4")
        _ = s.commitTyped()
        s.escape()  // done with that gear
        #expect(s.gearActive == nil)
        #expect(click(s, 60, 0) == "Gear")
        let spec = try #require(s.activeGear).spec(s.parameters)
        #expect(spec.teeth == 14 && spec.boreDiameter == 4)
        #expect(s.sketch.gears.count == 2)
    }

    @Test func escTakesBackWhatTheFieldsDid() throws {
        let s = placed(teeth: "20")
        s.setTyped(.teeth, "8")
        #expect(generatedCurves(s) < 160)
        s.clearTyped()  // Esc in a field
        #expect(try #require(s.activeGear).spec(s.parameters).teeth == 20 && generatedCurves(s) == 160)
    }

    @Test func leavingTheToolKeepsWhatWasTyped() throws {
        let s = placed()
        s.setTyped(.teeth, "12")
        #expect(s.keepGearEdit() == "Edit Gear", "the model commits it as an undo step")
        #expect(s.keepGearEdit() == nil)
        #expect(try #require(s.activeGear).spec(s.parameters).teeth == 12)
    }

    @Test func clickingAGearInSelectOpensItAgain() throws {
        let s = placed()
        let id = try #require(s.gearActive)
        s.setTool(.select)
        #expect(s.gearActive == nil)
        let tip = 10 + (try #require(s.activeGear ?? s.sketch.gears.first)).tipRadiusForTest(s.parameters)
        _ = s.handle(SketchMouse(phase: .moved, uv: SIMD2(tip, 5), pick: nil, tolerance: 0.5))
        _ = s.handle(SketchMouse(phase: .down, uv: SIMD2(tip, 5), pick: nil, tolerance: 0.5))
        #expect(s.tool == .gear && s.gearActive == id)
        #expect(s.inputFields.count == 5)
    }

    @Test func aGearThatCannotBeDrawnSaysWhyAndLeavesNothing() {
        let s = session()
        s.setTool(.gear)
        s.setTyped(.bore, "60")
        #expect(click(s, 3, 3) == nil)
        #expect(s.message?.contains("hole") == true)
        #expect(s.sketch.gears.isEmpty && s.sketch.curves.isEmpty && s.sketch.points.count == 1, "not even its centre point")
    }

    @Test func thePreviewFollowsTheCursorUntilAGearIsPlaced() throws {
        let s = session()
        s.setTool(.gear)
        s.setTyped(.bore, "5")
        _ = s.handle(SketchMouse(phase: .moved, uv: SIMD2(30, 0), pick: nil))
        let lines = s.previewPolylines()
        #expect(lines.count == 2, "the outline and the bore")
        #expect(abs((lines[0].map(\.x).max() ?? 0) - (30 + 16.5)) < 0.01)
        _ = click(s, 30, 0)
        #expect(s.previewPolylines().isEmpty, "the placed gear is shown instead")
    }

    @Test func aGearIsNotBuriedInMarksAndLabels() throws {
        let s = placed(teeth: "16")
        #expect(s.referenceMeasurements.isEmpty, "no grey size on each of its curves")
        var o = SketchOverlay()
        SketchOverlayBuilder.editing(s, into: &o)
        #expect(o.points.count == 2, "just the origin and the centre, not 250 points: \(o.points.count)")
        #expect(!o.curves.isEmpty)
        #expect(o.preview.isEmpty, "no Bézier handle lines")
    }
}

private extension SketchGearDef {
    func tipRadiusForTest(_ p: ParameterValues) -> Double { (try? spec(p).tipRadius) ?? 0 }
}
