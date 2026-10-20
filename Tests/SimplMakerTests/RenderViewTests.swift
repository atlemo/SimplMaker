// Copyright © 2026 Atle Mo. All rights reserved.
import AppKit
import CADCore
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
import simd
@testable import SimplMaker

/// The Render view as drawn: a solid floor in place of the grid, and a light that stays where it is set.
/// Set RENDER_DUMP_DIR to also write each picture there as a PNG.
@Suite @MainActor struct RenderViewTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    /// A 60 × 40 × 30 mm box standing on the floor, and a cylinder beside it.
    private func loaded() async throws -> DocumentModel {
        var d = CADDocument()
        d.features = [
            Feature(id: "a", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "60 mm", length: "40 mm", height: "30 mm"))),
            Feature(id: "c", name: "Cylinder1", .primitive(PrimitiveFeature(kind: .cylinder, plane: .xy, u: "90 mm", height: "30", diameter: "20"))),
        ]
        let model = DocumentModel(document: d)
        try await settle(model)
        return model
    }

    struct Picture {
        var width: Int, height: Int
        var bgra: [UInt8]
        func color(_ x: Int, _ y: Int) -> SIMD3<Float> {
            let i = (y * width + x) * 4
            return SIMD3(Float(bgra[i + 2]), Float(bgra[i + 1]), Float(bgra[i])) / 255
        }
    }

    private func render(_ model: DocumentModel, name: String, settings: RenderSettings?, grid: Bool = true,
                        yaw: Float = -.pi / 3, pitch: Float = 0.55, orthographic: Bool = true) async throws -> (Picture, Renderer, ViewportMTKView) {
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
        renderer.showGrid = grid
        renderer.showAxes = grid
        renderer.renderSettings = settings
        renderer.sceneBounds = model.sceneBounds
        renderer.camera.orthographic = orthographic
        renderer.camera.target = SIMD3(45, 20, 15)
        renderer.camera.distance = 260
        renderer.camera.yaw = yaw
        renderer.camera.pitch = pitch
        renderer.setOverlay(model.sketchOverlay())

        var picture = Picture(width: 0, height: 0, bgra: [])
        var last: [UInt8] = []
        for _ in 0..<40 {
            view.draw(view.bounds)
            try await Task.sleep(for: .milliseconds(100))
            guard let texture = view.fullSizeTexture else { continue }
            var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
            texture.getBytes(&bytes, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
            picture = Picture(width: texture.width, height: texture.height, bgra: bytes)
            if bytes == last && !ViewportSnapshot.isBlank(bytes) { break }
            last = bytes
        }
        try #require(picture.width > 0, "no frame came at the view's full size")
        if let dir = ProcessInfo.processInfo.environment["RENDER_DUMP_DIR"] { try dump(picture, to: dir + "/\(name).png") }
        withExtendedLifetime(window) {}
        return (picture, renderer, view)
    }

    private func dump(_ p: Picture, to path: String) throws {
        var rgba = p.bgra
        for i in stride(from: 0, to: rgba.count, by: 4) { rgba.swapAt(i, i + 2) }
        let provider = try #require(CGDataProvider(data: Data(rgba) as CFData))
        let image = try #require(CGImage(width: p.width, height: p.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: p.width * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try #require(CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    /// Where a point of the scene lands in the picture, in its pixels.
    private func pixel(of p: SIMD3<Float>, _ picture: Picture, _ renderer: Renderer, _ view: ViewportMTKView) -> (x: Int, y: Int) {
        let q = renderer.camera.project(p, viewSize: view.bounds.size)!
        let scale = CGFloat(picture.width) / view.bounds.width
        return (Int(q.x * scale), Int(q.y * scale))
    }

    @Test func theFloorReplacesTheGridAndTheBackdropIsTheFloorsOwnColour() async throws {
        let model = try await loaded()
        var settings = RenderSettings.quiet
        settings.floor = .white
        let (picture, renderer, view) = try await render(model, name: "studio", settings: settings)
        // A spot of floor well away from the bodies, where the grid used to have its lines, is the floor's lit colour, everywhere the same.
        let a = pixel(of: SIMD3(-10, 80, 0), picture, renderer, view), b = pixel(of: SIMD3(-10, 83, 0), picture, renderer, view)
        let floorA = picture.color(a.x, a.y), floorB = picture.color(b.x, b.y)
        #expect(simd_distance(floorA, floorB) < 0.01, "no grid line crosses the floor")
        #expect(abs(floorA.x - settings.floorColor.x) < 0.04, "the floor is the colour the settings give: \(floorA) vs \(settings.floorColor)")
        // The corner of the picture is floor fading into the backdrop: between the two.
        let corner = picture.color(2, 2)
        #expect(corner.x > settings.backdropColor.x - 0.04 && corner.x < settings.floorColor.x + 0.04, "the backdrop: \(corner)")
    }

    @Test func withoutRenderSettingsTheViewIsAsItWas() async throws {
        let model = try await loaded()
        let (plain, _, _) = try await render(model, name: "plain", settings: nil)
        let (rendered, _, _) = try await render(model, name: "plain-rendered", settings: RenderSettings())
        #expect(abs(plain.color(2, 2).x - rendered.color(2, 2).x) > 0.3, "the usual background, not the floor")
    }

    @Test func theLightStaysWhereItIsSetWhenTheViewTurns() async throws {
        let model = try await loaded()
        var settings = RenderSettings.quiet
        settings.direction = 0     // from the +X side
        settings.height = 20
        settings.brightness = 1.2
        settings.ambient = 0.2
        let lo = try #require(model.sceneBounds).min  // the box's near-bottom corner on the floor
        // Seen from two directions, the box's +X wall is the lit one both times (the highlight on it moves with the view).
        func wallBrightness(yaw: Float) async throws -> (lit: Float, dark: Float) {
            let (picture, renderer, view) = try await render(model, name: "light-\(Int(yaw * 100))", settings: settings, yaw: yaw, pitch: 0.25)
            let lit = pixel(of: SIMD3(lo.x + 60, lo.y + 20, 15), picture, renderer, view)    // the +X wall
            let dark = pixel(of: SIMD3(lo.x + 30, lo.y, 15), picture, renderer, view)    // the -Y wall, which both views see too
            return (picture.color(lit.x, lit.y).x, picture.color(dark.x, dark.y).x)
        }
        let a = try await wallBrightness(yaw: -.pi / 3)
        let b = try await wallBrightness(yaw: -.pi / 6)
        #expect(a.lit > a.dark + 0.1, "the wall toward the light is brighter: \(a)")
        #expect(b.lit > b.dark + 0.1, "and from another side too: \(b)")
    }

    /// A box's shadow falls on the floor away from the light, and not at all without shadows; the floor under the box shows it upside down.
    @Test func bodiesCastShadowsAndShowInTheFloor() async throws {
        let model = try await loaded()
        let lo = try #require(model.sceneBounds).min
        var settings = RenderSettings.quiet
        settings.direction = 0   // the light comes from the +X side: the shadow falls toward -X
        settings.height = 40
        settings.softness = 0.1
        settings.reflection = 0
        func floorBrightness(_ settings: RenderSettings, at p: SIMD3<Float>, name: String) async throws -> Float {
            let (picture, renderer, view) = try await render(model, name: name, settings: settings, yaw: -.pi / 3, pitch: 0.7)
            let q = pixel(of: p, picture, renderer, view)
            return picture.color(q.x, q.y).x
        }
        let inShadow = SIMD3<Float>(lo.x - 12, lo.y + 20, 0), clear = SIMD3<Float>(lo.x + 30, lo.y + 120, 0)
        let shaded = try await floorBrightness(settings, at: inShadow, name: "shadow")
        let open = try await floorBrightness(settings, at: clear, name: "shadow-open")
        #expect(shaded < open - 0.15, "the floor beside the box, away from the light, is in its shadow: \(shaded) vs \(open)")
        settings.shadows = false
        let none = try await floorBrightness(settings, at: inShadow, name: "no-shadow")
        #expect(abs(none - open) < 0.03, "no shadow without shadows: \(none) vs \(open)")

        // The reflection: the floor just in front of the box's foot is darker with it than without.
        settings.shadows = false
        let foot = SIMD3<Float>(lo.x + 30, lo.y - 3, 0)
        settings.reflection = 0
        let bare = try await floorBrightness(settings, at: foot, name: "no-reflection")
        settings.reflection = 1
        let mirrored = try await floorBrightness(settings, at: foot, name: "reflection")
        #expect(mirrored < bare - 0.02, "the floor shows the box: \(mirrored) vs \(bare)")
    }

    /// Blur softens the reflection: along a row through the box's reflection its side edge is a gentler step, while the
    /// foot of the box (where it meets the floor) stays about as dark.
    @Test func theReflectionCanBeBlurred() async throws {
        let model = try await loaded()
        let lo = try #require(model.sceneBounds).min
        var settings = RenderSettings.quiet
        settings.shadows = false
        settings.reflection = 1
        func scan(blur: Double, name: String) async throws -> (steepest: Float, foot: Float) {
            settings.reflectionBlur = blur
            let (picture, renderer, view) = try await render(model, name: name, settings: settings, yaw: -.pi / 3, pitch: 0.7)
            let foot = pixel(of: SIMD3(lo.x + 30, lo.y, 0), picture, renderer, view)
            let corner = pixel(of: SIMD3(lo.x + 60, lo.y, 0), picture, renderer, view)  // the box's lowest point on the screen
            let row = corner.y + 18  // below the box, well down its reflection, where the blur has grown
            var steepest: Float = 0, last = picture.color(max(foot.x - 330, 1), row).x
            for x in max(foot.x - 329, 2)..<min(foot.x + 330, picture.width - 1) {
                let c = picture.color(x, row).x
                steepest = max(steepest, abs(c - last))
                last = c
            }
            return (steepest, picture.color(foot.x, foot.y + 4).x)
        }
        let sharp = try await scan(blur: 0, name: "blur-0")
        let soft = try await scan(blur: 1, name: "blur-1")
        _ = try await scan(blur: 0.5, name: "blur-half")
        #expect(sharp.steepest > 0.015, "the unblurred reflection has an edge: \(sharp.steepest)")
        #expect(soft.steepest < sharp.steepest * 0.7, "the blurred one is gentler: \(soft.steepest) vs \(sharp.steepest)")
    }

    /// Noise is grain over the floor, the backdrop and the bodies alike: flat colour turns grainy, and none at 0.
    @Test func noiseGrainsTheWholeView() async throws {
        let model = try await loaded()
        let lo = try #require(model.sceneBounds).min
        var settings = RenderSettings.quiet
        settings.shadows = false
        settings.reflection = 0
        func grain(_ noise: Double, name: String) async throws -> (floor: Float, body: Float) {
            settings.noise = noise
            let (picture, renderer, view) = try await render(model, name: name, settings: settings, yaw: -.pi / 3, pitch: 0.7)
            /// How much a patch of flat colour varies, as the mean step between neighbouring pixels.
            func roughness(_ centre: (x: Int, y: Int)) -> Float {
                var total: Float = 0, count: Float = 0
                for y in (centre.y - 12)..<(centre.y + 12) {
                    for x in (centre.x - 12)..<(centre.x + 12) {
                        total += abs(picture.color(x + 1, y).x - picture.color(x, y).x)
                        count += 1
                    }
                }
                return total / count
            }
            let floorSpot = pixel(of: SIMD3(lo.x - 40, lo.y + 100, 0), picture, renderer, view)
            let bodySpot = pixel(of: SIMD3(lo.x + 30, lo.y + 20, 30), picture, renderer, view)  // the middle of the box's top
            return (roughness(floorSpot), roughness(bodySpot))
        }
        let quiet = try await grain(0, name: "noise-0")
        let grainy = try await grain(1, name: "noise-1")
        _ = try await grain(0.2, name: "noise-default")
        #expect(quiet.floor < 0.004 && quiet.body < 0.004, "no grain without noise: \(quiet)")
        #expect(grainy.floor > 0.015, "the floor is grainy: \(grainy.floor)")
        #expect(grainy.body > 0.015, "and so is the body: \(grainy.body)")
    }

    /// Export render: the view's picture as PNG data, at the view's full size, the same as what it drew.
    @Test func theViewCanHandOverItsPictureAsAPNG() async throws {
        let model = try await loaded()
        var settings = RenderSettings.quiet
        settings.shadows = false
        let (picture, _, view) = try await render(model, name: "export-source", settings: settings)
        let png: Data? = await withCheckedContinuation { continuation in
            view.exportPNG { continuation.resume(returning: $0) }
        }
        let data = try #require(png, "a picture came back")
        if let dir = ProcessInfo.processInfo.environment["RENDER_DUMP_DIR"] { try data.write(to: URL(fileURLWithPath: dir + "/export.png")) }
        let rep = try #require(NSBitmapImageRep(data: data))
        #expect(rep.pixelsWide == picture.width && rep.pixelsHigh == picture.height, "full size: \(rep.pixelsWide) x \(rep.pixelsHigh)")
        // The middle of the box and a spot of floor are the same colours in the PNG as in the view's own frame.
        for (x, y) in [(picture.width / 4, picture.height / 2), (10, 10), (picture.width - 10, picture.height - 10)] {
            var raw = [Int](repeating: 0, count: 5)
            rep.getPixel(&raw, atX: x, y: y)
            let seen = picture.color(x, y)
            #expect(abs(Float(raw[0]) / 255 - seen.x) < 0.01 && abs(Float(raw[2]) / 255 - seen.z) < 0.01, "pixel \(x),\(y): \(raw) vs \(seen)")
        }
        #expect(view.framebufferOnly, "the view goes back to only displaying its frames")
    }

    /// The Render view shows the part alone: no sketch curves, profile fills or construction planes, until a tool needs them.
    @Test func theRenderViewLeavesOutSketchesAndPlanes() async throws {
        var sketch = Sketch()
        let r = sketch.addRectangle(0, 0, 10, 10, lineIDs: ["A", "B", "C", "D"])
        sketch.constrain(.fix(r.corners[0], x: 0, y: 0)); sketch.constrain(.fix(r.corners[2], x: 10, y: 10))
        var d = CADDocument()
        d.features = [
            Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: sketch))),
            Feature(id: "p", name: "Plane1", .plane(PlaneFeature(base: .xz, offset: "5 mm"))),
        ]
        let model = DocumentModel(document: d)
        try await settle(model)
        let before = model.sketchOverlay()
        #expect(!before.inactive.isEmpty && !before.regionIndices.isEmpty && !before.planeIndices.isEmpty, "they show as usual")

        model.setRenderView(true)
        let rendered = model.sketchOverlay()
        #expect(rendered.inactive.isEmpty && rendered.regionIndices.isEmpty && rendered.planeIndices.isEmpty
                && rendered.planeOutline.isEmpty && rendered.planeEdges.isEmpty, "the Render view leaves them out")

        model.pendingTool = .extrude   // a tool waiting for a profile needs the sketch
        #expect(!model.sketchOverlay().regionIndices.isEmpty, "a tool that picks profiles has them back")
        model.pendingTool = nil

        model.setRenderView(false)
        #expect(!model.sketchOverlay().inactive.isEmpty, "and they return when the view is off")
    }

    @Test func noiseStartsAtTenPercent() {
        #expect(RenderSettings().noise == 0.1)
    }

    @Test func settingsKeptByAnOlderVersionStillLoad() throws {
        let old = #"{"floor":"sand","brightness":1,"direction":-90,"height":40,"ambient":0.3,"showEdges":true}"#
        let s = try JSONDecoder().decode(RenderSettings.self, from: Data(old.utf8))
        #expect(s.floor == .sand && s.showEdges && s.brightness == 1)
        #expect(s.shadows && s.reflection == RenderSettings().reflection, "the newer settings keep their defaults")
    }

    @Test func theLightMatrixTakesInTheWholePartAndTheFloorUnderIt() {
        let lo = SIMD3<Float>(0, 0, 0), hi = SIMD3<Float>(60, 40, 30)
        let light = SIMD3<Float>(0.5, -0.4, 0.77)
        let m = Renderer.lightProjection(toward: light, lo: lo, hi: hi)
        for i in 0..<8 {
            let p = SIMD4<Float>(i & 1 == 0 ? lo.x : hi.x, i & 2 == 0 ? lo.y : hi.y, i & 4 == 0 ? lo.z : hi.z, 1)
            let c = m.matrix * p
            #expect(abs(c.x) <= 1.001 && abs(c.y) <= 1.001 && c.z >= -0.001 && c.z <= 1.001, "corner \(i) lands in the map: \(c)")
        }
        // Floor under the part, along the light, is inside the depth range too.
        let floor = m.matrix * SIMD4<Float>(0, 0, 0, 1)
        #expect(floor.z >= -0.001 && floor.z <= 1.001)
        #expect(m.depth > 30 && m.extent.x > 40)
    }

    @Test func theRenderViewIsOffInSketchAndExclusiveWithThePrintPreview() async throws {
        let model = try await loaded()
        model.setRenderView(true)
        #expect(model.renderView && model.showRenderOptions)
        model.setPrintPreview(true)
        #expect(!model.renderView && model.printPreview)
        model.setRenderView(true)
        #expect(model.renderView && !model.printPreview)
        model.visualStyle = .wireframe
        model.setRenderView(true)
        #expect(model.visualStyle.isShaded, "the render view needs a shaded style")
    }

    @Test func theDialsBearingIsACompassAngleFromAbove() {
        var s = RenderSettings()
        s.direction = 90      // toward +Y: straight up on a dial seen from above
        #expect(abs(s.bearing - 0) < 1e-9)
        s.direction = 0       // toward +X: a quarter turn clockwise
        #expect(abs(s.bearing - 90) < 1e-9)
        s.direction = -90
        #expect(abs(s.bearing - 180) < 1e-9)
        s.direction = 180
        #expect(abs(s.bearing - 270) < 1e-9)
        for b in stride(from: 0.0, to: 360.0, by: 37.0) {   // and back again
            s.bearing = b
            #expect(abs(s.bearing - b) < 1e-9, "\(b)")
            #expect(s.direction > -180 && s.direction <= 180)
        }
    }

    @Test func adjustingALightLeavesThePresetForCustom() {
        var s = RenderSettings()
        #expect(s.matchingPreset == .studio)
        s.apply(.soft)
        #expect(s.matchingPreset == .soft)
        s.brightness += 0.1
        #expect(s.matchingPreset == nil, "Custom")
        s.apply(.dramatic)
        #expect(s.matchingPreset == .dramatic)
        s.softness = 0.9
        #expect(s.matchingPreset == .dramatic, "the shadows' softness is not part of the light")
        s.floor = .sand
        s.reflection = 0
        #expect(s.matchingPreset == .dramatic, "the floor and reflection are not the light")
    }

    /// Only for looking at: the panel drawn to a picture.
    @Test func thePanelAsAPicture() throws {
        guard let dir = ProcessInfo.processInfo.environment["RENDER_DUMP_DIR"] else { return }
        let model = DocumentModel(document: CADDocument())
        model.renderSettings.floor = .mid
        model.renderSettings.softness = 0.95
        let content = RenderPanel(model: model)
            .padding(30)
            .background(Color(white: 0.16))
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: content)
        host.appearance = NSAppearance(named: .darkAqua)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: dir + "/panel.png"))
        withExtendedLifetime(window) {}
    }

    @Test func thePresetsSetTheLight() {
        var s = RenderSettings()
        s.apply(.dramatic)
        #expect(s.brightness > RenderSettings().brightness && s.ambient < RenderSettings().ambient)
        s.apply(.studio)
        #expect(s == RenderSettings())
    }

    /// Only for looking at: a harsh low light on a dark floor, in perspective, as a picture.
    @Test func dramaticLightOnADarkFloor() async throws {
        let model = try await loaded()
        var settings = RenderSettings.quiet
        settings.apply(.dramatic)
        settings.floor = .charcoal
        _ = try await render(model, name: "dramatic", settings: settings, yaw: -.pi / 4, pitch: 0.4, orthographic: false)
        settings.apply(.soft)
        settings.floor = .sand
        settings.showEdges = true
        _ = try await render(model, name: "soft", settings: settings, yaw: -.pi / 3, pitch: 0.9)
    }
}

private extension RenderSettings {
    /// The default settings without grain, so the pictures' flat colours stay flat for the tests that compare pixels.
    static var quiet: RenderSettings {
        var s = RenderSettings()
        s.noise = 0
        return s
    }
}
