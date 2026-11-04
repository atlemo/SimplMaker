// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import Testing
@testable import CADKernel

/// Projecting sketch text onto a curved body: it lands on the surface and follows it.
@Suite struct ProjectTests {
    /// A 40 mm round post, 60 mm tall, with text sketched on the YZ plane (through its axis) and projected onto it.
    private func doc(_ text: String = "Hi", mode: ProjectMode = .emboss, height: String = "1 mm", flipped: Bool = true,
                     faces: [FaceRef] = [], body: Feature? = nil, at: SIMD2<Double> = SIMD2(-8, 25)) -> CADDocument {
        var s = Sketch()
        let p = s.addPoint(at.x, at.y)
        s.constrain(.fix(p, x: at.x, y: at.y))
        s.texts = [SketchText(id: "T", text: text, position: p, height: "10 mm")]
        var d = CADDocument()
        d.parameters = [Parameter("relief", "0.5 mm")]
        d.features = [
            body ?? Feature(id: "post", name: "Post", .primitive(PrimitiveFeature(kind: .cylinder, plane: .xy, height: "60 mm", diameter: "40 mm"))),
            Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .yz, sketch: s))),
        ]
        let letters = text.enumerated().map { ProfileRef(curves: ["T#\($0.offset)"]) }
        d.features.append(Feature(id: "pr", name: "Project1", .project(ProjectFeature(
            sketch: "sk", profiles: letters, target: "post", faces: faces, mode: mode, height: height, flipped: flipped))))
        return d
    }

    private func radii(_ body: KBody, onFacesNamed prefix: String) throws -> [Double] {
        let mesh = try body.tessellate(linearDeflection: 0.02)
        var out: [Double] = []
        for (t, face) in mesh.triangleFace.enumerated() where mesh.faceNames[Int(face)].hasPrefix(prefix) {
            for k in 0..<3 {
                let v = Int(mesh.indices[t * 3 + k]) * 3
                out.append(Double(mesh.positions[v] * mesh.positions[v] + mesh.positions[v + 1] * mesh.positions[v + 1]).squareRoot())
            }
        }
        return out
    }

    @Test func embossedTextAddsMaterialAndFollowsTheRoundSurface() throws {
        let before = try #require(Regenerator.regenerate(doc(height: "1 mm").withoutProjection).body("post")).volume
        let r = Regenerator.regenerate(doc(height: "1 mm"))
        #expect(r.errors.isEmpty, "\(r.errors)")
        let post = try #require(r.body("post"))
        #expect(post.volume > before + 20, "the letters add material: \(before) -> \(post.volume)")
        // Every vertex of the new faces is on the post's surface (radius 20) or on the raised top (radius 21): the
        // letters curve with the post. A flat extrusion would reach well past 21 at the sides of the text.
        let rs = try radii(post, onFacesNamed: "pr.relief")
        #expect(!rs.isEmpty)
        #expect(rs.allSatisfy { abs($0 - 21) < 0.03 || abs($0 - 20) < 0.03 }, "radii: \(Set(rs.map { ($0 * 100).rounded() / 100 }).sorted())")
        #expect(rs.contains { abs($0 - 21) < 0.03 }, "a raised top")
        let box = try #require(post.bounds)
        #expect(box.max.x < 21.05 && box.min.x > -20.05, "the letters land on the sketch's side only: \(box)")
    }

    @Test func debossedTextTakesMaterialAway() throws {
        let before = try #require(Regenerator.regenerate(doc().withoutProjection).body("post")).volume
        let r = Regenerator.regenerate(doc(mode: .deboss))
        #expect(r.errors.isEmpty, "\(r.errors)")
        let post = try #require(r.body("post"))
        #expect(post.volume < before - 20, "\(before) -> \(post.volume)")
        let rs = try radii(post, onFacesNamed: "pr.relief")
        #expect(rs.contains { abs($0 - 19) < 0.03 }, "a floor 1 mm below the surface")
        #expect(rs.allSatisfy { $0 > 18.97 && $0 < 20.03 })
    }

    @Test func theHeightIsAParameterAndScalesTheRelief() throws {
        func added(_ height: String) throws -> Double {
            let base = try #require(Regenerator.regenerate(doc().withoutProjection).body("post")).volume
            let r = Regenerator.regenerate(doc(height: height))
            #expect(r.errors.isEmpty, "\(r.errors)")
            return try #require(r.body("post")).volume - base
        }
        let one = try added("1 mm"), two = try added("2 mm"), named = try added("relief * 2")
        #expect(two > one * 1.9 && two < one * 2.3, "\(one) -> \(two)")
        #expect(abs(named - one) < one * 0.02, "relief * 2 = 1 mm: \(named) vs \(one)")
    }

    @Test func projectingTheOtherWayLandsOnTheOtherSide() throws {
        let r = Regenerator.regenerate(doc(flipped: false))
        #expect(r.errors.isEmpty, "\(r.errors)")
        let post = try #require(r.body("post"))
        #expect(post.bounds.map { $0.min.x < -20.9 && $0.max.x < 20.05 } == true, "the back of the post got the letters")
    }

    @Test func onlyThePickedFacesGetTheLetters() throws {
        // The post's top face is flat and the sketch is edge-on to it: the letters have nowhere to land.
        let r = Regenerator.regenerate(doc(faces: [FaceRef(body: "post", face: "post.top")]))
        let message = try #require(r.errors["pr"], "no error")
        #expect(message.contains("Nothing to project onto"), Comment(rawValue: message))
        let side = Regenerator.regenerate(doc(faces: [FaceRef(body: "post", face: "post.side")]))
        #expect(side.errors.isEmpty, "\(side.errors)")
    }

    @Test func debossOntoPickedFacesKeepsTheRestOfTheBody() throws {
        // Picking faces (the way the inspector does) and switching between emboss and deboss must not eat the body.
        let side = [FaceRef(body: "post", face: "post.side")]
        let before = try #require(Regenerator.regenerate(doc().withoutProjection).body("post")).volume
        for mode in [ProjectMode.emboss, .deboss, .emboss, .deboss] {
            let r = Regenerator.regenerate(doc(mode: mode, faces: side))
            #expect(r.errors.isEmpty, "\(mode): \(r.errors)")
            let post = try #require(r.body("post"))
            #expect(post.isValid, "\(mode) left an invalid body")
            #expect(abs(post.volume - before) < before * 0.1, "\(mode): \(before) -> \(post.volume)")
        }
    }

    @Test func flatBoxFacePickDebossAndEmbossKeepTheBody() throws {
        var s = Sketch()
        let p = s.addPoint(0, 0)
        s.constrain(.fix(p, x: 0, y: 0))
        s.texts = [SketchText(id: "T", text: "Hi", position: p, height: "10 mm")]
        func make(_ mode: ProjectMode, _ faces: [FaceRef]) -> CADDocument {
            var d = CADDocument()
            d.features = [
                Feature(id: "box", name: "Box", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "60 mm", length: "40 mm", height: "10 mm"))),
                Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s))),
                Feature(id: "pr", name: "Project1", .project(ProjectFeature(
                    sketch: "sk", profiles: ["T#0", "T#1"].map { ProfileRef(curves: [$0]) }, target: "box", faces: faces,
                    mode: mode, height: "1 mm", flipped: true))),
            ]
            return d
        }
        let before = try #require(Regenerator.regenerate(make(.emboss, []).withoutProjection).body("box")).volume
        let top = [FaceRef(body: "box", face: "box.top")]
        for mode in [ProjectMode.emboss, .deboss, .emboss, .deboss] {
            let r = Regenerator.regenerate(make(mode, top))
            #expect(r.errors.isEmpty, "\(mode): \(r.errors)")
            let box = try #require(r.body("box"))
            #expect(box.isValid, "\(mode) left an invalid body")
            // Raised by the height, or sunk into the top by it: the rest of the box stays.
            let change = box.volume - before
            #expect(mode == .emboss ? change > 0 : change < 0, "\(mode): \(before) -> \(box.volume)")
        }
    }

    /// Setting `wrap` on the projection in a document.
    private func wrapped(_ d: CADDocument, _ on: Bool?) -> CADDocument {
        var d = d
        for i in d.features.indices {
            if case .project(var p) = d.features[i].kind { p.wrap = on; d.features[i].kind = .project(p) }
        }
        return d
    }

    @Test func wrappedTextKeepsItsTrueSizeOnARoundPost() throws {
        // The same wide text on a flat face is the reference: its relief has the letters' true area.
        var s = Sketch()
        let p = s.addPoint(-2, 25)
        s.constrain(.fix(p, x: -2, y: 25))
        s.texts = [SketchText(id: "T", text: "HH", position: p, height: "10 mm")]
        var flat = CADDocument()
        flat.features = [
            Feature(id: "post", name: "Box", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "60 mm", length: "60 mm", height: "60 mm"))),
            Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .yz, sketch: s))),
            Feature(id: "pr", name: "Project1", .project(ProjectFeature(
                sketch: "sk", profiles: (0..<2).map { ProfileRef(curves: ["T#\($0)"]) }, target: "post", mode: .emboss, height: "1 mm", flipped: true))),
        ]
        let flatBefore = try #require(Regenerator.regenerate(flat.withoutProjection).body("post")).volume
        let flatResult = Regenerator.regenerate(flat)
        #expect(flatResult.errors.isEmpty, "\(flatResult.errors)")
        let trueVolume = try #require(flatResult.body("post")).volume - flatBefore
        #expect(trueVolume > 10)

        let round = doc("HH", at: SIMD2(-2, 25))
        let before = try #require(Regenerator.regenerate(round.withoutProjection).body("post")).volume
        func added(_ wrap: Bool) throws -> Double {
            let r = Regenerator.regenerate(wrapped(round, wrap))
            #expect(r.errors.isEmpty, "wrap \(wrap): \(r.errors)")
            let post = try #require(r.body("post"))
            #expect(post.isValid)
            return post.volume - before
        }
        let thrown = try added(false), laidOn = try added(true)
        // A relief 1 mm tall on a post of radius 20 has a base 2.5 % smaller than its top, hence the slack.
        #expect(abs(laidOn - trueVolume) < trueVolume * 0.07, "wrapped \(laidOn), true size \(trueVolume)")
        #expect(thrown > trueVolume * 1.04, "thrown on from the side it stretches: \(thrown) vs \(trueVolume)")
    }

    @Test func wrappedTextFollowsTheSurfaceAndDebossesToo() throws {
        let r = Regenerator.regenerate(wrapped(doc("Hi"), true))
        #expect(r.errors.isEmpty, "\(r.errors)")
        let post = try #require(r.body("post"))
        let rs = try radii(post, onFacesNamed: "pr.relief")
        #expect(rs.allSatisfy { abs($0 - 21) < 0.03 || abs($0 - 20) < 0.03 }, "radii: \(Set(rs.map { ($0 * 100).rounded() / 100 }).sorted())")
        let cut = Regenerator.regenerate(wrapped(doc("Hi", mode: .deboss), true))
        #expect(cut.errors.isEmpty, "\(cut.errors)")
        let before = try #require(Regenerator.regenerate(doc().withoutProjection).body("post")).volume
        #expect(try #require(cut.body("post")).volume < before - 10)
    }

    @Test func wrappedTextLandsOnEitherSideDependingOnTheDirection() throws {
        let before = try #require(Regenerator.regenerate(doc().withoutProjection).body("post")).volume
        for flipped in [true, false] {
            let r = Regenerator.regenerate(wrapped(doc("H", flipped: flipped), true))
            #expect(r.errors.isEmpty, "flipped \(flipped): \(r.errors)")
            let post = try #require(r.body("post"))
            #expect(post.volume > before + 10, "flipped \(flipped): \(post.volume) vs \(before)")
        }
    }

    @Test func wrappedRectangleWithStraightEdgesLandsOnThePost() throws {
        var s = Sketch()
        let rect = s.addRectangle(-5, 12, 5, 18)
        var d = CADDocument()
        d.features = [
            Feature(id: "post", name: "Post", .primitive(PrimitiveFeature(kind: .cylinder, plane: .xy, height: "60 mm", diameter: "30 mm"))),
            Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .yz, sketch: s))),
            Feature(id: "pr", name: "Project1", .project(ProjectFeature(
                sketch: "sk", profiles: [ProfileRef(curves: rect.lines, hintU: 0, hintV: 15)], target: "post", mode: .emboss, height: "1.5 mm", flipped: true))),
        ]
        let before = try #require(Regenerator.regenerate(d.withoutProjection).body("post")).volume
        for wrap in [false, true] {
            let r = Regenerator.regenerate(wrapped(d, wrap))
            #expect(r.errors.isEmpty, "wrap \(wrap): \(r.errors)")
            let post = try #require(r.body("post"))
            #expect(post.volume > before + 10, "wrap \(wrap): \(post.volume) vs \(before)")
        }
    }

    @Test func aSignedHeightSaysWhichWayTheProfilesGo() {
        var pf = ProjectFeature(sketch: "sk", profiles: [], target: "post")
        #expect(pf.mode == .emboss && pf.signedHeight == "1 mm")
        pf.setHeight("-2 mm")
        #expect(pf.mode == .deboss && pf.height == "2 mm" && pf.signedHeight == "-(2 mm)")
        pf.setHeight("relief * 2")
        #expect(pf.mode == .emboss && pf.height == "relief * 2")
        pf.setHeight("-relief")
        #expect(pf.mode == .deboss && pf.height == "relief")
    }

    @Test func aMissingFaceOrBodyOrAZeroHeightSaysSo() throws {
        let gone = Regenerator.regenerate(doc(faces: [FaceRef(body: "post", face: "post.nope")]))
        #expect(gone.errors["pr"]?.contains("gone") == true, "\(gone.errors)")
        let flat = Regenerator.regenerate(doc(height: "0 mm"))
        #expect(flat.errors["pr"]?.contains("more than zero") == true, "\(flat.errors)")
        var d = doc()
        if case .project(var p) = d.features[2].kind { p.target = "nobody"; d.features[2].kind = .project(p) }
        #expect(Regenerator.regenerate(d).errors["pr"]?.contains("missing") == true)
    }

    @Test func textWrapsAroundASphereToo() throws {
        let ball = Feature(id: "post", name: "Ball", .primitive(PrimitiveFeature(kind: .sphere, plane: .xy, diameter: "40 mm")))
        let before = try #require(Regenerator.regenerate(doc(body: ball).withoutProjection).body("post")).volume
        let r = Regenerator.regenerate(doc("Hi", height: "1 mm", body: ball, at: SIMD2(-8, -5)))
        #expect(r.errors.isEmpty, "\(r.errors)")
        let post = try #require(r.body("post"))
        #expect(post.volume > before + 10, "\(before) -> \(post.volume)")
        #expect(post.isValid)
    }

    @Test func aProjectionRemembersWhereItLandedForItsHandle() throws {
        let r = Regenerator.regenerate(doc())
        let handle = try #require(r.projectionHandles["pr"])
        #expect(abs(handle.normal.x - 1) < 0.5 && handle.origin.x > 15, "on the +x side of the post: \(handle)")
    }

    @Test func aProjectionIsSavedAndReferencesWhatItUses() throws {
        let d = doc()
        let back = try CADDocument.decode(try d.encoded())
        #expect(back.features[2] == d.features[2])
        let f = d.features[2]
        #expect(f.references == ["sk", "post"])
        #expect(f.changedBodies == ["post"])
        #expect(f.sketchesUsed == ["sk"])
        #expect(f.kind.expressions == ["1 mm"])
        #expect(!f.createsBody)
    }
}

private extension CADDocument {
    /// The same document without its projection, to measure what the projection added.
    var withoutProjection: CADDocument {
        var d = self
        d.features.removeAll { if case .project = $0.kind { true } else { false } }
        return d
    }

    /// A strip that follows a run of smooth cubics, an offset curve closing it: one side face per run, and a deboss
    /// projected onto it builds (a surface that is only tangent-continuous at its joints can't be thickened).
    private func curvedStrip(flatRun: Bool = false) throws -> CADDocument {
        var s = Sketch()
        let lead = s.addPoint(-60, 0)
        let p0 = s.addPoint(0, 0), p1 = s.addPoint(63, 0), p2 = s.addPoint(88, 8), p3 = s.addPoint(98, 20)
        let b1 = s.addBezier(start: p0, control1: s.addPoint(30, 0), control2: s.addPoint(45, 0), end: p1)
        let b2 = s.addBezier(start: p1, control1: s.addPoint(75, 0), control2: s.addPoint(85, 3), end: p2)
        let b3 = s.addBezier(start: p2, control1: s.addPoint(89.8, 11), control2: s.addPoint(95, 16), end: p3)
        var run = [b1, b2, b3]
        if flatRun { run.insert(s.addLine(lead, p0), at: 0) }
        let made = s.offset(run, distance: 2, expression: "2 mm")
        var ends: [EntityID] = []
        for id in made {
            if case .bezier(let a, _, _, let b)? = s.curve(id)?.geometry { ends += [a, b] }
            if case .line(let a, let b)? = s.curve(id)?.geometry { ends += [a, b] }
        }
        s.addLine(flatRun ? lead : p0, ends.first!); s.addLine(p3, ends.last!)
        var plate = Sketch()
        if flatRun { plate.addRectangle(-40, -15, 100, 10) } else { plate.addRectangle(20, -15, 60, 10) }
        var d = CADDocument()
        d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xz, sketch: s)))]
        let sk = try #require(Regenerator.regenerate(d).sketches["sk"])
        let region = try #require(sk.regions.first)
        let ref = ProfileRef(curves: region.tags.split(separator: ",").map(String.init), hintU: region.sample.x, hintV: region.sample.y)
        d.features.append(Feature(id: "e", name: "Extrude1", .extrude(ExtrudeFeature(sketch: "sk", profiles: [ref], extent: .distance("20 mm")))))
        d.features.append(Feature(id: "sk2", name: "Sketch2", .sketch(SketchFeature(plane: .xy, sketch: plate))))
        let sk2 = try #require(Regenerator.regenerate(d).sketches["sk2"])
        let r2 = try #require(sk2.regions.first)
        let pref = ProfileRef(curves: r2.tags.split(separator: ",").map(String.init), hintU: r2.sample.x, hintV: r2.sample.y)
        d.features.append(Feature(id: "pr", name: "Project1", .project(ProjectFeature(
            sketch: "sk2", profiles: [pref], target: "e", mode: .deboss, height: "1 mm"))))
        return d
    }

    @Test func aDebossOnASmoothRunOfCubicsBuildsAndTakesTheRightAmountAway() throws {
        let d = try curvedStrip()
        var plain = d
        plain.features.removeLast()
        let before = try #require(Regenerator.regenerate(plain).body("e"))
        #expect(before.faceNames.filter { $0.contains(".side.") }.count == 4, "\(before.faceNames)")
        let r = Regenerator.regenerate(d)
        #expect(r.errors.isEmpty, "\(r.errors)")
        let after = try #require(r.body("e"))
        // The strip is 209.78 mm² thick-wise and 20 mm long; the volume reads true on spline faces.
        #expect(abs(before.volume - 209.78178 * 20) < 1, "\(before.volume)")
        // 60 × 10 mm of the surface (it is nearly flat there), 1 mm deep.
        #expect(abs((before.volume - after.volume) - 600) < 5, "\(before.volume - after.volume)")
    }

    /// A deboss across the join of a flat run and a curved one is one pocket: the walls the two pieces of the relief
    /// share at the join would otherwise stay behind as a thin membrane across the floor.
    @Test func aDebossAcrossAFlatRunAndACurveHasNoWallAtTheJoin() throws {
        let r = Regenerator.regenerate(try curvedStrip(flatRun: true))
        #expect(r.errors.isEmpty, "\(r.errors)")
        let body = try #require(r.body("e"))
        let mesh = try body.tessellate(linearDeflection: 0.01)
        // The join is at x = 0; no relief face may stand there across the pocket.
        for (t, face) in mesh.triangleFace.enumerated() where mesh.faceNames[Int(face)].hasPrefix("pr.relief") {
            let xs = (0..<3).map { Double(mesh.positions[Int(mesh.indices[t * 3 + $0]) * 3]) }
            #expect(!xs.allSatisfy { abs($0) < 1e-6 }, "a wall across the pocket at the join")
        }
    }
}
