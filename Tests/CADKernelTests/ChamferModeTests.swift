// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import Testing
@testable import CADKernel

/// Chamfers measured two ways: a distance on each face, or a distance and an angle.
@Suite struct ChamferModeTests {
    /// A 20 × 20 × 10 box centred on the origin in x and y, standing on z = 0.
    private func box(_ extra: [Feature] = []) -> CADDocument {
        var d = CADDocument()
        d.features = [Feature(id: "b", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "20", length: "20", height: "10")))] + extra
        return d
    }

    private func body() throws -> (KBody, edge: String) {
        let b = try #require(Regenerator.regenerate(box()).body("b"))
        let edge = try #require(try b.faceEdges("b.top").first)
        return (b, edge)
    }

    /// How far the top face's centre moved from the middle: a strip of width w cut off one 20 mm edge of the
    /// square moves it by w (20 − w/2) / (20 − w) ... measured from the face itself.
    private func topShift(_ b: KBody) -> Double {
        guard let c = try? b.faceCenter("b.top") else { return .nan }
        return (c.x * c.x + c.y * c.y).squareRoot()
    }

    @Test func twoDistancesMeasureTheFirstOnTheNamedFace() throws {
        let (b, edge) = try body()
        let plain = b.volume
        // 2 mm on the top, 4 mm down the side: a triangle of 4 mm² along 20 mm.
        let onTop = try b.chamfer(edges: [edge], faces: ["b.top"], mode: .twoDistances, first: 2, second: 4, flipped: false, featureID: "c")
        #expect(abs((plain - onTop.volume) - 80) < 1e-6, "\(plain - onTop.volume)")
        #expect(abs(topShift(onTop) - 1.0) < 1e-6, "2 mm of the top is cut off: \(topShift(onTop))")
        // Flipped: the 2 mm go down the side and the 4 mm across the top.
        let flipped = try b.chamfer(edges: [edge], faces: ["b.top"], mode: .twoDistances, first: 2, second: 4, flipped: true, featureID: "c")
        #expect(abs(topShift(flipped) - 2.0) < 1e-6, "\(topShift(flipped))")
        #expect(abs((plain - flipped.volume) - 80) < 1e-6)
        #expect(onTop.hasFace("c.chamfer.\(edge)"), "the new face is named after the edge as before")
    }

    @Test func withoutAFaceTheSmallerNameDecidesAndFlipTakesTheOther() throws {
        let (b, edge) = try body()
        let sides = try b.edgeFaces(edge).sorted()
        let a = try b.chamfer(edges: [edge], faces: [""], mode: .twoDistances, first: 2, second: 4, flipped: false, featureID: "c")
        let named = try b.chamfer(edges: [edge], faces: [sides[0]], mode: .twoDistances, first: 2, second: 4, flipped: false, featureID: "c")
        #expect(abs(topShift(a) - topShift(named)) < 1e-9)
        let flipped = try b.chamfer(edges: [edge], faces: [""], mode: .twoDistances, first: 2, second: 4, flipped: true, featureID: "c")
        let other = try b.chamfer(edges: [edge], faces: [sides[1]], mode: .twoDistances, first: 2, second: 4, flipped: false, featureID: "c")
        #expect(abs(topShift(flipped) - topShift(other)) < 1e-9)
    }

    @Test func distanceAndAngle() throws {
        let (b, edge) = try body()
        let plain = b.volume
        // 3 mm along the top at 45 degrees to it: 3 mm down the side, a right triangle of 4.5 mm².
        let a45 = try b.chamfer(edges: [edge], faces: ["b.top"], mode: .distanceAngle, first: 3, second: .pi / 4, flipped: false, featureID: "c")
        #expect(abs((plain - a45.volume) - 90) < 1e-6, "\(plain - a45.volume)")
        // At 30 degrees it goes down 3 tan 30°.
        let a30 = try b.chamfer(edges: [edge], faces: ["b.top"], mode: .distanceAngle, first: 3, second: .pi / 6, flipped: false, featureID: "c")
        #expect(abs((plain - a30.volume) - 0.5 * 3 * 3 * tan(.pi / 6) * 20) < 1e-6, "\(plain - a30.volume)")
        // The distance is on the top face.
        #expect(abs(topShift(a30) - (3 * 20 * (10 - 1.5)) / (400 - 60)) < 1e-6)
    }

    @Test func equalDistanceStillWorks() throws {
        let (b, edge) = try body()
        let viaMode = try b.chamfer(edges: [edge], faces: [""], mode: .equalDistance, first: 2, second: 0, flipped: false, featureID: "c")
        let plain = try b.chamfer(edges: [edge], distance: 2, featureID: "c")
        #expect(abs(viaMode.volume - plain.volume) < 1e-9)
    }

    @Test func badValuesAreRefused() throws {
        let (b, edge) = try body()
        #expect(throws: KernelError.self) { try b.chamfer(edges: [edge], faces: [""], mode: .twoDistances, first: 2, second: 0, flipped: false, featureID: "c") }
        #expect(throws: KernelError.self) { try b.chamfer(edges: [edge], faces: [""], mode: .distanceAngle, first: 2, second: 0, flipped: false, featureID: "c") }
        #expect(throws: KernelError.self) { try b.chamfer(edges: [edge], faces: [""], mode: .distanceAngle, first: 2, second: .pi / 2, flipped: false, featureID: "c") }
        #expect(throws: KernelError.self) { try b.chamfer(edges: [edge], faces: [""], mode: .twoDistances, first: 50, second: 2, flipped: false, featureID: "c") }
    }

    @Test func handlesPointAlongEachFaceAwayFromTheEdge() throws {
        let (b, edge) = try body()
        let h = try b.chamferHandle(edge, face: "b.top")
        #expect(abs(h.first.z) < 1e-9, "along the top: \(h.first)")
        #expect(h.first.x * h.origin.x + h.first.y * h.origin.y < 0, "and away from the edge, into the top")
        #expect(abs(h.second.z + 1) < 1e-9, "down the side: \(h.second)")
        #expect(abs(h.normal.z - 1) < 1e-9, "the top's normal points out: \(h.normal)")
        let flipped = try b.chamferHandle(edge, face: "b.top", flipped: true)
        #expect(abs(flipped.first.z + 1) < 1e-9 && abs(flipped.second.z) < 1e-9)
        #expect(abs(flipped.normal.z) < 1e-9, "the side's normal")
    }

    @Test func theRegeneratorMeasuresFacePicksOnThePickedFace() throws {
        let top = FaceRef(body: "b", face: "b.top")
        let plain = try #require(Regenerator.regenerate(box()).body("b")).volume
        // Every top edge: 1 mm on the top, 2 mm down the sides. (Four corners overlap, so only the sign is exact.)
        var ef = EdgeFeature(edges: [], faces: [top], size: "1 mm")
        ef.setMode(.twoDistances)
        ef.second = "2 mm"
        let r = Regenerator.regenerate(box([Feature(id: "c", name: "Chamfer1", .chamfer(ef))]))
        #expect(r.errors.isEmpty, "\(r.errors)")
        let chamfered = try #require(r.body("b"))
        #expect(chamfered.volume < plain)
        // The top face lost 1 mm all round: it is 18 × 18 (centre unchanged).
        #expect(topShift(chamfered) < 1e-9)
        // Flipped, the 1 mm goes down the sides and the 2 mm across the top: the same triangles, but they meet
        // differently at the corners, so the body is another one.
        ef.flipped = true
        let f = Regenerator.regenerate(box([Feature(id: "c", name: "Chamfer1", .chamfer(ef))]))
        #expect(f.errors.isEmpty, "\(f.errors)")
        let flippedBody = try #require(f.body("b"))
        #expect(abs(flippedBody.volume - chamfered.volume) > 1e-3, "flipping measures the other way")
        #expect(abs(topShift(flippedBody)) < 1e-9)
        #expect(flippedBody.volume < plain - 4 * 20 * 0.9, "four edges of about 1 mm²")
        // A bad second value says so.
        ef.second = "wide"
        let bad = Regenerator.regenerate(box([Feature(id: "c", name: "Chamfer1", .chamfer(ef))]))
        #expect(!bad.errors.isEmpty)
    }

    @Test func angleModeNeedsAnAngle() throws {
        let top = FaceRef(body: "b", face: "b.top")
        var ef = EdgeFeature(edges: [], faces: [top], size: "2 mm")
        ef.setMode(.distanceAngle)
        #expect(ef.second == "45 deg")
        let ok = Regenerator.regenerate(box([Feature(id: "c", name: "Chamfer1", .chamfer(ef))]))
        #expect(ok.errors.isEmpty, "\(ok.errors)")
        ef.second = "3 mm"
        #expect(!Regenerator.regenerate(box([Feature(id: "c", name: "Chamfer1", .chamfer(ef))])).errors.isEmpty, "a length isn't an angle")
    }

    @Test func theModeIsSavedAndOldFilesStillOpen() throws {
        let top = FaceRef(body: "b", face: "b.top")
        var ef = EdgeFeature(edges: [], faces: [top], size: "2 mm")
        ef.setMode(.twoDistances)
        ef.second = "3 mm"
        ef.flipped = true
        let back = try CADDocument.decode(try box([Feature(id: "c", name: "Chamfer1", .chamfer(ef))]).encoded())
        guard case .chamfer(let got) = back.features[1].kind else { Issue.record("expected a chamfer"); return }
        #expect(got == ef)
        // An equal-distance chamfer writes nothing new, and a file without the new keys reads as one.
        let plain = EdgeFeature(edges: [], faces: [top], size: "2 mm")
        let text = String(decoding: try box([Feature(id: "c", name: "Chamfer1", .chamfer(plain))]).encoded(), as: UTF8.self)
        #expect(!text.contains("\"mode\"") && !text.contains("\"second\"") && !text.contains("\"flipped\""))
        guard case .chamfer(let old) = try CADDocument.decode(Data(text.utf8)).features[1].kind else { Issue.record("expected a chamfer"); return }
        #expect(old.mode == .equalDistance && old.second == "" && !old.flipped)
    }

    @Test func switchingModeResetsTheSecondValueOnlyWhenItsKindChanges() {
        var ef = EdgeFeature(edges: [], size: "edge_chamfer")
        ef.setMode(.twoDistances)
        #expect(ef.second == "edge_chamfer", "the same as the first, to start with")
        ef.second = "3 mm"
        ef.setMode(.distanceAngle)
        #expect(ef.second == "45 deg")
        ef.second = "30 deg"
        ef.setMode(.twoDistances)
        #expect(ef.second == "edge_chamfer")
        ef.setMode(.equalDistance)
        #expect(ef.second == "" && ef.mode == .equalDistance)
        var renamed = Feature.Kind.chamfer({ var e = EdgeFeature(edges: [], size: "w"); e.setMode(.twoDistances); e.second = "w / 2"; return e }())
        renamed.mapExpressions { $0.replacingOccurrences(of: "w", with: "width") }
        guard case .chamfer(let r) = renamed else { return }
        #expect(r.size == "width" && r.second == "width / 2")
    }
}
