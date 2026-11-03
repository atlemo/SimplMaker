// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
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
                        yaw: Float = -.pi / 3, pitch: Float = 0.55, orthographic: Bool = true,
                        distance: Float = 260, materials: [UInt32] = [], colors: [SIMD4<Float>?] = [], roughness: [Float] = [], focus: SIMD3<Float>? = nil, selected: [UInt32] = [],
                        target: SIMD3<Float> = SIMD3(45, 20, 15)) async throws -> (Picture, Renderer, ViewportMTKView) {
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
        renderer.bodyMaterials = materials
        renderer.bodyRoughness = roughness
        renderer.focusPoint = focus
        renderer.selected = selected
        renderer.bodyColors = colors
        renderer.sceneBounds = model.sceneBounds
        renderer.camera.orthographic = orthographic
        renderer.camera.target = target
        renderer.camera.distance = distance
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
        // The usual background is light in a light appearance and dark in a dark one: take the floor from the other end, so
        // that the two pictures differ whichever this Mac is in.
        var settings = RenderSettings()
        settings.floor = plain.color(2, 2).x > 0.5 ? .charcoal : .white
        let (rendered, _, _) = try await render(model, name: "plain-rendered", settings: settings)
        #expect(abs(plain.color(2, 2).x - rendered.color(2, 2).x) > 0.3, "the usual background, not the floor")
    }

    /// In an orthographic view the camera's `eye` is only a point near the model, so a top seen at a shallow angle can lie
    /// above it. The face must still be shaded as one turned toward the viewer, the same at any distance.
    @Test func aFaceSeenAtAShallowAngleKeepsItsShadeInAnOrthographicView() async throws {
        let model = try await loaded()
        let top = SIMD3<Float>(83, 0, 30)  // on the cylinder's top, near its left rim, which stays in view when close
        func shade(distance: Float) async throws -> Float {
            let (picture, renderer, view) = try await render(model, name: "shallow-\(Int(distance))", settings: .quiet, yaw: -.pi / 3,
                                                             pitch: 0.2, distance: distance)
            #expect(renderer.camera.eye.z < top.z || distance > 100, "the eye is below the top face")
            let q = pixel(of: top, picture, renderer, view)
            return picture.color(q.x, q.y).x
        }
        let far = try await shade(distance: 260), near = try await shade(distance: 60)
        #expect(abs(far - near) < 0.03, "the top is \(far) from far away and \(near) from near: it must not turn dark")
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
        model.renderSettings.apply(.photo)
        for tab in [RenderPanel.Tab.simple, .advanced] {
        let content = RenderPanel(model: model, tab: tab)
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
        try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: dir + "/panel-\(tab.rawValue.lowercased()).png"))
        withExtendedLifetime(window) {}
        }
    }

    /// Only for looking at: the Appearance panel with its material row.
    @Test func theAppearancePanelAsAPicture() async throws {
        guard let dir = ProcessInfo.processInfo.environment["RENDER_DUMP_DIR"] else { return }
        let model = try await loaded()
        model.selectBody("a")
        model.setBodyMaterial(.wood, of: ["a"])
        for scheme in [(ColorScheme.light, NSAppearance.Name.aqua), (.dark, .darkAqua)] {
            let content = AppearancePanel(model: model)
                .padding(30)
                .background(Color(white: scheme.0 == .dark ? 0.16 : 0.9))
                .environment(\.colorScheme, scheme.0)
            let host = NSHostingView(rootView: content)
            host.appearance = NSAppearance(named: scheme.1)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: scheme.1)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: dir + "/appearance-\(scheme.0 == .dark ? "dark" : "light").png"))
            withExtendedLifetime(window) {}
        }
    }

    @Test func theRenderViewHidesTheBrowserAndInspectorAndBringsThemBack() async throws {
        let model = try await loaded()
        model.setRenderView(true)
        #expect(!model.showSidebar && !model.showInspector && !model.showTimeline, "the timeline goes too, by default")
        model.showInspector = true  // the user brings one back
        model.setRenderView(true)   // asking again changes nothing
        #expect(model.showInspector)
        model.setRenderView(false)
        #expect(model.showSidebar && model.showInspector && model.showTimeline, "what the render view hid is back when it goes off")
        model.showSidebar = false   // closed by the user before
        model.setRenderView(true)
        model.setRenderView(false)
        #expect(!model.showSidebar, "a panel the user had closed stays closed")
    }

    @Test func aMaterialIsKeptWithAColourThatSuitsIt() async throws {
        let model = try await loaded()
        #expect(model.displayColor(of: "a") == nil)
        model.setBodyMaterial(.wood, of: ["a"])
        #expect(model.displayMaterial(of: "a") == .wood)
        #expect(model.displayColor(of: "a") == BodyColor(hex: "#B5834F"))
        #expect(model.displayMaterial(of: "c") == nil)
        model.setBodyColor(BodyColor(hex: "#112233"), of: ["c"])
        model.setBodyMaterial(.metal, of: ["c"])
        #expect(model.displayColor(of: "c") == BodyColor(hex: "#112233"), "a colour of its own is kept")
        let back = try JSONDecoder().decode(CADDocument.self, from: JSONEncoder().encode(model.document))
        #expect(back.bodyMaterials == ["a": .wood, "c": .metal])
        model.setBodyMaterial(nil, of: ["c"])
        #expect(model.displayMaterial(of: "c") == nil)
        #expect(!model.isRegenerating, "a material rebuilds nothing")
    }

    @Test func aMaterialIsOneUndoStep() async throws {
        let model = try await loaded()
        let undo = UndoManager()
        model.undoManager = undo
        model.setBodyMaterial(.glass, of: ["a", "c"])
        #expect(model.displayMaterial(of: "a") == .glass && model.displayMaterial(of: "c") == .glass)
        undo.undo()
        #expect(model.displayMaterial(of: "a") == nil && model.displayMaterial(of: "c") == nil)
        #expect(model.displayColor(of: "a") == nil, "the colour that came with it goes too")
    }

    /// Metal, glass, wood and a plain box side by side, each in a colour of its own: looked at as a picture, and checked
    /// for the one thing each must be (metal not flat, glass see-through, wood grained).
    @Test func theMaterialsAsPictures() async throws {
        var d = CADDocument()
        let names = ["plain", "metal", "glass", "wood", "round"]
        d.features = names.enumerated().map { i, n in
            i == 4 ? Feature(id: n, name: n, .primitive(PrimitiveFeature(kind: .cylinder, plane: .xy, u: "\(i * 70 + 25) mm", v: "25 mm", height: "40", diameter: "40")))
                   : Feature(id: n, name: n, .primitive(PrimitiveFeature(kind: .box, plane: .xy, u: "\(i * 70) mm", width: "50 mm", length: "50 mm", height: "40 mm")))
        }
        let model = DocumentModel(document: d)
        try await settle(model)
        let tan = SIMD4<Float>(0.71, 0.51, 0.31, 1)
        let colors: [SIMD4<Float>?] = [SIMD4(0.75, 0.78, 0.82, 1), SIMD4(0.79, 0.8, 0.82, 1), SIMD4(0.75, 0.87, 0.92, 1), tan, SIMD4(0.79, 0.8, 0.82, 1)]
        var settings = RenderSettings.quiet
        settings.reflection = 0
        let plainOnly = try await render(model, name: "materials-off", settings: settings, yaw: -.pi / 5, pitch: 0.5, orthographic: false,
                                         distance: 560, materials: [0, 0, 0, 0, 0], colors: colors, target: SIMD3(150, 25, 15))
        let made = try await render(model, name: "materials", settings: settings, yaw: -.pi / 5, pitch: 0.5, orthographic: false,
                                    distance: 560, materials: [0, 1, 2, 3, 1], colors: colors, target: SIMD3(150, 25, 15))
        func spread(_ shot: (Picture, Renderer, ViewportMTKView), body: Int) -> Float {
            let c = shot.0, r = shot.1, v = shot.2
            let x0 = Float(body * 70)
            var lo = Float.greatestFiniteMagnitude, hi: Float = 0
            // Along the top face of the box.
            for i in 0..<12 {
                let p = SIMD3<Float>(x0 + 5 + Float(i) * 3.5, 25, 40)
                let q = pixel(of: p, c, r, v)
                let l = c.color(q.x, q.y)
                let lum = 0.3 * l.x + 0.59 * l.y + 0.11 * l.z
                lo = min(lo, lum); hi = max(hi, lum)
            }
            return hi - lo
        }
        #expect(spread(made, body: 3) > spread(plainOnly, body: 3) + 0.02, "wood has grain over its top")
        // Glass lets the floor show: a point on the glass box's face is not the colour of the opaque one.
        let g = SIMD3<Float>(2 * 70 + 25, 0, 20)
        let a = pixel(of: g, plainOnly.0, plainOnly.1, plainOnly.2), b = pixel(of: g, made.0, made.1, made.2)
        let opaque = plainOnly.0.color(a.x, a.y), glass = made.0.color(b.x, b.y)
        #expect(simd_length(opaque - glass) > 0.05, "glass is not painted like a plain body")
        let m = pixel(of: SIMD3(70 + 25, 0, 20), made.0, made.1, made.2)
        let mp = pixel(of: SIMD3(70 + 25, 0, 20), plainOnly.0, plainOnly.1, plainOnly.2)
        #expect(simd_length(made.0.color(m.x, m.y) - plainOnly.0.color(mp.x, mp.y)) > 0.05, "metal is not painted like a plain body")
    }

    /// Only for looking at: glass boxes and a glass cylinder in front of a dark box and a wooden one.
    @Test func theGlassAsAPicture() async throws {
        guard ProcessInfo.processInfo.environment["RENDER_DUMP_DIR"] != nil else { return }
        var d = CADDocument()
        d.features = [
            Feature(id: "back", name: "back", .primitive(PrimitiveFeature(kind: .box, plane: .xy, u: "0 mm", width: "40 mm", length: "120 mm", height: "50 mm"))),
            Feature(id: "wood", name: "wood", .primitive(PrimitiveFeature(kind: .box, plane: .xy, u: "100 mm", width: "40 mm", length: "40 mm", height: "30 mm"))),
            Feature(id: "slab", name: "slab", .primitive(PrimitiveFeature(kind: .box, plane: .xy, u: "20 mm", v: "-40 mm", width: "90 mm", length: "20 mm", height: "60 mm"))),
            Feature(id: "cyl", name: "cyl", .primitive(PrimitiveFeature(kind: .cylinder, plane: .xy, u: "70 mm", v: "50 mm", height: "45", diameter: "50"))),
        ]
        let model = DocumentModel(document: d)
        try await settle(model)
        let colors: [SIMD4<Float>?] = [SIMD4(0.15, 0.17, 0.2, 1), SIMD4(0.71, 0.51, 0.31, 1), SIMD4(0.75, 0.87, 0.92, 1), SIMD4(0.75, 0.87, 0.92, 1)]
        var settings = RenderSettings.quiet
        settings.showEdges = true
        _ = try await render(model, name: "glass", settings: settings, yaw: -.pi / 5, pitch: 0.45, orthographic: false,
                             distance: 330, materials: [0, 3, 2, 2], colors: colors, target: SIMD3(60, 30, 20))
        settings.apply(.dramatic)
        settings.floor = .charcoal
        _ = try await render(model, name: "glass-dark", settings: settings, yaw: -.pi / 4, pitch: 0.35, orthographic: false,
                             distance: 330, materials: [0, 3, 2, 2], colors: colors, target: SIMD3(60, 30, 20))
    }

    /// Only for timing (RENDER_TIMING=1): GPU time per frame of the render view, by material, on the threaded manifold example.
    @Test func timeTheMaterials() async throws {
        guard ProcessInfo.processInfo.environment["RENDER_TIMING"] != nil else { return }
        let model = DocumentModel(document: .manifoldDemo())
        try await settle(model)
        let count = model.visibleMeshes.count
        let triangles = model.visibleMeshes.reduce(into: 0) { $0 += $1.mesh.indices.count / 3 }
        print("TIMING bodies \(count), triangles \(triangles)")
        let bounds = try #require(model.sceneBounds)
        let middle = (bounds.min + bounds.max) * 0.5
        let size = simd_length(bounds.max - bounds.min)
        for (label, blur) in [("default look", 0.25), ("no blur", 0.0)] {
            var settings = RenderSettings()
            settings.reflectionBlur = blur
            for (name, kind) in [("plain", UInt32(0)), ("metal", 1), ("glass", 2), ("wood", 3)] {
                let (_, renderer, view) = try await render(model, name: "timing", settings: settings, yaw: -.pi / 5, pitch: 0.5,
                                                           orthographic: false, distance: size * 2, materials: Array(repeating: kind, count: count),
                                                           colors: Array(repeating: SIMD4(0.7, 0.5, 0.3, 1), count: count), target: middle)
                var times: [Double] = []
                for _ in 0..<15 {
                    view.draw(view.bounds)
                    try await Task.sleep(for: .milliseconds(150))
                    times.append(renderer.lastGPUSeconds * 1000)
                }
                times.sort()
                print("TIMING \(label) \(name): median \(String(format: "%.1f", times[times.count / 2])) ms, worst \(String(format: "%.1f", times.last!)) ms")
            }
        }
    }

    /// Only for timing (RENDER_TIMING=1): selecting a body while the Appearance panel is open.
    @Test func timeSelectingWithTheAppearancePanel() async throws {
        guard ProcessInfo.processInfo.environment["RENDER_TIMING"] != nil else { return }
        let model = DocumentModel(document: .manifoldDemo())
        try await settle(model)
        model.showAppearance = true
        let host = NSHostingView(rootView: AppearancePanel(model: model).environment(\.colorScheme, .light))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let ids = model.bodies.map(\.id)
        var times: [Double] = []
        for i in 0..<20 {
            let t = Date()
            model.selectBody(ids[i % ids.count])
            try await Task.sleep(for: .milliseconds(1))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            times.append(Date().timeIntervalSince(t) * 1000)
        }
        print("TIMING select with panel (\(ids.count) bodies): \(times.map { String(format: "%.0f", $0) }.joined(separator: " ")) ms")
        withExtendedLifetime(window) {}
    }

    @Test func theTimelineMenusAreNotWorkedOutWhenTheBarIsDrawn() async throws {
        var d = CADDocument()
        d.features = [Feature(id: "base", name: "Box", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "10", length: "10", height: "10")))]
        for i in 0..<30 {
            d.features.append(Feature(id: "f\(i)", name: "Fillet\(i)", .fillet(EdgeFeature(edges: [EdgeRef(body: "base", edge: "e\(i)")], size: "1 mm"))))
        }
        let model = DocumentModel(document: d)
        try await settle(model)
        let host = NSHostingView(rootView: TimelineBar(model: model).frame(width: 1200))
        host.frame = NSRect(x: 0, y: 0, width: 1200, height: 60)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        for i in 0..<5 {
            model.selection = []
            model.selectedFeature = "f\(i)"
            try await Task.sleep(for: .milliseconds(20))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
        }
        #expect(model.reorderChecksMade == 0, "drawing the bar worked out \(model.reorderChecksMade) menu checks")
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

    // MARK: quality

    @Test func thePresetsAsPictures() async throws {
        let model = try await loaded()
        for quality in RenderSettings.Quality.allCases {
            var settings = RenderSettings()
            settings.apply(quality)
            settings.noise = 0
            let (picture, _, _) = try await render(model, name: "quality-\(quality.rawValue)", settings: settings, orthographic: false, distance: 220,
                                                   materials: [0, 1], colors: [SIMD4(0.8, 0.45, 0.3, 1), nil])
            #expect(picture.width > 0)
        }
    }

    @Test func theQualityPresetsAreRecognisedAndLeaveTheLightAlone() {
        var s = RenderSettings()
        #expect(s.matchingQuality == .simple)
        s.direction = 40
        s.apply(.photo)
        #expect(s.matchingQuality == .photo)
        #expect(s.direction == 40, "a quality preset does not move the light")
        #expect(s.physicalLight && s.occlusion > 0.5 && s.refraction)
        #expect(s.depthOfField == 0, "no quality preset turns the depth blur on")
        s.bloom = 0.9
        #expect(s.matchingQuality == nil, "one advanced change leaves the preset for Custom")
        s.apply(.realistic)
        #expect(s.matchingQuality == .realistic)
        #expect(RenderSettings.fresh.matchingQuality == .realistic)
    }

    @Test func settingsFromBeforeTheQualityPresetsLoadAsSimple() throws {
        let old = #"{"floor":"sand","brightness":0.9,"noise":0.2}"#
        let s = try JSONDecoder().decode(RenderSettings.self, from: Data(old.utf8))
        #expect(s.matchingQuality == .simple)
        #expect(s.floor == .sand && s.environment == .studio && s.exportQuality == .standard)
        let again = try JSONDecoder().decode(RenderSettings.self, from: JSONEncoder().encode(RenderSettings.fresh))
        #expect(again == RenderSettings.fresh)
    }

    @Test func theUniformsOfTheSimpleLookAreTheOldOnes() {
        // The Studio room is the one the shader always had, so Simple looks as it did.
        let u = Uniforms(viewProj: matrix_identity_float4x4, eye: .zero, viewport: .zero, hovered: 0, selectedCount: 0,
                         faceColor: .zero, faceHoverColor: .zero, faceSelectedColor: .zero, regionColor: .zero)
        let room = RenderSettings.Environment.studio.colors
        #expect(SIMD3(u.envZenith.x, u.envZenith.y, u.envZenith.z) == room.zenith && u.envZenith.w == room.strips)
        #expect(SIMD3(u.envSky.x, u.envSky.y, u.envSky.z) == room.skyHorizon && u.envSky.w == room.key)
        #expect(SIMD3(u.envGroundA.x, u.envGroundA.y, u.envGroundA.z) == room.groundHorizon)
        #expect(SIMD3(u.envGroundB.x, u.envGroundB.y, u.envGroundB.z) == room.groundDown)
        #expect(u.look1.x == 0, "physical light is off")
    }

    @Test func thePhysicalFloorIsTheColourTheSettingsWorkOut() async throws {
        let model = try await loaded()
        var settings = RenderSettings.quiet
        settings.apply(.realistic)
        settings.vignette = 0
        settings.bloom = 0
        settings.occlusion = 0
        settings.contactShadows = 0
        let (picture, renderer, view) = try await render(model, name: "physical-floor", settings: settings)
        let a = pixel(of: SIMD3(-10, 80, 0), picture, renderer, view)
        let floor = picture.color(a.x, a.y)
        #expect(abs(floor.x - settings.floorColor.x) < 0.04, "the floor: \(floor) vs \(settings.floorColor)")
        #expect(settings.floorColor.x < 1, "the filmic curve keeps a white floor from clipping: \(settings.floorColor)")
    }

    @Test func occlusionDarkensTheFloorAtTheFootOfABody() async throws {
        let model = try await loaded()
        var off = RenderSettings.quiet
        off.apply(.realistic)
        off.vignette = 0; off.bloom = 0; off.contactShadows = 0; off.shadows = false
        var on = off
        on.occlusion = 1
        let bounds = try #require(model.sceneBounds)
        // Spots on the floor a few mm outside the part's footprint, on every side; the one that is seen darkest because of occlusion.
        let middle = (bounds.min + bounds.max) / 2
        var spots: [SIMD3<Float>] = []
        for dx in [Float(-1), 0, 1] { for dy in [Float(-1), 0, 1] where dx != 0 || dy != 0 {
            spots.append(SIMD3(dx < 0 ? bounds.min.x - 4 : dx > 0 ? bounds.max.x + 4 : middle.x, dy < 0 ? bounds.min.y - 4 : dy > 0 ? bounds.max.y + 4 : middle.y, 0))
        } }
        func floors(_ settings: RenderSettings, name: String) async throws -> [Float] {
            let (picture, renderer, view) = try await render(model, name: name, settings: settings, orthographic: false)
            return spots.map { let q = pixel(of: $0, picture, renderer, view); return picture.color(q.x, q.y).x }
        }
        let without = try await floors(off, name: "occlusion-off")
        let with = try await floors(on, name: "occlusion-on")
        let darkening = zip(without, with).map { $0 - $1 }
        #expect(darkening.max()! > 0.03, "darker at the foot: \(darkening)")
    }

    @Test func theVignetteDarkensTheCornersAndTheGlowStaysWithinWhite() async throws {
        let model = try await loaded()
        var plain = RenderSettings.quiet
        plain.apply(.realistic)
        plain.vignette = 0; plain.bloom = 0
        var shaded = plain
        shaded.vignette = 1
        shaded.bloom = 1
        let (a, _, _) = try await render(model, name: "vignette-off", settings: plain)
        let (b, _, _) = try await render(model, name: "vignette-on", settings: shaded)
        #expect(b.color(3, 3).x < a.color(3, 3).x - 0.05, "darker corner: \(b.color(3, 3)) vs \(a.color(3, 3))")
        let mid = (a.width / 2, a.height / 2)
        #expect(simd_distance(a.color(mid.0, mid.1), b.color(mid.0, mid.1)) < 0.25, "the middle is hardly touched")
    }

    @Test func depthBlurSoftensWhatIsOutOfFocusAndKeepsThePartSharp() async throws {
        let model = try await loaded()
        var sharp = RenderSettings.quiet
        sharp.apply(.realistic)
        sharp.vignette = 0; sharp.bloom = 0; sharp.occlusion = 0; sharp.contactShadows = 0
        var blurred = sharp
        blurred.depthOfField = 1
        let (a, _, _) = try await render(model, name: "dof-off", settings: sharp, yaw: -.pi / 3, pitch: 0.35, orthographic: false, distance: 150)
        let (b, _, _) = try await render(model, name: "dof-on", settings: blurred, yaw: -.pi / 3, pitch: 0.35, orthographic: false, distance: 150)
        // The horizon-side floor far behind the part is blurred, so an edge there (the floor fading) is the same or softer: compare
        // the total variation of a row near the top of the picture.
        func variation(_ p: Picture, row: Int) -> Float {
            var sum: Float = 0
            for x in 1..<p.width { sum += abs(p.color(x, row).x - p.color(x - 1, row).x) }
            return sum
        }
        #expect(b.width == a.width)
        #expect(variation(b, row: 8) <= variation(a, row: 8) + 0.01)
    }

    @Test func anExportMadeFromSeveralPicturesIsAPNGOfTheViewsSize() async throws {
        let model = try await loaded()
        var settings = RenderSettings.fresh
        settings.exportQuality = .high
        let (picture, _, view) = try await render(model, name: "export-source", settings: settings)
        nonisolated(unsafe) var result: Data?
        nonisolated(unsafe) var finished = false
        view.exportPNG(frames: 4) { data in
            result = data
            finished = true
        }
        for _ in 0..<400 where !finished { try await Task.sleep(for: .milliseconds(25)) }
        let png = try #require(result)
        let image = try #require(NSBitmapImageRep(data: png))
        #expect(image.pixelsWide == picture.width && image.pixelsHigh == picture.height)
    }


    /// Only for looking at: the materials and the glass under each quality preset.
    @Test func theQualityPresetsOnMaterialsAndGlassAsPictures() async throws {
        guard ProcessInfo.processInfo.environment["RENDER_DUMP_DIR"] != nil else { return }
        var d = CADDocument()
        let names = ["plain", "metal", "wood", "round"]
        d.features = names.enumerated().map { i, n in
            i == 3 ? Feature(id: n, name: n, .primitive(PrimitiveFeature(kind: .cylinder, plane: .xy, u: "\(i * 70 + 25) mm", v: "25 mm", height: "40", diameter: "40")))
                   : Feature(id: n, name: n, .primitive(PrimitiveFeature(kind: .box, plane: .xy, u: "\(i * 70) mm", width: "50 mm", length: "50 mm", height: "40 mm")))
        }
        let model = DocumentModel(document: d)
        try await settle(model)
        let colors: [SIMD4<Float>?] = [SIMD4(0.75, 0.78, 0.82, 1), SIMD4(0.79, 0.8, 0.82, 1), SIMD4(0.71, 0.51, 0.31, 1), SIMD4(0.95, 0.75, 0.3, 1)]
        for quality in [RenderSettings.Quality.simple, .realistic, .photo] {
            var settings = RenderSettings()
            settings.apply(quality)
            settings.noise = 0
            _ = try await render(model, name: "materials-\(quality.rawValue)", settings: settings, yaw: -.pi / 5, pitch: 0.5, orthographic: false,
                                 distance: 520, materials: [0, 1, 3, 1], colors: colors, target: SIMD3(125, 25, 15))
        }

        var g = CADDocument()
        g.features = [
            Feature(id: "back", name: "back", .primitive(PrimitiveFeature(kind: .box, plane: .xy, u: "0 mm", width: "40 mm", length: "120 mm", height: "50 mm"))),
            Feature(id: "wood", name: "wood", .primitive(PrimitiveFeature(kind: .box, plane: .xy, u: "100 mm", width: "40 mm", length: "40 mm", height: "30 mm"))),
            Feature(id: "slab", name: "slab", .primitive(PrimitiveFeature(kind: .box, plane: .xy, u: "20 mm", v: "-40 mm", width: "90 mm", length: "20 mm", height: "60 mm"))),
            Feature(id: "cyl", name: "cyl", .primitive(PrimitiveFeature(kind: .cylinder, plane: .xy, u: "70 mm", v: "50 mm", height: "45", diameter: "50"))),
        ]
        let glassModel = DocumentModel(document: g)
        try await settle(glassModel)
        let glassColors: [SIMD4<Float>?] = [SIMD4(0.15, 0.17, 0.2, 1), SIMD4(0.71, 0.51, 0.31, 1), SIMD4(0.75, 0.87, 0.92, 1), SIMD4(0.75, 0.87, 0.92, 1)]
        for quality in [RenderSettings.Quality.simple, .realistic, .photo] {
            var settings = RenderSettings()
            settings.apply(quality)
            settings.noise = 0
            _ = try await render(glassModel, name: "glass-\(quality.rawValue)", settings: settings, yaw: -.pi / 5, pitch: 0.45, orthographic: false,
                                 distance: 330, materials: [0, 3, 2, 2], colors: glassColors, target: SIMD3(60, 30, 20))
        }
    }


    @Test func anEmptyPartRendersInEveryQuality() async throws {
        let model = DocumentModel(document: CADDocument())
        try await settle(model)
        for quality in RenderSettings.Quality.allCases {
            var settings = RenderSettings.quiet
            settings.apply(quality)
            let (picture, _, _) = try await render(model, name: "empty-\(quality.rawValue)", settings: settings)
            #expect(picture.width > 0)
        }
    }

    /// Only for timing (RENDER_TIMING=1): GPU time per frame of each quality preset, on the box and cylinder.
    @Test func timeTheQualityPresets() async throws {
        guard ProcessInfo.processInfo.environment["RENDER_TIMING"] != nil else { return }
        let model = try await loaded()
        for quality in RenderSettings.Quality.allCases {
            var settings = RenderSettings()
            settings.apply(quality)
            let (_, renderer, view) = try await render(model, name: "timing-\(quality.rawValue)", settings: settings, orthographic: false,
                                                       materials: [0, 2])
            var times: [Double] = []
            for _ in 0..<10 {
                view.draw(view.bounds)
                try await Task.sleep(for: .milliseconds(50))
                times.append(renderer.lastGPUSeconds * 1000)
            }
            print("RENDER-TIMING \(quality.rawValue): median \(String(format: "%.2f", times.sorted()[times.count / 2])) ms (800x560 view)")
        }
    }


    @Test func plasticHasARoughnessThatTheMaterialStartsWith() async throws {
        let model = try await loaded()
        let undo = UndoManager()
        model.undoManager = undo
        // Each change is its own undo group once the run loop has turned.
        func step(_ change: () -> Void) async throws {
            change()
            try await Task.sleep(for: .milliseconds(60))
        }
        try await step { model.setBodyMaterial(.plastic, of: ["a"]) }
        #expect(model.displayMaterial(of: "a") == .plastic)
        #expect(model.displayRoughness(of: "a") == BodyMaterial.plastic.defaultRoughness)
        #expect(model.displayColor(of: "a") == BodyColor(hex: "#E6E4DE"))
        model.previewBodyRoughness(0.9, of: ["a"])
        #expect(model.displayRoughness(of: "a") == 0.9, "the slider shows at once")
        #expect(model.document.bodyRoughness["a"] == nil, "but the part has not changed yet")
        try await step { model.setBodyRoughness(0.9, of: ["a"]) }
        #expect(model.document.bodyRoughness["a"] == 0.9 && model.roughnessPreview == nil)
        let back = try JSONDecoder().decode(CADDocument.self, from: JSONEncoder().encode(model.document))
        #expect(back.bodyRoughness == ["a": 0.9] && back.bodyMaterials == ["a": .plastic])
        undo.undo()
        #expect(model.displayRoughness(of: "a") == BodyMaterial.plastic.defaultRoughness, "setting it is one undo step")
        try await step { model.setBodyRoughness(0.1, of: ["a"]) }
        try await step { model.setBodyMaterial(.glass, of: ["a"]) }
        #expect(model.displayRoughness(of: "a") == nil && model.document.bodyRoughness["a"] == nil, "glass has none, and a new material starts afresh")
        model.setBodyMaterial(.metal, of: ["c"])
        #expect(model.displayRoughness(of: "c") == BodyMaterial.metal.defaultRoughness, "metal has one too")
        #expect(!model.isRegenerating, "a roughness rebuilds nothing")
    }

    @Test func aRoughnessCopiesWithTheBody() throws {
        let copied = CopiedBody(name: "x", color: nil, material: .plastic, roughness: 0.7, step: Data())
        let back = try JSONDecoder().decode(CopiedBody.self, from: JSONEncoder().encode(copied))
        #expect(back.roughness == 0.7 && back.material == .plastic)
    }

    /// Only for looking at: plastic from glossy to matte under each quality, next to a plain body.
    @Test func plasticFromGlossyToMatteAsPictures() async throws {
        guard ProcessInfo.processInfo.environment["RENDER_DUMP_DIR"] != nil else { return }
        var d = CADDocument()
        d.features = (0..<5).map { i in
            Feature(id: "p\(i)", name: "p\(i)", .primitive(PrimitiveFeature(kind: i == 4 ? .box : .cylinder, plane: .xy, u: "\(i * 60) mm", v: "0 mm",
                                                                               width: "40 mm", length: "40 mm", height: "40", diameter: "40")))
        }
        let model = DocumentModel(document: d)
        try await settle(model)
        let red = SIMD4<Float>(0.8, 0.12, 0.1, 1)
        for quality in [RenderSettings.Quality.simple, .realistic] {
            var settings = RenderSettings()
            settings.apply(quality)
            settings.noise = 0
            _ = try await render(model, name: "plastic-\(quality.rawValue)", settings: settings, yaw: -.pi / 6, pitch: 0.4, orthographic: false,
                                 distance: 460, materials: [4, 4, 4, 4, 0], colors: Array(repeating: red, count: 5),
                                 roughness: [0, 0.25, 0.55, 1, -1], target: SIMD3(120, 0, 15))
        }
    }

    @Test func aClickRayFindsWhereToFocus() async throws {
        let model = try await loaded()
        // Straight down onto the box's top (the box is 30 mm high), and past everything onto the floor.
        let top = try #require(model.focusPoint(origin: SIMD3(0, 0, 200), direction: SIMD3(0, 0, -1)))
        #expect(abs(top.z - 30) < 0.01, "the part first: \(top)")
        let floor = try #require(model.focusPoint(origin: SIMD3(-200, -200, 100), direction: simd_normalize(SIMD3(1, 1, -1))))
        #expect(abs(floor.z) < 1e-6, "else the floor: \(floor)")
        #expect(model.focusPoint(origin: SIMD3(0, 0, 200), direction: SIMD3(0, 0, 1)) == nil, "a ray into the sky finds nothing")
    }

    @Test func pickingTheFocusSwitchesTheBlurOnAndAutoGoesBack() async throws {
        let model = try await loaded()
        model.renderSettings.depthOfField = 0
        model.togglePickingRenderFocus()
        #expect(model.pickingRenderFocus)
        model.setRenderFocus(SIMD3(1, 2, 3))
        #expect(!model.pickingRenderFocus && model.renderFocusPoint == SIMD3(1, 2, 3))
        #expect(model.renderSettings.depthOfField > 0, "choosing the sharp spot turns the blur on")
        model.setRenderFocus(nil)
        #expect(model.renderFocusPoint == nil)
    }

    @Test func theFocusPointMovesTheSharpDistance() async throws {
        let model = try await loaded()
        var settings = RenderSettings.quiet
        settings.apply(.realistic)
        settings.vignette = 0; settings.bloom = 0; settings.occlusion = 0; settings.contactShadows = 0
        settings.depthOfField = 1
        // Focus on the floor at the middle of the view, then on the floor far away: the box's edge is sharp in the first, blurred in the second.
        func edge(_ p: Picture, at q: (x: Int, y: Int)) -> Float {
            var steepest: Float = 0
            for x in (q.x - 14)..<(q.x + 14) { steepest = max(steepest, abs(p.color(x + 1, q.y).x - p.color(x, q.y).x)) }
            return steepest
        }
        let spots: [SIMD3<Float>] = [SIMD3(45, 20, 0), SIMD3(400, 400, 0)]
        var seen: [Float] = []
        for focus in spots {
            let (picture, renderer, view) = try await render(model, name: "focus-\(Int(focus.x))", settings: settings, yaw: -.pi / 3, pitch: 0.35,
                                                              orthographic: false, distance: 150, focus: focus)
            seen.append(edge(picture, at: pixel(of: SIMD3(30, -20, 15), picture, renderer, view)))
        }
        #expect(seen[0] > seen[1] * 1.3, "the box's edge is sharper when the focus is near it: \(seen)")
    }


    @Test func aSelectedBodyShowsNoOutlineInTheRenderViewUnlessEdgesAreOn() async throws {
        let model = try await loaded()
        var settings = RenderSettings.quiet
        let whole = [PickID(wholeBody: 0).raw]
        func darkestAlongTheBoxEdge(_ settings: RenderSettings, selected: [UInt32], name: String) async throws -> Float {
            let (p, renderer, view) = try await render(model, name: name, settings: settings, selected: selected)
            // The box's vertical front corner, a few pixels either side.
            let q = pixel(of: SIMD3(30, -20, 15), p, renderer, view)
            var darkest: Float = 1
            for x in (q.x - 4)...(q.x + 4) { darkest = min(darkest, p.color(x, q.y).x) }
            return darkest
        }
        settings.showEdges = false
        let selected = try await darkestAlongTheBoxEdge(settings, selected: whole, name: "outline-selected")
        settings.showEdges = true
        let withEdges = try await darkestAlongTheBoxEdge(settings, selected: whole, name: "outline-edges-on")
        // The selected body is tinted either way; the difference is the dark line along its edge.
        #expect(withEdges < selected - 0.05, "with Show edges on the outline is drawn, without it it is not: \(withEdges) vs \(selected)")
    }


    /// Only for looking at a part of the user's: RENDER_FILE=path.simplmaker RENDER_DUMP_DIR=dir.
    @Test func aPartFromAFileAsAPicture() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["RENDER_FILE"], env["RENDER_DUMP_DIR"] != nil else { return }
        var doc = try JSONDecoder().decode(CADDocument.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        for id in (env["RENDER_HIDE"] ?? "").split(separator: ",") { doc.hidden.insert(String(id)) }
        if let recolor = env["RENDER_RECOLOR"] {  // id=#hex
            let parts = recolor.split(separator: "=")
            if parts.count == 2, let c = BodyColor(hex: String(parts[1])) { doc.bodyColors[String(parts[0])] = c }
        }
        let model = DocumentModel(document: doc)
        try await settle(model)
        let meshes = model.visibleMeshes
        let materials: [UInt32] = meshes.map { m in
            switch model.displayMaterial(of: m.id) { case nil: 0; case .metal: 1; case .glass: 2; case .wood: 3; case .plastic: 4 }
        }
        let colors: [SIMD4<Float>?] = meshes.map { m in
            model.displayColor(of: m.id).map { let (r, g, b) = $0.components; return SIMD4(Float(r), Float(g), Float(b), 1) }
        }
        let roughness: [Float] = meshes.map { m in model.displayRoughness(of: m.id).map { Float($0) } ?? -1 }
        let b = try #require(model.sceneBounds)
        let mid = (b.min + b.max) / 2
        var settings = RenderSettings()
        settings.apply(env["RENDER_QUALITY"].flatMap { RenderSettings.Quality(rawValue: $0) } ?? .realistic)
        settings.noise = 0
        if env["RENDER_NO_REFRACTION"] != nil { settings.refraction = false }
        if env["RENDER_NO_AO"] != nil { settings.occlusion = 0; settings.contactShadows = 0 }
        _ = try await render(model, name: env["RENDER_NAME"] ?? "file", settings: settings, yaw: -.pi / 4, pitch: 0.6, orthographic: true,
                             distance: simd_length(b.max - b.min) * Float(env["RENDER_ZOOM"].flatMap { Double($0) } ?? 1.4), materials: materials, colors: colors, roughness: roughness,
                             target: mid + SIMD3<Float>(Float(env["RENDER_DX"].flatMap { Double($0) } ?? 0), Float(env["RENDER_DY"].flatMap { Double($0) } ?? 0), 0))
    }

    @Test func glassBendsTheFloorBehindItAndIsDarkerWhereItIsThick() async throws {
        let model = try await loaded()
        var plain = RenderSettings.quiet
        plain.apply(.realistic)
        plain.refraction = false
        var bent = plain
        bent.refraction = true
        let colors: [SIMD4<Float>?] = [SIMD4(0.75, 0.88, 0.95, 1), nil]
        let (a, renderer, view) = try await render(model, name: "glass-plain", settings: plain, materials: [2, 0], colors: colors)
        let (b, _, _) = try await render(model, name: "glass-refracted", settings: bent, materials: [2, 0], colors: colors)
        #expect(a.width == b.width)
        // The top of the glass box: bent, it shows the floor under it through the glass, as lit there and darker for the thickness.
        let q = pixel(of: SIMD3(0, 0, 30), a, renderer, view)
        #expect(simd_distance(a.color(q.x, q.y), b.color(q.x, q.y)) > 0.015,
                "refraction changes what the glass shows: \(a.color(q.x, q.y)) vs \(b.color(q.x, q.y))")
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
