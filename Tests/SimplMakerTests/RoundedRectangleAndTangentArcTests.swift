// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import Testing
@testable import SimplMaker

/// The Rounded Rectangle and Tangent Arc sketch tools, as they are drawn with the mouse.
@Suite @MainActor struct RoundedRectangleAndTangentArcTests {
    private func session() -> SketchSession {
        SketchSession(featureID: IDs.make(), frame: .xy, sketch: Sketch(), parameters: ParameterEvaluator.evaluate([]))
    }

    private func click(_ s: SketchSession, _ x: Double, _ y: Double) -> String? {
        _ = s.handle(SketchMouse(phase: .moved, uv: SIMD2(x, y), pick: nil))
        let down = s.handle(SketchMouse(phase: .down, uv: SIMD2(x, y), pick: nil))
        let up = s.handle(SketchMouse(phase: .up, uv: SIMD2(x, y), pick: nil))
        return down.commit ?? up.commit
    }

    @Test func roundedRectangleIsAFamilyOfTheRectangleTools() {
        #expect(SketchTool.roundedRectangle.family == [.rectangle, .centerRectangle, .rectangle3Point, .roundedRectangle, .centerRoundedRectangle])
        #expect(SketchTool.forKey("r", current: .rectangle3Point) == .roundedRectangle)
        #expect(SketchTool.forKey("r", current: .roundedRectangle) == .centerRoundedRectangle)
        #expect(SketchTool.forKey("r", current: .centerRoundedRectangle) == .rectangle)
    }

    @Test func twoCornersDrawARoundedRectangleOfTheTypedRadius() {
        let s = session()
        s.setTool(.roundedRectangle)
        s.setTyped(.radius, "2")
        _ = click(s, 0, 0)
        _ = click(s, 20, 10)
        #expect(s.sketch.curves.count == 8, "four sides and four corner arcs")
        #expect(s.sketch.dimensions.filter { if case .radius = $0.kind { return true } else { return false } }.count == 1)
        #expect(s.roundedRadius == "2 mm")
    }

    @Test func aRadiusTooBigForTheRectangleDrawsNothingAndSaysWhy() {
        let s = session()
        s.setTool(.roundedRectangle)
        s.setTyped(.radius, "9")
        _ = click(s, 0, 0)
        _ = click(s, 20, 10)
        #expect(s.sketch.curves.isEmpty)
        #expect(s.message != nil)
    }

    /// A 50 x 30 rounded rectangle of radius 5 with a length dimension on every side (corner to corner), as the
    /// Dimension tool leaves them.
    private func dimensionedRoundedRectangle() -> SketchSession {
        var sk = Sketch()
        let made = sk.addRoundedRectangle(from: SketchSnap(SIMD2(0, 0)), to: SketchSnap(SIMD2(50, 30)), radius: 5, expression: "5 mm")!
        // The corners are (0,0), (50,0), (50,30), (0,30): bottom, right, top, left.
        let c = made.corners
        sk.dimension(.distance(c[0], c[1]), "50 mm")
        sk.dimension(.distance(c[3], c[2]), "50 mm")
        sk.dimension(.distance(c[0], c[3]), "30 mm")
        sk.dimension(.distance(c[1], c[2]), "30 mm")
        return SketchSession(featureID: IDs.make(), frame: .xy, sketch: sk, parameters: ParameterEvaluator.evaluate([]))
    }

    @Test func theRadiusOfADimensionedRoundedRectangleCanBeChangedLater() {
        let s = dimensionedRoundedRectangle()
        let radius = s.sketch.dimensions.first { if case .radius = $0.kind { return true } else { return false } }
        #expect(s.setDimension(radius!.id, expression: "4") == "Edit Dimension", Comment(rawValue: s.message ?? ""))
        #expect(s.setDimension(radius!.id, expression: "8") == "Edit Dimension", Comment(rawValue: s.message ?? ""))
    }

    /// The other three corners show a light "R 5 mm" too; clicking one must edit the one radius they all share,
    /// not add a second radius dimension that fights it.
    @Test func clickingAnotherCornersRadiusEditsTheSharedRadius() {
        let s = dimensionedRoundedRectangle()
        func radiusDimensions() -> [SketchDimension] {
            s.sketch.dimensions.filter { if case .radius = $0.kind { return true } else { return false } }
        }
        let original = radiusDimensions().first!
        let arcs = s.sketch.curves.filter { if case .arc = $0.geometry { return true } else { return false } }.map(\.id)
        for arc in arcs {
            _ = s.dimensionReference(arc)
            #expect(radiusDimensions().count == 1, "no second radius dimension")
            #expect(s.editingDimension == original.id, "the shared radius opens for typing")
        }
        #expect(s.setDimension(original.id, expression: "4") == "Edit Dimension", Comment(rawValue: s.message ?? ""))
        for arc in arcs {
            #expect(abs((s.sketch.curve(arc).flatMap { s.sketch.radius(of: $0) } ?? 0) - 4) < 1e-6)
        }
    }

    /// Outer width and height of the drawn outline: the extent of the straight sides' lines (the virtual corners).
    private func outerSize(_ s: SketchSession) -> (w: Double, h: Double) {
        var xs: [Double] = [], ys: [Double] = []
        for c in s.sketch.curves {
            guard case .line(let a, let b) = c.geometry, let pa = s.sketch.position(a), let pb = s.sketch.position(b) else { continue }
            if abs(pa.y - pb.y) < 1e-6 { ys.append(pa.y) }
            if abs(pa.x - pb.x) < 1e-6 { xs.append(pa.x) }
        }
        return ((xs.max() ?? 0) - (xs.min() ?? 0), (ys.max() ?? 0) - (ys.min() ?? 0))
    }

    @Test func changingTheRadiusKeepsTheRectangleItsSize() {
        let s = session()
        s.setTool(.roundedRectangle)
        s.setTyped(.radius, "5")
        _ = click(s, 0, 0)
        _ = click(s, 50, 30)
        let before = outerSize(s)
        #expect(abs(before.w - 50) < 1e-6 && abs(before.h - 30) < 1e-6)
        let radius = s.sketch.dimensions.first { if case .radius = $0.kind { return true } else { return false } }!
        for value in ["4", "8", "2"] {
            #expect(s.setDimension(radius.id, expression: value) == "Edit Dimension", Comment(rawValue: s.message ?? ""))
            let after = outerSize(s)
            #expect(abs(after.w - 50) < 1e-6 && abs(after.h - 30) < 1e-6, "radius \(value): the outline is \(after.w) x \(after.h)")
        }
    }

    /// Which corner the rectangle is drawn from decides which corner arc carries the radius dimension; the outline
    /// must keep its size whichever it is.
    @Test func changingTheRadiusKeepsTheSizeWhicheverWayTheRectangleWasDrawn() {
        for (name, a, b) in [("bottom-left to top-right", (0.0, 0.0), (50.0, 30.0)), ("top-left to bottom-right", (0.0, 30.0), (50.0, 0.0)),
                             ("top-right to bottom-left", (50.0, 30.0), (0.0, 0.0)), ("bottom-right to top-left", (50.0, 0.0), (0.0, 30.0))] {
            let s = session(); s.setTool(.roundedRectangle); s.setTyped(.radius, "4")
            _ = click(s, a.0, a.1); _ = click(s, b.0, b.1)
            let radius = s.sketch.dimensions.first { if case .radius = $0.kind { return true } else { return false } }!
            for v in ["9", "2", "4"] {
                #expect(s.setDimension(radius.id, expression: v) == "Edit Dimension", Comment(rawValue: "\(name), radius \(v)"))
                let size = outerSize(s)
                #expect(abs(size.w - 50) < 1e-6 && abs(size.h - 30) < 1e-6, Comment(rawValue: "\(name), radius \(v): \(size.w) x \(size.h)"))
            }
        }
    }

    @Test func aTangentArcMustStartOnAFreeEnd() {
        let s = session()
        s.setTool(.tangentArc)
        _ = click(s, 50, 50)
        #expect(s.sketch.curves.isEmpty)
        #expect(s.message != nil)
    }
}

@Suite @MainActor struct SketchChamferToolTests {
    @Test func chamferIsOnTheModifyGroupAndKeepsItsOwnKey() {
        #expect(SketchTool.modify.contains(.chamfer))
        #expect(SketchTool.chamfer.family == [.chamfer])
    }
}
