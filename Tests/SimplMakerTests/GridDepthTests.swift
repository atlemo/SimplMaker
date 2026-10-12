// The ground grid goes behind the bodies that stand on it, however long its lines are.
// Copyright © 2026 Atle Mo. All rights reserved.
import AppKit
import CADCore
import Foundation
import Testing
@testable import SimplMaker

@Suite(.serialized) @MainActor struct GridDepthTests {
    private func rgba(_ png: Data) throws -> (width: Int, height: Int, rgba: [UInt8]) {
        let rep = try #require(NSBitmapImageRep(data: png))
        let image = try #require(rep.cgImage)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (image.width, image.height, bytes)
    }

    /// How many pixels of the body (as drawn without the grid) are different once the grid is drawn: grid lines showing through it.
    private func throughTheBody(elevation: Double, azimuth: Double, perspective: Bool = false, size: Int = 60) async throws -> Int {
        let rig = AIServiceTests.Rig()
        let (id, model) = await rig.open(CADDocument())
        _ = try await rig.service.createBox(documentID: id, CADService.BoxRequest(width: "\(size)", length: "\(size * 2 / 3)", height: "\(size / 2)", id: "base"))
        var noGrid = SnapshotOptions(); noGrid.perspective = perspective
        let plain = try await ViewportSnapshot.render(model, direction: .iso, azimuth: azimuth, elevation: elevation, width: 800, height: 600, axes: false, options: noGrid)
        var withGrid = noGrid; withGrid.grid = true
        let gridded = try await ViewportSnapshot.render(model, direction: .iso, azimuth: azimuth, elevation: elevation, width: 800, height: 600, axes: false, options: withGrid)
        if let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DUMP_DIR"] {
            try? gridded.png.write(to: URL(fileURLWithPath: dir + "/grid-\(perspective ? "p" : "o")\(size)-\(Int(elevation))-\(Int(azimuth)).png"))
        }
        let a = try rgba(plain.png), b = try rgba(gridded.png)
        let bg = Array(a.rgba[0..<4])
        func isBody(_ x: Int, _ y: Int) -> Bool {
            let i = (y * a.width + x) * 4
            return abs(Int(a.rgba[i]) - Int(bg[0])) + abs(Int(a.rgba[i + 1]) - Int(bg[1])) + abs(Int(a.rgba[i + 2]) - Int(bg[2])) > 60
        }
        // Only pixels well inside the body count: along its outline a pixel is part body, part background, and the grid
        // behind the background part is right.
        let margin = 3
        var count = 0
        for y in margin..<(a.height - margin) { for x in margin..<(a.width - margin) {
            var inside = true
            scan: for dy in -margin...margin { for dx in -margin...margin where !isBody(x + dx, y + dy) { inside = false; break scan } }
            guard inside else { continue }
            let i = (y * a.width + x) * 4
            let diff = abs(Int(a.rgba[i]) - Int(b.rgba[i])) + abs(Int(a.rgba[i + 1]) - Int(b.rgba[i + 1])) + abs(Int(a.rgba[i + 2]) - Int(b.rgba[i + 2]))
            if diff > 30 { count += 1 }
        } }
        return count
    }

    @Test func theGridIsHiddenFromUnderTheFloor() {
        var camera = Camera()
        camera.target = SIMD3(0, 0, 40)
        for orthographic in [true, false] {
            camera.orthographic = orthographic
            camera.pitch = 0.4
            #expect(!camera.isBelowGround)
            camera.pitch = -0.1
            #expect(camera.isBelowGround == orthographic, "an orthographic view looks up at the floor from any negative pitch; a perspective one needs the eye itself below it (here it is still 18 mm up)")
            camera.pitch = -1.2
            #expect(camera.isBelowGround)
        }
    }

    @Test func gridNeverShowsThroughTheBody() async throws {
        for perspective in [false, true] { for size in [60, 400] { for elevation in [3.0, 10.0, 30.0] {
            for azimuth in [-60.0, 20.0] {
                let n = try await throughTheBody(elevation: elevation, azimuth: azimuth, perspective: perspective, size: size)
                // A few pixels where the body meets the ground are fine.
                #expect(n < 20, "\(perspective ? "perspective" : "orthographic"), size \(size), elevation \(elevation)°, azimuth \(azimuth)°: \(n) body pixels have grid lines over them")
            }
        } } }
    }
}
