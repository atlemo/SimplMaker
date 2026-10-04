// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import CADKernel
import Foundation
import Testing
import simd
@testable import SimplMaker

/// The Measure tool: what it reads out for one piece or two, and how clicks drive it.
@Suite @MainActor struct MeasureToolTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    /// Two boxes side by side (a: 20 × 20 × 10 at the origin, b: 10 × 10 × 20 centred 50 mm along X), and two cylinders.
    private func model(_ features: [Feature]) async throws -> DocumentModel {
        var d = CADDocument()
        d.features = features
        let model = DocumentModel(document: d)
        try await settle(model)
        return model
    }

    private static let boxes = [
        Feature(id: "a", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "20", length: "20", height: "10"))),
        Feature(id: "b", name: "Box2", .primitive(PrimitiveFeature(kind: .box, plane: .xy, u: "50", width: "10", length: "10", height: "20"))),
    ]

    private func face(_ model: DocumentModel, _ name: String) throws -> PickID {
        for (body, m) in model.meshes.enumerated() {
            if let i = m.mesh.faceNames.firstIndex(of: name) { return PickID(body: body, face: i) }
        }
        throw MeasureTestError.missing(name)
    }

    private func edge(_ model: DocumentModel, _ body: Int, _ index: Int) -> PickID { PickID(body: body, edge: index) }

    private func value(_ m: MeasureReadout?, _ section: Int, _ label: String) -> String? {
        m?.sections[safe: section]?.rows.first { $0.label == label }?.value
    }

    @Test func clickingAFaceReadsItsSizeAndKeepsTheToolActive() async throws {
        let model = try await model(Self.boxes)
        model.run(.measure)
        #expect(model.pendingTool == .measure && model.measurement == nil)
        #expect(model.measurePrompt().hasPrefix("Click a face"))
        model.toolClick(.measure, try face(model, "a.top"))
        #expect(model.pendingTool == .measure, "stays until it is finished")
        let m = try #require(model.measurement)
        #expect(m.sections.map(\.title) == ["Flat face · Body1"], "with several bodies, the title says which")
        #expect(value(m, 0, "Area") == "400 mm²")
        #expect(value(m, 0, "Perimeter") == "80 mm")
        #expect(value(m, 0, "Size") == "X 20 mm · Y 20 mm")
        #expect(m.labels.map(\.text) == ["400 mm²"])
    }

    @Test func twoFacesReadTheDistanceAndAngleBetweenThem() async throws {
        let model = try await model(Self.boxes)
        model.run(.measure)
        model.toolClick(.measure, try face(model, "a.top"))
        model.toolClick(.measure, try face(model, "a.bottom"))
        var m = try #require(model.measurement)
        #expect(m.sections.map(\.title) == ["Between", "First: Flat face · Body1", "Second: Flat face · Body1"])
        #expect(value(m, 0, "Shortest distance") == "10 mm")
        #expect(value(m, 0, "Angle") == "0° (parallel)")
        #expect(value(m, 0, "Between the planes") == "10 mm")
        #expect(m.line != nil && m.labels.map(\.text) == ["10 mm"])

        model.toolClick(.measure, try face(model, "a.top"))  // a third click starts over
        model.toolClick(.measure, try face(model, "a.left"))
        m = try #require(model.measurement)
        #expect(value(m, 0, "Angle") == "90° (perpendicular)")
        #expect(value(m, 0, "Shortest distance") == "0 mm", "the faces share an edge")
        #expect(m.line == nil, "nothing to draw between faces that touch")
    }

    @Test func clickingAPickedPieceLetsGoOfItAndEmptySpaceClearsAll() async throws {
        let model = try await model(Self.boxes)
        model.run(.measure)
        let top = try face(model, "a.top"), side = try face(model, "a.left")
        model.toolClick(.measure, top)
        model.toolClick(.measure, side)
        #expect(model.selection.count == 2)
        model.toolClick(.measure, top)
        #expect(model.selection == [side])
        model.toolClick(.measure, nil)
        #expect(model.selection.isEmpty && model.measurement == nil)
        #expect(model.pendingTool == .measure)
    }

    @Test func edgesReadLengthAndRoundEdgesReadTheirDiameter() async throws {
        let model = try await model(Self.boxes + [
            Feature(id: "c", name: "Cyl", .primitive(PrimitiveFeature(kind: .cylinder, plane: .xy, u: "-50", height: "20", diameter: "10"))),
        ])
        model.run(.measure)
        let boxEdges = model.meshes[0].mesh.edgeNames.count
        #expect(boxEdges == 12)
        model.toolClick(.measure, edge(model, 0, 0))
        var m = try #require(model.measurement)
        #expect(m.sections.first?.title == "Straight edge · Body1")
        #expect(["20 mm", "10 mm"].contains(value(m, 0, "Length")))

        let cylinder = model.meshes.firstIndex { $0.id == "c" }!
        let circle = try #require(model.meshes[cylinder].mesh.edgeNames.indices.first { i in
            (try? model.result?.body("c")?.measure(.edge(model.meshes[cylinder].mesh.edgeNames[i])))?.geometry == .circle
        })
        model.toolClick(.measure, nil)
        model.toolClick(.measure, edge(model, cylinder, circle))
        m = try #require(model.measurement)
        #expect(m.sections.first?.title == "Circular edge · Body3")
        #expect(value(m, 0, "Diameter") == "10 mm" && value(m, 0, "Radius") == "5 mm")
        #expect(m.labels.map(\.text) == ["Ø 10 mm"])
    }

    @Test func bodiesFromTheBrowserAreMeasuredWholeAndBetweenEachOther() async throws {
        let model = try await model(Self.boxes)
        model.selectBody("a")
        model.run(.measure)
        #expect(model.pendingTool == .measure && model.selection.count == 1, "a body picked beforehand is kept")
        var m = try #require(model.measurement)
        #expect(value(m, 0, "Volume") == "4000 mm³ (4 cm³)")
        #expect(value(m, 0, "Surface area") == "1600 mm²")
        model.selectBody("b")
        m = try #require(model.measurement)
        #expect(m.sections.first?.title == "Between")
        #expect(value(m, 0, "Shortest distance") == "35 mm")
        #expect(m.sections.dropFirst().map(\.title) == ["First: Body · Body1", "Second: Body · Body2"])
    }

    @Test func twoRoundFacesReadTheSpacingBetweenTheirAxes() async throws {
        let model = try await model([
            Feature(id: "c1", name: "Cyl1", .primitive(PrimitiveFeature(kind: .cylinder, plane: .xy, height: "5", diameter: "10"))),
            Feature(id: "c2", name: "Cyl2", .primitive(PrimitiveFeature(kind: .cylinder, plane: .xy, u: "30", height: "5", diameter: "6"))),
        ])
        model.run(.measure)
        model.toolClick(.measure, try face(model, "c1.side"))
        model.toolClick(.measure, try face(model, "c2.side"))
        let m = try #require(model.measurement)
        #expect(value(m, 0, "Axis to axis") == "30 mm")
        #expect(value(m, 0, "Angle") == "0° (parallel)")
        #expect(value(m, 0, "Shortest distance") == "22 mm", "30 between the axes less both radii")
        #expect(value(m, 1, "Diameter") == "10 mm" && value(m, 2, "Diameter") == "6 mm")
    }

    @Test func theViewportDrawsTheLineBetweenTwoPieces() async throws {
        let model = try await model(Self.boxes)
        model.run(.measure)
        model.toolClick(.measure, try face(model, "a.top"))
        #expect(model.sketchOverlay().measure.isEmpty && model.dimensionLabels().map(\.text) == ["400 mm²"])
        model.toolClick(.measure, try face(model, "b.top"))
        let overlay = model.sketchOverlay()
        #expect(overlay.measure.count == 1 && overlay.measurePoints.count == 2)
        #expect(model.dimensionLabels().count == 1)
        model.cancelTool()
        #expect(model.measurement == nil && model.sketchOverlay().measure.isEmpty && model.dimensionLabels().isEmpty)
    }

    @Test func finishingTheToolWithTheToolButtonLeavesNothingHighlightedBehind() async throws {
        let model = try await model(Self.boxes)
        model.run(.measure)
        model.toolClick(.measure, try face(model, "a.top"))
        model.run(.measure)  // pressing it again finishes it
        #expect(model.pendingTool == nil && model.measurement == nil)
    }

    @Test func unitsReadInMillimetresOrInches() {
        let mm = MeasureUnits(), us = MeasureUnits(us: true)
        #expect(mm.length(25.4) == "25.4 mm" && us.length(25.4) == "1 in")
        #expect(mm.area(100) == "100 mm²" && us.area(645.16) == "1 in²")
        #expect(mm.volume(500) == "500 mm³" && mm.volume(12_500) == "12500 mm³ (12.5 cm³)")
        #expect(mm.angle(.pi / 4) == "45°" && mm.length(-0.0001) == "0 mm")
        #expect(mm.point(SIMD3(1, 2.5, -3)) == "(1, 2.5, -3)" && us.point(SIMD3(25.4, 0, 0)) == "(1, 0, 0)")
    }

    @Test func anglesBetweenDirectionsReadBothWaysRound() {
        #expect(MeasureReport.angleText(SIMD3(0, 0, 1), SIMD3(0, 0, -1)) == "0° (parallel)")
        #expect(MeasureReport.angleText(SIMD3(1, 0, 0), SIMD3(0, 5, 0)) == "90° (perpendicular)")
        #expect(MeasureReport.angleText(SIMD3(1, 0, 0), SIMD3(1, 1, 0)) == "45° / 135°")
        #expect(MeasureReport.angleText(.zero, SIMD3(1, 0, 0)) == nil)
    }
}

private enum MeasureTestError: Error { case missing(String) }
