// Replays a document's timeline through the kernel. This is what makes SimplCAD parametric:
// change any parameter or feature, call regenerate, and every downstream feature is rebuilt.
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CKernel
import Foundation
import simd

public struct SketchResult: Sendable {
    public var frame: Frame
    /// The sketch after solving (point positions satisfy constraints and dimensions).
    public var solved: Sketch
    public var solve: SolveResult
    public var regions: [KSketch.Region]
    /// Triangulated regions (same order as `regions`) for display and profile picking.
    public var regionMeshes: [Mesh]
    let kernelSketch: KSketch
}

extension SketchResult {
    /// World-space box around the sketch's profiles (or its points, when it has none).
    public var bounds: (min: SIMD3<Double>, max: SIMD3<Double>)? {
        var points: [SIMD3<Double>] = regionMeshes.flatMap { m in
            stride(from: 0, to: m.positions.count, by: 3).map {
                SIMD3(Double(m.positions[$0]), Double(m.positions[$0 + 1]), Double(m.positions[$0 + 2]))
            }
        }
        if points.isEmpty { points = solved.points.filter { $0.id != "origin" }.map { frame.point($0.x, $0.y) } }
        guard let first = points.first else { return nil }
        return points.dropFirst().reduce((first, first)) { (simd_min($0.0, $1), simd_max($0.1, $1)) }
    }
}

public struct BodyResult: Sendable, Identifiable {
    /// Id of the feature that created the body (stable across regenerations).
    public var id: FeatureID
    public var name: String
    public var body: KBody
}

public struct RegenResult: Sendable {
    public var parameters: ParameterValues = ParameterValues()
    public var sketches: [FeatureID: SketchResult] = [:]
    /// Bodies in creation order.
    public var bodies: [BodyResult] = []
    /// Per-feature errors; a failed feature is skipped and later features keep going.
    public var errors: [FeatureID: String] = [:]
    /// For fillets/chamfers: the bodies as they were just before the feature (keyed by body id),
    /// so drag handles can sit on edges that the feature itself rounds away.
    public var edgeFeatureInputs: [FeatureID: [FeatureID: KBody]] = [:]
    /// For face extrudes and holes: the body as it was before, so the handle can sit on the original
    /// face (and a hole finds that face's centre); for moves, rotates and patterns: the bodies they take.
    public var featureInputs: [FeatureID: [FeatureID: KBody]] = [:]
    /// For moves: the sketches as they were before, so the handle can sit where they were.
    public var sketchInputs: [FeatureID: [FeatureID: SketchResult]] = [:]
    /// Names given to bodies (the rest are "Body1", "Body2"…).
    public var bodyNames: [FeatureID: String] = [:]
    /// Construction planes, by the id of their Plane feature.
    public var planes: [FeatureID: Frame] = [:]
    public var duration: TimeInterval = 0

    public func body(_ id: FeatureID) -> KBody? { bodies.first { $0.id == id }?.body }

    public init() {}
}

/// What a rebuild had after each feature, keyed by everything that led up to it, so the next
/// rebuild can pick up at the first feature that changed (dragging a size near the end of the
/// timeline then rebuilds only that feature and what follows).
public final class RegenCache: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [(key: Int, result: RegenResult)] = []
    public init() {}

    /// The snapshots that still hold: those whose keys match, from the start of the timeline.
    fileprivate func valid(for keys: [Int]) -> [(key: Int, result: RegenResult)] {
        lock.lock(); defer { lock.unlock() }
        var n = 0
        while n < keys.count, n < snapshots.count, snapshots[n].key == keys[n] { n += 1 }
        return Array(snapshots.prefix(n))
    }

    fileprivate func store(_ snapshots: [(key: Int, result: RegenResult)]) {
        lock.lock(); defer { lock.unlock() }
        self.snapshots = snapshots
    }
}

/// Bodies read from STEP files, so a rebuild (after any parameter change, say) doesn't read the
/// same file again. Kernel bodies never change once built, so sharing them is safe.
final class ImportCache: @unchecked Sendable {
    static let shared = ImportCache()
    private let lock = NSLock()
    private var bodies: [FeatureID: (data: Data, body: KBody)] = [:]

    func body(_ data: Data, featureID: FeatureID) throws -> KBody {
        lock.lock()
        if let hit = bodies[featureID], hit.data == data { lock.unlock(); return hit.body }
        lock.unlock()
        let body = try KBody.importSTEP(data, featureID: featureID)
        lock.lock(); defer { lock.unlock() }
        if bodies.count >= 16 { bodies.removeAll() }  // many imports (several open parts): start over
        bodies[featureID] = (data, body)
        return body
    }
}

public enum Regenerator {
    public static func regenerate(_ doc: CADDocument, cache: RegenCache? = nil) -> RegenResult {
        let start = Date()
        var r = RegenResult()
        r.parameters = ParameterEvaluator.evaluate(doc.parameters)
        r.bodyNames = doc.bodyNames

        // Each feature's key covers the parameters, body names and every feature up to it.
        let features = Array(doc.activeFeatures)
        var keys: [Int] = []
        var hasher = Hasher()
        hasher.combine(doc.parameters)
        hasher.combine(doc.bodyNames)
        var previous = hasher.finalize()
        for f in features {
            var h = Hasher()
            h.combine(previous)
            h.combine(f)
            previous = h.finalize()
            keys.append(previous)
        }
        // Pick up after the last feature that hasn't changed since the previous rebuild.
        var snapshots = cache?.valid(for: keys) ?? []
        if let last = snapshots.last { r = last.result }
        let first = snapshots.count

        for (index, feature) in features.enumerated() where index >= first {
            defer { if cache != nil { snapshots.append((keys[index], r)) } }
            guard !feature.suppressed else { continue }
            do {
                switch feature.kind {
                case .sketch(let f): r.sketches[feature.id] = try sketch(f, r)
                case .extrude(let f): try extrude(f, feature, &r)
                case .fillet(let f): try edgeFeature(f, feature, fillet: true, &r)
                case .chamfer(let f): try edgeFeature(f, feature, fillet: false, &r)
                case .revolve(let f): try revolve(f, feature, &r)
                case .sweep(let f): try sweep(f, feature, &r)
                case .loft(let f): try loft(f, feature, &r)
                case .rib(let f): try rib(f, feature, &r)
                case .hole(let f): try hole(f, feature, &r)
                case .primitive(let f): try primitive(f, feature, &r)
                case .pipe(let f): try pipe(f, feature, &r)
                case .move(let f): try move(f, feature, &r)
                case .rotate(let f): try rotate(f, feature, &r)
                case .combine(let f): try combine(f, feature, &r)
                case .plane(let f): r.planes[feature.id] = try plane(f, r)
                case .mirror(let f): try mirror(f, feature, &r)
                case .pattern(let f): try pattern(f, feature, &r)
                case .shell(let f): try shell(f, feature, &r)
                case .importBody(let f): try importBody(f, feature, &r)
                }
            } catch {
                r.errors[feature.id] = "\(error)"
            }
        }
        cache?.store(snapshots)
        r.duration = Date().timeIntervalSince(start)
        return r
    }

    // MARK: features

    public static func resolvePlane(_ plane: PlaneRef, _ r: RegenResult) throws -> Frame {
        switch plane {
        case .xy: return .xy
        case .xz: return .xz
        case .yz: return .yz
        case .face(let ref):
            guard let body = r.body(ref.body) else { throw KernelError(message: "the body this sketch is on is missing") }
            return try body.faceFrame(ref.face)
        case .plane(let id):
            guard let frame = r.planes[id] else { throw KernelError(message: "the construction plane failed or is missing") }
            return frame
        }
    }

    // MARK: construction planes, mirror, pattern, shell

    /// `v` turned by `angle` about the unit axis `k` (Rodrigues).
    static func turned(_ v: SIMD3<Double>, about k: SIMD3<Double>, by angle: Double) -> SIMD3<Double> {
        v * cos(angle) + simd_cross(k, v) * sin(angle) + k * simd_dot(k, v) * (1 - cos(angle))
    }

    public static func plane(_ f: PlaneFeature, _ r: RegenResult) throws -> Frame {
        let base = try resolvePlane(f.base, r)
        let angle = try r.parameters.value(of: f.angle, kind: .angle)
        let offset = try r.parameters.value(of: f.offset, kind: .length)
        let k = simd_normalize(f.axis == .horizontal ? base.xAxis : base.yAxis)
        let normal = simd_normalize(turned(base.normal, about: k, by: angle))
        let x = simd_normalize(turned(base.xAxis, about: k, by: angle))
        return Frame(origin: base.origin + offset * normal, normal: normal, xAxis: x)
    }

    /// A pattern's direction or axis: a point on it and its unit direction.
    public static func line(_ axis: PatternAxis, _ r: RegenResult) throws -> (origin: SIMD3<Double>, direction: SIMD3<Double>) {
        switch axis {
        case .x: return (.zero, SIMD3(1, 0, 0))
        case .y: return (.zero, SIMD3(0, 1, 0))
        case .z: return (.zero, SIMD3(0, 0, 1))
        case .edge(let e):
            guard let body = r.body(e.body) else { throw KernelError(message: "the body with the axis edge is missing") }
            let l = try body.edgeLine(e.edge)
            return (l.origin, simd_normalize(l.direction))
        }
    }

    /// Adds copies to their bodies (Join), or gathers them into one new body.
    static func place(_ copies: [(index: Int, copy: KBody)], _ operation: BodyOperation, _ feature: Feature,
                      _ r: inout RegenResult) throws {
        if operation == .newBody {
            guard var all = copies.first?.copy else { return }
            for c in copies.dropFirst() { all = try all.boolean(c.copy, SK_FUSE) }
            r.bodies.append(BodyResult(id: feature.id, name: r.bodyNames[feature.id] ?? "Body\(r.bodies.count + 1)", body: all))
        } else {
            for c in copies { r.bodies[c.index].body = try r.bodies[c.index].body.boolean(c.copy, SK_FUSE) }
        }
    }

    static func mirror(_ f: MirrorFeature, _ feature: Feature, _ r: inout RegenResult) throws {
        let frame = try resolvePlane(f.plane, r)
        let indices = try transformInputs(f.bodies, feature, &r)
        let copies = try indices.map { i in
            (i, try r.bodies[i].body.mirroredCopy(through: frame.origin, normal: frame.normal, prefix: "\(feature.id)."))
        }
        try place(copies, f.operation, feature, &r)
    }

    static func pattern(_ f: PatternFeature, _ feature: Feature, _ r: inout RegenResult) throws {
        let p = r.parameters
        let n = Int(try p.value(of: f.count, kind: .none).rounded())
        guard n >= 1, n <= 500 else { throw KernelError(message: "the number of copies must be between 1 and 500") }
        let axis = try line(f.axis, r)
        let indices = try transformInputs(f.bodies, feature, &r)
        var copies: [(Int, KBody)] = []
        if f.kind == .linear {
            let spacing = try p.value(of: f.spacing, kind: .length)
            for k in 1..<max(n, 1) {
                for i in indices {
                    copies.append((i, try r.bodies[i].body.translatedCopy(axis.direction * spacing * Double(k), prefix: "\(feature.id).\(k).")))
                }
            }
        } else {
            let total = try p.value(of: f.spacing, kind: .angle)
            // All the way round: n equal steps; less: the last copy lands at the end of the angle.
            let step = abs(abs(total) - 2 * .pi) < 1e-9 ? total / Double(n) : total / Double(max(n - 1, 1))
            for k in 1..<max(n, 1) {
                for i in indices {
                    copies.append((i, try r.bodies[i].body.rotatedCopy(about: axis.origin, axis: axis.direction, angle: step * Double(k),
                                                                        prefix: "\(feature.id).\(k).")))
                }
            }
        }
        try place(copies.map { (index: $0.0, copy: $0.1) }, f.operation, feature, &r)
    }

    static func shell(_ f: ShellFeature, _ feature: Feature, _ r: inout RegenResult) throws {
        guard let i = r.bodies.firstIndex(where: { $0.id == f.body }) else { throw KernelError(message: "the body to shell is missing") }
        r.featureInputs[feature.id, default: [:]][f.body] = r.bodies[i].body
        let thickness = try r.parameters.value(of: f.thickness, kind: .length)
        let faces = f.faces.filter { $0.body == f.body }.map(\.face)
        let before = r.bodies[i].body.volume
        let shelled = try r.bodies[i].body.shell(removing: faces, thickness: thickness, inside: f.inside, featureID: feature.id)
        // Walls too thick for the body can come back as the unchanged body instead of an error.
        let after = shelled.volume
        guard f.inside ? after < before - 1e-6 && after > 1e-6 : after > before + 1e-6 else {
            throw KernelError(message: "shell failed (is the wall thicker than the body allows?)")
        }
        r.bodies[i].body = shelled
    }

    /// Reads a STEP file's contents into a body, the way an Import feature does, and keeps it
    /// for the rebuild that follows (so a file can be checked before it's added).
    public static func importedBody(_ data: Data, featureID: FeatureID) throws -> KBody {
        try ImportCache.shared.body(data, featureID: featureID)
    }

    static func importBody(_ f: ImportFeature, _ feature: Feature, _ r: inout RegenResult) throws {
        let body = try importedBody(f.data, featureID: feature.id)
        r.bodies.append(BodyResult(id: feature.id, name: r.bodyNames[feature.id] ?? "Body\(r.bodies.count + 1)", body: body))
    }

    /// Where a sketch lies: its plane, with upright axes unless it's from before they were (see
    /// SketchFeature.uprightAxes).
    public static func sketchFrame(_ f: SketchFeature, _ r: RegenResult) throws -> Frame {
        let frame = try resolvePlane(f.plane, r)
        return f.plane.isFaceOrPlane && f.uprightAxes == true ? frame.upright : frame
    }

    static func sketch(_ f: SketchFeature, _ r: RegenResult) throws -> SketchResult {
        let frame = try sketchFrame(f, r)
        var values: [EntityID: Double] = [:]
        for d in f.sketch.dimensions {
            do { values[d.id] = try r.parameters.value(of: d.expression, kind: d.unitKind) }
            catch { throw KernelError(message: "dimension '\(d.expression)': \(error)") }
        }
        var solved = f.sketch
        let solve = SketchSolver.solveLocally(&solved, dimensionValues: values)  // a changed parameter moves only what it drives
        guard solve.status == .solved else {
            throw KernelError(message: "sketch cannot satisfy its constraints (residual \(solve.maxResidual))")
        }
        return try sketchResult(solved, solve: solve, frame: frame, parameters: r.parameters)
    }

    /// A solved sketch's profiles on a plane.
    static func sketchResult(_ solved: Sketch, solve: SolveResult, frame: Frame, parameters: ParameterValues) throws -> SketchResult {
        let ks = try KSketch(frame: frame)
        for c in solved.curves where !c.construction { try add(c, of: solved, to: ks) }
        // Text: every letter contour's pieces share a tag, so a letter is one profile.
        for t in solved.texts {
            for (n, contour) in t.contours(in: solved, parameters: parameters).enumerated() {
                let tag = "\(t.id)#\(n)"
                for seg in contour {
                    if seg.count == 2 { try ks.addLine(tag, seg[0], seg[1]) } else { try ks.addBezier(tag, seg) }
                }
            }
        }
        let regions = try ks.buildRegions()
        let meshes = regions.map { (try? ks.regionMesh($0.index)) ?? Mesh.empty }
        return SketchResult(frame: frame, solved: solved, solve: solve, regions: regions, regionMeshes: meshes,
                            kernelSketch: ks)
    }

    static func sketchResult(_ id: FeatureID, _ r: RegenResult) throws -> SketchResult {
        guard let sk = r.sketches[id] else { throw KernelError(message: "its sketch failed or is missing") }
        return sk
    }

    /// The region a profile reference points at: same bounding curves, nearest to its hint.
    /// The region a profile reference means, as the sketch is now. Sketch edits change the curves
    /// around a region all the time (rounding a corner adds an arc, trimming splits a line,
    /// redrawing gives new ids), so an exact match comes first, then the region that contains the
    /// point that was picked, then the one sharing most of its curves; nil if nothing is close.
    public static func region(_ ref: ProfileRef, in sk: SketchResult) -> KSketch.Region? {
        let hint = SIMD2(ref.hintU, ref.hintV)
        if let exact = sk.regions.filter({ $0.tags == ref.tagString }).min(by: { vlength($0.sample - hint) < vlength($1.sample - hint) }) {
            return exact
        }
        // Regions never overlap, so at most one contains the picked point.
        if let around = sk.regions.first(where: { sk.kernelSketch.regionContains($0.index, hint) }) { return around }
        let wanted = Set(ref.curves)
        func overlap(_ r: KSketch.Region) -> Double {
            let tags = Set(r.tags.split(separator: ",").map(String.init))
            let union = tags.union(wanted).count
            return union == 0 ? 0 : Double(tags.intersection(wanted).count) / Double(union)
        }
        guard let best = sk.regions.max(by: { overlap($0) < overlap($1) }), overlap(best) >= 1.0 / 3 else { return nil }
        return best
    }

    static func profiles(_ refs: [ProfileRef], in sk: SketchResult) throws -> [KProfile] {
        var used = Set<Int>()  // two old profiles can now be one region (the line between them was deleted)
        return try refs.compactMap { ref in
            guard let region = region(ref, in: sk) else {
                throw KernelError(message: "a profile it used no longer exists · double-click it in the timeline to pick again")
            }
            guard used.insert(region.index).inserted else { return nil }
            return try sk.kernelSketch.profile(region.index)
        }
    }

    /// A path through sketch curves (construction curves included), from the solved sketch.
    static func path(_ ref: CurveRef, _ r: RegenResult) throws -> (path: KPath, frame: Frame) {
        let sk = try sketchResult(ref.sketch, r)
        let ks = try KSketch(frame: sk.frame)
        for id in ref.curves {
            guard let c = sk.solved.curve(id) else { throw KernelError(message: "a path curve was deleted from its sketch") }
            try add(c, of: sk.solved, to: ks)
        }
        return (try ks.path(ref.curves), sk.frame)
    }

    static func add(_ c: SketchCurve, of solved: Sketch, to ks: KSketch) throws {
        switch c.geometry {
        case .line(let a, let b):
            guard let pa = solved.point(a), let pb = solved.point(b) else { return }
            try ks.addLine(c.id, pa.position, pb.position)
        case .circle(let center, let radius):
            guard let pc = solved.point(center) else { return }
            try ks.addCircle(c.id, center: pc.position, radius: radius)
        case .arc(let center, let s, let e):
            guard let pc = solved.point(center), let ps = solved.point(s), let pe = solved.point(e) else { return }
            let a0 = atan2(ps.y - pc.y, ps.x - pc.x), a1 = atan2(pe.y - pc.y, pe.x - pc.x)
            try ks.addArc(c.id, center: pc.position, radius: vlength(ps.position - pc.position), from: a0, to: a1)
        case .bezier:
            let poles = solved.pointIDs(of: c).compactMap { solved.point($0)?.position }
            guard poles.count == 4 else { return }
            try ks.addBezier(c.id, poles)
        }
    }

    /// Adds a feature's solid as a new body, or joins/cuts/intersects it with the target body.
    static func combine(_ tool: KBody, _ operation: BodyOperation, target: FeatureID?, _ feature: Feature,
                        _ r: inout RegenResult) throws {
        if operation == .newBody {
            r.bodies.append(BodyResult(id: feature.id, name: r.bodyNames[feature.id] ?? "Body\(r.bodies.count + 1)", body: tool))
            return
        }
        if operation == .cut, target == nil {
            // No body chosen: cut every body the tool passes through.
            guard !r.bodies.isEmpty else { throw KernelError(message: "no body to cut") }
            guard let tb = tool.bounds else { return }
            for i in r.bodies.indices {
                guard let b = r.bodies[i].body.bounds, overlaps(b, tb) else { continue }
                let cut = try r.bodies[i].body.boolean(tool, SK_CUT)
                if cut.volume <= 1e-9 { throw KernelError(message: "the cut removes all of \(r.bodies[i].name)") }
                r.bodies[i].body = cut
            }
            return
        }
        guard let index = target.flatMap({ t in r.bodies.firstIndex { $0.id == t } }) ?? (r.bodies.isEmpty ? nil : r.bodies.count - 1)
        else { throw KernelError(message: "no body to \(operation.rawValue.lowercased())") }
        let op: SKBooleanOp = operation == .join ? SK_FUSE : operation == .cut ? SK_CUT : SK_COMMON
        let combined = try r.bodies[index].body.boolean(tool, op)
        if operation != .join, combined.volume <= 1e-9 {
            throw KernelError(message: operation == .cut ? "the cut removes all of \(r.bodies[index].name)"
                                                         : "the new shape doesn't overlap \(r.bodies[index].name)")
        }
        r.bodies[index].body = combined
    }

    static func extrude(_ f: ExtrudeFeature, _ feature: Feature, _ r: inout RegenResult) throws {
        let profiles: [KProfile], normal: SIMD3<Double>, planeOrigin: SIMD3<Double>
        if let face = f.face {
            guard let body = r.body(face.body) else { throw KernelError(message: "the body with that face is missing") }
            r.featureInputs[feature.id] = [face.body: body]  // the face moves once extruded; its handle stays on the input
            profiles = [try body.faceProfile(face.face)]
            let frame = try body.faceFrame(face.face)
            normal = frame.normal; planeOrigin = frame.origin
        } else {
            let sk = try sketchResult(f.sketch, r)
            profiles = try Self.profiles(f.profiles, in: sk)
            normal = sk.frame.normal; planeOrigin = sk.frame.origin
        }

        let p = r.parameters
        let dir = f.flipped ? -normal : normal
        var distance: Double, back: Double
        switch f.extent {
        case .distance(let d): distance = try p.value(of: d, kind: .length); back = 0
        case .symmetric(let d): distance = try p.value(of: d, kind: .length) / 2; back = distance
        case .twoSides(let d, let b): distance = try p.value(of: d, kind: .length); back = try p.value(of: b, kind: .length)
        case .throughAll:
            // Past the farthest corner of any body, measured along the direction.
            let boxes = r.bodies.compactMap { $0.body.bounds }
            guard !boxes.isEmpty else { throw KernelError(message: "there's no body to go through") }
            var far = 0.0
            for b in boxes {
                for c in 0..<8 {
                    let corner = SIMD3(c & 1 == 0 ? b.min.x : b.max.x, c & 2 == 0 ? b.min.y : b.max.y, c & 4 == 0 ? b.min.z : b.max.z)
                    far = max(far, simd_dot(corner - planeOrigin, dir))
                }
            }
            guard far > 1e-4 else { throw KernelError(message: "every body is behind the sketch · flip the direction") }  // boxes carry a hair of tolerance
            distance = far + 1; back = 0
        case .toFace(let ref):
            guard let body = r.body(ref.body) else { throw KernelError(message: "the body with the face to extrude to is missing") }
            let face: Frame
            do { face = try body.faceFrame(ref.face) } catch { throw KernelError(message: "the face to extrude to is gone or isn't flat") }
            guard abs(simd_dot(face.normal, normal)) > 0.9999 else {
                throw KernelError(message: "the face to extrude to isn't parallel to the sketch")
            }
            distance = simd_dot(face.origin - planeOrigin, dir); back = 0
            guard distance > 1e-9 else { throw KernelError(message: "the face is behind the sketch · flip the direction") }
        }
        let tool = try KBody.extrude(profiles, direction: dir, distance: distance, back: back, featureID: feature.id)
        try combine(tool, f.operation, target: f.target, feature, &r)
    }

    /// The revolve axis in world space.
    public static func axis(_ a: AxisRef, sketch sk: SketchResult) throws -> (origin: SIMD3<Double>, direction: SIMD3<Double>) {
        switch a {
        case .x: return (.zero, SIMD3(1, 0, 0))
        case .y: return (.zero, SIMD3(0, 1, 0))
        case .z: return (.zero, SIMD3(0, 0, 1))
        case .sketchX: return (sk.frame.origin, sk.frame.xAxis)
        case .sketchY: return (sk.frame.origin, sk.frame.yAxis)
        case .line(let id):
            guard let (a, b) = sk.solved.lineEnds(id) else { throw KernelError(message: "the axis line was deleted") }
            let pa = sk.frame.point(a.x, a.y), pb = sk.frame.point(b.x, b.y)
            let d = pb - pa, len = (d * d).sum().squareRoot()
            guard len > 1e-9 else { throw KernelError(message: "the axis line has no length") }
            return (pa, d / len)
        }
    }

    static func revolve(_ f: RevolveFeature, _ feature: Feature, _ r: inout RegenResult) throws {
        let sk = try sketchResult(f.sketch, r)
        let profiles = try profiles(f.profiles, in: sk)
        let ax = try axis(f.axis, sketch: sk)
        let angle = try r.parameters.value(of: f.angle, kind: .angle)
        let tool = try KBody.revolve(profiles, axisOrigin: ax.origin, axisDirection: ax.direction, angle: angle,
                                     featureID: feature.id)
        try combine(tool, f.operation, target: f.target, feature, &r)
    }

    static func sweep(_ f: SweepFeature, _ feature: Feature, _ r: inout RegenResult) throws {
        let sk = try sketchResult(f.sketch, r)
        let profiles = try profiles(f.profiles, in: sk)
        let tool = try KBody.sweep(profiles, along: try path(f.path, r).path, featureID: feature.id)
        try combine(tool, f.operation, target: f.target, feature, &r)
    }

    static func loft(_ f: LoftFeature, _ feature: Feature, _ r: inout RegenResult) throws {
        guard f.sections.count >= 2 else { throw KernelError(message: "a loft needs at least two profiles") }
        let profiles = try f.sections.map { s in try Self.profiles([s.profile], in: try sketchResult(s.sketch, r))[0] }
        let tool = try KBody.loft(profiles, ruled: f.ruled, featureID: feature.id)
        try combine(tool, f.operation, target: f.target, feature, &r)
    }

    static func targetIndex(_ target: FeatureID?, _ r: RegenResult) throws -> Int {
        guard let i = target.flatMap({ t in r.bodies.firstIndex { $0.id == t } }) ?? (r.bodies.isEmpty ? nil : r.bodies.count - 1)
        else { throw KernelError(message: "there is no body to add it to") }
        return i
    }

    static func rib(_ f: RibFeature, _ feature: Feature, _ r: inout RegenResult) throws {
        let i = try targetIndex(f.target, r)
        let thickness = try r.parameters.value(of: f.thickness, kind: .length)
        r.bodies[i].body = try r.bodies[i].body.rib(along: try path(f.path, r).path, thickness: thickness, featureID: feature.id)
    }

    /// Where a hole's top centre is: (u, v) in its face's frame, drilling against the face normal.
    public static func holeFrame(_ f: HoleFeature, _ r: RegenResult) throws -> Frame {
        guard let body = r.body(f.face.body) else { throw KernelError(message: "the body with the hole's face is missing") }
        let face = try body.faceFrame(f.face.face)
        let u = try r.parameters.value(of: f.u, kind: .length), v = try r.parameters.value(of: f.v, kind: .length)
        return Frame(origin: face.point(u, v), normal: face.normal, xAxis: face.xAxis)
    }

    static func hole(_ f: HoleFeature, _ feature: Feature, _ r: inout RegenResult) throws {
        guard let i = r.bodies.firstIndex(where: { $0.id == f.face.body }) else {
            throw KernelError(message: "the body with the hole's face is missing")
        }
        let p = r.parameters
        let frame = try holeFrame(f, r)
        let depth: Double
        if let d = f.depth {
            depth = try p.value(of: d, kind: .length)
        } else if let b = r.bodies[i].body.bounds {  // through all: longer than the body is wide
            let d = b.max - b.min
            depth = (d * d).sum().squareRoot() * 2 + 1
        } else {
            throw KernelError(message: "the body is empty")
        }
        let kind: KHole
        switch f.kind {
        case .simple: kind = .simple
        case .counterbore: kind = .counterbore(diameter: try p.value(of: f.headDiameter, kind: .length),
                                               depth: try p.value(of: f.headDepth, kind: .length))
        case .countersink: kind = .countersink(diameter: try p.value(of: f.headDiameter, kind: .length),
                                               angle: try p.value(of: f.headAngle, kind: .angle))
        }
        let tip = f.depth == nil ? 0 : try p.value(of: f.tipAngle, kind: .angle)
        let tool = try KBody.hole(at: frame, kind, diameter: try p.value(of: f.diameter, kind: .length), depth: depth,
                                  tipAngle: tip, featureID: feature.id)
        // The face as it was before the cut: its centre doesn't move with the hole (see the move dot).
        r.featureInputs[feature.id] = [f.face.body: r.bodies[i].body]
        r.bodies[i].body = try r.bodies[i].body.boolean(tool, SK_CUT)
    }

    /// The frame a primitive stands on: its plane, moved to (u, v).
    public static func primitiveFrame(_ f: PrimitiveFeature, _ r: RegenResult) throws -> Frame {
        let plane = try resolvePlane(f.plane, r)
        let u = try r.parameters.value(of: f.u, kind: .length), v = try r.parameters.value(of: f.v, kind: .length)
        return Frame(origin: plane.point(u, v), normal: plane.normal, xAxis: plane.xAxis)
    }

    static func primitive(_ f: PrimitiveFeature, _ feature: Feature, _ r: inout RegenResult) throws {
        let p = r.parameters
        func len(_ s: String) throws -> Double { try p.value(of: s, kind: .length) }
        let shape: KPrimitive
        switch f.kind {
        case .box: shape = .box(width: try len(f.width), length: try len(f.length), height: try len(f.height))
        case .cylinder: shape = .cylinder(diameter: try len(f.diameter), height: try len(f.height))
        case .sphere: shape = .sphere(diameter: try len(f.diameter))
        case .torus: shape = .torus(diameter: try len(f.diameter), tube: try len(f.tube))
        case .coil: shape = .coil(diameter: try len(f.diameter), section: try len(f.tube), pitch: try len(f.pitch),
                                  turns: try p.value(of: f.turns, kind: .none))
        }
        let tool = try KBody.primitive(shape, on: try primitiveFrame(f, r), featureID: feature.id)
        try combine(tool, f.operation, target: f.target, feature, &r)
    }

    public static func direction(_ a: Axis3) -> SIMD3<Double> {
        switch a {
        case .x: return SIMD3(1, 0, 0)
        case .y: return SIMD3(0, 1, 0)
        case .z: return SIMD3(0, 0, 1)
        }
    }

    /// The middle of the bounding box around several bodies.
    public static func center(of bodies: [KBody], sketches: [SketchResult] = []) -> SIMD3<Double>? {
        let boxes = bodies.compactMap(\.bounds) + sketches.compactMap(\.bounds)
        guard let first = boxes.first else { return nil }
        let lo = boxes.dropFirst().reduce(first.min) { simd_min($0, $1.min) }
        let hi = boxes.dropFirst().reduce(first.max) { simd_max($0, $1.max) }
        return (lo + hi) / 2
    }

    /// The bodies a move or rotate works on, recorded as they were before it (for its drag handle).
    static func transformInputs(_ ids: [FeatureID], _ feature: Feature, _ r: inout RegenResult) throws -> [Int] {
        let indices = try ids.map { id in
            guard let i = r.bodies.firstIndex(where: { $0.id == id }) else { throw KernelError(message: "a body it moves is missing") }
            return i
        }
        guard !indices.isEmpty else { throw KernelError(message: "no body to move") }
        for i in indices { r.featureInputs[feature.id, default: [:]][r.bodies[i].id] = r.bodies[i].body }
        return indices
    }

    static func move(_ f: MoveFeature, _ feature: Feature, _ r: inout RegenResult) throws {
        let p = r.parameters
        let d = SIMD3(try p.value(of: f.dx, kind: .length), try p.value(of: f.dy, kind: .length), try p.value(of: f.dz, kind: .length))
        for id in f.sketches {
            guard let sk = r.sketches[id] else { throw KernelError(message: "a sketch it moves failed or is missing") }
            r.sketchInputs[feature.id, default: [:]][id] = sk
            var frame = sk.frame
            frame.origin += d
            r.sketches[id] = try sketchResult(sk.solved, solve: sk.solve, frame: frame, parameters: p)
        }
        if f.bodies.isEmpty && !f.sketches.isEmpty { return }
        for i in try transformInputs(f.bodies, feature, &r) { r.bodies[i].body = try r.bodies[i].body.translated(d) }
    }

    static func combine(_ f: CombineFeature, _ feature: Feature, _ r: inout RegenResult) throws {
        guard let t = r.bodies.firstIndex(where: { $0.id == f.target }) else { throw KernelError(message: "the target body is missing") }
        let tools = f.tools.filter { $0 != f.target }
        guard !tools.isEmpty else { throw KernelError(message: "pick at least one body to combine with the target") }
        var body = r.bodies[t].body
        for id in tools {
            guard let tool = r.body(id) else { throw KernelError(message: "a tool body is missing") }
            body = try body.boolean(tool, f.operation == .cut ? SK_CUT : f.operation == .intersect ? SK_COMMON : SK_FUSE)
        }
        if f.operation != .join, body.volume <= 1e-9 {
            throw KernelError(message: f.operation == .cut ? "the cut removes the whole body" : "the bodies don't overlap")
        }
        r.bodies[t].body = body
        if !f.keepTools { r.bodies.removeAll { tools.contains($0.id) } }
    }

    static func rotate(_ f: RotateFeature, _ feature: Feature, _ r: inout RegenResult) throws {
        let angle = try r.parameters.value(of: f.angle, kind: .angle)
        let indices = try transformInputs(f.bodies, feature, &r)
        guard let c = center(of: indices.map { r.bodies[$0].body }) else { throw KernelError(message: "the body is empty") }
        for i in indices { r.bodies[i].body = try r.bodies[i].body.rotated(about: c, axis: direction(f.axis), angle: angle) }
    }

    static func pipe(_ f: PipeFeature, _ feature: Feature, _ r: inout RegenResult) throws {
        let p = r.parameters
        let wall = try f.wall.map { try p.value(of: $0, kind: .length) } ?? 0
        let tool = try KBody.pipe(along: try path(f.path, r).path, diameter: try p.value(of: f.diameter, kind: .length),
                                  wall: wall, featureID: feature.id)
        try combine(tool, f.operation, target: f.target, feature, &r)
    }

    static func edgeFeature(_ f: EdgeFeature, _ feature: Feature, fillet: Bool, _ r: inout RegenResult) throws {
        // Group edges per body, keeping order.
        var order: [FeatureID] = []
        var byBody: [FeatureID: [String]] = [:]
        func add(_ body: FeatureID, _ edge: String) {
            if byBody[body] == nil { order.append(body) }
            if byBody[body]?.contains(edge) != true { byBody[body, default: []].append(edge) }
        }
        for e in f.edges { add(e.body, e.edge) }
        // A face stands for every edge around it, as the face is now.
        for face in f.faces {
            guard let b = r.body(face.body) else { throw KernelError(message: "body is missing") }
            for edge in try b.faceEdges(face.face) { add(face.body, edge) }
        }
        // Record the inputs first, so the drag handle still shows when the size is invalid.
        for bodyID in order {
            if let b = r.body(bodyID) { r.edgeFeatureInputs[feature.id, default: [:]][bodyID] = b }
        }
        let size = try r.parameters.value(of: f.size, kind: .length)
        for bodyID in order {
            guard let i = r.bodies.firstIndex(where: { $0.id == bodyID }) else {
                throw KernelError(message: "body is missing")
            }
            let edges = byBody[bodyID]!
            let b = r.bodies[i].body
            r.bodies[i].body = try fillet
                ? b.fillet(edges: edges, radius: size, featureID: feature.id)
                : b.chamfer(edges: edges, distance: size, featureID: feature.id)
        }
    }
}

func overlaps(_ a: (min: SIMD3<Double>, max: SIMD3<Double>), _ b: (min: SIMD3<Double>, max: SIMD3<Double>)) -> Bool {
    let eps = 1e-6
    return a.min.x <= b.max.x + eps && b.min.x <= a.max.x + eps && a.min.y <= b.max.y + eps && b.min.y <= a.max.y + eps
        && a.min.z <= b.max.z + eps && b.min.z <= a.max.z + eps
}

@inline(__always) func vlength(_ v: SIMD2<Double>) -> Double { (v.x * v.x + v.y * v.y).squareRoot() }
