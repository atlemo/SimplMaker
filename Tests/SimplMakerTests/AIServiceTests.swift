// The AI interface's read side: the documents it names, what it says about them, and the rules around it.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import Testing
@testable import SimplMaker

@Suite @MainActor struct AIServiceTests {
    private func box(_ id: String = "box1") -> Feature {
        Feature(id: id, name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "100 mm", length: "50 mm", height: "20 mm")))
    }

    /// A service over its own registry, so tests don't see each other's documents. The registry holds documents
    /// weakly (as the app does, where the window's file owns them), so the rig keeps the ones it opens.
    @MainActor final class Rig {
        let registry = DocumentRegistry()
        let service: CADService
        private var models: [DocumentModel] = []
        init() { service = CADService(registry: registry) }

        func open(_ doc: CADDocument) async -> (id: String, model: DocumentModel) {
            let model = DocumentModel(document: doc)
            models.append(model)
            let id = registry.register(model)
            await model.rebuilt()
            return (id, model)
        }
    }

    private func encoded<T: Encodable>(_ value: T) throws -> [String: Any] {
        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        let object = try JSONSerialization.jsonObject(with: enc.encode(value))
        return try #require(object as? [String: Any])
    }

    // MARK: waiting for the kernel

    @Test func rebuiltReturnsOnceTheModelIsBuilt() async throws {
        let model = DocumentModel(document: .demo())
        await model.rebuilt()
        #expect(!model.isRegenerating)
        #expect(model.result?.bodies.count == 1)
        #expect(model.result?.errors.isEmpty == true)
    }

    @Test func rebuiltWaitsForTheLatestChange() async throws {
        let model = DocumentModel(document: .demo())
        await model.rebuilt()
        let before = try #require(model.result?.bodies.first?.body.volume)
        model.setParameter("thickness", expression: "20 mm")
        await model.rebuilt()
        let after = try #require(model.result?.bodies.first?.body.volume)
        #expect(after > before * 1.5, "the result is the one for the new thickness")
    }

    @Test func rebuiltIsImmediateWhenNothingIsRunning() async throws {
        let model = DocumentModel(document: .demo())
        await model.rebuilt()
        await model.rebuilt()
        #expect(model.isRebuildIdle)
    }

    @Test func rebuiltOutlastsTheRebuildThatTakesAFailedNewFeatureOut() async throws {
        let model = DocumentModel(document: .demo())
        await model.rebuilt()
        model.add(Feature(id: "big", name: "Fillet9", .fillet(EdgeFeature(
            edges: [EdgeRef(body: "plate", edge: "plate.end|plate.side.L3")], size: "500 mm"))))
        await model.rebuilt()
        #expect(model.document.features.contains { $0.id == "big" } == false, "the tools take a feature that does not build out again")
        #expect(model.alert?.title.contains("could not be made") == true)
        #expect(model.isRebuildIdle && model.result?.errors.isEmpty == true, "and rebuilt() returned only after that")
    }

    // MARK: commit

    @Test func commitIsOneUndoStepAndLeavesTheSelectionAlone() async throws {
        let model = DocumentModel(document: CADDocument())
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        model.selection = [PickID(wholeBody: 0)]
        undo.beginUndoGrouping()
        model.commit(box())
        undo.endUndoGrouping()
        await model.rebuilt()
        #expect(model.document.features.map(\.id) == ["box1"])
        #expect(model.selectedFeature == nil && model.newFeature == nil, "the tools' extras are not part of it")
        undo.undo()
        #expect(model.document.features.isEmpty)
        await model.rebuilt()
    }

    @Test func everyChangeAdvancesTheRevision() async throws {
        let model = DocumentModel(document: .demo())
        let r0 = model.documentRevision
        model.setParameter("thickness", expression: "12 mm")
        #expect(model.documentRevision > r0)
        let r1 = model.documentRevision
        model.setParameter("thickness", expression: "12 mm")  // no change
        #expect(model.documentRevision == r1)
        await model.rebuilt()
    }

    // MARK: registry

    @Test func documentsGetIdsThatAreNotReused() async throws {
        let registry = DocumentRegistry()
        var first: DocumentModel? = DocumentModel()
        let a = registry.register(first!)
        #expect(registry.register(first!) == a, "registering again keeps the id")
        let second = DocumentModel()
        let b = registry.register(second)
        await second.rebuilt()
        #expect(a != b)
        await first!.rebuilt()  // a rebuild under way keeps its model alive until its task has finished
        first = nil
        try await Task.sleep(for: .milliseconds(100))
        #expect(registry.documents.map(\.id) == [b], "a closed document is gone")
        let c = registry.register(DocumentModel())
        #expect(c != a && c != b)
    }

    @Test func theFrontmostIsTheOneActivatedOrTheOnlyOne() async throws {
        let registry = DocumentRegistry()
        let a = DocumentModel(), b = DocumentModel()
        registry.register(a)
        #expect(registry.frontmost?.model === a, "the only document is the front one")
        registry.register(b)
        #expect(registry.frontmost == nil, "two documents and none in front: it can't be told")
        registry.activate(b)
        #expect(registry.frontmost?.model === b)
    }

    // MARK: entity references

    @Test func entityReferencesRoundTrip() {
        let refs: [AIEntityRef] = [
            .face(FaceRef(body: "plate", face: "plate.end")),
            .edge(EdgeRef(body: "plate", edge: "plate.end|plate.side.L3")),
            .profile(sketch: "base", curves: ["C0", "L0", "L1"], copy: 0),
            .profile(sketch: "base", curves: ["A", "B"], copy: 2),
            .curve(sketch: "base", id: "L1"),
            .plane("xy"), .plane("a1b2c3d4"),
        ]
        for ref in refs { #expect(AIEntityRef(ref.string) == ref, "\(ref.string)") }
        #expect(AIEntityRef.profile(sketch: "s", curves: ["b", "a"], copy: 0).string == "profile:s/a,b", "curves are sorted")
        #expect(AIEntityRef("face:plate") == nil && AIEntityRef("nonsense") == nil && AIEntityRef("cube:a/b") == nil)
        #expect(AIEntityRef("face:/x") == nil && AIEntityRef("profile:s/") == nil)
    }

    // MARK: documents

    @Test func listsTheOpenDocuments() async throws {
        let rig = Rig(); let service = rig.service; let registry = rig.registry
        let a = await rig.open(.demo())
        let b = await rig.open(CADDocument())
        registry.activate(b.model)
        let list = try service.listDocuments()
        #expect(list.documents.map(\.id) == [a.id, b.id])
        #expect(list.documents.map(\.isActive) == [false, true])
        #expect(list.documents.map(\.featureCount) == [6, 0])
        #expect(list.documents.allSatisfy { $0.name == "Untitled" })
    }

    @Test func getDocumentDescribesTheFeatureTree() async throws {
        let rig = Rig(); let service = rig.service; let registry = rig.registry
        let (id, _) = await rig.open(.demo())
        let d = try await service.getDocument(id: id)
        #expect(d.documentId == id && d.units == "mm" && d.timelineMarker == nil)
        #expect(d.features.map(\.id) == ["base", "plate", "pinsk", "pin", "corners", "topedge"])
        #expect(d.features.allSatisfy { $0.status == "ok" && $0.error == nil })
        #expect(d.parameters.map(\.name) == ["width", "depth", "thickness", "hole_d", "pin_d", "corner_r", "edge_chamfer"])

        let plate = try #require(d.features.first { $0.id == "plate" })
        #expect(plate.type == "Extrude" && plate.createsBody)
        #expect(plate.dependencies == ["base"])
        #expect(plate.children == ["pinsk", "pin", "corners", "topedge"])
        #expect(plate.parameters["distance"] == .quantity(expression: "thickness", value: 10, unit: "mm"))
        #expect(plate.parameters["extent"] == .text("distance") && plate.parameters["operation"] == .text("new_body"))

        let body = try #require(d.bodies.first)
        #expect(d.bodies.count == 1 && body.id == "plate" && body.isValid && body.volume > 0 && body.faceCount > 6)
        #expect(body.boundsMax[2] - body.boundsMin[2] > 9.9)
    }

    @Test func parametersCarryValuesAndWhatUsesThem() async throws {
        let rig = Rig(); let service = rig.service; let registry = rig.registry
        let (id, _) = await rig.open(.demo())
        let params = try await service.listParameters(documentID: id)
        let holeD = try #require(params.first { $0.name == "hole_d" })
        #expect(holeD.expression == "depth / 4" && holeD.value == 10 && holeD.unit == "mm" && holeD.comment == "follows depth")
        #expect(holeD.usedBy == ["base"])
        let thickness = try #require(params.first { $0.name == "thickness" })
        #expect(thickness.usedBy.contains("plate"))
    }

    @Test func aBoxIsDescribedByItsSizes() async throws {
        let rig = Rig(); let service = rig.service; let registry = rig.registry
        var doc = CADDocument()
        doc.addFeature(box())
        let (id, _) = await rig.open(doc)
        let d = try await service.getDocument(id: id)
        let f = try #require(d.features.first)
        #expect(f.type == "Box" && f.createsBody && f.dependencies.isEmpty)
        #expect(f.parameters["kind"] == .text("box") && f.parameters["plane"] == .text("plane:xy"))
        #expect(f.parameters["width"] == .quantity(expression: "100 mm", value: 100, unit: "mm"))
        #expect(f.parameters["length"] == .quantity(expression: "50 mm", value: 50, unit: "mm"))
        #expect(f.parameters["height"] == .quantity(expression: "20 mm", value: 20, unit: "mm"))
        let volume = try #require(d.bodies.first?.volume)
        #expect(abs(volume - 100_000) < 1e-3, "\(volume)")
    }

    @Test func aFeatureThatFailsSaysSo() async throws {
        let rig = Rig(); let service = rig.service; let registry = rig.registry
        var doc = CADDocument.demo()
        doc.addFeature(Feature(id: "big", name: "Fillet9", .fillet(EdgeFeature(
            edges: [EdgeRef(body: "plate", edge: "plate.end|plate.side.L3")], size: "500 mm"))))
        let (id, _) = await rig.open(doc)
        let d = try await service.getDocument(id: id)
        let big = try #require(d.features.first { $0.id == "big" })
        #expect(big.status == "error" && big.error?.isEmpty == false)
        #expect(d.features.filter { $0.status == "error" }.count == 1, "the rest still builds")
    }

    @Test func featuresAfterTheMarkerAreRolledBack() async throws {
        let rig = Rig(); let service = rig.service; let registry = rig.registry
        var doc = CADDocument.demo()
        doc.rollback = 2
        let (id, _) = await rig.open(doc)
        let d = try await service.getDocument(id: id)
        #expect(d.timelineMarker == 2)
        #expect(d.features.map(\.status) == ["ok", "ok", "rolled_back", "rolled_back", "rolled_back", "rolled_back"])
    }

    @Test func getFeatureAddsASketchsDimensionsAndProfiles() async throws {
        let rig = Rig(); let service = rig.service; let registry = rig.registry
        let (id, _) = await rig.open(.demo())
        let f = try await service.getFeature(documentID: id, featureID: "base")
        let sketch = try #require(f.sketch)
        #expect(f.feature.type == "Sketch" && f.feature.children == ["plate"])
        #expect(sketch.dimensions.count == 5 && sketch.degreesOfFreedom == 0)
        let width = try #require(sketch.dimensions.first { $0.id != "" && $0.kind == "length" && $0.refs == ["L0"] })
        #expect(width.field == .quantity(expression: "width", value: 60, unit: "mm"))
        #expect(!sketch.profiles.isEmpty)
        for p in sketch.profiles {
            guard case .profile(let s, let curves, _)? = AIEntityRef(p.id) else { Issue.record("\(p.id)"); continue }
            #expect(s == "base" && !curves.isEmpty && p.area > 0)
        }
        let plate = try await service.getFeature(documentID: id, featureID: "plate")
        #expect(plate.sketch == nil)
    }

    @Test func theResponseIsPlainSnakeCaseJSON() async throws {
        let rig = Rig(); let service = rig.service; let registry = rig.registry
        var doc = CADDocument()
        doc.addFeature(box())
        let (id, _) = await rig.open(doc)
        let json = try encoded(await service.getDocument(id: id))
        #expect(json["document_id"] as? String == id && json["units"] as? String == "mm")
        let features = try #require(json["features"] as? [[String: Any]])
        let first = try #require(features.first)
        #expect(first["creates_body"] as? Bool == true && first["id"] as? String == "box1")
        let width = try #require((first["parameters"] as? [String: Any])?["width"] as? [String: Any])
        #expect(width["expression"] as? String == "100 mm" && width["value"] as? Double == 100 && width["unit"] as? String == "mm")
        let bounds = try #require((json["bodies"] as? [[String: Any]])?.first?["bounds_max"] as? [Double])
        #expect(bounds.count == 3 && abs(bounds[2] - 20) < 1e-6, "\(bounds)")
        let timeline = json["timeline_marker"]
        #expect(timeline == nil, "absent when the marker is at the end")
    }

    // MARK: resolving

    @Test func anUnknownDocumentIsRefused() async throws {
        let rig = Rig(); let service = rig.service; let registry = rig.registry
        _ = await rig.open(.demo())
        await #expect(throws: AIError.self) { try await service.getDocument(id: "doc_99") }
        do { _ = try await service.getDocument(id: "doc_99") } catch let e as AIError {
            #expect(e.code == .documentNotFound && e.recoverable)
        }
    }

    @Test func noIdMeansTheFrontDocumentAndIsRefusedWhenThatIsNotKnown() async throws {
        let rig = Rig(); let service = rig.service; let registry = rig.registry
        let a = await rig.open(.demo())
        #expect(try await service.getDocument().documentId == a.id)
        let b = await rig.open(CADDocument())
        do { _ = try await service.getDocument(); Issue.record("should be ambiguous") } catch let e as AIError {
            #expect(e.code == .noActiveDocument)
            #expect(e.reason?.contains(a.id) == true && e.reason?.contains(b.id) == true)
        }
        registry.activate(b.model)
        #expect(try await service.getDocument().documentId == b.id)
    }

    @Test func noOpenDocumentIsSaid() async throws {
        let service = Rig().service
        do { _ = try await service.getDocument(); Issue.record("should fail") } catch let e as AIError {
            #expect(e.code == .noActiveDocument && e.message.contains("No document"))
        }
    }

    @Test func anUnknownFeatureIsRefused() async throws {
        let rig = Rig(); let service = rig.service; let registry = rig.registry
        let (id, _) = await rig.open(.demo())
        do { _ = try await service.getFeature(documentID: id, featureID: "nope"); Issue.record("should fail") } catch let e as AIError {
            #expect(e.code == .featureNotFound)
        }
    }

    // MARK: selection

    @Test func theSelectionIsNamedByIdsThatSurviveARebuild() async throws {
        let rig = Rig(); let service = rig.service; let registry = rig.registry
        var doc = CADDocument()
        doc.addFeature(box())
        let (id, model) = await rig.open(doc)
        #expect(try service.getSelection(documentID: id).entities.isEmpty)

        model.selection = [PickID(wholeBody: 0)]
        var s = try service.getSelection(documentID: id)
        #expect(s.entities == [SelectedEntity(id: "box1", type: "body", featureId: "box1")])

        let faceName = try #require(model.meshes[0].mesh.faceNames.first)
        let edgeName = try #require(model.meshes[0].mesh.edgeNames.first)
        model.selection = [PickID(body: 0, face: 0), PickID(body: 0, edge: 0)]
        s = try service.getSelection(documentID: id)
        #expect(s.entities.map(\.type) == ["face", "edge"])
        #expect(AIEntityRef(s.entities[0].id) == .face(FaceRef(body: "box1", face: faceName)))
        #expect(AIEntityRef(s.entities[1].id) == .edge(EdgeRef(body: "box1", edge: edgeName)))
        #expect(s.entities.allSatisfy { $0.featureId == "box1" })
        #expect(s.revision == model.documentRevision)
    }
}
