// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import CADKernel
import Foundation
import simd
import Testing
@testable import SimplMaker

/// The revolve's angle dial: a dot on a circle round the body, just outside its edge, rather than a tangent arrow
/// a full turn long that leaves the body far behind.
@Suite @MainActor struct RevolveDialTests {
    private func loaded(_ doc: CADDocument) async throws -> DocumentModel {
        let model = DocumentModel(document: doc)
        try await settle(model)
        return model
    }

    /// Waits for background rebuilds: a kernel call still running when the test process exits crashes it.
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    private func slot(_ model: DocumentModel, _ sketch: FeatureID) throws -> Int {
        try #require(model.sketchSlots.firstIndex(of: sketch)) + 1
    }

    /// A square on XZ, from 5 to 15 mm out from the Z axis (its construction line), 20 mm tall.
    private func revolveDoc() -> CADDocument {
        var s = Sketch()
        let r = s.addRectangle(5, 0, 15, 20, lineIDs: ["A", "B", "C", "D"])
        s.constrain(.fix(r.corners[0], x: 5, y: 0)); s.constrain(.fix(r.corners[2], x: 15, y: 20))
        let a = s.addPoint(0, 0), b = s.addPoint(0, 30)
        s.constrain(.fix(a, x: 0, y: 0)); s.constrain(.fix(b, x: 0, y: 30))
        s.addLine(a, b, id: "AX", construction: true)
        var doc = CADDocument()
        doc.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xz, sketch: s)))]
        return doc
    }

    /// The square revolved a full turn about the Z axis, with the revolve selected.
    private func revolved() async throws -> DocumentModel {
        let model = try await loaded(revolveDoc())
        let s = try slot(model, "sk")
        model.run(.revolve)
        let profile = try #require((0..<10).map { PickID(region: $0, slot: s) }.first { model.profile(of: $0) != nil })
        model.click(profile, additive: false)
        model.confirmTool()
        try await settle(model)
        return model
    }

    /// A mouse ray (origin, direction) that meets the dial's plane at `angle` round the dot's circle.
    private func ray(_ h: DocumentModel.DragHandle, _ dial: DocumentModel.DragHandle.Dial, _ angle: Double) -> (SIMD3<Double>, SIMD3<Double>) {
        let pn = simd_normalize(simd_cross(h.direction, dial.side))
        let point = h.base + dial.radius * (cos(angle) * h.direction + sin(angle) * dial.side)
        return (point + 50 * pn, -pn)
    }

    /// Drags the dot to `angle` (radians round the circle, from the profile).
    private func drag(_ model: DocumentModel, to angle: Double) throws {
        let h = try #require(model.dragHandle), dial = try #require(h.dial)
        let (o, d) = ray(h, dial, angle)
        model.dragHandle(rayOrigin: o, direction: d)
    }

    @Test func theDotRidesJustOutsideTheBodyNotAFullTurnAway() async throws {
        let model = try await revolved()
        let h = try #require(model.dragHandle)
        let dial = try #require(h.dial)
        #expect(dial.wraps && abs(dial.reach - 2 * .pi) < 1e-9, "the dot goes all the way round")
        #expect(abs(h.value - 2 * .pi) < 1e-9, "a full turn by default")
        #expect(model.showsField(h), "its field shows beside the dot")
        let dot = h.anchor
        let distance = hypot(dot.x, dot.y)
        #expect(distance > 15 && distance < 25, "just outside the 15 mm outer edge: \(dot)")
        #expect(dot.z > 0 && dot.z < 20, "beside the wall, between the body's bottom and top: \(dot)")
    }

    @Test func theDotTurnsRoundFromItsCurrentTurnAndNeverJumpsBackToTheStart() async throws {
        let model = try await revolved()
        model.beginHandleDrag()
        try drag(model, to: -Double.pi / 180)  // a degree short of the start, from the full turn: 359°, not 1°
        #expect(abs((model.handlePreviewValue ?? -1) - (2 * .pi - .pi / 180)) < 1e-6, "\(model.handlePreviewValue ?? -1)")
        try drag(model, to: -3 * Double.pi / 180)  // a little further back
        #expect(abs((model.handlePreviewValue ?? -1) - (2 * .pi - 3 * .pi / 180)) < 1e-6, "\(model.handlePreviewValue ?? -1)")
        model.endHandleDrag()
        try await settle(model)
    }

    @Test func draggingPastTheStartStopsAtAFewDegrees() async throws {
        let model = try await revolved()
        model.beginHandleDrag()
        // Small steps, as a real drag makes them: the dot goes round from the full turn to 90°, then back past the start.
        for step in [-90.0, -180, 90] {
            try drag(model, to: step * .pi / 180)
            #expect(abs((model.handlePreviewValue ?? -1) - (step < 0 ? step + 360 : step) * .pi / 180) < 1e-6,
                    "\(model.handlePreviewValue ?? -1)")
        }
        try drag(model, to: -20 * .pi / 180)  // 110° back past the start: a turn of nothing is no turn
        #expect(abs((model.handlePreviewValue ?? -1) - .pi / 180) < 1e-6, "\(model.handlePreviewValue ?? -1)")
        model.endHandleDrag()
        try await settle(model)
    }
}
