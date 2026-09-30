// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplCAD

/// The sketch toolbar's Move, Rotate and Scale.
@Suite @MainActor struct SketchTransformToolTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    /// A model editing a sketch with a free 10 × 4 rectangle, and the sketch's line ids.
    private func editing(constrained: Bool = false) async throws -> (DocumentModel, SketchSession, [EntityID]) {
        var s = Sketch()
        let (lines, corners) = s.addRectangle(20, 20, 30, 24)
        if constrained { s.dimension(.horizontalDistance("origin", corners[0]), "20 mm", id: "x") }
        var d = CADDocument()
        d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s)))]
        let model = DocumentModel(document: d)
        try await settle(model)
        model.editSketch("sk")
        return (model, try #require(model.sketchSession), lines)
    }

    private func committed(_ model: DocumentModel) -> Sketch? {
        if case .sketch(let sf)? = model.document.features.first?.kind { return sf.sketch }
        return nil
    }

    @Test func moveSlidesTheWholeSketchWhenNothingIsSelected() async throws {
        let (model, session, _) = try await editing()
        #expect(session.canTransform && session.transformTargetDescription == "the whole sketch")
        session.beginTransform(.move)
        #expect(session.transformRequested == .move)
        model.sketchCommand { $0.moveSelection(x: "5", y: "-2 mm") }
        #expect(session.transformRequested == nil && session.message == nil)
        let s = try #require(committed(model))
        #expect(s.points.contains { $0.position == SIMD2(25, 18) } && s.points.contains { $0.position == SIMD2(35, 22) })
    }

    @Test func scaleAboutTheSelectionOrTheOrigin() async throws {
        let (model, session, lines) = try await editing()
        session.selection = lines
        #expect(session.transformTargetDescription == "4 selected")
        model.sketchCommand { $0.scaleSelection(factor: "2", about: .selection) }
        var s = try #require(committed(model))
        #expect(s.points.contains { $0.position == SIMD2(15, 18) } && s.points.contains { $0.position == SIMD2(35, 26) })
        model.sketchCommand { $0.scaleSelection(factor: "0.5", about: .origin) }
        s = try #require(committed(model))
        #expect(s.points.contains { $0.position == SIMD2(7.5, 9) })
    }

    @Test func rotateQuarterTurnAboutTheOrigin() async throws {
        let (model, _, _) = try await editing()
        model.sketchCommand { $0.rotateSelection(angle: "90", about: .origin) }
        let s = try #require(committed(model))
        // (20, 20) → (-20, 20): a bare number is degrees.
        #expect(s.points.contains { abs($0.x + 20) < 1e-9 && abs($0.y - 20) < 1e-9 })
    }

    @Test func aTiltThatTheRectanglesConstraintsForbidIsRefused() async throws {
        let (model, session, _) = try await editing()
        let before = try #require(committed(model))
        model.sketchCommand { $0.rotateSelection(angle: "30", about: .selection) }
        #expect(session.message?.contains("horizontal, vertical") == true)
        #expect(committed(model) == before)
        // A quarter turn is fine: horizontal and vertical trade places.
        model.sketchCommand { $0.rotateSelection(angle: "90", about: .selection) }
        let s = try #require(committed(model))
        let xs = s.points.filter { $0.id != "origin" }.map(\.x), ys = s.points.filter { $0.id != "origin" }.map(\.y)
        #expect(abs((xs.max()! - xs.min()!) - 4) < 1e-9 && abs((ys.max()! - ys.min()!) - 10) < 1e-9)
    }

    @Test func badValuesAreRefusedWithAReason() async throws {
        let (model, session, _) = try await editing()
        let before = try #require(committed(model))
        model.sketchCommand { $0.scaleSelection(factor: "0", about: .origin) }
        #expect(session.message?.contains("more than zero") == true)
        model.sketchCommand { $0.scaleSelection(factor: "abc", about: .origin) }
        #expect(session.message != nil)
        model.sketchCommand { $0.moveSelection(x: "0", y: "0") }
        #expect(session.message?.contains("zero") == true)
        model.sketchCommand { $0.rotateSelection(angle: "360", about: .origin) }
        #expect(session.message?.contains("zero") == true)
        #expect(committed(model) == before, "nothing changed")
    }

    @Test func aDimensionThatHoldsTheGeometryStopsTheMove() async throws {
        let (model, session, _) = try await editing(constrained: true)
        let before = try #require(committed(model))
        model.sketchCommand { $0.moveSelection(x: "5", y: "0") }
        #expect(session.message?.contains("Constraints or dimensions") == true)
        #expect(committed(model) == before)
        // Moving along the free direction works; the distance from the origin is only in x.
        model.sketchCommand { $0.moveSelection(x: "0", y: "5") }
        #expect(committed(model)?.points.contains { $0.position == SIMD2(20, 25) } == true)
    }

    @Test func scalingAboutTheOriginTakesTheDimensionsAlong() async throws {
        let (model, _, _) = try await editing(constrained: true)
        model.sketchCommand { $0.scaleSelection(factor: "2", about: .origin) }
        let s = try #require(committed(model))
        #expect(s.points.contains { $0.position == SIMD2(40, 40) })
        #expect(abs(s.dimensionValues(ParameterValues())["x"]! - 40) < 1e-9)
    }

    @Test func aSketchWithNothingInItCantBeTransformed() async throws {
        var d = CADDocument()
        d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: Sketch())))]
        let model = DocumentModel(document: d)
        try await settle(model)
        model.editSketch("sk")
        let session = try #require(model.sketchSession)
        #expect(!session.canTransform)
        session.beginTransform(.move)
        #expect(session.transformRequested == nil)
    }
}
