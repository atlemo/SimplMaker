// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import Testing
import simd
@testable import SimplMaker

/// The Lay on Floor tool: click a flat face and its body lies on that face.
@Suite @MainActor struct LayOnFloorToolTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    /// A box "a" 20 mm square and 20 mm tall, lifted 50 mm off the floor, and a cylinder "c" beside it.
    private func loaded() async throws -> DocumentModel {
        var d = CADDocument()
        d.features = [
            Feature(id: "a", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "20 mm", length: "20 mm", height: "20 mm"))),
            Feature(id: "c", name: "Cylinder1", .primitive(PrimitiveFeature(kind: .cylinder, plane: .xy, u: "60 mm", height: "20", diameter: "10"))),
            Feature(id: "m", name: "Move1", .move(MoveFeature(bodies: ["a"], dz: "50 mm"))),
        ]
        let model = DocumentModel(document: d)
        try await settle(model)
        return model
    }

    private func face(_ model: DocumentModel, _ body: String, _ name: String) throws -> PickID {
        let index = try #require(model.meshes.firstIndex { $0.id == body })
        return PickID(body: index, face: try #require(model.meshes[index].mesh.faceNames.firstIndex(of: name)))
    }

    private func lay(_ model: DocumentModel) -> LayOnFloorFeature? {
        guard case .layOnFloor(let f)? = model.document.features.last?.kind else { return nil }
        return f
    }

    @Test func clickingAFaceLaysItsBodyOnTheFloor() async throws {
        let model = try await loaded()
        let cylinderBefore = try #require(model.result?.body("c")?.bounds)
        model.run(.layOnFloor)
        #expect(model.pendingTool == .layOnFloor)
        #expect(model.toolPrompt?.contains("floor") == true)
        model.toolClick(.layOnFloor, try face(model, "a", "a.top"))
        #expect(lay(model)?.face == FaceRef(body: "a", face: "a.top"))
        #expect(model.pendingTool == nil)
        try await settle(model)
        #expect(model.result?.errors.isEmpty == true, "\(model.result?.errors ?? [:])")
        let body = try #require(model.result?.body("a"))
        let frame = try body.faceFrame("a.top")
        #expect(abs(frame.origin.z) < 1e-9 && abs(frame.normal.z + 1) < 1e-9, "\(frame)")
        #expect(try #require(body.bounds).min.z > -1e-6)
        // The other body did not move.
        let cylinderAfter = try #require(model.result?.body("c")?.bounds)
        #expect(cylinderAfter.min == cylinderBefore.min && cylinderAfter.max == cylinderBefore.max, "the cylinder stays")
    }

    @Test func theOtherBodiesInItsFolderTurnAndDropWithIt() async throws {
        let model = try await loaded()
        _ = model.newFolder(holding: ["a", "c"])
        let cylinderBefore = try #require(model.result?.body("c")?.bounds)
        model.toolClick(.layOnFloor, try face(model, "a", "a.top"))
        #expect(lay(model)?.alongside == ["c"])
        try await settle(model)
        #expect(model.result?.errors.isEmpty == true, "\(model.result?.errors ?? [:])")
        // The box lies on its top face: it was 50 to 70 high, and now sits on the floor.
        #expect(abs(try #require(model.result?.body("a")?.bounds).min.z) < 1e-6)
        // The cylinder made the same half turn about the middle of that face (z 70) and dropped by 70 mm: 0...20 became 50...70.
        let cylinder = try #require(model.result?.body("c")?.bounds)
        #expect(abs(cylinder.min.z - 50) < 0.1 && abs(cylinder.max.z - 70) < 0.1, "it moved: \(cylinderBefore) -> \(cylinder)")
        #expect(abs(cylinder.max.z - cylinder.min.z - (cylinderBefore.max.z - cylinderBefore.min.z)) < 1e-6, "same shape")
    }

    @Test func bodiesOutsideTheFolderStayPut() async throws {
        let model = try await loaded()
        model.toolClick(.layOnFloor, try face(model, "a", "a.top"))
        #expect(lay(model)?.alongside.isEmpty == true)
    }

    @Test func aFaceAlreadySelectedLaysAtOnce() async throws {
        let model = try await loaded()
        model.selection = [try face(model, "a", "a.bottom")]
        model.run(.layOnFloor)
        #expect(lay(model)?.face == FaceRef(body: "a", face: "a.bottom"))
        #expect(model.pendingTool == nil)
    }

    @Test func aCurvedFaceIsRefusedAndTheToolKeepsWaiting() async throws {
        let model = try await loaded()
        model.run(.layOnFloor)
        let cylinder = try #require(model.result?.body("c"))
        let round = try #require(cylinder.faceNames.first { (try? cylinder.faceFrame($0)) == nil })
        let before = model.document.features.count
        model.toolClick(.layOnFloor, try face(model, "c", round))
        #expect(model.document.features.count == before)
        #expect(model.alert?.title.contains("flat") == true)
        #expect(model.pendingTool == .layOnFloor)
    }

    @Test func theFaceContextMenuHasIt() async throws {
        let model = try await loaded()
        let items = model.contextItems(for: try face(model, "a", "a.top"), ray: nil)
        #expect(items.compactMap(\.title).contains("Lay Face on Floor"))
    }

    @Test func itHasAShortcutAndAnIconOfItsOwn() {
        #expect(DesignTool.layOnFloor.symbol == "lay-on-floor" && IconGlyphs.table["lay-on-floor"] != nil)
        let chords = DesignTool.allCases.map { KeyChord($0.defaultKey, $0.defaultModifiers) }
        #expect(Set(chords).count == chords.count, "two tools share a shortcut")
    }
}
