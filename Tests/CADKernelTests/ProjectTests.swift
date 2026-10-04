// Copyright © 2026 Atle Mo. All rights reserved.
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
}
