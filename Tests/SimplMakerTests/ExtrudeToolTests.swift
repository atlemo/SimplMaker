// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import CADKernel
import Foundation
import Testing
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
        #expect(model.dragHandles.map(\.label) == ["Distance"])
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
        let h = model.dragHandles
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
        #expect(model.dragHandles.count == 1)
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
}
