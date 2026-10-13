// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplMaker

/// The sketch toolbar's Mirror: pick what to copy, then the line to mirror across; the image is shown live and kept on Return.
@Suite @MainActor struct SketchMirrorToolTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    /// A sketch with a 10 × 4 rectangle at (20, 20), and a construction line along x = 0 ("guide").
    private func editing() async throws -> (DocumentModel, SketchSession, lines: [EntityID], guide: EntityID) {
        var s = Sketch()
        let (lines, _) = s.addRectangle(20, 20, 30, 24)
        let guide = s.addLine(s.addPoint(0, -10), s.addPoint(0, 40), construction: true)
        var d = CADDocument()
        d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s)))]
        let model = DocumentModel(document: d)
        try await settle(model)
        model.editSketch("sk")
        return (model, try #require(model.sketchSession), lines, guide)
    }

    private func committed(_ model: DocumentModel) -> Sketch? {
        if case .sketch(let sf)? = model.document.features.first?.kind { return sf.sketch }
        return nil
    }

    private func click(_ session: SketchSession, _ id: EntityID) {
        _ = session.handle(SketchMouse(phase: .down, uv: .zero, pick: session.pickID(for: id)))
    }

    @Test func waitsForALineAndShowsNothingUntilThereIsOne() async throws {
        let (model, session, lines, guide) = try await editing()
        session.select(lines[0], additive: false)
        session.beginTransform(.mirror)
        #expect(session.isMirroring && session.mirrorSetup?.sources == [lines[0]] && session.mirrorSetup?.line == "")
        #expect(session.statusText.contains("Click the line to mirror across"))
        let before = session.sketch.curves.count
        #expect(session.commitMirror() == nil && session.message != nil, "Return without a line says what is missing")
        #expect(session.isMirroring && session.sketch.curves.count == before)
        click(session, guide)
        #expect(session.mirrorSetup?.line == guide && session.mirrorLineName == "the construction line")
        #expect(session.sketch.curves.count == before + 1, "the image of the one side")
        #expect(committed(model)?.mirrors.isEmpty == true, "nothing is stored yet")
        try await settle(model)
    }

    @Test func aClickedLineMirrorsTheWholeSketchAndReturnKeepsIt() async throws {
        let (model, session, lines, guide) = try await editing()
        let undo = UndoManager()
        model.undoManager = undo
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        let before = try #require(committed(model))
        session.beginTransform(.mirror)  // nothing selected: all of it
        click(session, guide)
        model.commitSketchTyped()
        undo.endUndoGrouping()
        #expect(!session.isMirroring)
        let s = try #require(committed(model))
        #expect(s.mirrors.count == 1 && s.mirrors[0].line == guide)
        #expect(s.points.contains { $0.position == SIMD2(-30, 20) } && s.points.contains { $0.position == SIMD2(-20, 24) })
        #expect(s.curves.filter { Sketch.isGenerated($0.id) }.count == lines.count, "the guide itself isn't copied")
        undo.undo()
        #expect(committed(model) == before)
        try await settle(model)
    }

    @Test func anAxisButtonChoosesTheAxis() async throws {
        let (model, session, lines, _) = try await editing()
        session.select(lines[0], additive: false)
        session.beginTransform(.mirror)
        session.setMirrorLine(SketchMirrorDef.xAxis)
        #expect(session.mirrorLineName == "the X axis")
        model.commitSketchTyped()
        let s = try #require(committed(model))
        #expect(s.points.contains { Sketch.isGenerated($0.id) && $0.position == SIMD2(20, -20) })
        try await settle(model)
    }

    @Test func aSelectedConstructionLineIsTheMirrorLine() async throws {
        let (model, session, lines, guide) = try await editing()
        session.select(lines[0], additive: false)
        session.select(guide, additive: true)
        session.beginTransform(.mirror)
        #expect(session.mirrorSetup?.line == guide && session.mirrorSetup?.sources == [lines[0]])
        model.commitSketchTyped()
        #expect(committed(model)?.mirrors.first?.sources == [lines[0]])
        try await settle(model)
    }

    @Test func escapeTakesItBackAndKeepsTheSelection() async throws {
        let (model, session, lines, guide) = try await editing()
        let before = try #require(committed(model))
        session.select(lines[1], additive: false)
        session.beginTransform(.mirror)
        click(session, guide)
        session.escape()
        #expect(!session.isMirroring && session.sketch == before && session.selection == [lines[1]])
        #expect(committed(model) == before)
        try await settle(model)
    }

    @Test func clickingAnImageSelectsItLikeAnyCurveAndDoesNotOpenTheMirror() async throws {
        let (model, session, lines, guide) = try await editing()
        session.beginTransform(.mirror)
        click(session, guide)
        model.commitSketchTyped()
        let before = try #require(committed(model))
        let images = session.sketch.curves.filter { Sketch.isGenerated($0.id) }
        #expect(images.count == lines.count)
        click(session, images[0].id)
        #expect(!session.isMirroring, "a click is a pick, not the start of editing")
        #expect(session.selection == [images[0].id])
        _ = session.handle(SketchMouse(phase: .dragged, uv: SIMD2(5, 5)))
        #expect(session.sketch == before, "an image can't be dragged")
        // A second click, as in a double-click, and a click on an original line, change nothing about the mirror.
        click(session, lines[0])
        #expect(!session.isMirroring && session.sketch.mirrors.first?.line == guide)
        try await settle(model)
    }

    @Test func aDoubleClickOnAnImageSelectsItsWholeOutline() async throws {
        let (model, session, _, guide) = try await editing()
        session.beginTransform(.mirror)
        click(session, guide)
        model.commitSketchTyped()
        let images = session.sketch.curves.filter { Sketch.isGenerated($0.id) }.map(\.id)
        click(session, images[0])
        session.selectConnected(additive: false)
        #expect(Set(session.selection) == Set(images), "the four sides of the mirrored rectangle, apart from the original")
        try await settle(model)
    }

    @Test func theMirrorButtonChangesTheMirrorOfTheSelectedImageAndDeleteRemovesIt() async throws {
        let (model, session, lines, guide) = try await editing()
        session.beginTransform(.mirror)
        click(session, guide)
        model.commitSketchTyped()
        let images = session.sketch.curves.filter { Sketch.isGenerated($0.id) }.map(\.id)
        session.select(images[0], additive: false)
        #expect(session.canMirror)
        session.beginTransform(.mirror)
        #expect(session.isMirroring && !session.mirrorIsNew && session.mirrorSetup?.line == guide)
        session.setMirrorLine(SketchMirrorDef.yAxis)
        model.commitSketchTyped()
        #expect(committed(model)?.mirrors.first?.line == SketchMirrorDef.yAxis)

        session.select(try #require(session.sketch.curves.first { Sketch.isGenerated($0.id) }).id, additive: false)
        model.sketchCommand { $0.deleteSelection() }
        #expect(committed(model)?.mirrors.isEmpty == true && committed(model)?.curves.count == lines.count + 1)
        try await settle(model)
    }

    @Test func theHUDsDeleteRemovesTheMirrorBeingChanged() async throws {
        let (model, session, lines, guide) = try await editing()
        session.beginTransform(.mirror)
        click(session, guide)
        model.commitSketchTyped()
        session.select(try #require(session.sketch.curves.first { Sketch.isGenerated($0.id) }).id, additive: false)
        session.beginTransform(.mirror)
        model.commitSketch(session.deleteMirror())
        #expect(committed(model)?.mirrors.isEmpty == true && committed(model)?.curves.count == lines.count + 1)
        try await settle(model)
    }

    @Test func theWholeMirroredShapeCanBeOffsetImageAndAll() async throws {
        let (model, session, lines, guide) = try await editing()
        session.beginTransform(.mirror)
        click(session, guide)
        model.commitSketchTyped()
        let images = session.sketch.curves.filter { Sketch.isGenerated($0.id) }.map(\.id)
        for id in lines + images { session.select(id, additive: true) }
        session.beginOffset()
        #expect(session.isOffsetting && session.offsetProblem == nil, "\(session.offsetProblem ?? "")")
        #expect(session.commitOffset() != nil && session.message == nil, "\(session.message ?? "")")
        let s = try #require(session.sketch)
        #expect(session.solve?.status == .solved)
        #expect(s.mirrors.count == 1 && s.curves.filter { !Sketch.isGenerated($0.id) }.count > lines.count + 1)
        try await settle(model)
    }

    /// The editing sketch with a second construction line, vertical at x = -20, to mirror the first mirror's result across.
    private func mirroredTwiceSetup() async throws -> (DocumentModel, SketchSession, lines: [EntityID], guide: EntityID, vertical: EntityID) {
        var s = Sketch()
        let (lines, _) = s.addRectangle(20, 20, 30, 24)
        let guide = s.addLine(s.addPoint(0, -10), s.addPoint(0, 40), construction: true)
        let vertical = s.addLine(s.addPoint(-20, -10), s.addPoint(-20, 40), construction: true)
        var d = CADDocument()
        d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s)))]
        let model = DocumentModel(document: d)
        try await settle(model)
        model.editSketch("sk")
        return (model, try #require(model.sketchSession), lines, guide, vertical)
    }

    @Test func aShapeThatWasMirroredCanBeMirroredAgainWholeAndItIsKept() async throws {
        let (model, session, lines, guide, vertical) = try await mirroredTwiceSetup()
        session.select(lines[0], additive: false)
        for l in lines.dropFirst() { session.select(l, additive: true) }
        session.beginTransform(.mirror)
        click(session, guide)
        model.commitSketchTyped()
        #expect(committed(model)?.curves.filter { Sketch.isGenerated($0.id) }.count == lines.count)

        // Nothing selected: the whole sketch, the first image included.
        session.selection = []
        session.beginTransform(.mirror)
        #expect(session.mirrorSetup?.sources.contains { Sketch.isGenerated($0) } == true)
        click(session, vertical)
        let shown = session.sketch.curves.filter { $0.id.hasPrefix(session.mirrorSetup!.id + "~") }
        #expect(shown.count >= 2 * lines.count, "both the original and its image are copied: \(shown.count)")
        model.commitSketchTyped()
        let kept = try #require(committed(model))
        #expect(kept.mirrors.count == 2 && kept.curves.contains { $0.id.contains("~") && $0.id.split(separator: "~").count == 3 })
        try await settle(model)
    }

    @Test func leavingTheSketchWhileAMirrorIsOpenKeepsItWhenItHasItsLine() async throws {
        let (model, session, lines, guide, _) = try await mirroredTwiceSetup()
        session.select(lines[0], additive: false)
        session.beginTransform(.mirror)
        click(session, guide)
        #expect(session.isMirroring)
        model.finishSketch()
        let kept = try #require(committed(model))
        #expect(kept.mirrors.count == 1 && kept.mirrors[0].line == guide, "what was shown is what stays")
        try await settle(model)

        // With no line chosen there is nothing to keep, and nothing is left half done.
        model.editSketch("sk")
        let again = try #require(model.sketchSession)
        again.select(lines[1], additive: false)
        again.beginTransform(.mirror)
        model.finishSketch()
        #expect(committed(model)?.mirrors.count == 1)
        try await settle(model)
    }

    @Test func changingTheFirstMirrorsLineKeepsTheSecondOne() async throws {
        let (model, session, lines, guide, vertical) = try await mirroredTwiceSetup()
        session.beginTransform(.mirror)
        click(session, guide)
        model.commitSketchTyped()
        session.beginTransform(.mirror)  // whole sketch again, image included
        click(session, vertical)
        model.commitSketchTyped()
        #expect(committed(model)?.mirrors.count == 2)
        let image = try #require(session.sketch.curves.first { $0.id.hasPrefix(committed(model)!.mirrors[0].id + "~") })
        session.select(image.id, additive: false)
        session.beginTransform(.mirror)  // changes the first
        session.setMirrorLine(SketchMirrorDef.xAxis)
        model.commitSketchTyped()
        let s = try #require(committed(model))
        #expect(s.mirrors.count == 2 && s.mirrors[0].line == SketchMirrorDef.xAxis, "\(s.mirrors.map(\.line))")
        #expect(s.curves.contains { $0.id.split(separator: "~").count == 3 }, "the second still copies the first's image")
        _ = lines
        try await settle(model)
    }

    @Test func aCurvedOrMissingLineIsRefused() async throws {
        var s = Sketch()
        let c = s.addCircle(center: s.addPoint(5, 5), radius: 3)
        let dot = s.addPoint(20, 20)
        var d = CADDocument()
        d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s)))]
        let model = DocumentModel(document: d)
        try await settle(model)
        model.editSketch("sk")
        let session = try #require(model.sketchSession)
        session.select(dot, additive: false)
        session.beginTransform(.mirror)
        click(session, c)
        #expect(session.mirrorSetup?.line == "" && session.message != nil)
        try await settle(model)
    }
}
