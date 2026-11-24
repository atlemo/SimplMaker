// A sweep that also turns its profile about the path, on straight and curved paths.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import simd
import Testing
@testable import CADKernel

@Suite struct TwistedSweepTests {
    typealias T = NewFeatureTests

    /// A 30 mm line up the Z axis, drawn on XZ.
    static let line = T.sketch("path", on: .xz) { s in
        let a = s.addPoint(0, 0), b = s.addPoint(0, 30)
        s.constrain(.fix(a, x: 0, y: 0)); s.constrain(.fix(b, x: 0, y: 30))
        s.addLine(a, b, id: "L")
    }
    /// An S-shaped curve in XZ, from the origin up to z = 60.
    static let curve = T.sketch("path", on: .xz) { s in
        let p = [(0.0, 0.0), (40.0, 10.0), (40.0, 50.0), (0.0, 60.0)].map { pt -> EntityID in
            let id = s.addPoint(pt.0, pt.1); s.constrain(.fix(id, x: pt.0, y: pt.1)); return id
        }
        s.addBezier(start: p[0], control1: p[1], control2: p[2], end: p[3], id: "B")
    }
    static let plane = Feature(id: "pp", name: "pp", .plane(PlaneFeature(along: CurveRef(sketch: "path", curves: ["B"]), position: "0")))

    static func rectangle(on plane: PlaneRef) -> Feature {
        T.sketch("prof", on: plane) { s in T.rect(&s, -3, -1.5, 3, 1.5, ids: ["A", "B", "C", "D"]) }
    }
    static func sweep(_ path: [EntityID], twist: String?) -> Feature {
        Feature(id: "sw", name: "sw", .sweep(SweepFeature(sketch: "prof", profiles: [ProfileRef(curves: ["A", "B", "C", "D"])],
                                                          path: CurveRef(sketch: "path", curves: path), twist: twist)))
    }

    @Test func aBarTwistedAlongALineKeepsItsVolumeAndTurnsItsEnd() throws {
        let r = try T.regen([Self.line, Self.rectangle(on: .xy), Self.sweep(["L"], twist: "90 deg")])
        let body = try #require(r.body("sw"))
        #expect(body.isValid)
        #expect(T.close(body.volume, 6 * 3 * 30, 2e-3), "area × length: \(body.volume)")
        // The 6 × 3 rectangle ends up turned a quarter turn: 3 wide in X, 6 long in Y.
        let end = try body.measure(.face("sw.end"))
        #expect(abs((end.bounds.max.x - end.bounds.min.x) - 3) < 1e-6 && abs((end.bounds.max.y - end.bounds.min.y) - 6) < 1e-6, "\(end.bounds)")
        #expect(abs(end.centroid.z - 30) < 1e-6)
        let start = try body.measure(.face("sw.start"))
        #expect(abs((start.bounds.max.x - start.bounds.min.x) - 6) < 1e-6, "the start stays as drawn")
        #expect(body.hasFace("sw.side.A") || body.faceNames.contains { $0.hasPrefix("sw.side") }, "\(body.faceNames)")
    }

    @Test func noTwistIsThePlainSweep() throws {
        let plain = try #require(try T.regen([Self.line, Self.rectangle(on: .xy), Self.sweep(["L"], twist: nil)]).body("sw"))
        let zero = try #require(try T.regen([Self.line, Self.rectangle(on: .xy), Self.sweep(["L"], twist: "0 deg")]).body("sw"))
        #expect(T.close(plain.volume, zero.volume, 1e-9))
        #expect(plain.faceNames == zero.faceNames, "the same faces, named the same")
    }

    @Test func aProfileTwistsAlongACurvedPath() throws {
        let untwisted = try #require(try T.regen([Self.curve, Self.plane, Self.rectangle(on: .plane("pp")), Self.sweep(["B"], twist: nil)]).body("sw"))
        let twisted = try #require(try T.regen([Self.curve, Self.plane, Self.rectangle(on: .plane("pp")), Self.sweep(["B"], twist: "270 deg")]).body("sw"))
        #expect(twisted.isValid)
        // A profile centred on the path sweeps out the same volume however it turns about it.
        #expect(T.close(twisted.volume, untwisted.volume, 0.01), "\(twisted.volume) against \(untwisted.volume)")
        let a = try #require(untwisted.bounds), b = try #require(twisted.bounds)
        #expect(simd_length(a.max - b.max) < 6 && simd_length(a.min - b.min) < 6, "it follows the same path: \(a) \(b)")
    }

    @Test func theTwistFollowsAParameter() throws {
        var doc = CADDocument()
        doc.parameters = [Parameter("turn", "180 deg", unit: .angle)]
        doc.features = [Self.line, Self.rectangle(on: .xy), Self.sweep(["L"], twist: "turn")]
        let r = Regenerator.regenerate(doc)
        #expect(r.errors.isEmpty, "\(r.errors)")
        let end = try #require(r.body("sw")).measure(.face("sw.end"))
        #expect(abs((end.bounds.max.x - end.bounds.min.x) - 6) < 1e-6, "a half turn leaves the rectangle the same way up: \(end.bounds)")
    }

    @Test func aRingOfTouchingCirclesTwistsAlongACurvedPath() throws {
        let (ring, profiles) = TouchingProfilesTests.ring(on: .plane("pp"))
        let twisted = Feature(id: "sw", name: "sw", .sweep(SweepFeature(sketch: "ring", profiles: profiles, path: CurveRef(sketch: "path", curves: ["B"]), twist: "120 deg")))
        let r = try T.regen([Self.curve, Self.plane, ring, twisted])
        #expect(try #require(r.body("sw")).isValid)
    }

    @Test func profilesThatShareAnEdgeAreOneSolidAndOnesThatOnlyTouchAreNot() throws {
        // A 6 × 3 rectangle split down the middle by a line: two profiles with an edge between them, swept (and twisted) as one solid.
        let split = T.sketch("prof", on: .xy) { s in
            T.rect(&s, -3, -1.5, 3, 1.5, ids: ["A", "B", "C", "D"])
            let a = s.addPoint(0, -1.5), b = s.addPoint(0, 1.5)
            s.constrain(.fix(a, x: 0, y: -1.5)); s.constrain(.fix(b, x: 0, y: 1.5))
            s.addLine(a, b, id: "M")
        }
        let region = try #require(try T.regen([split]).sketches["prof"]).regions
        #expect(region.count == 2)
        let refs = region.map { ProfileRef(curves: $0.tags.split(separator: ",").map(String.init)) }
        for twist in [nil, "60 deg"] as [String?] {
            let sweep = Feature(id: "sw", name: "sw", .sweep(SweepFeature(sketch: "prof", profiles: refs, path: CurveRef(sketch: "path", curves: ["L"]), twist: twist)))
            let body = try #require(try T.regen([Self.line, split, sweep]).body("sw"))
            #expect(body.isValid && T.close(body.volume, 6 * 3 * 30, 2e-3), "\(String(describing: twist)): \(body.volume)")
            #expect(try body.splitIntoParts(featureID: "x").count == 1, "\(String(describing: twist)): joined into one solid")
        }
    }

    /// The profile sits at the END of the path (the ring's plane at position 1, as when the path was drawn the other way round): the
    /// sweep must still follow the path and twist away from the profile.
    @Test func aProfileAtTheFarEndOfThePathTwistsAwayFromIt() throws {
        let atEnd = Feature(id: "pe", name: "pe", .plane(PlaneFeature(along: CurveRef(sketch: "path", curves: ["B"]), position: "1")))
        // One circle of Ø5 whose centre is 8 mm off the path: untwisted it keeps to one side of the path; twisted it spirals round it.
        let off = T.sketch("prof", on: .plane("pe")) { s in
            let c = s.addPoint(8, 0); s.constrain(.fix(c, x: 8, y: 0)); s.addCircle(center: c, radius: 2.5, id: "K")
        }
        func sweep(_ twist: String?) -> Feature {
            Feature(id: "sw", name: "sw", .sweep(SweepFeature(sketch: "prof", profiles: [ProfileRef(curves: ["K"])], path: CurveRef(sketch: "path", curves: ["B"]), twist: twist)))
        }
        let plain = try #require(try T.regen([Self.curve, atEnd, off, sweep(nil)]).body("sw"))
        let barely = try #require(try T.regen([Self.curve, atEnd, off, sweep("0.01 deg")]).body("sw"))
        let spun = try #require(try T.regen([Self.curve, atEnd, off, sweep("360 deg")]).body("sw"))
        #expect(plain.isValid && barely.isValid && spun.isValid)
        // With next to no twist the circle keeps to where it was drawn, 8 mm to the -Y side of the path (Ø5: y from -10.5 to -5.5),
        // and follows the path the whole way; the plain sweep tilts it a little at the far end, which it should not copy.
        let a = try #require(plain.bounds), b = try #require(barely.bounds), c = try #require(spun.bounds)
        #expect(abs(b.min.y + 10.5) < 0.1 && b.max.y < -4, "y \(b.min.y)..\(b.max.y)")
        #expect(abs(b.max.z - 64) < 2 && abs(b.min.z + 4) < 2, "it runs the length of the path (z 0..60, plus the circle): \(b.min.z)..\(b.max.z)")
        #expect(T.close(barely.volume, plain.volume, 0.1), "\(barely.volume) against \(plain.volume)")
        // Spiralling round the path, it reaches the other side of it: the path runs in the XZ plane, so the circle (8 mm off, in X
        // for the plain sweep) now also goes out to the other side in Y.
        #expect(c.max.y - c.min.y > (a.max.y - a.min.y) + 10, "y \(a.min.y)..\(a.max.y) became \(c.min.y)..\(c.max.y)")
    }

    @Test func aRingOfCirclesTwistsKeepsItsVolumeWhateverTheTwist() throws {
        let atEnd = Feature(id: "pe", name: "pe", .plane(PlaneFeature(along: CurveRef(sketch: "path", curves: ["B"]), position: "1")))
        let (ring, profiles) = TouchingProfilesTests.ring(on: .plane("pe"))
        func sweep(_ twist: String?) -> Feature {
            Feature(id: "sw", name: "sw", .sweep(SweepFeature(sketch: "ring", profiles: profiles, path: CurveRef(sketch: "path", curves: ["B"]), twist: twist)))
        }
        let plain = try #require(try T.regen([Self.curve, atEnd, ring, sweep(nil)]).body("sw"))
        for twist in ["90 deg", "360 deg", "-360 deg", "1080 deg"] {
            let body = try #require(try T.regen([Self.curve, atEnd, ring, sweep(twist)]).body("sw"))
            #expect(body.isValid && T.close(body.volume, plain.volume, 0.01), "\(twist): \(body.volume) against \(plain.volume)")
            let a = try #require(plain.bounds), b = try #require(body.bounds)
            #expect(simd_length(a.min - b.min) < 3 && simd_length(a.max - b.max) < 3, "\(twist) stays on the path: \(a) against \(b)")
        }
    }
}
