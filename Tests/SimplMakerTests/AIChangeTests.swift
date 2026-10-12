// Changing a part through the AI interface: the transaction rules and the tools built on them.
// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplMaker

@Suite @MainActor struct AIChangeTests {
    /// A part open in its own registry, with an undo manager like a window has.
    private func open(_ doc: CADDocument = CADDocument()) async -> (rig: AIServiceTests.Rig, service: CADService, id: String,
                                                                     model: DocumentModel, undo: UndoManager) {
        let rig = AIServiceTests.Rig()
        let (id, model) = await rig.open(doc)
        let undo = UndoManager()
        model.undoManager = undo
        return (rig, rig.service, id, model, undo)
    }

    private func box(_ w: String = "100", _ l: String = "50", _ h: String = "20") -> CADService.BoxRequest {
        CADService.BoxRequest(width: w, length: l, height: h)
    }

    private func code(_ error: Error) -> AIError.Code? { (error as? AIError)?.code }

    /// Runs `body`, which must throw an AIError; its code.
    private func refusal(_ body: () async throws -> Void) async -> AIError? {
        do { try await body() } catch { return error as? AIError }
        return nil
    }

    private func volume(_ model: DocumentModel) -> Double { model.result?.bodies.first?.body.volume ?? 0 }

    // MARK: create_box

    @Test func aBoxIsCreatedAsANativeFeatureWithItsBody() async throws {
        let t = await open()
        let r = try await t.service.createBox(documentID: t.id, box())
        #expect(r.success && r.documentId == t.id && r.message.contains("Box1"))
        let f = try #require(r.feature)
        #expect(f.type == "Box" && f.name == "Box1" && f.createsBody && f.status == "ok")
        #expect(f.parameters["width"] == .quantity(expression: "100", value: 100, unit: "mm"))
        #expect(f.parameters["kind"] == .text("box") && f.parameters["plane"] == .text("plane:xy"))
        let body = try #require(r.bodies.first)
        #expect(r.bodies.count == 1 && body.id == f.id && abs(body.volume - 100_000) < 1e-3)
        #expect(abs(body.boundsMax[2] - 20) < 1e-6 && abs(body.boundsMin[2]) < 1e-6, "stands on the plane")
        #expect(t.model.document.features.count == 1 && t.model.result?.bodies.count == 1, "in the real document, built")
        #expect(r.revision == t.model.documentRevision)
        #expect(t.model.aiActivity == nil, "the status line is cleared")
    }

    @Test func theBoxIsOneUndoStepThatTheUserSees() async throws {
        let t = await open()
        _ = try await t.service.createBox(documentID: t.id, box())
        #expect(t.undo.undoActionName == "AI: Create Box")
        t.undo.undo()
        #expect(t.model.document.features.isEmpty, "one Undo takes the whole thing away")
        await t.model.rebuilt()
        #expect(t.model.result?.bodies.isEmpty == true)
    }

    @Test func aBoxCanHaveItsOwnNameIdPlaceAndSizesAsExpressions() async throws {
        var doc = CADDocument()
        doc.parameters = [Parameter("wall", "2 mm")]
        let t = await open(doc)
        var request = box("wall * 10", "2 in", "1 cm")
        request.name = "Base"; request.id = "base"; request.plane = "xz"; request.u = "5"; request.v = "-3"
        let r = try await t.service.createBox(documentID: t.id, request)
        let f = try #require(r.feature)
        #expect(f.id == "base" && f.name == "Base")
        #expect(f.parameters["width"] == .quantity(expression: "wall * 10", value: 20, unit: "mm"))
        #expect(f.parameters["length"] == .quantity(expression: "2 in", value: 50.8, unit: "mm"), "inches are converted")
        #expect(f.parameters["height"] == .quantity(expression: "1 cm", value: 10, unit: "mm"))
        #expect(f.parameters["plane"] == .text("plane:xz") && f.parameters["u"] == .quantity(expression: "5", value: 5, unit: "mm"))
        let again = await refusal { _ = try await t.service.createBox(documentID: t.id, {
            var b = box(); b.id = "base"; return b }()) }
        #expect(again?.code == .invalidArguments && again?.message.contains("already used") == true)
    }

    @Test func badSizesAreRefusedWithAReasonAndNothingChanges() async throws {
        let t = await open()
        let revision = t.model.documentRevision
        for (w, why) in [("0", "greater than 0"), ("-5", "greater than 0"), ("abc", "not a valid length"), ("5 deg", "not a valid length"), ("nope * 2", "unknown")] {
            let e = await refusal { _ = try await t.service.createBox(documentID: t.id, box(w)) }
            #expect(e?.code == .invalidValue && (e?.message.lowercased().contains(why) == true), "\(w): \(e?.message ?? "no error")")
            #expect(e?.recoverable == true && e?.reason?.isEmpty == false)
        }
        #expect(t.model.document.features.isEmpty && t.model.documentRevision == revision && !t.undo.canUndo, "no trace of the failures")
    }

    @Test func aBoxOnAnUnknownPlaneOrTargetIsRefused() async throws {
        let t = await open()
        var onNothing = box(); onNothing.plane = "plane:ghost"
        #expect(await refusal { _ = try await t.service.createBox(documentID: t.id, onNothing) }?.code == .invalidArguments)
        var odd = box(); odd.plane = "banana"
        #expect(await refusal { _ = try await t.service.createBox(documentID: t.id, odd) }?.code == .invalidArguments)
        var joined = box(); joined.operation = .join
        let e = await refusal { _ = try await t.service.createBox(documentID: t.id, joined) }
        #expect(e?.code == .invalidArguments && e?.message.contains("needs a body") == true)
    }

    @Test func aSecondBoxCanJoinTheFirst() async throws {
        let t = await open()
        _ = try await t.service.createBox(documentID: t.id, box("10", "10", "10"))
        var second = box("10", "10", "10"); second.operation = .join; second.v = "5"
        let r = try await t.service.createBox(documentID: t.id, second)
        #expect(r.bodies.count == 1, "joined into the first body")
        #expect(r.bodies[0].volume > 1000 && r.bodies[0].volume < 2000)
    }

    // MARK: modify_feature

    @Test func changingTheWidthChangesTheFeatureNotTheShapeAroundIt() async throws {
        let t = await open()
        let created = try await t.service.createBox(documentID: t.id, box())
        let id = try #require(created.feature?.id)
        let r = try await t.service.modifyFeature(documentID: t.id, featureID: id, settings: ["width": .int(120)], unlink: false)
        #expect(r.success && r.feature?.id == id && t.model.document.features.count == 1, "the same feature, not a new box")
        #expect(r.bodies.first?.id == id)
        #expect(abs(volume(t.model) - 120 * 50 * 20) < 1e-3)
        let change = try #require(r.changes.first)
        #expect(change.field == "width" && r.changes.count == 1)
        #expect(change.before == .quantity(expression: "100", value: 100, unit: "mm"))
        #expect(change.after == .quantity(expression: "120 mm", value: 120, unit: "mm"))
        #expect(r.message.contains("width 100 → 120 mm"))
        #expect(t.undo.undoActionName == "AI: Change Box1")
    }

    @Test func severalSettingsChangeTogetherAndUndoTogether() async throws {
        let t = await open()
        let id = try #require(try await t.service.createBox(documentID: t.id, box()).feature?.id)
        let r = try await t.service.modifyFeature(documentID: t.id, featureID: id,
                                                  settings: ["height": "30", "length": .double(40.5), "u": .int(10)], unlink: false)
        #expect(r.changes.map(\.field) == ["height", "length", "u"])
        #expect(abs(volume(t.model) - 100 * 40.5 * 30) < 1e-2)
        t.undo.undo()
        await t.model.rebuilt()
        #expect(abs(volume(t.model) - 100_000) < 1e-3, "one Undo restores all three")
    }

    @Test func aWrongOrImpossibleValueIsRefusedAndTheOldOneStays() async throws {
        let t = await open()
        let id = try #require(try await t.service.createBox(documentID: t.id, box()).feature?.id)
        let before = t.model.document
        let revision = t.model.documentRevision
        let unknown = await refusal { _ = try await t.service.modifyFeature(documentID: t.id, featureID: id, settings: ["colour": "red"], unlink: false) }
        #expect(unknown?.code == .unknownField && unknown?.reason?.contains("width, length, height") == true)
        let zero = await refusal { _ = try await t.service.modifyFeature(documentID: t.id, featureID: id, settings: ["width": .int(0)], unlink: false) }
        #expect(zero?.code == .invalidValue)
        let text = await refusal { _ = try await t.service.modifyFeature(documentID: t.id, featureID: id, settings: ["width": "wide"], unlink: false) }
        #expect(text?.code == .invalidValue)
        let empty = await refusal { _ = try await t.service.modifyFeature(documentID: t.id, featureID: id, settings: [:], unlink: false) }
        #expect(empty?.code == .invalidArguments)
        let same = await refusal { _ = try await t.service.modifyFeature(documentID: t.id, featureID: id, settings: ["width": "100"], unlink: false) }
        #expect(same?.code == .invalidValue && same?.message.contains("already has") == true)
        let missing = await refusal { _ = try await t.service.modifyFeature(documentID: t.id, featureID: "ghost", settings: ["width": 1], unlink: false) }
        #expect(missing?.code == .featureNotFound)
        #expect(t.model.document == before && t.model.documentRevision == revision, "not a trace")
        // One bad value among good ones refuses all of them.
        let mixed = await refusal { _ = try await t.service.modifyFeature(documentID: t.id, featureID: id, settings: ["width": 150, "height": 0], unlink: false) }
        #expect(mixed?.code == .invalidValue && t.model.document == before)
    }

    @Test func aFeatureThatCannotBeChangedYetSaysWhatCan() async throws {
        var doc = CADDocument.demo()
        doc.features.append(Feature(id: "hollow", name: "Hollow", .split(SplitFeature(bodies: ["base"], tool: .plane(.xy)))))
        let t = await open(doc)
        let e = await refusal { _ = try await t.service.modifyFeature(documentID: t.id, featureID: "hollow", settings: ["tool": 5], unlink: false) }
        #expect(e?.code == .unsupportedFeature && e?.reason?.contains("Box") == true && e?.reason?.contains("set_parameter") == true)
    }

    @Test func aSizeThatFollowsAParameterIsNotQuietlyUnlinked() async throws {
        var doc = CADDocument()
        doc.parameters = [Parameter("w", "60 mm")]
        let t = await open(doc)
        let id = try #require(try await t.service.createBox(documentID: t.id, box("w", "40", "10")).feature?.id)
        let e = await refusal { _ = try await t.service.modifyFeature(documentID: t.id, featureID: id, settings: ["width": 80], unlink: false) }
        #expect(e?.code == .parameterLinked && e?.message.contains("w") == true && e?.reason?.contains("set_parameter") == true && e?.reason?.contains("unlink") == true)
        // An expression keeps the link.
        let kept = try await t.service.modifyFeature(documentID: t.id, featureID: id, settings: ["width": "w + 20"], unlink: false)
        #expect(kept.changes.first?.after == .quantity(expression: "w + 20", value: 80, unit: "mm"))
        // unlink replaces it.
        let cut = try await t.service.modifyFeature(documentID: t.id, featureID: id, settings: ["width": 50], unlink: true)
        #expect(cut.feature?.parameters["width"] == .quantity(expression: "50 mm", value: 50, unit: "mm"))
    }

    @Test func aChangeThatWouldBreakALaterFeatureIsRefusedWhole() async throws {
        let t = await open()
        let id = try #require(try await t.service.createBox(documentID: t.id, box("20", "20", "20")).feature?.id)
        let body = try #require(t.model.result?.body(id))
        // A 5 mm fillet along an edge between the top and a side.
        let edge = try #require(body.edgeNames.first { name in (try? body.edgeFaces(name))?.contains { $0.hasSuffix("top") } == true
            && (try? body.edgeFaces(name))?.contains { $0.contains("side") || $0.hasSuffix("front") || $0.hasSuffix("back") || $0.hasSuffix("left") || $0.hasSuffix("right") } == true })
        t.model.mutate("Fillet") { $0.addFeature(Feature(id: "round", name: "Fillet1", .fillet(EdgeFeature(edges: [EdgeRef(body: id, edge: edge)], size: "5 mm")))) }
        await t.model.rebuilt()
        #expect(t.model.result?.errors.isEmpty == true, "\(t.model.result?.errors ?? [:])")
        let before = t.model.document
        let revision = t.model.documentRevision
        let undoName = t.undo.undoActionName
        // A box only 2 mm tall can't have a 5 mm fillet along its top edge.
        let e = await refusal { _ = try await t.service.modifyFeature(documentID: t.id, featureID: id, settings: ["height": 2], unlink: false) }
        #expect(e?.code == .rebuildFailed, "\(e?.message ?? "built!")")
        #expect(e?.message.contains("Fillet1") == true, "names the feature that breaks")
        #expect(e?.reason?.contains("unchanged") == true && e?.recoverable == true)
        #expect(t.model.document == before && t.model.documentRevision == revision, "the part is exactly as it was")
        #expect(t.undo.undoActionName == undoName, "and no undo step was made")
        #expect(t.model.result?.errors.isEmpty == true)
    }

    // MARK: the rules around a change

    @Test func aStaleRevisionRefusesTheChange() async throws {
        let t = await open()
        let created = try await t.service.createBox(documentID: t.id, box())
        let id = try #require(created.feature?.id)
        let seen = created.revision
        t.model.setParameter("x", expression: "1")  // no such parameter: nothing happens
        t.model.mutate("The user edits") { $0.parameters.append(Parameter("note", "1 mm")) }  // the user changes something
        let e = await refusal { _ = try await t.service.modifyFeature(documentID: t.id, featureID: id, settings: ["width": 5], unlink: false, expectedRevision: seen) }
        #expect(e?.code == .staleRevision && e?.message.contains("revision \(seen)") == true)
        #expect(abs(volume(t.model) - 100_000) < 1e-3, "not changed")
        let ok = try await t.service.modifyFeature(documentID: t.id, featureID: id, settings: ["width": 5], unlink: false, expectedRevision: t.model.documentRevision)
        #expect(ok.success)
    }

    @Test func theResultsRevisionIsTheOneToPassNext() async throws {
        let t = await open()
        let a = try await t.service.createBox(documentID: t.id, box())
        let id = try #require(a.feature?.id)
        let b = try await t.service.modifyFeature(documentID: t.id, featureID: id, settings: ["width": 90], unlink: false, expectedRevision: a.revision)
        let c = try await t.service.modifyFeature(documentID: t.id, featureID: id, settings: ["width": 80], unlink: false, expectedRevision: b.revision)
        #expect(b.revision > a.revision && c.revision > b.revision)
    }

    @Test func aBusyUserIsNotInterrupted() async throws {
        let t = await open()
        let id = try #require(try await t.service.createBox(documentID: t.id, box()).feature?.id)
        t.model.pendingTool = .extrude  // the Extrude tool is waiting for a pick
        let before = t.model.document
        let e1 = await refusal { _ = try await t.service.createBox(documentID: t.id, box()) }
        let e2 = await refusal { _ = try await t.service.modifyFeature(documentID: t.id, featureID: id, settings: ["width": 5], unlink: false) }
        let e3 = await refusal { _ = try await t.service.undo(documentID: t.id) }
        for e in [e1, e2, e3] {
            #expect(e?.code == .userBusy && e?.message.contains("Extrude tool") == true && e?.recoverable == true)
        }
        #expect(t.model.document == before && t.model.pendingTool == .extrude, "nothing of theirs was cancelled")
        t.model.pendingTool = nil
        #expect(try await t.service.modifyFeature(documentID: t.id, featureID: id, settings: ["width": 5], unlink: false).success)
    }

    @Test func aSketchBeingEditedCountsAsBusy() async throws {
        var s = Sketch()
        s.addRectangle(0, 0, 10, 10, lineIDs: ["A", "B", "C", "D"])
        var doc = CADDocument()
        doc.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s)))]
        let t = await open(doc)
        t.model.editSketch("sk")
        #expect(t.model.sketchSession != nil)
        let e = await refusal { _ = try await t.service.createBox(documentID: t.id, box()) }
        #expect(e?.code == .userBusy && e?.message.contains("editing a sketch") == true)
        #expect(t.model.sketchSession != nil, "still editing")
    }

    @Test func aRolledBackTimelineStopsNewFeatures() async throws {
        var doc = CADDocument.demo()
        doc.rollback = 2
        let t = await open(doc)
        let e = await refusal { _ = try await t.service.createBox(documentID: t.id, box()) }
        #expect(e?.code == .timelineRolledBack && e?.message.contains("position 2") == true)
        #expect(t.model.document.features.count == 6)
    }

    @Test func changesNeedAnExplicitDocument() async throws {
        let t = await open()
        let e = await refusal { _ = try await t.service.createBox(documentID: "doc_999", box()) }
        #expect(e?.code == .documentNotFound)
        let args = AIArguments(["width": 1])
        #expect((try? args.requiredDocumentID()) == nil)
        do { _ = try args.requiredDocumentID() } catch let error as AIError {
            #expect(error.code == .invalidArguments && error.reason?.contains("list_documents") == true)
        }
    }

    @Test func withoutALicenseNothingChanges() async throws {
        let t = await open()
        let rig = AIServiceTests.Rig(licensed: false)
        let (id, model) = await rig.open(CADDocument())
        let e = await refusal { _ = try await rig.service.createBox(documentID: id, box()) }
        #expect(e?.code == .licenseRequired && model.document.features.isEmpty)
        _ = t
    }

    // MARK: set_parameter

    @Test func aParameterIsCreatedThenChangedAndEverythingThatUsesItFollows() async throws {
        let t = await open()
        let made = try await t.service.setParameter(documentID: t.id, name: "wall", value: .int(3), unit: nil, comment: "wall thickness")
        #expect(made.parameter == ParameterInfo(name: "wall", expression: "3 mm", unit: "mm", value: 3, comment: "wall thickness", error: nil, usedBy: []))
        #expect(made.message.contains("Created") && t.undo.undoActionName == "AI: Set wall")
        let id = try #require(try await t.service.createBox(documentID: t.id, box("wall * 10", "20", "20")).feature?.id)
        #expect(abs(volume(t.model) - 30 * 20 * 20) < 1e-3)
        let changed = try await t.service.setParameter(documentID: t.id, name: "wall", value: .int(4), unit: nil, comment: nil)
        #expect(changed.parameter?.expression == "4 mm" && changed.parameter?.usedBy == [id] && changed.message.contains("was 3 mm"))
        #expect(abs(volume(t.model) - 40 * 20 * 20) < 1e-3, "the box followed")
        #expect(changed.bodies.first.map { abs($0.volume - 16_000) < 1e-3 } == true)
    }

    @Test func parametersTakeUnitsAndExpressionsAndRefuseBadOnes() async throws {
        let t = await open()
        let angle = try await t.service.setParameter(documentID: t.id, name: "tilt", value: .int(45), unit: .angle, comment: nil)
        #expect(angle.parameter?.expression == "45 deg" && angle.parameter?.unit == "deg" && angle.parameter?.value == 45)
        let inferred = try await t.service.setParameter(documentID: t.id, name: "gap", value: "2 in", unit: nil, comment: nil)
        #expect(inferred.parameter?.unit == "mm" && inferred.parameter?.value == 50.8)
        let derived = try await t.service.setParameter(documentID: t.id, name: "twice", value: "gap * 2", unit: nil, comment: nil)
        #expect(derived.parameter?.value == 101.6)
        for name in ["", "2bad", "has space", "mm", "sin"] {
            let e = await refusal { _ = try await t.service.setParameter(documentID: t.id, name: name, value: 1, unit: nil, comment: nil) }
            #expect(e?.code == .invalidArguments, "\(name)")
        }
        let unknown = await refusal { _ = try await t.service.setParameter(documentID: t.id, name: "p", value: "ghost + 1", unit: nil, comment: nil) }
        #expect(unknown?.code == .invalidValue)
        let circular = await refusal { _ = try await t.service.setParameter(documentID: t.id, name: "gap", value: "twice", unit: nil, comment: nil) }
        #expect(circular?.code == .invalidValue, "a loop: \(circular?.message ?? "accepted")")
        #expect(t.model.document.parameters.map(\.name) == ["tilt", "gap", "twice"], "none of the refused ones got in")
    }

    @Test func aParameterThatWouldBreakAFeatureIsRefused() async throws {
        let t = await open()
        _ = try await t.service.setParameter(documentID: t.id, name: "h", value: .int(10), unit: nil, comment: nil)
        _ = try await t.service.createBox(documentID: t.id, box("20", "20", "h"))
        let e = await refusal { _ = try await t.service.setParameter(documentID: t.id, name: "h", value: .int(-4), unit: nil, comment: nil) }
        #expect(e?.code == .rebuildFailed || e?.code == .invalidValue, "\(e?.message ?? "accepted")")
        #expect(t.model.document.parameters.first?.expression == "10 mm", "unchanged")
    }

    // MARK: undo and redo

    @Test func undoAndRedoGoThroughTheUsersOwnHistory() async throws {
        let t = await open()
        let created = try await t.service.createBox(documentID: t.id, box())
        let id = try #require(created.feature?.id)
        _ = try await t.service.modifyFeature(documentID: t.id, featureID: id, settings: ["width": 120], unlink: false)
        let undone = try await t.service.undo(documentID: t.id)
        #expect(undone.step == "AI: Change Box1" && undone.message == "Undid AI: Change Box1." && undone.featureCount == 1)
        #expect(abs(volume(t.model) - 100_000) < 1e-3)
        let again = try await t.service.undo(documentID: t.id)
        #expect(again.step == "AI: Create Box" && again.featureCount == 0 && again.bodies.isEmpty)
        let redone = try await t.service.redo(documentID: t.id)
        #expect(redone.step == "AI: Create Box" && redone.featureCount == 1)
        _ = try await t.service.redo(documentID: t.id)
        #expect(abs(volume(t.model) - 120_000) < 1e-3)
        #expect(await refusal { _ = try await t.service.redo(documentID: t.id) }?.code == .nothingToRedo)
    }

    @Test func nothingToUndoIsSaid() async throws {
        let t = await open()
        let e = await refusal { _ = try await t.service.undo(documentID: t.id) }
        #expect(e?.code == .nothingToUndo)
    }

    @Test func undoCanBeGuardedAgainstUndoingTheUsersOwnWork() async throws {
        let t = await open()
        let a = try await t.service.createBox(documentID: t.id, box())
        t.model.mutate("The user renames something") { $0.parameters.append(Parameter("mine", "1 mm")) }
        let e = await refusal { _ = try await t.service.undo(documentID: t.id, expectedRevision: a.revision) }
        #expect(e?.code == .staleRevision)
        #expect(t.model.document.parameters.map(\.name) == ["mine"], "the user's step is still there")
    }

    @Test func withoutAWindowThereIsNoHistoryToUse() async throws {
        let rig = AIServiceTests.Rig()
        let (id, model) = await rig.open(CADDocument())
        model.undoManager = nil
        let e = await refusal { _ = try await rig.service.undo(documentID: id) }
        #expect(e?.code == .undoUnavailable)
    }

    // MARK: what get_feature offers

    @Test func getFeatureSaysWhatCanBeChanged() async throws {
        let t = await open()
        let id = try #require(try await t.service.createBox(documentID: t.id, box()).feature?.id)
        let d = try await t.service.getFeature(documentID: t.id, featureID: id)
        #expect(d.editable == ["width", "length", "height", "u", "v"])
        let demo = await open(.demo())
        #expect(try await demo.service.getFeature(documentID: demo.id, featureID: "corners").editable == ["size"])
        #expect(try await demo.service.getFeature(documentID: demo.id, featureID: "topedge").editable == ["size"])
        #expect(try await demo.service.getFeature(documentID: demo.id, featureID: "plate").editable == ["distance", "taper"])
    }
}
