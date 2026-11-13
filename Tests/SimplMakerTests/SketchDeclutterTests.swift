// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplMaker

/// Dimension values and constraint symbols on a sketch that is far too small on screen are left out.
@Suite @MainActor struct SketchDeclutterTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    /// Two parallel 20 mm lines, one 20 mm and one 6 mm dimensioned (the other lines are only measured), and an angle between two 6 mm lines.
    private func editing() async throws -> (DocumentModel, SketchSession, long: EntityID, short: EntityID) {
        var s = Sketch()
        let long = s.addLine(s.addPoint(0, 0), s.addPoint(20, 0))
        let long2 = s.addLine(s.addPoint(0, 5), s.addPoint(20, 5))
        let short = s.addLine(s.addPoint(40, 0), s.addPoint(46, 0))
        let short2 = s.addLine(s.addPoint(40, 5), s.addPoint(46, 5))
        s.dimension(.length(long), "20 mm", id: "dl")
        s.dimension(.length(short), "6 mm", id: "ds")
        s.constrain(.parallel(long, long2))
        s.constrain(.parallel(short, short2))
        var d = CADDocument()
        d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s)))]
        let model = DocumentModel(document: d)
        try await settle(model)
        model.editSketch("sk")
        return (model, try #require(model.sketchSession), long, short)
    }

    private func ids(_ session: SketchSession) -> Set<String> { Set(SketchOverlayBuilder.labels(session).map(\.id)) }

    @Test func everythingShowsUntilTheZoomIsKnown() async throws {
        let (model, session, _, _) = try await editing()
        #expect(session.mmPerPixel == 0)
        #expect(ids(session).isSuperset(of: ["dl", "ds"]))
        #expect(!SketchOverlayBuilder.glyphs(session).isEmpty)
        try await settle(model)
    }

    @Test func zoomedOutTheShortOnesGoAndTheLongOnesStay() async throws {
        let (model, session, _, _) = try await editing()
        // 0.12 mm a pixel: 20 mm is 167 px, 6 mm is 50 px: under the 60 a dimension needs.
        #expect(session.setViewScale(mmPerPixel: 0.12))
        let near = ids(session)
        #expect(near.contains("dl") && near.contains("ds") == false, "\(near)")
        // 1 mm a pixel: 20 mm is 20 px: nothing is worth a label.
        session.setViewScale(mmPerPixel: 1)
        #expect(ids(session).isEmpty)
        #expect(SketchOverlayBuilder.glyphs(session).isEmpty, "the parallel symbols are on lines of 20 px and 6 px")
        // Zoomed in again, they all come back.
        session.setViewScale(mmPerPixel: 0.02)
        #expect(ids(session).isSuperset(of: ["dl", "ds"]) && SketchOverlayBuilder.glyphs(session).count == 4)
        try await settle(model)
    }

    @Test func aDimensionBeingChangedOrSelectedStaysWhateverTheZoom() async throws {
        let (model, session, _, _) = try await editing()
        session.setViewScale(mmPerPixel: 2)
        #expect(ids(session).isEmpty)
        session.select("dl", additive: false)
        #expect(ids(session) == ["dl"])
        session.selection = []
        session.editingDimension = "ds"
        #expect(ids(session) == ["ds"])
        try await settle(model)
    }

    @Test func aSelectedConstraintSymbolStays() async throws {
        let (model, session, _, _) = try await editing()
        session.setViewScale(mmPerPixel: 2)
        let constraint = try #require(session.sketch.constraints.first).id
        session.select(constraint, additive: false)
        #expect(SketchOverlayBuilder.glyphs(session).contains { $0.constraint == constraint })
        try await settle(model)
    }

    @Test func theLightMeasuredSizesNeedMoreRoomThanDimensions() async throws {
        let (model, session, long2, _) = try await editing()
        _ = long2
        let measured = session.referenceMeasurements
        #expect(!measured.isEmpty)
        session.setViewScale(mmPerPixel: 0.1)  // the 20 mm lines are 200 px
        let longMeasured = try #require(measured.first { $0.value > 19 })
        #expect(SketchOverlayBuilder.shows(measured: longMeasured, session))
        session.setViewScale(mmPerPixel: 0.25)  // 80 px: enough for a dimension, not for a measured size
        #expect(!SketchOverlayBuilder.shows(measured: longMeasured, session))
        let dl = try #require(session.sketch.dimensions.first { $0.id == "dl" })
        #expect(SketchOverlayBuilder.shows(dl, session))
        try await settle(model)
    }

    @Test func aTinyChangeOfZoomIsNotAChangeAndAnUnknownOneIsIgnored() async throws {
        let (model, session, _, _) = try await editing()
        #expect(session.setViewScale(mmPerPixel: 0.1))
        #expect(!session.setViewScale(mmPerPixel: 0.101) && !session.setViewScale(mmPerPixel: 0) && !session.setViewScale(mmPerPixel: .nan))
        #expect(session.mmPerPixel == 0.1)
        try await settle(model)
    }

    /// A 60 x 40 rectangle with an 8 mm offset inside it: four lines, four offset dimensions.
    private func offsetEditing() async throws -> (DocumentModel, SketchSession, offsets: [EntityID]) {
        var s = Sketch()
        let (a, b, c, d) = (s.addPoint(0, 0), s.addPoint(60, 0), s.addPoint(60, 40), s.addPoint(0, 40))
        let lines = [s.addLine(a, b), s.addLine(b, c), s.addLine(c, d), s.addLine(d, a)]
        _ = s.offset(lines, distance: -8, expression: "8 mm")
        let offsets = s.dimensions.map(\.id)
        #expect(offsets.count == 4)
        var doc = CADDocument()
        doc.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s)))]
        let model = DocumentModel(document: doc)
        try await settle(model)
        model.editSketch("sk")
        return (model, try #require(model.sketchSession), offsets)
    }

    @Test func anOffsetTooShortForItsLabelStaysAsOneLabelAndFourLines() async throws {
        let (model, session, offsets) = try await offsetEditing()
        // 0.5 mm a pixel: the 8 mm offset is 16 px, under the 60 a dimension needs, but enough to draw.
        session.setViewScale(mmPerPixel: 0.5)
        #expect(offsets.allSatisfy { d in session.sketch.dimensions.first { $0.id == d }.map { !SketchOverlayBuilder.shows($0, session) } == true })
        let marks = SketchOverlayBuilder.offsetMarks(session)
        #expect(marks.lines == Set(offsets))
        #expect(marks.labelled.count == 1 && marks.labelled.isSubset(of: marks.lines))
        let labelled = ids(session).intersection(offsets)
        #expect(labelled == marks.labelled, "\(labelled)")
        // 2 mm a pixel: 4 px, nothing to see.
        session.setViewScale(mmPerPixel: 2)
        #expect(SketchOverlayBuilder.offsetMarks(session).lines.isEmpty)
        #expect(ids(session).intersection(offsets).isEmpty)
        // Zoomed in, every offset shows in full and the marks give way.
        session.setViewScale(mmPerPixel: 0.02)
        #expect(SketchOverlayBuilder.offsetMarks(session).lines.isEmpty)
        #expect(ids(session).isSuperset(of: Set(offsets)))
        try await settle(model)
    }

    /// A 10 mm radius quarter arc (about 16 mm long) with six tangent and point constraints on it, beside a 100 mm line.
    @Test func aCurveCrowdedWithSymbolsDropsThemWhenZoomedOutAndNeedsRoomForTheRow() async throws {
        var s = Sketch()
        let line = s.addLine(s.addPoint(0, 0), s.addPoint(100, 0))
        let centre = s.addPoint(0, 10), start = s.addPoint(10, 10), end = s.addPoint(0, 20)
        let arc = s.addArc(center: centre, start: start, end: end)
        for _ in 0..<5 { s.constrain(.tangent(line, arc)) }
        var d = CADDocument()
        d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s)))]
        let model = DocumentModel(document: d)
        try await settle(model)
        model.editSketch("sk")
        let session = try #require(model.sketchSession)
        func onArc() -> Int { SketchOverlayBuilder.glyphs(session).filter { $0.id.hasSuffix("#\(arc)") }.count }
        session.setViewScale(mmPerPixel: 0.02)  // the arc is 800 px
        #expect(onArc() == 5)
        // 0.25 mm a pixel: the arc is 63 px, the five symbols side by side 85: they would hang out over the corner.
        session.setViewScale(mmPerPixel: 0.25)
        #expect(onArc() == 0)
        // The line is 400 px, plenty for its five.
        #expect(SketchOverlayBuilder.glyphs(session).filter { $0.id.hasSuffix("#\(line)") }.count == 5)
        try await settle(model)
    }
}
