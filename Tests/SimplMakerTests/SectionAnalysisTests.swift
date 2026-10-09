// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import CADKernel
import Foundation
import Testing
import simd
@testable import SimplMaker

/// The Section Analysis tool: pick a plane, a face, a sketch or a canvas, slide the cut with the arrow, turn it on and off.
@Suite @MainActor struct SectionAnalysisTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    /// A 20 mm box "a" on the XY plane, a construction plane "p" 30 mm above it, and a sketch "s" on the XZ plane.
    private func loaded() async throws -> DocumentModel {
        var d = CADDocument()
        d.features = [
            Feature(id: "a", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "20 mm", length: "20 mm", height: "20 mm"))),
            Feature(id: "p", name: "Plane1", .plane(PlaneFeature(base: .xy, offset: "30 mm"))),
            Feature(id: "s", name: "Sketch1", .sketch(SketchFeature(plane: .xz, sketch: Sketch()))),
        ]
        let model = DocumentModel(document: d)
        try await settle(model)
        return model
    }

    private func face(_ model: DocumentModel, _ name: String) throws -> PickID {
        let index = try #require(model.meshes.firstIndex { $0.id == "a" })
        return PickID(body: index, face: try #require(model.meshes[index].mesh.faceNames.firstIndex(of: name)))
    }

    private func looking(_ direction: SIMD3<Double>, _ model: DocumentModel) {
        model.clickRay = (SIMD3(0, 0, 100), direction)
    }

    @Test func clickingAPlaneThroughTheFloorOfTheModelCutsHalfwayUp() async throws {
        let model = try await loaded()
        let bounds = try #require(model.sceneBounds)
        model.run(.sectionAnalysis)
        #expect(model.pendingTool == .sectionAnalysis)
        #expect(model.showsOriginPlanes, "the origin planes are offered")
        looking(SIMD3(0, 0, -1), model)  // from above
        model.toolClick(.sectionAnalysis, OriginPlane.xy.pickID)
        let cut = try #require(model.section)
        #expect(cut.source == .origin(.xy) && cut.title == "XY plane" && !cut.flipped)
        #expect(model.pendingTool == nil && model.sectionOn && model.sectionActive)
        // The plane touches the model's bottom, so it goes up to the middle: what is above is cut away.
        let middle = Double(bounds.min.z + bounds.max.z) / 2
        #expect(abs(cut.offset - middle) < 1e-4, "\(cut.offset) vs \(middle)")
        let clip = try #require(model.sectionClip)
        #expect(clip.x == 0 && clip.y == 0 && clip.z == 1 && abs(Double(clip.w) - middle) < 1e-4)
    }

    @Test func cutAwaySideFacesTheViewerWhoClicked() async throws {
        let model = try await loaded()
        looking(SIMD3(0, 0, 1), model)  // from below
        model.beginSection(from: OriginPlane.xy.pickID)
        let cut = try #require(model.section)
        #expect(cut.flipped, "seen from below, the part below the plane goes")
        let clip = try #require(model.sectionClip)
        #expect(clip.z == -1 && clip.w < 0, "everything under the middle: \(clip)")
    }

    @Test func aFaceCutsHalfwayThroughItsBody() async throws {
        let model = try await loaded()
        let bounds = try #require(model.sceneBounds)
        looking(SIMD3(0, 0, -1), model)
        model.beginSection(from: try face(model, "a.top"))
        let cut = try #require(model.section)
        #expect(cut.title == "Face of \(try #require(model.meshes.first { $0.id == "a" }).name)")
        guard case .face(let ref) = cut.source else { Issue.record("a face"); return }
        #expect(ref == FaceRef(body: "a", face: "a.top"))
        let clip = try #require(model.sectionClip)
        #expect(abs(Double(clip.w) - Double(bounds.min.z + bounds.max.z) / 2) < 1e-4)
    }

    @Test func aPlaneThroughTheModelIsLeftWhereItIs() async throws {
        let model = try await loaded()
        // A sketch plane through the middle of the box: the XZ plane cuts it only at its edge, so use a face-centred one.
        let bounds = try #require(model.sceneBounds)
        let source = SectionSource.origin(.yz)
        let inside = bounds.min.x < 0 && bounds.max.x > 0
        model.beginSection(source, title: "YZ plane")
        let cut = try #require(model.section)
        if inside { #expect(cut.offset == 0) } else { #expect(cut.offset != 0) }
    }

    @Test func aSketchOrAConstructionPlaneFromTheBrowserIsAPlaneToo() async throws {
        let model = try await loaded()
        model.run(.sectionAnalysis)
        model.selectedFeature = "p"  // the browser, while the tool waits
        let cut = try #require(model.section)
        #expect(cut.source == .plane("p") && cut.title == "Plane1")
        #expect(model.pendingTool == nil)
        #expect(abs(cut.frame.origin.z - 30) < 1e-6)

        model.chooseSectionPlane()
        #expect(model.pendingTool == .sectionAnalysis && model.selection.isEmpty)
        model.beginSection(feature: "s")
        #expect(model.section?.source == .sketch("s") && model.section?.title == "Sketch1")
        #expect(model.beginSection(feature: "a") == false, "a body is no plane")
    }

    @Test func aPlaneAlreadySelectedCutsAtOnce() async throws {
        let model = try await loaded()
        model.selection = [OriginPlane.xz.pickID]
        model.run(.sectionAnalysis)
        #expect(model.section?.source == .origin(.xz))
        #expect(model.pendingTool == nil && model.selection.isEmpty)
    }

    @Test func aCurvedFaceIsRefusedAndTheToolKeepsWaiting() async throws {
        var d = CADDocument()
        d.features = [Feature(id: "c", name: "Cylinder1", .primitive(PrimitiveFeature(kind: .cylinder, plane: .xy, height: "20", diameter: "10")))]
        let model = DocumentModel(document: d)
        try await settle(model)
        let body = try #require(model.result?.body("c"))
        let round = try #require(body.faceNames.first { (try? body.faceFrame($0)) == nil })
        let index = try #require(model.meshes.firstIndex { $0.id == "c" })
        let pick = PickID(body: index, face: try #require(model.meshes[index].mesh.faceNames.firstIndex(of: round)))
        model.run(.sectionAnalysis)
        model.toolClick(.sectionAnalysis, pick)
        #expect(model.section == nil && model.pendingTool == .sectionAnalysis)
        #expect(model.alert?.title.contains("flat") == true)
    }

    @Test func offsetFlipAndTheSwitch() async throws {
        let model = try await loaded()
        looking(SIMD3(0, 0, -1), model)
        model.beginSection(from: OriginPlane.xy.pickID)
        #expect(model.setSectionOffset(text: "5 mm"))
        #expect(model.section?.offset == 5)
        #expect(model.sectionClip.map { $0.z == 1 && $0.w == 5 } == true)
        #expect(!model.setSectionOffset(text: "deep"), "not a length")
        #expect(model.section?.offset == 5)

        // Flipping keeps the plane and cuts away the other side.
        model.flipSection()
        let flipped = try #require(model.sectionClip)
        #expect(flipped.z == -1 && flipped.w == -5)
        #expect(model.section?.offset == -5)

        // Off: nothing is cut, but the plane is remembered; on again brings it back.
        model.setSectionAnalysis(false)
        #expect(model.sectionClip == nil && model.section != nil && !model.sectionActive)
        var overlay = model.sketchOverlay()
        #expect(overlay.section.isEmpty && !overlay.handle.contains { $0.id == PickID.sectionHandle.raw })
        model.setSectionAnalysis(true)
        #expect(model.sectionClip == flipped)

        overlay = model.sketchOverlay()
        #expect(overlay.section.count == 4, "the plane's border")
        #expect(overlay.handle.count == 2 && overlay.handle.allSatisfy { $0.id == PickID.sectionHandle.raw }, "the arrow: shaft and head")

        model.endSection()
        #expect(model.section == nil && model.sectionClip == nil)
    }

    @Test func turningItOnWithNoPlaneAsksForOne() async throws {
        let model = try await loaded()
        model.setSectionAnalysis(true)
        #expect(model.pendingTool == .sectionAnalysis && model.section == nil)
        #expect(model.toolPrompt?.contains("plane") == true)
        model.cancelTool()
        #expect(model.pendingTool == nil)
    }

    @Test func draggingTheArrowSlidesTheCut() async throws {
        let model = try await loaded()
        looking(SIMD3(0, 0, -1), model)
        model.beginSection(from: OriginPlane.xy.pickID)
        let start = try #require(model.section).offset
        let arrow = try #require(model.sectionArrow())
        #expect(arrow.direction == SIMD3(0, 0, 1))
        // Grab the arrow from the side, then move the pointer 4 mm up the arrow's line.
        let side = SIMD3<Double>(-1, 0, 0)
        model.beginSectionDrag(rayOrigin: arrow.base + SIMD3(100, 0, 0), direction: side)
        model.dragSection(rayOrigin: arrow.base + SIMD3(100, 0, 4), direction: side, snapping: false)
        #expect(abs(try #require(model.section).offset - (start + 4)) < 1e-9)
        model.dragSection(rayOrigin: arrow.base + SIMD3(100, 0, -3), direction: side, snapping: false)
        #expect(abs(try #require(model.section).offset - (start - 3)) < 1e-9, "relative to where it was grabbed, not to the arrow's moving base")
        // Dragging goes in whole millimetres; with snapping off it follows the pointer.
        model.dragSection(rayOrigin: arrow.base + SIMD3(100, 0, 3.3), direction: side, snapping: true)
        let stepped = try #require(model.section).offset
        #expect(abs(stepped - stepped.rounded()) < 1e-9, "a whole number of mm: \(stepped)")
        model.dragSection(rayOrigin: arrow.base + SIMD3(100, 0, 3.3), direction: side, snapping: false)
        #expect(abs(try #require(model.section).offset - (start + 3.3)) < 1e-9)
        model.endSectionDrag()
        #expect(model.sectionDrag == nil)
    }

    @Test func theOffsetReadoutNeverBlocksTheArrow() async throws {
        let model = try await loaded()
        model.beginSection(from: OriginPlane.xy.pickID)
        let labels = model.dimensionLabels()
        #expect(labels.count == 1 && labels[0].text == model.sectionOffsetText)
        #expect(labels[0].passesClicks, "clicks go through it to the arrow")
        #expect(labels[0].outward != nil, "it stands past the arrow's tip")
    }

    @Test func theArrowYieldsToOtherHandlesAndSketching() async throws {
        let model = try await loaded()
        model.beginSection(from: OriginPlane.xy.pickID)
        #expect(model.showsSectionArrow)
        model.selection = [OriginPlane.xz.pickID]
        model.run(.box)
        #expect(!model.showsSectionArrow, "another tool is waiting")
        model.cancelTool()
        #expect(model.showsSectionArrow)
    }

    @Test func theToolIsInTheInspectGroupWithAKey() {
        #expect(DesignTool.inspect.contains(.sectionAnalysis))
        #expect(DesignTool.sectionAnalysis.accepts(.face) && DesignTool.sectionAnalysis.accepts(.plane))
        #expect(DesignTool.sectionAnalysis.accepts(.region) && !DesignTool.sectionAnalysis.accepts(.edge))
        #expect(DesignTool.sectionAnalysis.defaultModifiers == .shift)
    }

    /// The shaders compile and the pipelines build (the renderer makes them when it starts).
    @Test func theRendererBuildsTheCuttingPipelines() throws {
        let renderer = try #require(Renderer())
        renderer.sectionPlane = SIMD4(0, 0, 1, 10)
        #expect(renderer.sectionPlane != nil)
    }
}
