// Copyright © 2026 Atle Mo. All rights reserved.
import AppKit
import CADCore
import CADKernel
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import simd
@testable import SimplMaker

/// Sketching as drawn: the slice cuts away what lies between the sketch plane and the camera, and faces are lit
/// evenly. Set SLICE_DUMP_DIR to also write each picture there as a PNG.
@Suite(.serialized) @MainActor struct SketchSliceRenderTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    /// A 60 × 40 × 30 mm box shelled open at the top, and a plane across its middle (y = 0) to sketch on.
    private func loaded() async throws -> DocumentModel {
        var d = CADDocument()
        d.features = [
            Feature(id: "a", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "60 mm", length: "40 mm", height: "30 mm"))),
            Feature(id: "sh", name: "Shell1", .shell(ShellFeature(body: "a", faces: [FaceRef(body: "a", face: "a.top")]))),
            Feature(id: "p", name: "Plane1", .plane(PlaneFeature(base: .xz, offset: "0 mm"))),
        ]
        let model = DocumentModel(document: d)
        try await settle(model)
        return model
    }

    private func render(_ model: DocumentModel, name: String, flatOn: Bool = false, sketching: Bool = false) async throws -> [UInt8] {
        let view = ViewportMTKView(frame: NSRect(x: 0, y: 0, width: 800, height: 560), device: nil)
        let renderer = try #require(Renderer())
        view.device = renderer.device
        view.renderer = renderer
        view.model = model
        view.colorPixelFormat = Renderer.colorFormat
        view.depthStencilPixelFormat = Renderer.depthFormat
        view.framebufferOnly = false
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        renderer.setScene(model.visibleMeshes)
        renderer.showGrid = false
        renderer.showAxes = false
        renderer.sketchSlice = model.sketchSlicePlane
        if flatOn {  // close up and square on to a wall, in perspective: the glare would sweep over it
            renderer.camera.orthographic = false
            renderer.camera.target = SIMD3(0, 0, 15)
            renderer.camera.distance = 90
            renderer.camera.yaw = 0
            renderer.camera.pitch = 0
        } else {
            renderer.camera.orthographic = true
            renderer.camera.target = SIMD3(30, 20, 15)
            renderer.camera.distance = 200
            renderer.camera.yaw = 0.35
            renderer.camera.pitch = 0.45
        }
        if sketching, let f = model.sketchSession?.frame {
            renderer.setSketchGrid(SketchGrid(frame: f, minor: 1, major: 10, u: -50...50, v: -50...50, lines: false))
        }
        renderer.setOverlay(model.sketchOverlay())

        var bytes: [UInt8] = [], last: [UInt8] = []
        var size = (0, 0)
        for _ in 0..<40 {
            view.draw(view.bounds)
            try await Task.sleep(for: .milliseconds(100))
            let texture = try #require(view.currentDrawable?.texture)
            bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
            size = (texture.width, texture.height)
            texture.getBytes(&bytes, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
            if bytes == last { break }
            last = bytes
        }
        if let dir = ProcessInfo.processInfo.environment["SLICE_DUMP_DIR"] {
            var rgba = bytes
            for i in stride(from: 0, to: rgba.count, by: 4) { rgba.swapAt(i, i + 2) }
            let provider = try #require(CGDataProvider(data: Data(rgba) as CFData))
            let image = try #require(CGImage(width: size.0, height: size.1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size.0 * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                             provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            let destination = try #require(CGImageDestinationCreateWithURL(URL(fileURLWithPath: dir + "/\(name).png") as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
        }
        withExtendedLifetime(window) {}
        return bytes
    }

    @Test func theSliceCutsAwayWhatIsBetweenThePlaneAndTheCamera() async throws {
        let model = try await loaded()
        model.beginSketch(on: .plane("p"))
        model.sketchSlice = false  // it came on by itself: this plane is behind a wall
        #expect(model.sketchSession != nil && model.sketchSlicePlane == nil)
        let whole = try await render(model, name: "unsliced")
        model.sketchSlice = true
        let plane = try #require(model.sketchSlicePlane)
        #expect(abs(plane.origin.y) < 1e-3 && abs(abs(plane.normal.y) - 1) < 1e-3)
        let sliced = try await render(model, name: "sliced")
        #expect(whole != sliced, "the front half of the box is gone")
        model.finishSketch()
        #expect(model.sketchSlicePlane == nil, "only while sketching")
    }

    /// The spread of brightness over the middle of the picture.
    private func spread(_ bytes: [UInt8], width: Int = 1600) -> Int {
        let height = bytes.count / 4 / width
        var lo = 255, hi = 0
        for y in (height / 2 - 100)..<(height / 2 + 100) {
            for x in (width / 2 - 100)..<(width / 2 + 100) {
                let i = (y * width + x) * 4
                let l = (Int(bytes[i]) + Int(bytes[i + 1]) + Int(bytes[i + 2])) / 3
                lo = min(lo, l); hi = max(hi, l)
            }
        }
        return hi - lo
    }

    @Test func aFlatFaceIsLitEvenlyWhileSketching() async throws {
        let model = try await loaded()
        let lit = try await render(model, name: "flat-lit", flatOn: true)
        model.beginSketch(on: .yz)
        let even = try await render(model, name: "flat-even", flatOn: true, sketching: true)
        let (a, b) = (spread(lit), spread(even))
        #expect(b < a && b <= 4, "brightness varies by \(a) normally and \(b) while sketching")
    }

    // MARK: knowing when the plane is hidden

    @Test func aPlaneBetweenWallsIsHiddenSoTheSliceComesOnAndExplainsItselfOnce() async throws {
        UserDefaults.standard.removeObject(forKey: DocumentModel.sliceExplainedKey)
        defer { UserDefaults.standard.removeObject(forKey: DocumentModel.sliceExplainedKey) }
        let model = try await loaded()
        model.beginSketch(on: .plane("p"))  // across the middle of the box, with a wall in front of it
        #expect(model.sketchSlice, "the front wall hides it")
        #expect(model.alert?.title.contains("hidden") == true, "told why, the first time")
        model.alert = nil
        model.finishSketch()
        model.beginSketch(on: .plane("p"))
        #expect(model.sketchSlice && model.alert == nil, "on again, without the explanation")
    }

    @Test func aPlaneInTheOpenOrOnAFaceIsNotHidden() async throws {
        let model = try await loaded()
        let up = SIMD3<Double>(0, 0, 1), x = SIMD3<Double>(1, 0, 0)
        #expect(!model.isSketchPlaneHidden(Frame(origin: SIMD3(0, 0, 40), normal: up, xAxis: x)), "above the box: nothing in front")
        #expect(!model.isSketchPlaneHidden(Frame(origin: SIMD3(0, 0, 30), normal: up, xAxis: x)), "on the rim of the box")
        #expect(!model.isSketchPlaneHidden(.xy), "the box stands on the floor: it doesn't hide it")
        #expect(model.isSketchPlaneHidden(Frame(origin: SIMD3(0, 0, 10), normal: up, xAxis: x)) == false,
                "inside the open box, looking down into it: nothing is in front")
        model.beginSketch(on: .xy)
        #expect(!model.sketchSlice)
    }

    @Test func aNewSketchStartsWithoutTheSliceUnlessThePlaneIsHidden() async throws {
        let model = try await loaded()
        model.sketchSlice = true  // left on from an earlier sketch
        model.beginSketch(on: .xy)
        #expect(!model.sketchSlice)
    }
}
