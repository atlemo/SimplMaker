// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import AppKit
import Foundation
import Metal
import Testing
@testable import SimplMaker

/// A click on one letter of a text picks the whole text: to extrude, project or move it in one click.
@Suite @MainActor struct TextSelectionTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    /// A sketch on the XY plane with the words "Hi" and, further along, "Ok"; with `plate`, a rectangle round the first.
    private func model(plate: Bool = false) async throws -> DocumentModel {
        var s = Sketch()
        let a = s.addPoint(0, 0), b = s.addPoint(40, 0)
        s.constrain(.fix(a, x: 0, y: 0)); s.constrain(.fix(b, x: 40, y: 0))
        s.texts = [SketchText(id: "T1", text: "Hi", position: a, height: "10 mm"),
                   SketchText(id: "T2", text: "Ok", position: b, height: "10 mm")]
        if plate {
            let r = s.addRectangle(-5, -5, 30, 20, lineIDs: ["A", "B", "C", "D"])
            s.constrain(.fix(r.corners[0], x: -5, y: -5)); s.constrain(.fix(r.corners[2], x: 30, y: 20))
        }
        var d = CADDocument()
        d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s)))]
        let model = DocumentModel(document: d)
        try await settle(model)
        return model
    }

    private func picks(_ model: DocumentModel) throws -> [PickID] {
        let slot = try #require(model.sketchSlots.firstIndex(of: "sk")) + 1
        return (0..<(model.result?.sketches["sk"]?.regions.count ?? 0)).map { PickID(region: $0, slot: slot) }
    }

    /// The regions made only of this text's contours, without the insides of its letters (an O's inside is a region of
    /// its own, whose single tag is also one of the ring's).
    private func letters(_ model: DocumentModel, of text: String) throws -> [PickID] {
        let all = try picks(model).compactMap { pick in model.profile(of: pick).map { (pick, Set($0.region.tags.split(separator: ",").map(String.init))) } }
        let own = all.filter { !$0.1.isEmpty && $0.1.allSatisfy { $0.hasPrefix(text + "#") } }
        return own.filter { pick, tags in !own.contains { $0.1 != tags && $0.1.isSuperset(of: tags) } }.map(\.0)
    }

    /// The inside of the first O.
    private func counter(_ model: DocumentModel, of text: String) throws -> PickID {
        let ink = Set(try letters(model, of: text))
        return try #require(try picks(model).first { pick in
            !ink.contains(pick) && (model.profile(of: pick)?.region.tags.hasPrefix(text + "#") ?? false)
        })
    }

    @Test func aClickOnOneLetterPicksTheWholeText() async throws {
        let model = try await model()
        let hi = try letters(model, of: "T1"), ok = try letters(model, of: "T2")
        #expect(hi.count >= 3 && ok.count >= 2, "H, the stem and dot of i; O, k")
        model.click(hi[1], additive: false)
        #expect(Set(model.selection) == Set(hi), "every letter of Hi, and nothing of Ok")
        #expect(model.selection.first == hi[1], "the letter clicked comes first")
        #expect(model.selectedProfiles.count == hi.count)
    }

    @Test func theInsideOfAnOIsNotPartOfTheText() async throws {
        let model = try await model()
        let ok = try letters(model, of: "T2"), hole = try counter(model, of: "T2")
        #expect(ok.count == 2, "O and k")
        model.click(ok[0], additive: false)
        #expect(!model.selection.contains(hole) && Set(model.selection) == Set(ok), "extruding the text must not fill the O")
        model.selection = []
        model.click(hole, additive: false)
        #expect(Set(model.selection) == Set(ok), "a click inside the O still means the text")
    }

    @Test func clickingTheTextAgainPutsItDown() async throws {
        let model = try await model()
        let hi = try letters(model, of: "T1")
        model.click(hi[0], additive: false)
        model.click(hi[2], additive: false)
        #expect(model.selection.isEmpty)
    }

    @Test func shiftClickAddsAndRemovesAWholeText() async throws {
        let model = try await model()
        let hi = try letters(model, of: "T1"), ok = try letters(model, of: "T2")
        model.click(hi[0], additive: false)
        model.click(ok[0], additive: true)
        #expect(Set(model.selection) == Set(hi + ok))
        model.click(hi[1], additive: true)
        #expect(Set(model.selection) == Set(ok), "the second ⇧-click took Hi out again")
    }

    @Test func optionClickPicksOneLetter() async throws {
        let model = try await model()
        let hi = try letters(model, of: "T1")
        model.click(hi[0], additive: false, single: true)
        #expect(model.selection == [hi[0]])
        model.click(hi[1], additive: true, single: true)
        #expect(Set(model.selection) == Set([hi[0], hi[1]]))
    }

    @Test func aPlateWithTheTextCutOutOfItIsNotPartOfTheText() async throws {
        let model = try await model(plate: true)
        let hi = try letters(model, of: "T1"), ok = try letters(model, of: "T2")
        let plate = try #require(try picks(model).first { !hi.contains($0) && !ok.contains($0) })
        #expect(model.profileGroup(of: plate) == [plate], "a region that has other curves in it stands for itself")
        model.click(hi[0], additive: false)
        #expect(!model.selection.contains(plate))
    }

    @Test func oneClickWithTheExtrudeToolExtrudesTheWholeText() async throws {
        let model = try await model()
        let hi = try letters(model, of: "T1")
        model.run(.extrude)
        model.click(hi[1], additive: false)
        let extrudes = model.document.features.compactMap { f -> ExtrudeFeature? in
            if case .extrude(let e) = f.kind { return e } else { return nil }
        }
        #expect(extrudes.count == 1)
        #expect(extrudes.first?.profiles.count == hi.count, "every letter of Hi in the one feature")
        #expect(extrudes.first?.profiles.count == (try letters(model, of: "T1")).count)
        try await settle(model)
        #expect(model.result?.bodies.count == 1, "the letters of one text make one body")
    }

    @Test func theLoftToolStillTakesOneProfile() async throws {
        let model = try await model()
        let hi = try letters(model, of: "T1")
        model.run(.loft)
        model.click(hi[1], additive: false)
        #expect(model.selection == [hi[1]])
        #expect(model.profileGroup(of: hi[1]) == [hi[1]])
    }

    @Test func theRightClickMenuExtrudesTheWholeText() async throws {
        let model = try await model()
        let hi = try letters(model, of: "T1")
        let items = model.contextItems(for: hi[1])
        guard case .action(_, _, _, let extrude)? = items.first(where: { $0.title == "Extrude" }) else {
            Issue.record("no Extrude in the menu"); return
        }
        extrude()  // picks the profile the menu was opened on, and extrudes it
        guard case .extrude(let e)? = model.document.features.last?.kind else { Issue.record("no extrude made"); return }
        #expect(e.profiles.count == hi.count, "every letter of Hi, though the menu was opened on one")
    }

    /// Hovering a letter lights the rest of its text, in the picture the GPU draws, and not another text's letters.
    @Test func hoveringALetterLightsTheWholeTextOnScreen() async throws {
        var sketch = Sketch()
        let a = sketch.addPoint(0, 0), b = sketch.addPoint(0, 30)
        sketch.constrain(.fix(a, x: 0, y: 0)); sketch.constrain(.fix(b, x: 0, y: 30))
        sketch.texts = [SketchText(id: "T1", text: "HI", position: a, height: "20 mm"),
                        SketchText(id: "T2", text: "I", position: b, height: "20 mm")]
        var d = CADDocument()
        d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: sketch)))]
        let model = DocumentModel(document: d)
        try await settle(model)
        let first = try letters(model, of: "T1"), other = try letters(model, of: "T2")
        #expect(first.count == 2 && other.count == 1)
        let result = try #require(model.result?.sketches["sk"])
        func middle(_ pick: PickID) -> SIMD3<Float> {
            let w = result.frame.point(result.regions[pick.element].sample.x, result.regions[pick.element].sample.y)
            return SIMD3(Float(w.x), Float(w.y), Float(w.z))
        }

        let renderer = try #require(Renderer())
        let (view, window) = ViewportSnapshot.offscreenView(width: 800, height: 600, renderer: renderer)
        renderer.setOverlay(model.sketchOverlay())
        renderer.palette = .make(dark: false, increaseContrast: false)
        renderer.camera.setStandard(.top)
        renderer.camera.orthographic = true
        renderer.camera.target = SIMD3(8, 25, 0)
        renderer.camera.distance = 90
        let background = renderer.palette.background
        view.clearColor = MTLClearColor(red: Double(background.x), green: Double(background.y), blue: Double(background.z), alpha: 1)

        func colour(at world: SIMD3<Float>) throws -> [Int] {
            for _ in 0..<3 { view.draw(view.bounds); renderer.waitForGPU() }  // the first frames of a new view settle
            let texture = try #require(view.currentDrawable?.texture)
            var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
            texture.getBytes(&bytes, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
            let p = try #require(renderer.camera.project(world, viewSize: view.bounds.size))
            let scale = Double(texture.width) / Double(view.bounds.width)
            let (x, y) = (Int(Double(p.x) * scale), Int(Double(p.y) * scale))
            guard x >= 0, y >= 0, x < texture.width, y < texture.height else {
                Issue.record("\(world) is off the picture at (\(x), \(y)) of \(texture.width) × \(texture.height), view \(view.bounds.size)")
                return [0, 0, 0]
            }
            let at = (y * texture.width + x) * 4
            return [Int(bytes[at]), Int(bytes[at + 1]), Int(bytes[at + 2])]
        }
        func distance(_ p: [Int], _ q: [Int]) -> Int { zip(p, q).map { abs($0 - $1) }.reduce(0, +) }

        renderer.hovered = 0
        let h0 = try colour(at: middle(first[0])), i0 = try colour(at: middle(first[1])), t0 = try colour(at: middle(other[0]))
        let flat = try colour(at: SIMD3(-8, 25, 0))
        #expect(distance(h0, flat) > 12, "the letters are filled, or there is nothing to compare: \(h0) on \(flat)")

        renderer.hovered = PickID(region: first[0].element, slot: first[0].sketchSlot).raw
        renderer.hoverGroup = model.profileGroup(of: first[0]).map(\.raw)
        let h1 = try colour(at: middle(first[0])), i1 = try colour(at: middle(first[1])), t1 = try colour(at: middle(other[0]))
        #expect(distance(h1, h0) > 6, "the hovered letter lights up: \(h0) -> \(h1)")
        #expect(distance(i1, i0) > 6, "so does the rest of its text: \(i0) -> \(i1)")
        #expect(distance(t1, t0) <= 2, "another text does not: \(t0) -> \(t1)")
        #expect(distance(h1, i1) <= 4, "the whole text lights alike: \(h1) and \(i1)")
        withExtendedLifetime(window) {}
    }
}
