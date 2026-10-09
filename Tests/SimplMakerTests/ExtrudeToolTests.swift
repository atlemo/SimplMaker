// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import CADKernel
import Foundation
import Testing
import simd
@testable import SimplMaker

/// The Extrude tool's three ways of reaching, chosen from the arrow beside its toolbar button.
@Suite @MainActor struct ExtrudeToolTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    /// A 10 mm square on the XY plane, ready to extrude.
    private func squareModel() async throws -> DocumentModel {
        var s = Sketch()
        let r = s.addRectangle(0, 0, 10, 10, lineIDs: ["A", "B", "C", "D"])
        s.constrain(.fix(r.corners[0], x: 0, y: 0)); s.constrain(.fix(r.corners[2], x: 10, y: 10))
        var d = CADDocument()
        d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s)))]
        let model = DocumentModel(document: d)
        try await settle(model)
        return model
    }

    private func pickProfile(_ model: DocumentModel) throws {
        let slot = try #require(model.sketchSlots.firstIndex(of: "sk")) + 1
        let region = try #require((0..<10).map { PickID(region: $0, slot: slot) }.first { model.profile(of: $0) != nil })
        model.click(region, additive: false)
    }

    @Test func startingAToolFromASketchLeavesTheCameraWhereItIs() async throws {
        let model = try await squareModel()
        model.editSketch("sk")
        model.finishSketch()
        #expect(!model.sketchClosedKeepingView, "closing a sketch by itself turns back to the view it was opened from")
        model.editSketch("sk")
        model.run(.extrude)
        #expect(model.sketchSession == nil && model.sketchClosedKeepingView, "extruding stays put")
    }

    private var extrude: (DocumentModel) -> ExtrudeFeature? {
        { model in
            guard case .extrude(let e)? = model.document.features.last?.kind else { return nil }
            return e
        }
    }

    /// The extruded body's height range along Z.
    private func zRange(_ model: DocumentModel) throws -> ClosedRange<Double> {
        let b = try #require(model.result?.bodies.first?.body.bounds)
        return b.min.z...b.max.z
    }

    @Test func theButtonStartsOneDirection() async throws {
        let model = try await squareModel()
        #expect(model.extrudeMode == .oneDirection)
        model.run(.extrude)
        try pickProfile(model)
        #expect(extrude(model)?.extent == .distance("4 mm"))
        try await settle(model)
        #expect(model.dragHandles.filter { $0.dial == nil }.map(\.label) == ["Distance"])
        let z = try zRange(model)
        #expect(abs(z.lowerBound) < 1e-6 && abs(z.upperBound - 4) < 1e-6, "\(z)")
    }

    @Test func choosingAWayWithAProfilePickedExtrudesThatWay() async throws {
        let model = try await squareModel()
        try pickProfile(model)  // no tool yet: the profile is only selected
        #expect(model.document.features.count == 1)
        model.chooseExtrudeMode(.twoDirections)
        #expect(extrude(model)?.extent == .twoSides("4 mm", back: "2 mm"))
        #expect(model.extrudeMode == .twoDirections, "the button now works that way")
    }

    @Test func twoDirectionsHasAnArrowEachWay() async throws {
        let model = try await squareModel()
        model.chooseExtrudeMode(.twoDirections)  // nothing picked: the tool waits, in that way
        #expect(model.pendingTool == .extrude && model.extrudeMode == .twoDirections)
        try pickProfile(model)
        try await settle(model)
        #expect(model.result?.errors.isEmpty == true, "\(model.result?.errors ?? [:])")
        let z = try zRange(model)
        #expect(abs(z.lowerBound + 2) < 1e-6 && abs(z.upperBound - 4) < 1e-6, "4 up, 2 down: \(z)")
        let h = model.dragHandles.filter { $0.dial == nil }
        #expect(h.map(\.label) == ["Distance 1", "Distance 2"])
        #expect(h[0].direction.z > 0.99 && h[1].direction.z < -0.99, "one arrow each way")
        #expect(h[0].allowsNegative && !h[1].allowsNegative)
    }

    @Test func eachDistanceIsTypedInItsOwnField() async throws {
        let model = try await squareModel()
        model.chooseExtrudeMode(.twoDirections)
        try pickProfile(model)
        try await settle(model)
        #expect(model.handleFieldText(for: 0) == "4 mm" && model.handleFieldText(for: 1) == "2 mm")
        #expect(model.commitHandle("3", slot: 1))
        try await settle(model)
        #expect(extrude(model)?.extent == .twoSides("4 mm", back: "3 mm"))
        #expect(model.commitHandle("7", slot: 0))
        try await settle(model)
        #expect(extrude(model)?.extent == .twoSides("7 mm", back: "3 mm"))
        #expect(!model.commitHandle("0", slot: 1), "the second side can't be zero")
        #expect(!model.commitHandle("-2", slot: 1), "and can't be pulled back through the plane")
        let z = try zRange(model)
        #expect(abs(z.lowerBound + 3) < 1e-6 && abs(z.upperBound - 7) < 1e-6, "\(z)")
    }

    @Test func mirroredReachesHalfEachWay() async throws {
        let model = try await squareModel()
        model.chooseExtrudeMode(.mirrored)
        try pickProfile(model)
        try await settle(model)
        #expect(extrude(model)?.extent == .symmetric("4 mm"))
        let z = try zRange(model)
        #expect(abs(z.lowerBound + 2) < 1e-6 && abs(z.upperBound - 2) < 1e-6, "\(z)")
        #expect(model.dragHandles.filter { $0.dial == nil }.count == 1)
    }

    @Test func changingTheTypeKeepsTheSize() async throws {
        let model = try await squareModel()
        model.run(.extrude)
        try pickProfile(model)
        let id = try #require(model.document.features.last?.id)
        try await settle(model)
        #expect(model.commitHandle("12", slot: 0))
        model.setExtrudeMode(.twoDirections, of: id)
        #expect(extrude(model)?.extent == .twoSides("12 mm", back: "12 mm"), "the second side starts as long as the first")
        model.setExtrudeMode(.mirrored, of: id)
        #expect(extrude(model)?.extent == .symmetric("12 mm"))
        model.setExtrudeMode(.oneDirection, of: id)
        #expect(extrude(model)?.extent == .distance("12 mm"))
    }

    @Test func extentsWithoutASizeHaveNoMode() {
        #expect(ExtrudeExtent.throughAll.mode == nil)
        #expect(ExtrudeExtent.toFace(FaceRef(body: "b", face: "b.top")).mode == nil)
        #expect(ExtrudeExtent.throughAll.changed(to: .twoDirections) == .twoSides("4 mm", back: "4 mm"))
    }

    @Test func parametersWorkInBothDistances() async throws {
        var s = Sketch()
        let r = s.addRectangle(0, 0, 10, 10, lineIDs: ["A", "B", "C", "D"])
        s.constrain(.fix(r.corners[0], x: 0, y: 0)); s.constrain(.fix(r.corners[2], x: 10, y: 10))
        var d = CADDocument()
        d.parameters = [Parameter("up", "8 mm"), Parameter("down", "2 mm")]
        d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s)))]
        let model = DocumentModel(document: d)
        try await settle(model)
        model.chooseExtrudeMode(.twoDirections)
        try pickProfile(model)
        try await settle(model)
        #expect(model.commitHandle("up", slot: 0))
        #expect(model.commitHandle("down", slot: 1))
        try await settle(model)
        #expect(extrude(model)?.extent == .twoSides("up", back: "down"))
        #expect(model.document.features(using: "down").count == 1, "the second side counts as using the parameter")
        #expect(model.result?.errors.isEmpty == true, "\(model.result?.errors ?? [:])")
    }

    // MARK: taper

    private func volume(_ model: DocumentModel) throws -> Double {
        try #require(model.result?.bodies.first?.body.volume)
    }

    @Test func anExtrudeHasATaperDialThatStartsAtZero() async throws {
        let model = try await squareModel()
        model.run(.extrude)
        try pickProfile(model)
        try await settle(model)
        #expect(extrude(model)?.taper == nil)
        let dial = try #require(model.dragHandles.first { $0.dial != nil })
        #expect(dial.slot == DocumentModel.taperSlot && dial.label == "Taper" && dial.unit == .angle)
        #expect(abs(dial.value) < 1e-12 && dial.allowsNegative && dial.allowsZero)
        #expect(abs(dial.base.z - 4) < 1e-6, "the dial hangs on the arrow's tip")
        #expect(abs(simd_dot(dial.direction, dial.dial!.side)) < 1e-9, "its arc is at right angles to its axis")
        #expect(!model.showsField(dial), "no field until the dot is used")
        let v = try volume(model)
        #expect(abs(v - 400) < 1e-6)
    }

    @Test func aTypedAngleTapersTheSides() async throws {
        let model = try await squareModel()
        model.run(.extrude)
        try pickProfile(model)
        try await settle(model)
        #expect(model.commitHandle("-10", slot: DocumentModel.taperSlot))
        try await settle(model)
        #expect(extrude(model)?.taper == "-10 deg")
        #expect(model.result?.errors.isEmpty == true, "\(model.result?.errors ?? [:])")
        // Narrowing: a frustum 4 mm high whose top is 10 − 2·4·tan 10° square.
        let t = tan(10.0 * .pi / 180)
        let top = 10 - 8 * t
        let want = 4 * (100 + 10 * top + top * top) / 3
        let got = try volume(model)
        #expect(abs(got - want) < 1e-6, "\(got) vs \(want)")
        let tapered = try #require(model.dragHandles.first { $0.dial != nil })
        #expect(model.showsField(tapered), "a taper shows its field")
        #expect(model.commitHandle("15", slot: DocumentModel.taperSlot))
        try await settle(model)
        let grown = try volume(model)
        #expect(grown > 400, "positive leans out")
        #expect(model.commitHandle("0", slot: DocumentModel.taperSlot), "zero takes the taper away")
        try await settle(model)
        let straight = try volume(model)
        #expect(abs(straight - 400) < 1e-6)
        #expect(!model.commitHandle("90", slot: DocumentModel.taperSlot) && model.handleProblem != nil, "it can't reach 90°")
        #expect(!model.commitHandle("-86", slot: DocumentModel.taperSlot), "or lean past 85° the other way")
    }

    @Test func draggingTheDotSetsTheAngle() async throws {
        let model = try await squareModel()
        model.run(.extrude)
        try pickProfile(model)
        try await settle(model)
        let dial = try #require(model.dragHandles.first { $0.dial != nil }), arc = try #require(dial.dial)
        model.beginHandleDrag(slot: DocumentModel.taperSlot)
        #expect(model.dialFieldOpen == dial.featureID, "grabbing the dot opens its field")
        // Point the mouse at 20° towards the side, through the arc's plane.
        let a = 20.0 * .pi / 180
        let target = dial.base + arc.radius * (cos(a) * dial.direction + sin(a) * arc.side)
        let pn = simd_normalize(simd_cross(dial.direction, arc.side))
        model.dragHandle(rayOrigin: target + pn * 100, direction: -pn)
        model.endHandleDrag()
        try await settle(model)
        #expect(extrude(model)?.taper == "20 deg", "\(String(describing: extrude(model)?.taper))")
        // Far past the end of the arc stops at 85°; the other side goes negative.
        model.beginHandleDrag(slot: DocumentModel.taperSlot)
        let far = dial.base + arc.radius * 3 * (-arc.side) + dial.direction * 0.1
        model.dragHandle(rayOrigin: far + pn * 100, direction: -pn)
        model.endHandleDrag()
        try await settle(model)
        #expect(extrude(model)?.taper == "-85 deg", "\(String(describing: extrude(model)?.taper))")
    }

    @Test func aClickOnTheDotAsksForItsField() async throws {
        let model = try await squareModel()
        model.run(.extrude)
        try pickProfile(model)
        try await settle(model)
        let before = model.handleFocusRequest
        model.beginHandleDrag(slot: DocumentModel.taperSlot)
        model.endHandleDrag()  // no drag in between
        #expect(model.handleFocusRequest == before + 1 && model.handleFocusSlot == DocumentModel.taperSlot)
        #expect(extrude(model)?.taper == nil, "nothing changed")
    }

    @Test func theDialTurnsToFaceTheCamera() async throws {
        let model = try await squareModel()
        model.run(.extrude)
        try pickProfile(model)
        try await settle(model)
        // Looking along −Y, from the front: the arc is spread along X, to the right of the screen.
        #expect(model.updateDialView(.init(forward: SIMD3(0, 1, 0), right: SIMD3(1, 0, 0), mmPerPoint: 0.1)))
        var arc = try #require(model.dragHandles.first { $0.dial != nil }?.dial)
        #expect(simd_dot(arc.side, SIMD3(1, 0, 0)) > 0.99 && abs(arc.radius - 8) < 1e-9, "\(arc)")
        // From the right, looking along −X: spread along Y, to the right of the screen (which is +Y now).
        #expect(model.updateDialView(.init(forward: SIMD3(-1, 0, 0), right: SIMD3(0, 1, 0), mmPerPoint: 0.1)))
        arc = try #require(model.dragHandles.first { $0.dial != nil }?.dial)
        #expect(simd_dot(arc.side, SIMD3(0, 1, 0)) > 0.99, "\(arc)")
        #expect(!model.updateDialView(.init(forward: SIMD3(-1, 0, 0), right: SIMD3(0, 1, 0), mmPerPoint: 0.1)), "nothing new: no redraw")
    }

    @Test func aTaperSurvivesSavingAndOldFilesLoad() throws {
        var e = ExtrudeFeature(sketch: "sk", profiles: [], extent: .distance("4 mm"))
        e.taper = "-5 deg"
        let back = try JSONDecoder().decode(ExtrudeFeature.self, from: JSONEncoder().encode(e))
        #expect(back.taper == "-5 deg")
        let old = try JSONEncoder().encode(ExtrudeFeature(sketch: "sk", profiles: [], extent: .distance("4 mm")))
        #expect(try JSONDecoder().decode(ExtrudeFeature.self, from: old).taper == nil)
    }
}
