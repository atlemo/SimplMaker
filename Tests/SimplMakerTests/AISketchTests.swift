// Sketches and extrudes made through the AI interface: shapes, dimensions, profiles, and the key ring that needs all of them.
// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplMaker

@Suite @MainActor struct AISketchTests {
    private func open(_ doc: CADDocument = CADDocument()) async -> (rig: AIServiceTests.Rig, service: CADService, id: String, model: DocumentModel, undo: UndoManager) {
        let rig = AIServiceTests.Rig()
        let (id, model) = await rig.open(doc)
        let undo = UndoManager()
        model.undoManager = undo
        return (rig, rig.service, id, model, undo)
    }

    private func pt(_ x: Double, _ y: Double) -> SketchPoint2 {
        SketchPoint2(x: AIValues.number(x) + " mm", y: AIValues.number(y) + " mm")
    }

    private func refusal(_ body: () async throws -> Void) async -> AIError? {
        do { try await body() } catch { return error as? AIError }
        return nil
    }

    /// The area of a stadium (a rectangle `length` × `width` with round ends) with a round hole, times `thickness`.
    private func stadiumPlateVolume(length: Double, width: Double, hole: Double, thickness: Double) -> Double {
        let r = width / 2
        let straight: Double = (length - width) * width
        let ends: Double = Double.pi * r * r
        let bore: Double = Double.pi * (hole / 2) * (hole / 2)
        return (straight + ends - bore) * thickness
    }

    private func volume(_ model: DocumentModel) -> Double { model.result?.bodies.first?.body.volume ?? 0 }

    private func sketch(_ model: DocumentModel, _ id: String) -> SketchResult? { model.result?.sketches[id] }

    @Test func aStadiumWithAHoleExtrudesToTheRightVolume() async throws {
        let t = await open()
        let r = try await t.service.batch(documentID: t.id, expectedRevision: nil, label: "Key ring plate", [
            CreateSketchOperation(plane: "xy", name: "Outline", id: "outline"),
            EditSketchOperation(sketchID: "outline", add: [
                .rectangle(id: "key", center: nil, corner: nil, width: "35", height: "15", cornerRadius: "7.5"),
                .circle(id: "hole", center: pt(-12, 0), diameter: "4", radius: nil),
            ]),
            CreateExtrudeOperation(sketchID: "outline", profiles: [.at(pt(10, 0))], distance: "3", direction: .forward,
                                   operation: .newBody, target: nil, startFace: nil, name: "Plate", id: "plate"),
        ])
        #expect(r.steps.count == 3 && r.success)
        #expect(t.model.result?.errors.isEmpty == true, "\(t.model.result?.errors ?? [:])")
        let expected = stadiumPlateVolume(length: 35, width: 15, hole: 4, thickness: 3)
        #expect(abs(volume(t.model) - expected) < 0.5, "\(volume(t.model)) vs \(expected)")
        #expect(t.undo.undoActionName == "AI: Key ring plate")
        t.undo.undo()
        #expect(t.model.document.features.isEmpty, "the three steps are one Undo")
    }

    @Test func shapesCarryNamedDimensionsThatCanBeEditedLater() async throws {
        let t = await open()
        _ = try await t.service.batch(documentID: t.id, expectedRevision: nil, label: nil, [
            CreateSketchOperation(plane: nil, name: nil, id: "s"),
            EditSketchOperation(sketchID: "s", add: [
                .rectangle(id: "key", center: nil, corner: nil, width: "35", height: "15", cornerRadius: "7.5"),
                .circle(id: "hole", center: pt(-12, 0), diameter: "4", radius: nil),
            ]),
            CreateExtrudeOperation(sketchID: "s", profiles: [.at(pt(10, 0))], distance: "3", direction: .forward, operation: .newBody,
                                   target: nil, startFace: nil, name: nil, id: "plate"),
        ])
        let d = try await t.service.getFeature(documentID: t.id, featureID: "s")
        #expect(d.editable.contains("key.width") && d.editable.contains("key.height"))
        #expect(d.editable.contains("hole.diameter") && d.editable.contains("hole.x") && d.editable.contains("key.x"))
        let sk = try #require(d.sketch)
        #expect(sk.degreesOfFreedom == 0, "fully constrained: \(sk.degreesOfFreedom ?? -1)")
        // "Make it 45 long and the hole 5."
        let r = try await t.service.modifyFeature(documentID: t.id, featureID: "s", settings: ["key.width": 45, "hole.diameter": 5], unlink: false)
        #expect(r.changes.map(\.field) == ["hole.diameter", "key.width"])
        #expect(abs(volume(t.model) - stadiumPlateVolume(length: 45, width: 15, hole: 5, thickness: 3)) < 0.5)
        let expected = stadiumPlateVolume(length: 45, width: 15, hole: 5, thickness: 3)
        #expect(abs(volume(t.model) - expected) < 0.5, "\(volume(t.model)) vs \(expected)")
        #expect(r.sketch?.profiles.isEmpty == false, "the answer shows the sketch's profiles")
    }

    // MARK: shapes

    /// Makes a sketch with the shapes and returns its profiles.
    private func draw(_ shapes: [SketchShape], on plane: String? = nil, in t: (rig: AIServiceTests.Rig, service: CADService, id: String, model: DocumentModel, undo: UndoManager),
                      sketchID: String = "s") async throws -> SketchInfo {
        let r = try await t.service.batch(documentID: t.id, expectedRevision: nil, label: nil, [
            CreateSketchOperation(plane: plane, name: nil, id: sketchID), EditSketchOperation(sketchID: sketchID, add: shapes)])
        return try #require(r.steps[1].sketch)
    }

    @Test func plainShapesMakeTheProfilesTheyShould() async throws {
        let t = await open()
        let rect = try await draw([.rectangle(id: nil, center: pt(5, 5), corner: nil, width: "30", height: "20", cornerRadius: nil)], in: t, sketchID: "a")
        #expect(rect.profiles.count == 1 && abs(rect.profiles[0].area - 600) < 1e-6)
        #expect(rect.profiles[0].bounds == [-10, -5, 20, 15], "centred on (5, 5): \(rect.profiles[0].bounds)")
        #expect(rect.degreesOfFreedom == 0)

        let circle = try await draw([.circle(id: "c", center: pt(0, 0), diameter: nil, radius: "5")], in: t, sketchID: "b")
        #expect(abs(circle.profiles[0].area - .pi * 25) < 0.05)
        #expect(circle.dimensions.map(\.id).contains("c.radius"))

        let hexagon = try await draw([.polygon(id: nil, center: pt(0, 0), radius: "10", sides: 6, rotation: nil)], in: t, sketchID: "c")
        #expect(abs(hexagon.profiles[0].area - 6 * 0.5 * 100 * sin(.pi / 3)) < 0.05, "\(hexagon.profiles[0].area)")

        let triangle = try await draw([.polyline(id: "tri", points: [pt(0, 0), pt(10, 0), pt(0, 6)], closed: true)], in: t, sketchID: "d")
        #expect(abs(triangle.profiles[0].area - 30) < 1e-6)

        // A half disc: an arc over a line.
        let half = try await draw([.arc(id: "top", from: pt(10, 0), through: pt(0, 10), to: pt(-10, 0)),
                                   .line(id: "base", from: pt(-10, 0), to: pt(10, 0))], in: t, sketchID: "e")
        #expect(half.profiles.count == 1 && abs(half.profiles[0].area - .pi * 50) < 0.1, "\(half.profiles.map(\.area))")
    }

    @Test func aRoundedRectangleKeepsItsSizesAndExtrudesRight() async throws {
        let t = await open()
        _ = try await draw([.rectangle(id: "r", center: nil, corner: nil, width: "40", height: "20", cornerRadius: "4")], in: t)
        _ = try await t.service.createExtrude(documentID: t.id, sketchID: "s", profiles: [.at(pt(0, 0))], distance: "5")
        // 40 × 20 minus four corners, each 4² − π·4²/4.
        let corner: Double = 16 - Double.pi * 16 / 4
        let expected: Double = (800 - 4 * corner) * 5
        #expect(abs(volume(t.model) - expected) < 0.5, "\(volume(t.model)) vs \(expected)")
    }

    @Test func aCornerRadiusThatIsTooBigIsRefusedWithTheLimit() async throws {
        let t = await open()
        let e = await refusal { _ = try await self.draw([.rectangle(id: nil, center: nil, corner: nil, width: "40", height: "20", cornerRadius: "11")], in: t) }
        #expect(e?.code == .invalidValue && e?.message.contains("too large") == true && e?.reason?.contains("10 mm") == true, "\(e?.message ?? "")")
        #expect(t.model.document.features.isEmpty, "the sketch that was created in the same step is gone too")
    }

    @Test func aPositionAtTheOriginOrOnTheNegativeSideKeepsItsSide() async throws {
        let t = await open()
        let info = try await draw([.circle(id: "left", center: pt(-12, 0), diameter: "4", radius: nil),
                                   .circle(id: "low", center: pt(0, -7), diameter: "2", radius: nil)], in: t)
        let left = try #require(t.model.result?.sketches["s"]?.solved.points.first { abs($0.x + 12) < 1e-6 && abs($0.y) < 1e-6 })
        #expect(left.x == -12)
        let low = try #require(t.model.result?.sketches["s"]?.solved.points.first { abs($0.x) < 1e-6 && abs($0.y + 7) < 1e-6 })
        #expect(low.y == -7)
        #expect(info.dimensions.first { $0.id == "left.x" }?.field == .quantity(expression: "12 mm", value: 12, unit: "mm"), "a distance has no sign")
    }

    @Test func positionsAndSizesCanUseParameters() async throws {
        var doc = CADDocument()
        doc.parameters = [Parameter("w", "30 mm"), Parameter("t", "2 mm")]
        let t = await open(doc)
        _ = try await draw([.rectangle(id: "p", center: nil, corner: nil, width: "w", height: "w / 2", cornerRadius: nil)], in: t)
        _ = try await t.service.createExtrude(documentID: t.id, sketchID: "s", profiles: [.at(pt(0, 0))], distance: "t")
        #expect(abs(volume(t.model) - 30 * 15 * 2) < 1e-3)
        _ = try await t.service.setParameter(documentID: t.id, name: "w", value: .int(40), unit: nil, comment: nil)
        #expect(abs(volume(t.model) - 40 * 20 * 2) < 1e-3, "the sketch and the extrude both followed the parameter")
    }

    // MARK: text

    @Test func textBecomesProfilesAndCanBeCentred() async throws {
        let t = await open()
        let info = try await draw([.text(id: "name", text: "Jane Doe", at: pt(0, 0), height: "5", font: nil, angle: nil, centered: true)], in: t)
        #expect(info.profiles.count >= 7, "a region for each letter (and each counter): \(info.profiles.count)")
        let all = info.profiles.map(\.bounds).filter { $0.count == 4 }
        let minX = all.map { $0[0] }.min() ?? 0, maxX = all.map { $0[2] }.max() ?? 0
        #expect(abs((minX + maxX) / 2) < 0.6, "centred on x = 0: \(minX) … \(maxX)")
        let width = maxX - minX
        #expect(width > 18 && width < 40, "a 5 mm cap height name is about 25 mm wide: \(width)")
        #expect(info.dimensions.map(\.id).sorted() == ["name.x", "name.y"])
        #expect(info.degreesOfFreedom == 0)
        // Changing the height scales it.
        let r = try await t.service.modifyFeature(documentID: t.id, featureID: "s", settings: ["name.height": 10], unlink: false)
        let big = r.sketch?.profiles.compactMap { $0.bounds.count == 4 ? $0.bounds : nil } ?? []
        let bigWidth = (big.map { $0[2] }.max() ?? 0) - (big.map { $0[0] }.min() ?? 0)
        #expect(abs(bigWidth - 2 * width) < 1.5, "\(bigWidth) vs \(2 * width)")
    }

    @Test func badTextIsRefused() async throws {
        let t = await open()
        for text in ["", "   ", String(repeating: "x", count: 201)] {
            let e = await refusal { _ = try await self.draw([.text(id: nil, text: text, at: pt(0, 0), height: "5", font: nil, angle: nil, centered: false)], in: t) }
            #expect(e?.code == .invalidArguments, "\(text.count)")
        }
    }

    // MARK: refusals

    @Test func badShapesAreRefusedWithAReason() async throws {
        let t = await open()
        func problem(_ shape: SketchShape) async -> AIError? { await refusal { _ = try await self.draw([shape], in: t) } }
        #expect(await problem(.circle(id: nil, center: pt(0, 0), diameter: nil, radius: nil))?.code == .invalidArguments)
        #expect(await problem(.circle(id: nil, center: pt(0, 0), diameter: "4", radius: "2"))?.code == .invalidArguments)
        #expect(await problem(.circle(id: nil, center: pt(0, 0), diameter: "-4", radius: nil))?.code == .invalidValue)
        #expect(await problem(.rectangle(id: nil, center: nil, corner: nil, width: "0", height: "5", cornerRadius: nil))?.code == .invalidValue)
        #expect(await problem(.polygon(id: nil, center: pt(0, 0), radius: "5", sides: 2, rotation: nil))?.code == .invalidArguments)
        #expect(await problem(.polyline(id: nil, points: [pt(0, 0)], closed: false))?.code == .invalidArguments)
        #expect(await problem(.polyline(id: nil, points: [pt(0, 0), pt(1, 0)], closed: true))?.code == .invalidArguments)
        #expect(await problem(.polyline(id: nil, points: [pt(0, 0), pt(0, 0), pt(1, 1)], closed: false))?.code == .invalidValue)
        #expect(await problem(.line(id: nil, from: pt(1, 1), to: pt(1, 1)))?.code == .invalidValue)
        #expect(await problem(.arc(id: nil, from: pt(0, 0), through: pt(1, 1), to: pt(2, 2)))?.message.contains("straight line") == true)
        #expect(await problem(.circle(id: "bad id", center: pt(0, 0), diameter: "4", radius: nil))?.code == .invalidArguments)
        #expect(await problem(.circle(id: "origin", center: pt(0, 0), diameter: "4", radius: nil))?.code == .invalidArguments)
        let unknown = await refusal { _ = try await t.service.batch(documentID: t.id, expectedRevision: nil, label: nil,
                                                                    [EditSketchOperation(sketchID: "nope", add: [.circle(id: nil, center: pt(0, 0), diameter: "4", radius: nil)])]) }
        #expect(unknown?.code == .featureNotFound)
        #expect(t.model.document.features.isEmpty)
    }

    @Test func idsAreNotReusedWithinASketch() async throws {
        let t = await open()
        _ = try await draw([.circle(id: "hole", center: pt(0, 0), diameter: "4", radius: nil)], in: t)
        let e = await refusal { _ = try await t.service.batch(documentID: t.id, expectedRevision: nil, label: nil,
                                                              [EditSketchOperation(sketchID: "s", add: [.circle(id: "hole", center: pt(5, 5), diameter: "2", radius: nil)])]) }
        #expect(e?.code == .invalidArguments && e?.message.contains("already used") == true)
        // Made-up ids count up.
        let r = try await t.service.batch(documentID: t.id, expectedRevision: nil, label: nil,
                                          [EditSketchOperation(sketchID: "s", add: [.circle(id: nil, center: pt(9, 0), diameter: "1", radius: nil),
                                                                                     .circle(id: nil, center: pt(12, 0), diameter: "1", radius: nil)])])
        let ids = r.steps[0].created?["shapes"]?.array?.compactMap { $0["id"]?.string }
        #expect(ids == ["circle1", "circle2"])
    }

    // MARK: extrudes

    @Test func anExtrudeCanGoEitherWayOrBothAndCutOrJoin() async throws {
        let t = await open()
        _ = try await draw([.rectangle(id: nil, center: nil, corner: nil, width: "10", height: "10", cornerRadius: nil)], in: t)
        func zRange() -> ClosedRange<Double> {
            let b = t.model.result?.bodies.first?.body.bounds
            return (b?.min.z ?? 0)...(b?.max.z ?? 0)
        }
        let forward = try await t.service.createExtrude(documentID: t.id, sketchID: "s", profiles: [.at(pt(0, 0))], distance: "4", id: "up")
        #expect(abs(zRange().lowerBound) < 1e-6 && abs(zRange().upperBound - 4) < 1e-6)
        #expect(forward.feature?.parameters["extent"] == .text("distance") && forward.feature?.parameters["operation"] == .text("new_body"))
        t.undo.undo()
        await t.model.rebuilt()
        _ = try await t.service.createExtrude(documentID: t.id, sketchID: "s", profiles: [.at(pt(0, 0))], distance: "4", direction: .backward)
        #expect(abs(zRange().lowerBound + 4) < 1e-6 && abs(zRange().upperBound) < 1e-6, "backwards: \(zRange())")
        t.undo.undo()
        await t.model.rebuilt()
        _ = try await t.service.createExtrude(documentID: t.id, sketchID: "s", profiles: [.at(pt(0, 0))], distance: "4", direction: .symmetric)
        #expect(abs(zRange().lowerBound + 2) < 1e-6 && abs(zRange().upperBound - 2) < 1e-6, "symmetric: \(zRange())")
        // A hole through all of it, from a second sketch.
        _ = try await t.service.batch(documentID: t.id, expectedRevision: nil, label: nil, [
            CreateSketchOperation(plane: "xy", name: nil, id: "h"),
            EditSketchOperation(sketchID: "h", add: [.circle(id: nil, center: pt(0, 0), diameter: "2", radius: nil)]),
        ])
        let before = volume(t.model)
        _ = try await t.service.createExtrude(documentID: t.id, sketchID: "h", profiles: [.at(pt(0, 0))], distance: nil, operation: .cut)
        // "Through all" goes one way from the sketch plane; the body here spans z = -2…2, so the first cut takes the upper half of the hole.
        #expect(abs(volume(t.model) - (before - .pi * 2)) < 0.05, "the upper half of a 2 mm hole: \(before) → \(volume(t.model))")
        _ = try await t.service.createExtrude(documentID: t.id, sketchID: "h", profiles: [.at(pt(0, 0))], distance: nil, direction: .backward, operation: .cut)
        #expect(abs(volume(t.model) - (before - .pi * 4)) < 0.05, "and the other way takes the rest: \(before) → \(volume(t.model))")
        #expect(t.model.result?.bodies.count == 1)
    }

    @Test func profilesCanBePickedByIdOrByPointAndBadPicksAreExplained() async throws {
        let t = await open()
        let sk = try await draw([.rectangle(id: "r", center: nil, corner: nil, width: "20", height: "20", cornerRadius: nil),
                                 .circle(id: "c", center: pt(0, 0), diameter: "6", radius: nil)], in: t)
        #expect(sk.profiles.count == 2, "the plate with a hole, and the disc in the hole: \(sk.profiles.map(\.id))")
        let plate = try #require(sk.profiles.max { $0.area < $1.area })
        #expect(abs(plate.area - (400 - .pi * 9)) < 0.05)
        let byID = try await t.service.createExtrude(documentID: t.id, sketchID: "s", profiles: [.id(plate.id)], distance: "2")
        #expect(abs(volume(t.model) - plate.area * 2) < 0.05 && byID.created?["profiles"]?.array?.first?.string == plate.id)
        #expect(await refusal { _ = try await t.service.createExtrude(documentID: t.id, sketchID: "s", profiles: [.at(pt(50, 50))], distance: "2", operation: .join) }?.message.contains("No profile") == true)
        let wrong = await refusal { _ = try await t.service.createExtrude(documentID: t.id, sketchID: "s", profiles: [.id("profile:other/abc")], distance: "2", operation: .join) }
        #expect(wrong?.code == .invalidArguments)
        let junk = await refusal { _ = try await t.service.createExtrude(documentID: t.id, sketchID: "s", profiles: [.id("banana")], distance: "2", operation: .join) }
        #expect(junk?.code == .invalidArguments && junk?.reason?.contains("get_feature") == true)
        let none = await refusal { _ = try await t.service.createExtrude(documentID: t.id, sketchID: "s", profiles: [], distance: "2", operation: .join) }
        #expect(none?.code == .invalidArguments)
        let flat = await refusal { _ = try await t.service.createExtrude(documentID: t.id, sketchID: "s", profiles: [.at(pt(8, 8))], distance: nil) }
        #expect(flat?.message.contains("only makes sense as a cut") == true)
    }

    @Test func anEmptySketchHasNothingToExtrude() async throws {
        let t = await open()
        _ = try await t.service.batch(documentID: t.id, expectedRevision: nil, label: nil, [CreateSketchOperation(plane: nil, name: nil, id: "s")])
        let e = await refusal { _ = try await t.service.createExtrude(documentID: t.id, sketchID: "s", profiles: [.at(pt(0, 0))], distance: "3") }
        #expect(e != nil && (e?.code == .invalidValue || e?.code == .invalidArguments), "\(e?.message ?? "built")")
    }

    @Test func anExtrudesDistanceCanBeChangedAfterwards() async throws {
        let t = await open()
        _ = try await draw([.rectangle(id: nil, center: nil, corner: nil, width: "10", height: "10", cornerRadius: nil)], in: t)
        let created = try await t.service.createExtrude(documentID: t.id, sketchID: "s", profiles: [.at(pt(0, 0))], distance: "4", id: "e")
        let id = try #require(created.feature?.id)
        let d = try await t.service.getFeature(documentID: t.id, featureID: id)
        #expect(d.editable == ["distance", "taper"])
        _ = try await t.service.modifyFeature(documentID: t.id, featureID: id, settings: ["distance": 7], unlink: false)
        #expect(abs(volume(t.model) - 700) < 1e-3)
        _ = try await t.service.modifyFeature(documentID: t.id, featureID: id, settings: ["taper": 5], unlink: false)
        #expect(volume(t.model) > 700, "leaning outwards makes it bigger: \(volume(t.model))")
    }

    @Test func aBatchThatFailsPartWayLeavesNothingAndSaysWhichStep() async throws {
        let t = await open()
        let before = t.model.document
        let e = await refusal { _ = try await t.service.batch(documentID: t.id, expectedRevision: nil, label: nil, [
            CreateSketchOperation(plane: nil, name: nil, id: "s"),
            EditSketchOperation(sketchID: "s", add: [.rectangle(id: nil, center: nil, corner: nil, width: "10", height: "10", cornerRadius: nil)]),
            CreateExtrudeOperation(sketchID: "s", profiles: [.at(pt(99, 99))], distance: "3", direction: .forward, operation: .newBody,
                                   target: nil, startFace: nil, name: nil, id: nil),
        ]) }
        #expect(e?.message.hasPrefix("Step 3 of 3 (create_extrude)") == true, "\(e?.message ?? "")")
        #expect(e?.reason?.contains("None of the steps was applied") == true)
        #expect(t.model.document == before && !t.undo.canUndo)
    }

    // MARK: delete_feature

    @Test func aFeatureWithDependentsIsNotDeletedUnlessAskedAndUndoRestoresIt() async throws {
        let t = await open()
        _ = try await draw([.rectangle(id: nil, center: nil, corner: nil, width: "10", height: "10", cornerRadius: nil)], in: t)
        let extrude = try await t.service.createExtrude(documentID: t.id, sketchID: "s", profiles: [.solid], distance: "4", id: "e")
        #expect(t.model.document.hidden.contains("s"), "the sketch is hidden once used")
        let kept = await refusal { _ = try await t.service.change(documentID: t.id, expectedRevision: nil, DeleteFeatureOperation(featureID: "s", withChildren: false)) }
        #expect(kept?.code == .hasDependents && kept?.message.contains("Extrude1") == true && kept?.reason?.contains("with_children") == true)
        #expect(t.model.document.features.count == 2)
        // Deleting the extrude alone shows its sketch again.
        _ = try await t.service.change(documentID: t.id, expectedRevision: nil, DeleteFeatureOperation(featureID: "e", withChildren: false))
        #expect(t.model.document.features.map(\.id) == ["s"] && !t.model.document.hidden.contains("s") && t.model.result?.bodies.isEmpty == true)
        t.undo.undo()
        await t.model.rebuilt()
        #expect(t.model.document.features.count == 2 && t.model.result?.bodies.count == 1, "Undo brings the extrude back")
        // With children, both go in one step.
        let both = try await t.service.change(documentID: t.id, expectedRevision: nil, DeleteFeatureOperation(featureID: "s", withChildren: true))
        #expect(t.model.document.features.isEmpty && both.message.contains("Sketch1") && both.message.contains(extrude.feature?.name ?? "Extrude1"))
        let ghost = await refusal { _ = try await t.service.change(documentID: t.id, expectedRevision: nil, DeleteFeatureOperation(featureID: "ghost", withChildren: false)) }
        #expect(ghost?.code == .featureNotFound)
    }

    @Test func aTextsWordsAreEditableAndKeepTheirMiddle() async throws {
        let t = await open()
        _ = try await draw([.text(id: "t", text: "Hello", at: pt(10, 0), height: "5", font: nil, angle: nil, centered: true)], in: t)
        func middle() -> Double {
            let boxes = (t.model.result?.sketches["s"]?.regions.indices.map { CADService.bounds(ofRegion: $0, in: t.model.result!.sketches["s"]!) } ?? []).filter { $0.count == 4 }
            return ((boxes.map { $0[0] }.min() ?? 0) + (boxes.map { $0[2] }.max() ?? 0)) / 2
        }
        #expect(abs(middle() - 10) < 0.6)
        let r = try await t.service.modifyFeature(documentID: t.id, featureID: "s", settings: ["t.text": "A much longer sentence"], unlink: false)
        #expect(r.changes.first?.before == .text("Hello") && r.changes.first?.after == .text("A much longer sentence"))
        #expect(abs(middle() - 10) < 0.6, "the longer words grew both ways: \(middle())")
        #expect(r.sketch?.texts.first?.text == "A much longer sentence")
        let empty = await refusal { _ = try await t.service.modifyFeature(documentID: t.id, featureID: "s", settings: ["t.text": "  "], unlink: false) }
        #expect(empty?.code == .invalidValue)
    }
}
