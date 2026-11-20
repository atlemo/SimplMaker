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

/// One piece of a mold: a half, or a quarter of a four-piece mold.
public struct MoldPiece: Sendable {
    public var id: FeatureID
    public var name: String
    public var body: KBody
    /// −1 behind the parting plane, +1 in front of it (along its normal).
    public var side: Int
    /// −1 behind the second plane of a four-piece mold, +1 in front of it; 0 in a two-piece mold.
    public var crossSide: Int
}

/// What a mold build came to.
public struct MoldResult: Sendable {
    public var setup: MoldSetup
    /// The pieces, in the order of `MoldSetup.pieceIDs`: behind the parting plane first, each behind the second plane first. Empty when
    /// the build failed.
    public var pieces: [MoldPiece] = []
    /// Why it could not be built, in words for the user; nil when it was.
    public var error: String?
    /// Things worth knowing about a mold that was built (keys made smaller, plane moved a hair, a gate that misses).
    public var warnings: [String] = []
    /// The parting plane as built: a point on it and its normal.
    public var partingPoint = SIMD3<Double>.zero
    public var partingNormal = SIMD3<Double>(0, 0, 1)
    /// The second plane of a four-piece mold (square to X, Y or Z, through the middle of the body); nil in a two-piece one.
    public var crossPoint: SIMD3<Double>?
    public var crossNormal: SIMD3<Double>?
    /// Where the gate goes in at the body (its axis runs up from here), and where each vent starts.
    public var gatePoint: SIMD3<Double>?
    public var ventPoints: [SIMD3<Double>] = []
    /// The block's size (mm), the body's volume and what the cavity holds: body, gate and vents (mm³). The silicone to mix.
    public var blockSize = SIMD3<Double>.zero
    public var bodyVolume = 0.0
    public var cavityVolume = 0.0
    public var seconds = 0.0
    /// The gate's and the vents' diameters (mm), for placing vents later.
    public var gateDiameter = 0.0
    public var ventDiameter = 0.0
    /// Which faces of the body the halves can let go of (nil when the body could not be read). Kept when the build is refused for an
    /// undercut, so the Check view can still show where it is.
    public var analysis: MoldAnalysis?

    public init(setup: MoldSetup, error: String? = nil) { self.setup = setup; self.error = error }

    public var isBuilt: Bool { error == nil && !pieces.isEmpty }

    /// The two halves of a two-piece mold (nil for a four-piece one, which has no halves).
    public var behind: KBody? { pieces.count == 2 ? pieces[0].body : nil }
    public var front: KBody? { pieces.count == 2 ? pieces[1].body : nil }

    /// The pieces with their ids and names, behind the parting plane first.
    public var halves: [BodyResult] { pieces.map { BodyResult(id: $0.id, name: $0.name, body: $0.body) } }

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

    /// What a side of a plane square to `axis` is called: "left", "bottom" and so on (the first is the side behind the plane).
    static func sideNames(axis: MoldAxis) -> (behind: String, front: String) {
        switch axis {
        case .x: ("left", "right")
        case .y: ("front", "back")
        case .z: ("bottom", "top")
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
            result.error = e.message; result.pieces = []
        } catch {
            result.error = "The mold could not be built: \(error)"; result.pieces = []
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
        out.gateDiameter = gateDiameter
        out.ventDiameter = ventDiameter

        // The body's mesh: where the gate goes in, and which faces the pieces can release.
        let diagonal = simd_length(ext)
        let mesh = try? part.tessellate(linearDeflection: max(0.05, diagonal * 0.002))

        // A four-piece mold cuts each half again across a second plane, square to the first, through the middle of the body.
        let partingAxis = MoldResult.axis(of: normal)
        let four = setup.pieces == 4
        var cross: (axis: MoldAxis, normal: SIMD3<Double>, coordinate: Double)?
        if four {
            let axis = crossAxis(setup, partingAxis: partingAxis, mesh: mesh, point: point, normal: normal, centre: centre, ext: ext)
            cross = (axis, axis.vector, centre[axis.index])
            out.crossPoint = centre; out.crossNormal = axis.vector
        }
        if let mesh {
            let analysis = MoldAnalysis.analyse(mesh, partingPoint: point, normal: normal, cross: cross.map { (centre, $0.normal) })
            out.analysis = analysis
            let pct = String(format: "%.0f%%", analysis.undercutShare * 100)
            if analysis.hasUndercuts {
                let faces = "\(analysis.undercutFaces.count) face\(analysis.undercutFaces.count == 1 ? "" : "s") (\(pct) of the surface)"
                switch setup.casting {
                case .resin:
                    throw MoldError(message: "\(faces) of the body can not be released across this parting plane: a rigid cast would be stuck in the mold. Part it another way (X, Y, Z or another plane)\(four ? "" : ", split the mold into four pieces,") or turn the body so that nothing hangs back against the pull. The Check view shows where.")
                case .silicone:
                    out.warnings.append("\(faces) lean back against the pull (undercuts). Silicone can be peeled out of a mild one, but a deep one will tear it: the Check view shows where, and another parting plane\(four ? "" : " or four pieces") may avoid it.")
                }
            }
            if setup.casting == .resin, analysis.noDraftShare > 0.25 {
                out.warnings.append("\(String(format: "%.0f%%", analysis.noDraftShare * 100)) of the surface is parallel to the pull, with no draft: a rigid cast sticks. Lean those faces 1° to 2° with Draft.")
            }
        }

        // Pour direction and the block.
        let up = setup.up.vector
        let size = ext + SIMD3(repeating: 2 * wall)
        out.blockSize = size
        let blockLow = bounds.min - SIMD3(repeating: wall)
        let blockHigh = bounds.max + SIMD3(repeating: wall)
        let block = try makeBlock(centre: centre, size: size)

        // Where the gate goes in: the body's highest point along "up", or the point the setup names.
        // A gate beside a vertical parting plane lies on the plane, so the split makes two half-channels.
        let upAxis = setup.up.axis
        let onPlane = upAxis != MoldResult.axis(of: normal)
        // The point has to lie on material: the average of the highest vertices is in the hole of a top face that has one (the SimplCAD
        // logo's), and a gate there pours into the hole and never reaches the cavity.
        let spot = gateSpot(of: part, mesh: mesh, along: up, bounds: bounds, ext: ext, radius: gateDiameter / 2,
                            plane: onPlane ? (axisIndex, planeCoordinate) : nil)
        // A hand-placed gate stays where it was clicked, at the height of the surface there (as a vent does): its channel starts a
        // millimetre under that surface. Lifting it to the body's highest point made it start in the air wherever the body is lower.
        var gate = setup.gatePoint?.vector ?? spot.point
        // The highest point of a round body is often where its own axis runs out (the pole of a sphere), and a gate exactly on that axis
        // makes the kernel's subtraction drop the cavity without saying so (a sphere at (13.7, -8.2) did). A hundredth of a millimetre to
        // the side is the same gate to the eye and to the printer, and the kernel copes.
        if setup.gatePoint == nil {
            for (axis, shift) in zip(MoldAxis.allCases.filter { $0 != upAxis }, [0.0137, 0.0071]) where !(upAxis != MoldResult.axis(of: normal) && axis.index == axisIndex) {
                gate[axis.index] += shift
            }
        }
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

        // Does the gate meet the body? It starts just under the highest point, so it does, unless the point was placed by hand or the
        // top is narrower than the gate (a ring around a hole): then it is measured how much of its mouth is in the body. A gate that
        // only touches the wall of a hole, or hangs over an edge, lets nothing into the cavity.
        let mouth = Double.pi * (gateDiameter / 2) * (gateDiameter / 2) * gateDepth
        var gateEngaged: Double?
        if setup.gatePoint != nil || (spot.margin ?? .infinity) < gateDiameter / 2 {
            let probe = try channel(gate, diameter: gateDiameter, id: "check")
            if let reach = try? part.distance(.body, to: probe, .body), reach.distance > 1e-3 {
                out.warnings.append("The gate does not reach the body (\(String(format: "%.1f", reach.distance)) mm away).")
            } else {
                let engaged = (try? probe.boolean(part, SK_COMMON))?.volume ?? 0
                gateEngaged = engaged
                if engaged < mouth * 0.25 {
                    out.warnings.append("The gate sits over a hole or an edge of the body, so almost none of it meets the body and the cavity may not fill. Move it onto solid material.")
                }
            }
        }

        // The keys: cones in the four corners of the ring around the body, on a parting plane; the last one is bigger so the pieces
        // only go together one way. They have to fit inside the ring: the key is made smaller if the wall is thin.
        var keyRadius = keyDiameter / 2
        let fits = (wall / 2 - clearance - 0.8) / bigKeyShare
        if setup.keys, keyRadius > fits {
            keyRadius = max(fits, 0.5)
            out.warnings.append("The keys are made smaller (\(String(format: "%.1f", keyRadius * 2)) mm) to fit the wall: a thicker wall takes bigger ones.")
        }
        /// One key: where it stands on its plane, its peg (on the piece in front of the plane) and its socket (in the one behind).
        struct Key { var spot: SIMD3<Double>; var peg: KBody; var socket: KBody }
        /// The keys of a plane square to `n` (through the axis' coordinate `at`), shifted by `shift` like the plane itself.
        func keys(on n: SIMD3<Double>, at: Double, shift: Double, tag: String) throws -> [Key] {
            guard setup.keys, keyRadius > 0 else { return [] }
            let index = MoldResult.axis(of: n).index
            let others = MoldAxis.allCases.filter { $0.index != index }
            let (ua, wa) = (others[0].vector, others[1].vector)
            let ru = (size[others[0].index] - wall) / 2, rw = (size[others[1].index] - wall) / 2
            var spots = [centre + ua * ru + wa * rw, centre - ua * ru + wa * rw, centre + ua * ru - wa * rw, centre - ua * ru - wa * rw]
            for i in spots.indices { spots[i][index] = at }
            var made: [Key] = []
            for (i, s) in spots.enumerated() {
                // A key that would sit in a channel is left out.
                let inPlane = { (q: SIMD3<Double>) in simd_length((q - s) * (SIMD3<Double>(1, 1, 1) - abs(n))) }
                let radius = keyRadius * (i == 3 ? bigKeyShare : 1)
                if axes.contains(where: { inPlane($0.point) < $0.radius + radius + clearance + 0.5 }) { continue }
                let peg = try cone(base: s + n * shift, dir: -n, r0: radius, r1: radius * keyTipShare, h: radius * keyHeightShare, id: "peg\(tag)\(i)")
                let socket = try cone(base: s + n * (shift + 0.01), dir: -n, r0: radius + clearance, r1: radius * keyTipShare + clearance,
                                      h: radius * keyHeightShare + clearance, id: "socket\(tag)\(i)")
                made.append(Key(spot: s, peg: peg, socket: socket))
            }
            return made
        }

        // How much the body's subtraction has to take out of the pieces, at least. The kernel sometimes answers a subtraction with a
        // valid solid that has no cavity in it (found with a sphere at (13.7, -8.2): one half came back whole, no error), so what was
        // taken out is measured. The channels were cut first, so the part of the body they already took is not taken again: for the gate
        // at the highest point that is a thin cap, otherwise it is measured.
        let overlap: Double
        if setup.gatePoint == nil, setup.vents.isEmpty, (spot.margin ?? .infinity) >= gateDiameter / 2 {
            overlap = Double.pi * (gateDiameter / 2) * (gateDiameter / 2) * gateDepth * 1.5
        } else if setup.gatePoint == nil, setup.vents.isEmpty, let gateEngaged {
            overlap = gateEngaged * 1.5
        } else {
            overlap = (try? channels.boolean(part, SK_COMMON))?.volume ?? channels.volume
        }
        let minimumRemoved = max(part.volume - overlap - part.volume * 0.002, part.volume * 0.5)

        /// What `attempt` made: the pieces, and the volume the keys added to some and took from others.
        typealias Built = (pieces: [KBody], pegs: Double, sockets: Double)

        /// The block (or the block with the cavity) cut in two at the parting plane `p`, and in four when the mold has a second plane
        /// (each half cut at `p2`). Nil when the kernel did not give pieces.
        func split(_ body: KBody, at p: SIMD3<Double>, andAt p2: SIMD3<Double>?) throws -> [KBody]? {
            let halves = try body.split(planeThrough: p, normal: normal, featureID: "mold")
            guard halves.count == 2 else { return nil }
            guard let cross, let p2 else { return halves }
            var quarters: [KBody] = []
            for half in halves {
                let pair = try half.split(planeThrough: p2, normal: cross.normal, featureID: "mold")
                guard pair.count == 2 else { return nil }
                quarters += pair
            }
            return quarters
        }

        // One try at the split, keys and the body cut out. The usual order cuts the body out of the pieces last (cheap on a heavy
        // body); `partFirst` cuts it out of the block before the split instead.
        func attempt(shift: Double, partFirst: Bool) throws -> Built? {
            let p = point + normal * shift
            let p2 = cross.map { centre + $0.normal * shift }
            let drilled = channels.isEmpty ? block : try block.boolean(channels, SK_CUT)
            var pieces: [KBody]
            if partFirst {
                let cavity = try drilled.boolean(part, SK_CUT)
                guard drilled.volume - cavity.volume >= minimumRemoved else { return nil }
                guard let cut = try split(cavity, at: p, andAt: p2),
                      abs(cut.reduce(0) { $0 + $1.volume } - cavity.volume) < cavity.volume * 0.002 else { return nil }
                pieces = cut
            } else {
                guard let cut = try split(drilled, at: p, andAt: p2) else { return nil }
                pieces = cut
            }
            // Which side of each plane a piece is on: the order the split gave them (behind first), as in `MoldSetup.pieceIDs`.
            func sides(_ i: Int) -> (side: Int, crossSide: Int) { four ? (i < 2 ? -1 : 1, i % 2 == 0 ? -1 : 1) : (i == 0 ? -1 : 1, 0) }

            var pegVolume = 0.0, socketVolume = 0.0
            // A plane's keys: pegs on the pieces in front of it, sockets in those behind. Each piece gets only the keys that lie in its own
            // part of the plane (`lies`), so a peg never joins two pieces.
            func fit(_ list: [Key], piece: Int, pegs onPegSide: Bool, lies: (Key) -> Bool) throws {
                let mine = list.filter(lies)
                guard !mine.isEmpty else { return }
                if onPegSide {
                    var pegs = mine[0].peg
                    for k in mine.dropFirst() { pegs = try pegs.boolean(k.peg, SK_FUSE) }
                    pieces[piece] = try pieces[piece].boolean(pegs, SK_FUSE)
                } else {
                    var sockets = mine[0].socket
                    for k in mine.dropFirst() { sockets = try sockets.boolean(k.socket, SK_FUSE) }
                    pieces[piece] = try pieces[piece].boolean(sockets, SK_CUT)
                }
            }
            let partingKeys = try keys(on: normal, at: p[axisIndex], shift: 0, tag: "")
            for k in partingKeys { pegVolume += k.peg.volume; socketVolume += k.socket.volume }
            for i in pieces.indices {
                let mine = sides(i)
                try fit(partingKeys, piece: i, pegs: mine.side > 0) { k in
                    guard let cross else { return true }
                    return (k.spot[cross.axis.index] > cross.coordinate ? 1 : -1) == mine.crossSide
                }
            }
            if let cross {
                // The second plane's keys, each on its own side of the first plane.
                let crossKeys = try keys(on: cross.normal, at: cross.coordinate + shift, shift: 0, tag: "c")
                for k in crossKeys { pegVolume += k.peg.volume; socketVolume += k.socket.volume }
                for i in pieces.indices {
                    let mine = sides(i)
                    try fit(crossKeys, piece: i, pegs: mine.crossSide > 0) { k in (k.spot[axisIndex] > p[axisIndex] ? 1 : -1) == mine.side }
                }
            }
            if !partFirst {
                let before = pieces.reduce(0) { $0 + $1.volume }
                for i in pieces.indices { pieces[i] = try pieces[i].boolean(part, SK_CUT) }
                guard before - pieces.reduce(0, { $0 + $1.volume }) >= minimumRemoved else { return nil }
            }
            guard pieces.allSatisfy({ $0.isValid && !$0.isEmpty }) else { return nil }
            return (pieces, pegVolume, socketVolume)
        }

        // The usual order first, then the other one, each at the plane and then nudged (a plane exactly through a seam or a pole of a
        // round face is what upsets the kernel).
        var built: Built?
        var used = 0.0
        search: for shift in [0.0] + nudges {
            for partFirst in [false, true] {
                if let b = try attempt(shift: shift, partFirst: partFirst) { built = b; used = shift; break search }
            }
        }
        guard let built else {
            throw MoldError(message: "The pieces could not be made at this parting plane. Move the plane a little, or pick another.")
        }
        if used != 0 { out.warnings.append("The parting plane was moved \(String(format: "%.2f", abs(used))) mm: exactly there it gave a broken split.") }

        // Names and ids: "Mold bottom half", or "Mold bottom left" in a four-piece mold.
        let ids = setup.pieceIDs
        let names = sideNames(axis: partingAxis)
        out.pieces = built.pieces.enumerated().map { i, body in
            if let cross {
                let across = sideNames(axis: cross.axis)
                let (a, b) = (i < 2 ? names.behind : names.front, i % 2 == 0 ? across.behind : across.front)
                return MoldPiece(id: ids[i], name: "\(setup.name) \(a) \(b)", body: body, side: i < 2 ? -1 : 1, crossSide: i % 2 == 0 ? -1 : 1)
            }
            return MoldPiece(id: ids[i], name: "\(setup.name) \(i == 0 ? halfNames(axis: partingAxis).behind : halfNames(axis: partingAxis).front)",
                             body: body, side: i == 0 ? -1 : 1, crossSide: 0)
        }
        out.partingPoint = point + normal * used
        if cross != nil { out.crossPoint = centre + (cross?.normal ?? .zero) * used }
        // What the cavity holds is what is missing from the block: its volume, less the pieces, plus what the keys added to some and took from others.
        out.cavityVolume = block.volume - built.pieces.reduce(0) { $0 + $1.volume } + built.pegs - built.sockets
    }

    /// The axis the second plane of a four-piece mold is square to. One the setup names (if it is not the parting plane's own). Else a
    /// plane that contains the pour direction, so the gate and the vents are cut lengthways; when both of the others do (the mold is parted
    /// across the pour direction), the one that leaves the least undercut, and among equals the longer side, so the pieces are the smaller.
    static func crossAxis(_ setup: MoldSetup, partingAxis: MoldAxis, mesh: Mesh?, point: SIMD3<Double>, normal: SIMD3<Double>,
                          centre: SIMD3<Double>, ext: SIMD3<Double>) -> MoldAxis {
        let candidates = MoldAxis.allCases.filter { $0 != partingAxis }
        if let named = setup.cross, candidates.contains(named) { return named }
        let aroundUp = candidates.filter { $0 != setup.up.axis }
        if aroundUp.count == 1 { return aroundUp[0] }
        let longer = candidates.max { ext[$0.index] < ext[$1.index] } ?? candidates[0]
        guard let mesh else { return longer }
        let scored = candidates.map { ($0, MoldAnalysis.analyse(mesh, partingPoint: point, normal: normal, cross: (centre, $0.vector))) }
        let total = scored.map(\.1.totalArea).max() ?? 0
        let least = scored.map(\.1.undercutArea).min() ?? 0
        let good = scored.filter { $0.1.undercutArea <= least + 0.005 * total }.map(\.0)
        return good.contains(longer) ? longer : (good.first ?? longer)
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
    static func highestPoint(of part: KBody, mesh: Mesh?, along up: SIMD3<Double>, bounds: (min: SIMD3<Double>, max: SIMD3<Double>), ext: SIMD3<Double>) -> SIMD3<Double> {
        let diagonal = simd_length(ext)
        let fallback = (bounds.min + bounds.max) / 2 + up * (simd_dot(ext, abs(up)) / 2)
        guard let mesh, !mesh.positions.isEmpty else { return fallback }
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

    /// Where the gate goes in: the middle of the body's highest surface, moved to where there is material when that middle is not on any
    /// (a top face with a hole, a ring). `margin` is how far the point is from the nearest edge of that top surface, so a gate of
    /// `radius` or less sits wholly on material; nil when the top is not flat enough to tell (a dome: its highest point is solid).
    /// `plane` keeps the point on a vertical parting plane (axis index, coordinate), where the gate is cut into two half-channels.
    static func gateSpot(of part: KBody, mesh: Mesh?, along up: SIMD3<Double>, bounds: (min: SIMD3<Double>, max: SIMD3<Double>),
                         ext: SIMD3<Double>, radius: Double, plane: (index: Int, coordinate: Double)?) -> (point: SIMD3<Double>, margin: Double?) {
        var base = highestPoint(of: part, mesh: mesh, along: up, bounds: bounds, ext: ext)
        if let plane { base[plane.index] = plane.coordinate }
        guard let mesh, mesh.indices.count >= 3, !mesh.positions.isEmpty else { return (base, nil) }
        let pos = mesh.positions
        func vertex(_ i: UInt32) -> SIMD3<Double> { let k = Int(i) * 3; return SIMD3(Double(pos[k]), Double(pos[k + 1]), Double(pos[k + 2])) }
        var best = -Double.infinity
        for i in stride(from: 0, to: pos.count - 2, by: 3) { best = max(best, simd_dot(SIMD3(Double(pos[i]), Double(pos[i + 1]), Double(pos[i + 2])), up)) }
        let tolerance = max(1e-3, simd_length(ext) * 1e-4)

        // The triangles of the highest, flat surface.
        var top: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] = []
        for t in stride(from: 0, to: mesh.indices.count - 2, by: 3) {
            let (a, b, c) = (vertex(mesh.indices[t]), vertex(mesh.indices[t + 1]), vertex(mesh.indices[t + 2]))
            if min(simd_dot(a, up), simd_dot(b, up), simd_dot(c, up)) >= best - tolerance { top.append((a, b, c)) }
        }
        guard !top.isEmpty else { return (base, nil) }

        // Everything in 2D across `up`. An edge that only one top triangle has is the surface's edge (a hole's rim counts).
        let ua = perpendicular(to: up), wa = simd_cross(up, ua)
        func flat(_ v: SIMD3<Double>) -> SIMD2<Double> { SIMD2(simd_dot(v, ua), simd_dot(v, wa)) }
        struct Corner: Hashable { var x, y, z: Int }
        func corner(_ v: SIMD3<Double>) -> Corner { Corner(x: Int((v.x * 1000).rounded()), y: Int((v.y * 1000).rounded()), z: Int((v.z * 1000).rounded())) }
        struct EdgeKey: Hashable { var a, b: Corner }
        var counts: [EdgeKey: (n: Int, p: SIMD2<Double>, q: SIMD2<Double>)] = [:]
        for (a, b, c) in top {
            for (u, v) in [(a, b), (b, c), (c, a)] {
                let (cu, cv) = (corner(u), corner(v))
                let key = (cu.x, cu.y, cu.z) < (cv.x, cv.y, cv.z) ? EdgeKey(a: cu, b: cv) : EdgeKey(a: cv, b: cu)
                counts[key] = ((counts[key]?.n ?? 0) + 1, flat(u), flat(v))
            }
        }
        let rim = counts.values.filter { $0.n == 1 }.map { ($0.p, $0.q) }
        guard !rim.isEmpty else { return (base, nil) }

        func distance(_ p: SIMD2<Double>, _ s: (SIMD2<Double>, SIMD2<Double>)) -> Double {
            let d = s.1 - s.0, l2 = simd_dot(d, d)
            let t = l2 > 0 ? max(0, min(1, simd_dot(p - s.0, d) / l2)) : 0
            return simd_length(p - (s.0 + d * t))
        }
        func inside(_ p: SIMD2<Double>) -> Bool {
            for (a, b, c) in top {
                let (pa, pb, pc) = (flat(a), flat(b), flat(c))
                func side(_ u: SIMD2<Double>, _ v: SIMD2<Double>) -> Double { (v.x - u.x) * (p.y - u.y) - (v.y - u.y) * (p.x - u.x) }
                let (s1, s2, s3) = (side(pa, pb), side(pb, pc), side(pc, pa))
                let eps = 1e-9
                if (s1 >= -eps && s2 >= -eps && s3 >= -eps) || (s1 <= eps && s2 <= eps && s3 <= eps) { return true }
            }
            return false
        }
        /// Distance to the surface's edge for a point on it; −1 for a point that is not (the middle of a hole).
        func margin(_ v: SIMD3<Double>) -> Double {
            let p = flat(v)
            guard inside(p) else { return -1 }
            return rim.reduce(Double.infinity) { min($0, distance(p, $1)) }
        }

        let middle = margin(base)
        if middle >= radius { return (base, middle) }

        // Candidates on the surface: the middle of its triangles, or along the parting plane where the plane crosses them. A step
        // through the triangles keeps this cheap on a body with a lot of them.
        var candidates: [SIMD3<Double>] = []
        let step = max(1, top.count / 300)
        for (i, tri) in top.enumerated() where i % step == 0 {
            let (a, b, c) = tri
            guard let plane else { candidates.append((a + b + c) / 3); continue }
            var ends: [SIMD3<Double>] = []
            for (u, v) in [(a, b), (b, c), (c, a)] {
                let (du, dv) = (u[plane.index] - plane.coordinate, v[plane.index] - plane.coordinate)
                if (du < 0) != (dv < 0), du != dv { ends.append(u + (v - u) * (du / (du - dv))) }
            }
            if ends.count >= 2 { for s in [0.25, 0.5, 0.75] { candidates.append(ends[0] + (ends[1] - ends[0]) * s) } }
        }
        var bestPoint = base, bestMargin = middle
        for var v in candidates {
            v += up * (best - simd_dot(v, up))
            let m = margin(v)
            if m > bestMargin { bestPoint = v; bestMargin = m }
        }
        if let plane { bestPoint[plane.index] = plane.coordinate }
        return (bestPoint, max(0, bestMargin))
    }

    // MARK: laying the halves out for printing

    /// The pieces as they are printed: each with its parting face up and its back on the floor (z = 0), side by side along X with a gap.
    /// The cavity opens upwards, so it is printed without support and the seam faces are the best surface.
    public static func printLayout(_ result: MoldResult, gap: Double = 10) -> [BodyResult] {
        guard result.isBuilt else { return [] }
        let n = result.partingNormal
        var placed: [BodyResult] = []
        var cursor = 0.0
        for piece in result.pieces {  // each piece's parting face looks towards the other side of the plane
            guard var body = try? turned(piece.body, from: n * Double(-piece.side), to: SIMD3(0, 0, 1)), let b = body.bounds else { continue }
            guard let moved = try? body.translated(SIMD3(cursor - b.min.x, -b.min.y, -b.min.z)) else { continue }
            body = moved
            placed.append(BodyResult(id: piece.id, name: piece.name, body: body))
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
