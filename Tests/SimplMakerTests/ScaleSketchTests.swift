// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplMaker

/// Scaling sketches (bodies are in ScaleBodyToolTests): the Scale feature, its tool, its drag handle and what is built after it.
@Suite @MainActor struct ScaleSketchTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    /// A 10 × 5 rectangle with a circle of radius 1 inside it, and a text.
    private func doc(extrudeAfter: Bool = false) -> CADDocument {
        var s = Sketch()
        s.addRectangle(0, 0, 10, 5)
        s.addCircle(center: s.addPoint(5, 2.5), radius: 1)
        var d = CADDocument()
        d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s)))]
        return d
    }

    @Test func scalingGrowsProfilesAndWhatIsBuiltAfterIt() throws {
        var d = doc()
        d.features.append(Feature(id: "s", name: "Scale1", .scale(ScaleFeature(sketches: ["sk"], factor: "2"))))
        var ref: ProfileRef?
        let before = Regenerator.regenerate(d)
        let sk = try #require(before.sketches["sk"])
        // Areas: the rectangle with the hole, and the disc.
        #expect(sk.regions.count == 2)
        let big = try #require(sk.regions.max { $0.area < $1.area })
        #expect(abs(big.area - (4 * (50 - Double.pi))) < 1e-6, "2 × the size = 4 × the area: \(big.area)")
        ref = ProfileRef(curves: big.tags.split(separator: ",").map(String.init), hintU: big.sample.x, hintV: big.sample.y)
        d.features.append(Feature(id: "e", name: "Extrude1", .extrude(ExtrudeFeature(
            sketch: "sk", profiles: [try #require(ref)], extent: .distance("3 mm"), operation: .newBody))))
        let r = Regenerator.regenerate(d)
        #expect(r.errors.isEmpty, "\(r.errors)")
        let body = try #require(r.body("e"))
        #expect(abs(body.volume - 3 * 4 * (50 - Double.pi)) < 1e-4, "\(body.volume)")
        let input = try #require(r.sketchInputs["s"]?["sk"])
        #expect(abs((input.bounds?.max.x ?? 0) - 10) < 1e-6, "the handle starts from the sketch as it was")
    }

    @Test func aFactorMayBeAParameter() throws {
        var d = doc()
        d.parameters = [Parameter("k", "0.5", unit: .none)]
        d.features.append(Feature(id: "s", name: "Scale1", .scale(ScaleFeature(sketches: ["sk"], factor: "k * 3"))))
        let r = Regenerator.regenerate(d)
        let big = try #require(r.sketches["sk"]?.regions.max { $0.area < $1.area })
        #expect(abs(big.area - 2.25 * (50 - Double.pi)) < 1e-6, "\(big.area)")
    }

    @Test func textScalesToo() throws {
        var s = Sketch()
        s.texts.append(SketchText(text: "I", position: s.addPoint(0, 0), height: "10 mm"))
        let scaled = s.scaled(by: 0.5, parameters: ParameterValues())
        #expect(scaled.texts[0].height == "5 mm")
    }

    @Test func aZeroOrMissingFactorIsAnErrorNotACrash() {
        var d = doc()
        d.features.append(Feature(id: "s", name: "Scale1", .scale(ScaleFeature(sketches: ["sk"], factor: "0"))))
        #expect(Regenerator.regenerate(d).errors["s"]?.contains("more than zero") == true)
        d.features[1] = Feature(id: "s", name: "Scale1", .scale(ScaleFeature(sketches: ["gone"], factor: "2")))
        #expect(Regenerator.regenerate(d).errors["s"] != nil)
    }

    @Test func itSurvivesSavingAndDependsOnItsSketch() throws {
        var d = doc()
        d.features.append(Feature(id: "s", name: "Scale1", .scale(ScaleFeature(sketches: ["sk"], factor: "2"))))
        #expect(try CADDocument.decode(try d.encoded()) == d)
        #expect(d.features[1].references.contains("sk"))
    }

    @Test func theScaleToolTakesASketchSelectedInTheBrowser() async throws {
        let model = DocumentModel(document: doc())
        try await settle(model)
        model.selectedFeature = "sk"
        model.run(.scale)
        guard case .scale(let s)? = model.document.features.last?.kind else { Issue.record("expected a scale"); return }
        #expect(s.sketches == ["sk"] && s.factor == "1")
        try await settle(model)
        let h = try #require(model.dragHandle)
        #expect(h.label == "Scale" && h.unit == .none && abs(h.value - 5) < 1e-9, "as long as half the sketch is wide: \(h.value)")
        #expect(model.commitHandle("2"))
        try await settle(model)
        let big = try #require(model.result?.sketches["sk"]?.regions.max { $0.area < $1.area })
        #expect(abs(big.area - 4 * (50 - Double.pi)) < 1e-6)
        #expect(!model.handleSizeProblem("hello", h).map { $0.contains("length") }!, "a plain number, not a length")
    }

    @Test func withNothingSelectedTheToolWaitsForASketch() async throws {
        let model = DocumentModel(document: doc())
        try await settle(model)
        model.selectedFeature = nil
        model.run(.scale)
        #expect(model.pendingTool == .scale && model.toolPrompt == "Click the bodies or sketches to scale")
        #expect(model.document.features.count == 1)
    }

    @Test func rightClickScaleAndUndo() async throws {
        let model = DocumentModel(document: doc())
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        try await settle(model)
        undo.beginUndoGrouping()
        model.scale(sketches: ["sk"])
        undo.endUndoGrouping()
        #expect(model.document.features.count == 2 && model.document.features[1].name == "Scale1")
        undo.undo()
        #expect(model.document.features.count == 1)
    }
}
