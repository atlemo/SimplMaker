// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplMaker

/// File → Import ▸ DXF as Sketch…, and the sketch coming back out as DXF.
@Suite @MainActor struct ImportDXFTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    /// A 40 × 20 plate with a round hole, as a laser-cutter file would hold it.
    private let plate = """
        0\nSECTION\n2\nENTITIES
        0\nLWPOLYLINE\n90\n4\n70\n1\n10\n0\n20\n0\n10\n40\n20\n0\n10\n40\n20\n20\n10\n0\n20\n20
        0\nCIRCLE\n10\n20\n20\n10\n40\n4
        0\nENDSEC\n0\nEOF

        """

    @Test func aDXFPlateBecomesASketchWithAHoleAndComesBackOut() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Plate.dxf")
        try Data(plate.utf8).write(to: url)

        let model = DocumentModel()
        try await settle(model)
        #expect(await model.importSVG(from: url))
        try await settle(model)
        let f = try #require(model.document.features.last)
        let sk = try #require(model.result?.sketches[f.id])
        #expect(model.result?.errors.isEmpty == true, "\(model.result?.errors ?? [:])")
        #expect(sk.regions.count == 2, "the plate and the hole's disc: \(sk.regions.map(\.area))")

        let out = DXFExport.text(sk.solved)
        let back = try DXFImport.sketch(from: Data(out.utf8))
        #expect(back.curveCount == 5 && abs(back.width - 40) < 1e-6 && abs(back.height - 20) < 1e-6)
    }

    @Test func aBrokenFileSaysWhy() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).dxf")
        try Data("not a drawing".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = DocumentModel()
        try await settle(model)
        #expect(await model.importSVG(from: url) == false)
        #expect(model.alert?.message.contains("DXF") == true, "\(model.alert?.message ?? "")")
    }
}
