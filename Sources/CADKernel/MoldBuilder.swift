// Builds the halves of a mold from its settings and the finished body (MoldSetup, in CADCore). It runs after the regenerator, on
// the same background thread, and its result is never saved. The recipe, found in the Phase 0 spike (docs/MOLD-PLAN.md):
//   block around the body → gate and vents cut into the plain block (one tool) → split at the parting plane → cone keys on the
//   plain halves → the body subtracted from each half last.
// Everything before the body is subtracted works on simple shapes, which is why this is about twice as fast as cutting the body
// out first on a heavy imported mesh.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CKernel
import Foundation
import simd

/// What a mold build came to.
public struct MoldResult: Sendable {
    public var setup: MoldSetup
    /// The half behind the parting plane and the half in front of it (along its normal). Nil when the build failed.
    public var behind: KBody?
    public var front: KBody?
    /// Why it could not be built, in words for the user; nil when it was.
    public var error: String?
    /// Things worth knowing about a mold that was built (keys made smaller, plane moved a hair, a gate that misses).
    public var warnings: [String] = []
    /// The parting plane as built: a point on it and its normal.
    public var partingPoint = SIMD3<Double>.zero
    public var partingNormal = SIMD3<Double>(0, 0, 1)
    /// Where the gate goes in at the body (its axis runs up from here), and where each vent starts.
    public var gatePoint: SIMD3<Double>?
    public var ventPoints: [SIMD3<Double>] = []
    /// The block's size (mm), the body's volume and what the cavity holds: body, gate and vents (mm³). The silicone to mix.
    public var blockSize = SIMD3<Double>.zero
    public var bodyVolume = 0.0
    public var cavityVolume = 0.0
    public var seconds = 0.0

    public init(setup: MoldSetup, error: String? = nil) { self.setup = setup; self.error = error }

    public var isBuilt: Bool { error == nil && behind != nil && front != nil }

    /// The halves with their ids and names, behind first.
    public var halves: [BodyResult] {
        guard let behind, let front else { return [] }
        let names = MoldBuilder.halfNames(axis: Self.axis(of: partingNormal))
        let ids = setup.halfIDs
        return [BodyResult(id: ids.behind, name: "\(setup.name) \(names.behind)", body: behind),
                BodyResult(id: ids.front, name: "\(setup.name) \(names.front)", body: front)]
    }

    static func axis(of n: SIMD3<Double>) -> MoldAxis { abs(n.x) > 0.5 ? .x : abs(n.y) > 0.5 ? .y : .z }
}

public enum MoldBuilder {
    /// Sizes used when the setup leaves a choice (see the notes in docs/MOLD-PLAN.md: all of them to be settled by test prints).
    static let keyHeightShare = 1.0       // key height as a share of its radius
    static let keyTipShare = 0.6          // the narrow end of the cone, as a share of its base
    static let bigKeyShare = 1.3          // the one key that is bigger, so the halves only go together one way
    static let gateDepth = 1.0            // how far under the body's highest point the gate starts
    /// A parting plane that gives invalid halves is moved by these distances, one after another, to dodge a seam of a round face.
    static let nudges = [0.05, -0.05, 0.2]

    public static func halfNames(axis: MoldAxis) -> (behind: String, front: String) {
        switch axis {
        case .x: ("left half", "right half")
        case .y: ("front half", "back half")
        case .z: ("bottom half", "top half")
        }
    }

    /// Builds the mold of `part` (the body the setup names, as the regeneration `r` made it).
    public static func build(_ setup: MoldSetup, part: KBody, in r: RegenResult) -> MoldResult {
        let started = Date()
        var result = MoldResult(setup: setup)
        defer { result.seconds = Date().timeIntervalSince(started) }
        do {
            try build(setup, part: part, in: r, into: &result)
        } catch let e as MoldError {
            result.error = e.message; result.behind = nil; result.front = nil
        } catch {
            result.error = "The mold could not be built: \(error)"; result.behind = nil; result.front = nil
        }
        return result
    }

    struct MoldError: Error { var message: String }

    private static func length(_ text: String, _ what: String, in r: RegenResult, min: Double = 0, allowZero: Bool = false) throws -> Double {
        let v: Double
        do { v = try r.parameters.value(of: text, kind: .length) } catch { throw MoldError(message: "The \(what) \"\(text)\" is not a length.") }
        guard v.isFinite, allowZero ? v >= min : v > min else { throw MoldError(message: "The \(what) must be more than \(min == 0 ? "zero" : "\(min) mm").") }
        return v
    }

    private static func build(_ setup: MoldSetup, part: KBody, in r: RegenResult, into out: inout MoldResult) throws {
        let wall = try length(setup.wall, "wall", in: r, min: 1)
        let gateDiameter = try length(setup.gateDiameter, "gate diameter", in: r)
        let ventDiameter = try length(setup.ventDiameter, "vent diameter", in: r)
        let keyDiameter = setup.keys ? try length(setup.keyDiameter, "key size", in: r) : 0
        let clearance = setup.keys ? try length(setup.keyClearance, "key clearance", in: r, allowZero: true) : 0
        let offset: Double
        do { offset = try r.parameters.value(of: setup.partingOffset, kind: .length) } catch {
            throw MoldError(message: "The parting offset \"\(setup.partingOffset)\" is not a length.")
        }

        // The body has to be a sound solid: a subtraction from a broken one is slow and gives halves that are wrong.
        guard part.isValid else {
            throw MoldError(message: "The body is not a valid solid (an imported mesh with gaps, for one). Repair it in Design first.")
        }
        guard let bounds = part.bounds, part.volume > 1e-6 else { throw MoldError(message: "The body is empty.") }
        let ext = bounds.max - bounds.min
        let centre = (bounds.min + bounds.max) / 2
        out.bodyVolume = part.volume

        // The parting plane: a point and a normal along X, Y or Z.
        var normal: SIMD3<Double>
        var point: SIMD3<Double>
        switch setup.parting {
        case .middle(let axis):
            normal = axis.vector; point = centre
        case .plane(let ref):
            let frame: Frame
            do { frame = try Regenerator.resolvePlane(ref, r) } catch { throw MoldError(message: "The parting plane is missing: \(error)") }
            guard let axis = MoldAxis.allCases.first(where: { abs(simd_dot(frame.normal, $0.vector)) > 1 - 1e-6 }) else {
                throw MoldError(message: "The parting plane leans. Only planes square to X, Y or Z can part a mold so far.")
            }
            normal = axis.vector * (simd_dot(frame.normal, axis.vector) > 0 ? 1 : -1)
            point = frame.origin
        }
        point += normal * offset
        let axisIndex = MoldResult.axis(of: normal).index
        let planeCoordinate = point[axisIndex]
        guard planeCoordinate > bounds.min[axisIndex] + 0.2, planeCoordinate < bounds.max[axisIndex] - 0.2 else {
            throw MoldError(message: "The parting plane does not cut through the body.")
        }
        out.partingNormal = normal

        // Pour direction and the block.
        let up = setup.up.vector
        let size = ext + SIMD3(repeating: 2 * wall)
        out.blockSize = size
        let blockLow = bounds.min - SIMD3(repeating: wall)
        let blockHigh = bounds.max + SIMD3(repeating: wall)
        let block = try makeBlock(centre: centre, size: size)

        // Where the gate goes in: the body's highest point along "up", or the point the setup names.
        let top = highestPoint(of: part, along: up, bounds: bounds, ext: ext)
        var gate = setup.gatePoint?.vector ?? top
        if setup.gatePoint != nil { gate += up * (simd_dot(top - gate, up)) }  // a hand-placed gate: its place across "up", the height of the top
        // A gate beside a vertical parting plane lies on the plane, so the split makes two half-channels.
        let upAxis = setup.up.axis
        if upAxis != MoldResult.axis(of: normal), setup.gatePoint == nil { gate[axisIndex] = planeCoordinate }
        out.gatePoint = gate

        func channel(_ p: SIMD3<Double>, diameter: Double, id: String) throws -> KBody {
            let start = p - up * gateDepth
            let topCoordinate = simd_dot(up, up.x + up.y + up.z > 0 ? blockHigh : blockLow)
            let length = topCoordinate - simd_dot(up, start) + 1
            return try rod(from: start, dir: up, diameter: diameter, length: length, id: id)
        }
        var channels = try channel(gate, diameter: gateDiameter, id: "gate")
        var axes: [(point: SIMD3<Double>, radius: Double)] = [(gate, gateDiameter / 2)]
        for (i, v) in setup.vents.enumerated() {
            channels = try channels.boolean(try channel(v.vector, diameter: ventDiameter, id: "vent\(i)"), SK_FUSE)
            axes.append((v.vector, ventDiameter / 2))
            out.ventPoints.append(v.vector)
        }
        if gateDiameter / 2 + 1 > wall { out.warnings.append("The gate is wider than the wall, so it may break through the side of the mold.") }

        // Does the gate meet the body? It starts just under the highest point, so it does, unless the point was placed by hand.
        if setup.gatePoint != nil, let reach = try? part.distance(.body, to: try channel(gate, diameter: gateDiameter, id: "check"), .body),
           reach.distance > 1e-3 {
            out.warnings.append("The gate does not reach the body (\(String(format: "%.1f", reach.distance)) mm away).")
        }

        // The keys: cones in the four corners of the ring around the body, on the parting plane; the last one is bigger so the halves
        // only go together one way. They have to fit inside the ring: the key is made smaller if the wall is thin.
        let others = MoldAxis.allCases.filter { $0.index != axisIndex }
        let (ua, wa) = (others[0].vector, others[1].vector)
        var keyRadius = keyDiameter / 2
        let fits = (wall / 2 - clearance - 0.8) / bigKeyShare
        if setup.keys, keyRadius > fits {
            keyRadius = max(fits, 0.5)
            out.warnings.append("The keys are made smaller (\(String(format: "%.1f", keyRadius * 2)) mm) to fit the wall: a thicker wall takes bigger ones.")
        }
        let spots: [SIMD3<Double>] = {
            let ru = (size[others[0].index] - wall) / 2, rw = (size[others[1].index] - wall) / 2
            let c = centre
            var p = [c + ua * ru + wa * rw, c - ua * ru + wa * rw, c + ua * ru - wa * rw, c - ua * ru - wa * rw]
            for i in p.indices { p[i][axisIndex] = planeCoordinate }
            return p
        }()

        // One try at the split, keys and the body cut out; repeated with the plane nudged when the halves come out invalid.
        func attempt(shift: Double) throws -> (behind: KBody, front: KBody, pegs: Double, sockets: Double)? {
            let p = point + normal * shift
            let drilled = channels.isEmpty ? block : try block.boolean(channels, SK_CUT)
            let halves = try drilled.split(planeThrough: p, normal: normal, featureID: "mold")
            guard halves.count == 2 else { return nil }
            var behind = halves[0], front = halves[1]
            var pegVolume = 0.0, socketVolume = 0.0
            if setup.keys, keyRadius > 0 {
                var pegs: KBody?, sockets: KBody?
                for (i, s) in spots.enumerated() {
                    // A key that would sit in a channel is left out.
                    let inPlane = { (q: SIMD3<Double>) in simd_length((q - s) * (SIMD3<Double>(1, 1, 1) - abs(normal))) }
                    let radius = keyRadius * (i == 3 ? bigKeyShare : 1)
                    if axes.contains(where: { inPlane($0.point) < $0.radius + radius + clearance + 0.5 }) { continue }
                    let peg = try cone(base: s + normal * shift, dir: -normal, r0: radius, r1: radius * keyTipShare,
                                       h: radius * keyHeightShare, id: "peg\(i)")
                    let socket = try cone(base: s + normal * (shift + 0.01), dir: -normal, r0: radius + clearance,
                                          r1: radius * keyTipShare + clearance, h: radius * keyHeightShare + clearance, id: "socket\(i)")
                    pegVolume += peg.volume; socketVolume += socket.volume
                    pegs = try pegs.map { try $0.boolean(peg, SK_FUSE) } ?? peg
                    sockets = try sockets.map { try $0.boolean(socket, SK_FUSE) } ?? socket
                }
                if let pegs, let sockets {
                    front = try front.boolean(pegs, SK_FUSE)
                    behind = try behind.boolean(sockets, SK_CUT)
                }
            }
            behind = try behind.boolean(part, SK_CUT)
            front = try front.boolean(part, SK_CUT)
            guard behind.isValid, front.isValid, !behind.isEmpty, !front.isEmpty else { return nil }
            return (behind, front, pegVolume, socketVolume)
        }

        var built: (behind: KBody, front: KBody, pegs: Double, sockets: Double)?
        var used = 0.0
        for shift in [0.0] + nudges {
            if let b = try attempt(shift: shift) { built = b; used = shift; break }
        }
        guard let built else {
            throw MoldError(message: "The halves could not be made at this parting plane. Move the plane a little, or pick another.")
        }
        if used != 0 { out.warnings.append("The parting plane was moved \(String(format: "%.2f", abs(used))) mm: exactly there it gave a broken split.") }
        out.behind = built.behind
        out.front = built.front
        out.partingPoint = point + normal * used
        // What the cavity holds is what is missing from the block: its volume, less the halves, plus what the keys added to one half and took from the other.
        out.cavityVolume = block.volume - built.behind.volume - built.front.volume + built.pegs - built.sockets
    }

    // MARK: building blocks

    static func makeBlock(centre c: SIMD3<Double>, size s: SIMD3<Double>) throws -> KBody {
        let frame = Frame(origin: SIMD3(c.x, c.y, c.z - s.z / 2), normal: SIMD3(0, 0, 1), xAxis: SIMD3(1, 0, 0))
        return try KBody.primitive(.box(width: s.x, length: s.y, height: s.z), on: frame, featureID: "block")
    }

    private static func perpendicular(to n: SIMD3<Double>) -> SIMD3<Double> {
        let x = abs(n.x) < 0.9 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
        return simd_normalize(x - simd_dot(x, n) * n)
    }

    /// A cylinder from `from` along `dir`.
    static func rod(from: SIMD3<Double>, dir: SIMD3<Double>, diameter: Double, length: Double, id: String) throws -> KBody {
        let n = simd_normalize(dir)
        return try KBody.primitive(.cylinder(diameter: diameter, height: length), on: Frame(origin: from, normal: n, xAxis: perpendicular(to: n)), featureID: id)
    }

    /// A cone standing on `base`, pointing along `dir`: radius r0 at the base narrowing to r1 over h.
    static func cone(base: SIMD3<Double>, dir: SIMD3<Double>, r0: Double, r1: Double, h: Double, id: String) throws -> KBody {
        let n = simd_normalize(dir)
        let xa = perpendicular(to: n)
        // The sketch plane contains the axis: its x is across, its y runs along `dir`.
        let s = try KSketch(frame: Frame(origin: base, normal: simd_cross(xa, n), xAxis: xa))
        try s.addLine("a", SIMD2(0, 0), SIMD2(r0, 0))
        try s.addLine("b", SIMD2(r0, 0), SIMD2(r1, h))
        try s.addLine("c", SIMD2(r1, h), SIMD2(0, h))
        try s.addLine("d", SIMD2(0, h), SIMD2(0, 0))
        guard let region = try s.buildRegions().first else { throw MoldError(message: "A key could not be drawn.") }
        return try KBody.revolve([s.profile(region.index)], axisOrigin: base, axisDirection: n, angle: 2 * .pi, featureID: id)
    }

    /// The highest point of the body along `up`; where a flat top is, its middle.
    static func highestPoint(of part: KBody, along up: SIMD3<Double>, bounds: (min: SIMD3<Double>, max: SIMD3<Double>), ext: SIMD3<Double>) -> SIMD3<Double> {
        let diagonal = simd_length(ext)
        let fallback = (bounds.min + bounds.max) / 2 + up * (simd_dot(ext, abs(up)) / 2)
        guard let mesh = try? part.tessellate(linearDeflection: max(0.05, diagonal * 0.002)), !mesh.positions.isEmpty else { return fallback }
        let p = mesh.positions
        var best = -Double.infinity
        for i in stride(from: 0, to: p.count - 2, by: 3) {
            best = max(best, simd_dot(SIMD3(Double(p[i]), Double(p[i + 1]), Double(p[i + 2])), up))
        }
        let tolerance = max(1e-3, diagonal * 1e-4)
        var sum = SIMD3<Double>.zero, n = 0.0
        for i in stride(from: 0, to: p.count - 2, by: 3) {
            let v = SIMD3(Double(p[i]), Double(p[i + 1]), Double(p[i + 2]))
            if simd_dot(v, up) >= best - tolerance { sum += v; n += 1 }
        }
        return n > 0 ? sum / n : fallback
    }

    // MARK: laying the halves out for printing

    /// The halves as they are printed: each with its parting face up and its back on the floor (z = 0), side by side along X with a gap.
    /// The cavity opens upwards, so it is printed without support and the seam faces are the best surface.
    public static func printLayout(_ result: MoldResult, gap: Double = 10) -> [BodyResult] {
        guard result.isBuilt else { return [] }
        let n = result.partingNormal
        var placed: [BodyResult] = []
        var cursor = 0.0
        for (half, outward) in zip(result.halves, [n, -n]) {  // each half's parting face looks towards the other one
            guard var body = try? turned(half.body, from: outward, to: SIMD3(0, 0, 1)), let b = body.bounds else { continue }
            guard let moved = try? body.translated(SIMD3(cursor - b.min.x, -b.min.y, -b.min.z)) else { continue }
            body = moved
            placed.append(BodyResult(id: half.id, name: half.name, body: body))
            cursor += (b.max.x - b.min.x) + gap
        }
        return placed
    }

    private static func turned(_ body: KBody, from a: SIMD3<Double>, to b: SIMD3<Double>) throws -> KBody {
        let d = simd_dot(a, b)
        if d > 1 - 1e-9 { return body }
        var axis = simd_cross(a, b)
        if simd_length(axis) < 1e-9 { axis = perpendicular(to: a) }  // opposite: any axis across will do
        return try body.rotated(about: .zero, axis: simd_normalize(axis), angle: acos(max(-1, min(1, d))))
    }
}
