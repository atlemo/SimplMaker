// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplMaker

/// The Chamfer tool's three ways of measuring, chosen from the arrow beside its toolbar button.
@Suite @MainActor struct ChamferToolTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    private func boxModel() async throws -> DocumentModel {
        var d = CADDocument()
        d.features = [Feature(id: "b", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "20", length: "20", height: "10")))]
        let model = DocumentModel(document: d)
        try await settle(model)
        return model
    }

    private func pickTop(_ model: DocumentModel) throws {
        let top = try #require(model.meshes.first?.mesh.faceNames.firstIndex(of: "b.top"))
        model.click(PickID(body: 0, face: top), additive: false)
    }

    private var chamfer: (DocumentModel) -> EdgeFeature? {
        { model in
            guard case .chamfer(let e)? = model.document.features.last?.kind else { return nil }
            return e
        }
    }

    /// A 20 × 1.5 × 10 strip: a 1 mm chamfer round its top face leaves nothing between the two long sides (1 + 1 > 1.5).
    private func stripModel() async throws -> DocumentModel {
        var d = CADDocument()
        d.features = [Feature(id: "b", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "20", length: "1.5", height: "10")))]
        let model = DocumentModel(document: d)
        try await settle(model)
        return model
    }

    @Test func aStartingSizeThatDoesNotFitIsMadeSmallerNotRefused() async throws {
        let model = try await stripModel()
        try pickTop(model)
        model.run(.chamfer)
        try await settle(model)
        #expect(model.alert == nil, "no alert: \(String(describing: model.alert?.message))")
        let e = try #require(chamfer(model), "the chamfer is kept")
        #expect(e.size == "0.5 mm", "1 mm did not fit the 1.5 mm strip; half of it does: \(e.size)")
        #expect(model.result?.errors.isEmpty == true)
        #expect(model.handleNote?.text.contains("1 mm didn't fit") == true && model.handleNote?.feature == model.document.features.last?.id)
        #expect(model.dragHandle != nil, "its arrow is there to change the size")
    }

    @Test func aStartingSizeThatFitsIsLeftAlone() async throws {
        let model = try await boxModel()
        try pickTop(model)
        model.run(.chamfer)
        try await settle(model)
        #expect(chamfer(model)?.size == "1 mm" && model.handleNote == nil)
    }

    @Test func theButtonStartsEqualDistance() async throws {
        let model = try await boxModel()
        #expect(model.chamferMode == .equalDistance)
        try pickTop(model)
        model.run(.chamfer)
        let e = try #require(chamfer(model))
        #expect(e.mode == .equalDistance && e.second.isEmpty)
        try await settle(model)
        #expect(model.dragHandles.count == 1)
    }

    @Test func choosingAWayStartsTheToolInThatWay() async throws {
        let model = try await boxModel()
        try pickTop(model)
        model.chooseChamferMode(.twoDistances)
        let e = try #require(chamfer(model))
        #expect(e.mode == .twoDistances && e.size == "1 mm" && e.second == "2 mm")
        #expect(model.chamferMode == .twoDistances, "the button now works that way")
        try await settle(model)
        #expect(model.result?.errors.isEmpty == true, "\(model.result?.errors ?? [:])")
        #expect(model.dragHandles.count == 2, "an arrow for each distance")
        #expect(model.dragHandles.map(\.label) == ["Distance 1", "Distance 2"])
        let h = model.dragHandles
        #expect(abs(h[0].direction.z) < 1e-9, "the first arrow lies along the picked top face: \(h[0].direction)")
        #expect(abs(h[1].direction.z + 1) < 1e-9, "the second goes down the side: \(h[1].direction)")
    }

    @Test func distanceAndAngleHasADistanceArrowAndAnAngleArrow() async throws {
        let model = try await boxModel()
        try pickTop(model)
        model.chooseChamferMode(.distanceAngle)
        let e = try #require(chamfer(model))
        #expect(e.mode == .distanceAngle && e.second == "45 deg")
        try await settle(model)
        #expect(model.result?.errors.isEmpty == true, "\(model.result?.errors ?? [:])")
        let handles = model.dragHandles
        #expect(handles.map(\.label) == ["Distance", "Angle"])
        #expect(handles[1].unit == .angle)
        #expect((handles[1].maxValue ?? 0) < .pi / 2, "the angle stops short of a right angle")
    }

    @Test func theChamferArrowStopsUnderARoundedCornersRadius() async throws {
        var d = CADDocument()
        d.features = [Feature(id: "b", name: "Cylinder1", .primitive(PrimitiveFeature(kind: .cylinder, plane: .xy, height: "10", diameter: "20")))]
        let model = DocumentModel(document: d)
        try await settle(model)
        try pickTop(model)
        model.run(.chamfer)
        try await settle(model)
        let h = try #require(model.dragHandles.first)
        #expect(abs((h.maxValue ?? 0) - 9.99) < 1e-9, "a hair under the 10 mm radius: \(String(describing: h.maxValue))")
        let problem = try #require(model.handleSizeProblem("12", h))
        #expect(problem.contains("at most") && problem.contains("radius"), "\(problem)")
        #expect(model.handleSizeProblem("5", h) == nil)
    }

    @Test func choosingAnotherWayWhileTheToolWaitsOnlyChangesTheWay() async throws {
        let model = try await boxModel()
        model.run(.chamfer)  // nothing picked: it waits for edges
        #expect(model.pendingTool == .chamfer)
        model.chooseChamferMode(.distanceAngle)
        #expect(model.pendingTool == .chamfer && model.chamferMode == .distanceAngle, "still waiting, not finished or cancelled")
        try pickTop(model)
        model.perform(.chamfer, confirmed: true)
        #expect(chamfer(model)?.mode == .distanceAngle)
    }

    @Test func eachSizeIsTypedInItsOwnField() async throws {
        let model = try await boxModel()
        try pickTop(model)
        model.chooseChamferMode(.twoDistances)
        try await settle(model)
        #expect(model.handleFieldText(for: 0) == "1 mm" && model.handleFieldText(for: 1) == "2 mm")
        #expect(model.commitHandle("3", slot: 1))
        try await settle(model)
        #expect(chamfer(model)?.second == "3 mm" && chamfer(model)?.size == "1 mm")
        #expect(model.commitHandle("1.5", slot: 0))
        #expect(chamfer(model)?.size == "1.5 mm")
        // The angle's field takes degrees.
        model.setChamferMode(.distanceAngle, of: try #require(model.document.features.last?.id))
        try await settle(model)
        #expect(model.handleFieldText(for: 1) == "45 deg")
        #expect(model.commitHandle("30", slot: 1))
        #expect(chamfer(model)?.second == "30 deg")
        #expect(!model.commitHandle("90", slot: 1), "a right angle can't be chamfered")
        #expect(model.handleProblem != nil)
    }

    @Test func flipSwapsTheFacesAndOnlyShowsForTheTwoWays() async throws {
        let model = try await boxModel()
        try pickTop(model)
        model.run(.chamfer)
        let id = try #require(model.document.features.last?.id)
        #expect(model.isFlipped(id) == nil, "an equal chamfer has nothing to flip")
        try await settle(model)
        model.setChamferMode(.twoDistances, of: id)
        try await settle(model)
        #expect(model.isFlipped(id) == false)
        model.toggleFlip(id)
        try await settle(model)
        #expect(chamfer(model)?.flipped == true)
        let h = model.dragHandles
        #expect(abs(h[0].direction.z + 1) < 1e-9 && abs(h[1].direction.z) < 1e-9, "the first distance is now down the side")
    }

    @Test func changingTheTypeKeepsTheFirstDistance() async throws {
        let model = try await boxModel()
        try pickTop(model)
        model.run(.chamfer)
        let id = try #require(model.document.features.last?.id)
        try await settle(model)
        #expect(model.commitHandle("2.5", slot: 0))
        model.setChamferMode(.distanceAngle, of: id)
        #expect(chamfer(model)?.size == "2.5 mm" && chamfer(model)?.second == "45 deg")
        model.setChamferMode(.equalDistance, of: id)
        #expect(chamfer(model)?.second == "" && chamfer(model)?.size == "2.5 mm")
    }

    @Test func parametersWorkInBothSizes() async throws {
        var d = CADDocument()
        d.parameters = [Parameter("cut", "2 mm"), Parameter("tilt", "30 deg", unit: .angle)]
        d.features = [Feature(id: "b", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "20", length: "20", height: "10")))]
        let model = DocumentModel(document: d)
        try await settle(model)
        try pickTop(model)
        model.chooseChamferMode(.distanceAngle)
        try await settle(model)
        #expect(model.commitHandle("cut", slot: 0))
        #expect(model.commitHandle("tilt", slot: 1))
        try await settle(model)
        #expect(chamfer(model)?.size == "cut" && chamfer(model)?.second == "tilt")
        #expect(model.result?.errors.isEmpty == true, "\(model.result?.errors ?? [:])")
        #expect(model.document.features(using: "tilt").count == 1, "the angle counts as using the parameter")
        #expect(!model.commitHandle("cut", slot: 1), "a length isn't an angle")
    }
}
