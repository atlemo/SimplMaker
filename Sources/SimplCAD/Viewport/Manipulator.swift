// The Move/Rotate manipulator: axis arrows, plane squares, a centre dot and rotation rings, drawn
// over the viewport in screen space. This file is the geometry (where things are on screen, what a
// click hits) and the drag math (what a mouse movement means); the drawing is in ManipulatorView.
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import CoreGraphics
import Foundation
import simd

extension Axis3 {
    var vector: SIMD3<Double> {
        switch self {
        case .x: return SIMD3(1, 0, 0)
        case .y: return SIMD3(0, 1, 0)
        case .z: return SIMD3(0, 0, 1)
        }
    }

    var index: Int { self == .x ? 0 : self == .y ? 1 : 2 }

    /// The other two axes, in an order that turns counter-clockwise about this one (X → Y → Z → X).
    var others: (Axis3, Axis3) {
        switch self {
        case .x: return (.y, .z)
        case .y: return (.z, .x)
        case .z: return (.x, .y)
        }
    }
}

/// A part of the manipulator that can be grabbed.
enum ManipulatorPart: Hashable, Sendable {
    /// An arrow: slides along an axis.
    case axis(Axis3)
    /// A square: slides in the plane square to the axis (the square between the other two arrows).
    case plane(Axis3)
    /// A ring: turns about the axis.
    case ring(Axis3)
    /// The dot in the middle: slides in the plane of the screen.
    case center
}

/// What a Move feature holds, as numbers: how far it moves (mm) and how far it turns (radians).
struct TransformValues: Equatable {
    var move = SIMD3<Double>.zero
    var turn = SIMD3<Double>.zero
}

/// The directions the manipulator's X, Y and Z point, and which parts it shows. A Move feature's is
/// the world's axes with everything; a sketch's is the sketch plane (its x, its y, its normal) with
/// arrows along the plane, the square between them and the ring about the normal.
struct ManipulatorFrame {
    var basis: [SIMD3<Double>] = Axis3.allCases.map(\.vector)
    var arrows = Axis3.allCases
    var squares = Axis3.allCases
    var rings = Axis3.allCases
    /// Whether the dot in the middle slides in the plane of the screen (else in the plane of the Z ring).
    var dotFollowsScreen = true

    static let world = ManipulatorFrame()

    init() {}

    init(sketch f: Frame) {
        basis = [f.xAxis, f.yAxis, f.normal]
        arrows = [.x, .y]
        squares = [.z]
        rings = [.z]
        dotFollowsScreen = false
    }

    func vector(_ axis: Axis3) -> SIMD3<Double> { basis[axis.index] }
}

// MARK: - where things are on screen

struct ManipulatorLayout {
    /// Sizes in points, so the manipulator looks the same however far away the model is.
    static let arrowReach: CGFloat = 78
    static let arrowGap: CGFloat = 16
    static let squareNear: CGFloat = 26
    static let squareFar: CGFloat = 52
    static let ringRadius: CGFloat = 104
    static let dotRadius: CGFloat = 8
    static let handleRadius: CGFloat = 10

    struct Arrow {
        var axis: Axis3
        var polygon: [CGPoint]
        var tail: CGPoint
        var tip: CGPoint
    }

    struct Square {
        var normal: Axis3
        var corners: [CGPoint]
    }

    struct Ring {
        var axis: Axis3
        /// The circle as a closed run of points.
        var outline: [CGPoint]
        /// The grab handle on it, and the direction the ring runs there (on screen, unit length).
        var handle: CGPoint
        var direction: CGVector
    }

    let camera: Camera
    let viewSize: CGSize
    let frame: ManipulatorFrame
    /// The manipulator's middle in the model, and how much it has turned already (the handles ride round).
    let middle: SIMD3<Double>
    let turn: SIMD3<Double>
    let center: CGPoint
    let pointsPerMM: Double
    private(set) var arrows: [Arrow] = []
    private(set) var squares: [Square] = []
    private(set) var rings: [Ring] = []

    static func project(_ p: SIMD3<Double>, _ camera: Camera, _ size: CGSize) -> CGPoint? {
        camera.project(SIMD3(Float(p.x), Float(p.y), Float(p.z)), viewSize: size)
    }

    init?(middle: SIMD3<Double>, turn: SIMD3<Double> = .zero, frame: ManipulatorFrame = .world, camera: Camera, viewSize: CGSize) {
        guard viewSize.width > 1, viewSize.height > 1, let c = Self.project(middle, camera, viewSize) else { return nil }
        // How long a millimetre looks, across the screen, where the manipulator is.
        let right = SIMD3(Double(camera.right.x), Double(camera.right.y), Double(camera.right.z))
        guard let r = Self.project(middle + right * 10, camera, viewSize) else { return nil }
        let ppm = hypot(r.x - c.x, r.y - c.y) / 10
        guard ppm > 1e-9 else { return nil }
        self.camera = camera; self.viewSize = viewSize; self.frame = frame; self.middle = middle; self.turn = turn; center = c; pointsPerMM = Double(ppm)
        func mm(_ points: CGFloat) -> Double { Double(points) / Double(ppm) }
        func at(_ p: SIMD3<Double>) -> CGPoint? { Self.project(p, camera, viewSize) }

        for axis in Axis3.allCases {
            let vector = frame.vector(axis)
            // Arrow: as long as it looks (shorter when it points toward or away from the viewer).
            if frame.arrows.contains(axis), let end = at(middle + vector * mm(Self.arrowReach)) {
                let v = CGVector(dx: end.x - c.x, dy: end.y - c.y)
                let len = hypot(v.dx, v.dy)
                if len >= Self.arrowGap + 14 {
                    let u = CGVector(dx: v.dx / len, dy: v.dy / len), n = CGVector(dx: -u.dy, dy: u.dx)
                    func pt(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
                        CGPoint(x: c.x + u.dx * along + n.dx * across, y: c.y + u.dy * along + n.dy * across)
                    }
                    let head = min(20, (len - Self.arrowGap) * 0.6)
                    arrows.append(Arrow(axis: axis, polygon: [
                        pt(Self.arrowGap, -4), pt(len - head, -4), pt(len - head, -11), pt(len, 0),
                        pt(len - head, 11), pt(len - head, 4), pt(Self.arrowGap, 4)], tail: pt(Self.arrowGap, 0), tip: pt(len, 0)))
                }
            }
            // Square between the other two arrows.
            let (a, b) = axis.others
            let (av, bv) = (frame.vector(a), frame.vector(b))
            let corners = [(Self.squareNear, Self.squareNear), (Self.squareFar, Self.squareNear),
                           (Self.squareFar, Self.squareFar), (Self.squareNear, Self.squareFar)]
                .compactMap { at(middle + av * mm($0.0) + bv * mm($0.1)) }
            if frame.squares.contains(axis), corners.count == 4, Self.area(corners) > 90 { squares.append(Square(normal: axis, corners: corners)) }
            // Ring about the axis, with its handle a little way round.
            guard frame.rings.contains(axis) else { continue }
            let radius = mm(Self.ringRadius)
            func onRing(_ t: Double) -> SIMD3<Double> { middle + radius * (cos(t) * av + sin(t) * bv) }
            let outline = stride(from: 0.0, to: 2 * Double.pi, by: 2 * Double.pi / 120).compactMap { at(onRing($0)) }
            let t = Double.pi / 4 + turn[axis.index]
            if outline.count == 120, let h = at(onRing(t)), let before = at(onRing(t - 0.05)), let after = at(onRing(t + 0.05)) {
                let d = CGVector(dx: after.x - before.x, dy: after.y - before.y), len = max(hypot(d.dx, d.dy), 1e-9)
                rings.append(Ring(axis: axis, outline: outline, handle: h, direction: CGVector(dx: d.dx / len, dy: d.dy / len)))
            }
        }
    }

    static func area(_ p: [CGPoint]) -> CGFloat {
        var s: CGFloat = 0
        for i in p.indices { let j = (i + 1) % p.count; s += p[i].x * p[j].y - p[j].x * p[i].y }
        return abs(s) / 2
    }

    /// What a click at `p` grabs, the small things first.
    func hit(_ p: CGPoint) -> ManipulatorPart? {
        if hypot(p.x - center.x, p.y - center.y) <= Self.dotRadius + 3 { return .center }
        for a in arrows where Self.distance(p, toSegment: a.tail, a.tip) <= 9 { return .axis(a.axis) }
        for r in rings where hypot(p.x - r.handle.x, p.y - r.handle.y) <= Self.handleRadius + 3 { return .ring(r.axis) }
        for s in squares where Self.contains(s.corners, p) { return .plane(s.normal) }
        for r in rings where Self.distance(p, toPolyline: r.outline, closed: true) <= 5 { return .ring(r.axis) }
        return nil
    }

    /// Where the typed value for a part goes: beside the tip of an arrow, or a ring's handle.
    func anchor(for part: ManipulatorPart) -> CGPoint? {
        switch part {
        case .axis(let a): return arrows.first { $0.axis == a }?.tip
        case .ring(let a): return rings.first { $0.axis == a }?.handle
        case .plane, .center: return nil
        }
    }

    static func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let ab = CGVector(dx: b.x - a.x, dy: b.y - a.y), l2 = ab.dx * ab.dx + ab.dy * ab.dy
        let t = l2 < 1e-9 ? 0 : min(max(((p.x - a.x) * ab.dx + (p.y - a.y) * ab.dy) / l2, 0), 1)
        return hypot(p.x - (a.x + t * ab.dx), p.y - (a.y + t * ab.dy))
    }

    static func distance(_ p: CGPoint, toPolyline pts: [CGPoint], closed: Bool) -> CGFloat {
        var best = CGFloat.infinity
        for i in pts.indices where closed || i + 1 < pts.count {
            best = min(best, distance(p, toSegment: pts[i], pts[(i + 1) % pts.count]))
        }
        return best
    }

    static func contains(_ poly: [CGPoint], _ p: CGPoint) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in poly.indices {
            if (poly[i].y > p.y) != (poly[j].y > p.y),
               p.x < (poly[j].x - poly[i].x) * (p.y - poly[i].y) / (poly[j].y - poly[i].y) + poly[i].x { inside.toggle() }
            j = i
        }
        return inside
    }
}

// MARK: - dragging

/// A grab of one part, and what dragging it does. Made at mouse-down; `values(at:)` maps each mouse
/// position to the new move and turn. Distances go in round steps (1, 2 or 5 × 10ⁿ mm) of about 6
/// points, and turns in round steps of degrees.
struct ManipulatorDrag {
    let part: ManipulatorPart
    let start: TransformValues
    private let frame: ManipulatorFrame
    private let middle: SIMD3<Double>
    private let pointsPerMM: Double
    private let ringRadiusPoints: CGFloat
    private var reference: Reference
    /// The angle the mouse has turned the ring through so far, kept across half turns.
    private var lastAngle = 0.0
    private var accumulated = 0.0

    private enum Reference {
        case axis(along: Double)
        case plane(SIMD3<Double>)
        case ring(angle: Double)
        /// A ring seen edge-on can't be read from where the mouse is on it, so the mouse's travel along it counts.
        case tangent(from: CGPoint, direction: CGVector)
    }

    typealias Ray = (origin: SIMD3<Double>, direction: SIMD3<Double>)

    private static func ray(_ p: CGPoint, _ camera: Camera, _ size: CGSize) -> Ray {
        let r = camera.ray(at: p, viewSize: size)
        return (SIMD3(Double(r.origin.x), Double(r.origin.y), Double(r.origin.z)),
                SIMD3(Double(r.direction.x), Double(r.direction.y), Double(r.direction.z)))
    }

    /// The point along an axis through `origin` nearest the ray, as a distance from `origin`.
    static func along(_ axis: SIMD3<Double>, from origin: SIMD3<Double>, ray: Ray) -> Double? {
        let b = simd_dot(axis, ray.direction), w = origin - ray.origin
        guard 1 - b * b > 1e-6 else { return nil }  // looking straight down the axis
        return (b * simd_dot(ray.direction, w) - simd_dot(axis, w)) / (1 - b * b)
    }

    static func hit(_ ray: Ray, plane origin: SIMD3<Double>, normal: SIMD3<Double>) -> SIMD3<Double>? {
        let denom = simd_dot(ray.direction, normal)
        guard abs(denom) > 1e-9 else { return nil }
        return ray.origin + simd_dot(origin - ray.origin, normal) / denom * ray.direction
    }

    /// Where a point is round a ring about `axis` through `middle`, counter-clockwise from the axis's first other axis.
    static func angle(of p: SIMD3<Double>, about axis: Axis3, through middle: SIMD3<Double>, in frame: ManipulatorFrame) -> Double {
        let (a, b) = axis.others
        return atan2(simd_dot(p - middle, frame.vector(b)), simd_dot(p - middle, frame.vector(a)))
    }

    init?(part grabbed: ManipulatorPart, at p: CGPoint, layout: ManipulatorLayout, start: TransformValues) {
        let part: ManipulatorPart = grabbed == .center && !layout.frame.dotFollowsScreen ? .plane(.z) : grabbed
        self.part = part; self.start = start
        frame = layout.frame; middle = layout.middle; pointsPerMM = layout.pointsPerMM; ringRadiusPoints = ManipulatorLayout.ringRadius
        let ray = Self.ray(p, layout.camera, layout.viewSize)
        switch part {
        case .axis(let a):
            guard let s = Self.along(frame.vector(a), from: middle, ray: ray) else { return nil }
            reference = .axis(along: s)
        case .plane(let n):
            guard let h = Self.hit(ray, plane: middle, normal: frame.vector(n)) else { return nil }
            reference = .plane(h)
        case .center:
            let f = layout.camera.forward
            guard let h = Self.hit(ray, plane: middle, normal: SIMD3(Double(f.x), Double(f.y), Double(f.z))) else { return nil }
            reference = .plane(h)
        case .ring(let a):
            if abs(simd_dot(ray.direction, frame.vector(a))) > 0.15, let h = Self.hit(ray, plane: middle, normal: frame.vector(a)) {
                let t = Self.angle(of: h, about: a, through: middle, in: frame)
                reference = .ring(angle: t)
                lastAngle = t
            } else if let ring = layout.rings.first(where: { $0.axis == a }) {
                reference = .tangent(from: p, direction: ring.direction)
            } else {
                return nil
            }
        }
    }

    private func snap(_ mm: Double) -> Double {
        let step = ViewportMTKView.niceStep(6 / pointsPerMM)
        return (mm / step).rounded() * step
    }

    private func snap(degrees radians: Double) -> Double {
        let step = max(ViewportMTKView.niceStep(6 * (180 / Double.pi) / Double(ringRadiusPoints)), 1)
        return (radians * 180 / Double.pi / step).rounded() * step * Double.pi / 180
    }

    /// The move and turn when the mouse is at `p`; nil when the mouse can't say (looking along an axis).
    mutating func values(at p: CGPoint, camera: Camera, viewSize: CGSize) -> TransformValues? {
        let ray = Self.ray(p, camera, viewSize)
        var v = start
        switch (part, reference) {
        case (.axis(let a), .axis(let s0)):
            guard let s = Self.along(frame.vector(a), from: middle, ray: ray) else { return nil }
            v.move[a.index] = snap(start.move[a.index] + s - s0)
        case (.plane(let n), .plane(let h0)):
            guard let h = Self.hit(ray, plane: middle, normal: frame.vector(n)) else { return nil }
            let (a, b) = n.others
            v.move[a.index] = snap(start.move[a.index] + simd_dot(h - h0, frame.vector(a)))
            v.move[b.index] = snap(start.move[b.index] + simd_dot(h - h0, frame.vector(b)))
        case (.center, .plane(let h0)):
            let f = camera.forward
            guard let h = Self.hit(ray, plane: middle, normal: SIMD3(Double(f.x), Double(f.y), Double(f.z))) else { return nil }
            for i in 0..<3 { v.move[i] = snap(start.move[i] + (h - h0)[i]) }
        case (.ring(let a), .ring):
            guard let h = Self.hit(ray, plane: middle, normal: frame.vector(a)) else { return nil }
            let t = Self.angle(of: h, about: a, through: middle, in: frame)
            var d = t - lastAngle
            if d > .pi { d -= 2 * .pi } else if d < -.pi { d += 2 * .pi }
            accumulated += d
            lastAngle = t
            v.turn[a.index] = snap(degrees: start.turn[a.index] + accumulated)
        case (.ring(let a), .tangent(let from, let dir)):
            let travelled = (p.x - from.x) * dir.dx + (p.y - from.y) * dir.dy
            v.turn[a.index] = snap(degrees: start.turn[a.index] + Double(travelled / ringRadiusPoints))
        default:
            return nil
        }
        return v
    }
}
