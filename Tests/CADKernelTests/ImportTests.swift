// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import Testing
@testable import CADKernel

/// STEP import: a body read from a file kept in the document.
@Suite struct ImportTests {
    /// A 20 × 10 × 5 box, written to a STEP file and read back as bytes.
    private func boxSTEP() throws -> Data {
        let box = try KBody.primitive(.box(width: 20, length: 10, height: 5), on: .xy, featureID: "b")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("simplcad-import-\(UUID().uuidString).step")
        defer { try? FileManager.default.removeItem(at: url) }
        try KBody.exportSTEP([box], to: url)
        return try Data(contentsOf: url)
    }

    /// Each test uses its own feature id: imported bodies are cached by it, across tests running at once.
    private func importing(_ data: Data, id: FeatureID, then extra: [Feature] = []) -> CADDocument {
        var d = CADDocument()
        d.parameters = [Parameter("r", "1 mm")]
        d.features = [Feature(id: id, name: "Import1", .importBody(ImportFeature(fileName: "box.step", data: data)))] + extra
        return d
    }

    @Test func anImportedBodyCanBeFilletedAndMoved() throws {
        let data = try boxSTEP()
        let plain = Regenerator.regenerate(importing(data, id: "imp"))
        #expect(plain.errors.isEmpty, "\(plain.errors)")
        let body = try #require(plain.body("imp"))
        #expect(abs(body.volume - 1000) < 1e-6 && body.faceNames.count == 6)
        #expect(body.faceNames.allSatisfy { $0.hasPrefix("imp.face") }, "\(body.faceNames)")

        // Features after it find its edges by name, rebuild after rebuild.
        let edge = try #require(body.edgeNames.first)
        let d = importing(data, id: "imp", then: [
            Feature(id: "f", name: "Fillet1", .fillet(EdgeFeature(edges: [EdgeRef(body: "imp", edge: edge)], size: "r"))),
            Feature(id: "m", name: "Move1", .move(MoveFeature(bodies: ["imp"], dx: "30 mm"))),
        ])
        let r = Regenerator.regenerate(d)
        #expect(r.errors.isEmpty, "\(r.errors)")
        let moved = try #require(r.body("imp"))
        #expect(moved.volume < 1000 && moved.volume > 990)
        #expect(abs((moved.bounds?.min.x ?? 0) - 20) < 1e-3)  // boxes carry the edge tolerances
    }

    @Test func aParameterChangeDoesNotReadTheFileAgain() throws {
        var d = importing(try boxSTEP(), id: "cached")
        let first = try #require(Regenerator.regenerate(d).body("cached"))
        d.parameters[0].expression = "2 mm"
        let second = try #require(Regenerator.regenerate(d).body("cached"))
        #expect(first === second)
    }

    @Test func aFileThatIsNotSTEPFailsTheFeature() {
        let r = Regenerator.regenerate(importing(Data("hello".utf8), id: "bad"))
        #expect(r.bodies.isEmpty)
        #expect(r.errors["bad"]?.contains("STEP") == true, "\(r.errors)")
    }

    @Test func theFileTravelsWithTheDocument() throws {
        let d = importing(try boxSTEP(), id: "saved")
        let back = try CADDocument.decode(try d.encoded())
        #expect(back == d)
        #expect(back.features[0].createsBody && back.features[0].typeName == "Import")
    }
}
