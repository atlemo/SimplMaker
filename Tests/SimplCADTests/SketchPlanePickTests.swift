// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import CADKernel
import Testing
@testable import SimplCAD

/// Creating a sketch first asks which plane to draw on.
@Suite @MainActor struct SketchPlanePickTests {
    @Test func sketchButtonAsksForAPlaneAndAClickAnswers() throws {
        let model = DocumentModel()
        #expect(!model.isPickingSketchPlane && model.cursorPrompt == nil)

        model.startSketch()
        #expect(model.isPickingSketchPlane)
        #expect(model.cursorPrompt == "Select a plane or planar face")
        #expect(model.sketchSession == nil && model.document.features.isEmpty)

        // Empty space, an edge or a sketch curve is not an answer.
        model.click(nil, additive: false)
        model.click(PickID(body: 0, edge: 0), additive: false)
        model.click(PickID(sketchCurve: 0), additive: false)
        #expect(model.isPickingSketchPlane && model.sketchSession == nil)

        model.click(OriginPlane.xz.pickID, additive: false)
        #expect(!model.isPickingSketchPlane && model.cursorPrompt == nil)
        let session = try #require(model.sketchSession)
        #expect(session.frame == Frame.xz)
        let feature = try #require(model.document.features.last)
        guard case .sketch(let sf) = feature.kind else { Issue.record("expected a sketch feature"); return }
        #expect(sf.plane == .xz)
        #expect(model.selectedFeature == feature.id)
    }

    @Test func escapeCancelsWithoutCreatingAnything() {
        let model = DocumentModel()
        model.startSketch()
        model.cancelSketchPlanePick()
        #expect(!model.isPickingSketchPlane)
        #expect(model.document.features.isEmpty && model.sketchSession == nil)
        model.cancelSketchPlanePick()  // harmless when not picking
        #expect(!model.isPickingSketchPlane)
    }

    @Test func originPlanesAreOnlyShownWhilePicking() {
        let model = DocumentModel()
        #expect(model.sketchOverlay().planeIndices.isEmpty && model.dimensionLabels().isEmpty)
        model.startSketch()
        let o = model.sketchOverlay()
        #expect(o.planeIndices.count == 18 && o.planeOutline.count == 12)
        #expect(model.dimensionLabels().map(\.id) == OriginPlane.allCases.map(\.labelID))
        model.click(OriginPlane.xy.pickID, additive: false)
        #expect(model.sketchOverlay().planeIndices.isEmpty)
        #expect(!model.dimensionLabels().contains { $0.id.hasPrefix("plane:") })
    }

    @Test func startingWhileSketchingFinishesThatSketchFirst() {
        let model = DocumentModel()
        model.beginSketch(on: .xy)
        #expect(model.sketchSession != nil)
        model.startSketch()
        #expect(model.sketchSession == nil && model.isPickingSketchPlane)
        #expect(model.document.features.count == 1)
    }

    @Test func directMenuItemsSkipThePrompt() {
        let model = DocumentModel()
        model.beginSketch(on: .yz)
        #expect(!model.isPickingSketchPlane && model.sketchSession?.frame == Frame.yz)
    }
}
