// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import Foundation
import Testing
@testable import CADKernel

/// 3MF export: a zip of three parts that a slicer can read.
@Suite struct ThreeMFTests {
    private func block() throws -> KBody {
        var s = Sketch()
        s.addRectangle(0, 0, 20, 10)
        var d = CADDocument()
        d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s)))]
        d.features.append(Feature(id: "e", name: "Extrude1", .extrude(ExtrudeFeature(sketch: "sk",
            profiles: [ProfileRef(curves: [], hintU: 10, hintV: 5)], extent: .distance("5 mm")))))
        return try #require(Regenerator.regenerate(d).body("e"))
    }

    @Test func crcMatchesTheStandardCheckValue() {
        #expect(ZipWriter.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test func aBlockBecomesEightSharedVerticesAndTwelveTriangles() throws {
        let mesh = try block().tessellate(linearDeflection: 0.02)
        let welded = ThreeMF.welded(mesh)
        #expect(welded.vertices.count == 8, "\(welded.vertices.count)")
        #expect(welded.triangles.count == 12, "\(welded.triangles.count)")
    }

    @Test func theFileIsAValidZipWithUnitsNamesAndColours() throws {
        let body = try block()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("threemf-\(UUID().uuidString).3mf")
        defer { try? FileManager.default.removeItem(at: url) }
        try ThreeMF.write([(name: "Base & <lid>", body: body, color: BodyColor(hex: "#FF8000"))], to: url)

        func unzip(_ args: [String]) throws -> (Int32, String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            try p.run()
            let out = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: out, as: UTF8.self))
        }
        let test = try unzip(["-t", url.path])
        #expect(test.0 == 0, "\(test.1)")
        let model = try unzip(["-p", url.path, "3D/3dmodel.model"]).1
        #expect(model.contains("unit=\"millimeter\""))
        #expect(model.contains("name=\"Base &amp; &lt;lid&gt;\""))
        #expect(model.contains("displaycolor=\"#FF8000FF\""))
        #expect(model.components(separatedBy: "<triangle ").count - 1 == 12)
        #expect(model.contains("<item objectid=\"2\"/>"))
    }

    @Test func nothingToWriteIsAnError() {
        #expect(throws: KernelError.self) { try ThreeMF.data([]) }
    }
}
