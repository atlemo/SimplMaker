// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import Testing
import simd
@testable import SimplMaker

/// The Twist Sweep tool in the app: made from a picked profile, an arrow for the length and a dial for the turn at the far end,
/// both previewed live as they are dragged or typed.
@Suite @MainActor struct TwistSweepToolTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    /// A 10 × 2 bar on the xy plane (x from -5 to 5), with a twist sweep of it when `sweep` is given.
    private func loaded(sweep: Bool) async throws -> DocumentModel {
        var s = Sketch()
        s.addRectangle(-5, -1, 5, 1)
        var d = CADDocument()
        d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s)))]
        if sweep {
            d.features.append(Feature(id: "tw", name: "Twist Sweep1", .twistSweep(TwistSweepFeature(
                sketch: "sk", profiles: [ProfileRef(curves: [], hintU: 0, hintV: 0)], distance: "30 mm", endAngle: "60 deg"))))
        }
        let model = DocumentModel(document: d)
        try await settle(model)
        return model
    }

    private var twist: (DocumentModel) -> TwistSweepFeature? {
        { model in
            guard case .twistSweep(let t)? = model.document.features.last?.kind else { return nil }
            return t
        }
    }

    @Test func theToolMakesATwistSweepFromAPickedProfile() async throws {
        let model = try await loaded(sweep: false)
        model.run(.twistSweep)
        #expect(model.pendingTool == .twistSweep && model.toolPrompt?.contains("twist") == true)
        let slot = try #require(model.sketchSlots.firstIndex(of: "sk")) + 1
        let region = PickID(region: 0, slot: slot)
        #expect(model.profile(of: region) != nil)
        model.click(region, additive: false)
        try await settle(model)
        let t = try #require(twist(model))
        #expect(t.sketch == "sk" && t.operation == .newBody && t.distance == "20 mm" && t.endAngle == "90 deg")
        #expect(model.result?.errors.isEmpty == true, "\(model.result?.errors ?? [:])")
        #expect(model.isHidden("sk"), "a sketch is hidden once a feature uses it")
        #expect(model.selectedFeature == model.document.features.last?.id && model.handleFocusRequest == 1, "the length field is ready for typing")
        #expect(model.pendingTool == nil)
    }

    @Test func theArrowSetsTheLengthAndTheDialSitsAtTheFarEnd() async throws {
        let model = try await loaded(sweep: true)
        model.selectedFeature = "tw"
        #expect(model.showsDial && model.selectedIsTwist)
        #expect(model.dragHandles.count == 2)
        let arrow = try #require(model.handle(for: "tw", slot: 0))
        #expect(arrow.label == "Length" && abs(arrow.value - 30) < 1e-9 && arrow.dial == nil)
        #expect(simd_length(arrow.direction - SIMD3(0, 0, 1)) < 1e-9 && simd_length(arrow.base) < 1e-6, "from the middle of the profile, up the normal: \(arrow.base)")
        let dialHandle = try #require(model.handle(for: "tw", slot: DocumentModel.taperSlot))
        let dial = try #require(dialHandle.dial)
        #expect(dialHandle.label == "End angle" && dialHandle.unit == .angle && abs(dialHandle.value - 60 * .pi / 180) < 1e-9)
        #expect(abs(dialHandle.base.z - 30) < 1e-6 && abs(dialHandle.base.x) < 1e-6 && abs(dialHandle.base.y) < 1e-6, "round the turning line, at the far end: \(dialHandle.base)")
        #expect(simd_length(dialHandle.direction - SIMD3(1, 0, 0)) < 1e-9 && simd_length(dial.side - SIMD3(0, 1, 0)) < 1e-9)
        #expect(dial.radius > 5, "outside the 10 mm profile: \(dial.radius)")
        #expect(model.featureWithoutHandle == nil)
        // The dot is where the end of the bar has got to.
        let end = dialHandle.anchor
        #expect(abs(simd_length(SIMD2(end.x, end.y)) - dial.radius) < 1e-6)
    }

    @Test func aFlippedSweepGrowsTheOtherWayButTheAngleStillTurnsTheSameWay() async throws {
        let model = try await loaded(sweep: true)
        model.updateFeature("tw", "Flip") { f in
            if case .twistSweep(var t) = f.kind { t.flipped = true; f.kind = .twistSweep(t) }
        }
        try await settle(model)
        model.selectedFeature = "tw"
        let arrow = try #require(model.handle(for: "tw", slot: 0))
        #expect(simd_length(arrow.direction - SIMD3(0, 0, -1)) < 1e-9)
        let dialHandle = try #require(model.handle(for: "tw", slot: DocumentModel.taperSlot))
        #expect(abs(dialHandle.base.z + 30) < 1e-6)
        #expect(simd_length(dialHandle.dial!.side - SIMD3(0, 1, 0)) < 1e-9, "positive is still counter-clockwise about the sketch's normal")
    }

    @Test func typingTheLengthOrTheTurnPreviewsAndStoresIt() async throws {
        let model = try await loaded(sweep: true)
        model.selectedFeature = "tw"
        model.activeHandleSlot = 0
        let before = try #require(model.result?.body("tw")).volume
        #expect(model.previewHandle("45 mm"))
        try await settle(model)
        let shorter = try #require(model.result?.body("tw")).volume
        #expect(shorter > before * 1.4, "the preview is the longer bar: \(shorter) against \(before)")
        #expect(twist(model)?.distance == "30 mm", "nothing is stored until it is accepted")
        #expect(model.commitHandle("45 mm"))
        try await settle(model)
        #expect(twist(model)?.distance == "45 mm")
        model.activeHandleSlot = DocumentModel.taperSlot
        #expect(model.commitHandle("-120 deg"), "the turn can go either way, and past the dial's half turn when typed")
        try await settle(model)
        #expect(twist(model)?.endAngle == "-120 deg")
        #expect(model.result?.errors.isEmpty == true, "\(model.result?.errors ?? [:])")
        #expect(model.commitHandle("9999 deg") == false && model.handleProblem != nil, "but not more than four turns")
    }

    @Test func draggingTheDialPreviewsTheTurnAndLettingGoKeepsIt() async throws {
        let model = try await loaded(sweep: true)
        model.selectedFeature = "tw"
        let dialHandle = try #require(model.handle(for: "tw", slot: DocumentModel.taperSlot))
        model.activeHandleSlot = DocumentModel.taperSlot
        model.beginHandleDrag(slot: DocumentModel.taperSlot)
        // A ray from above the xy plane, through the spot 30° round from the profile's x axis at the dial's radius.
        let r = dialHandle.dial!.radius, a = 30.0 * Double.pi / 180
        let target = dialHandle.base + SIMD3(r * cos(a), r * sin(a), 0)
        model.dragHandle(rayOrigin: target + SIMD3(0, 0, 100), direction: SIMD3(0, 0, -1))
        #expect(abs((model.handlePreviewValue.map { $0 * 180 / .pi } ?? 0) - 30) < 1.0, "\(String(describing: model.handlePreviewValue))")
        try await settle(model)
        #expect(twist(model)?.endAngle == "60 deg", "still the old value while the dot is held")
        model.endHandleDrag()
        try await settle(model)
        #expect(twist(model)?.endAngle == "30 deg", "\(String(describing: twist(model)?.endAngle))")
        #expect(model.result?.errors.isEmpty == true)
    }
}
