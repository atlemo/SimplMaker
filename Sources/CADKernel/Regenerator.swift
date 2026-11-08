// Replays a document's timeline through the kernel. This is what makes SimplMaker parametric:
// change any parameter or feature, call regenerate, and every downstream feature is rebuilt.
// Copyright © 2026 Atle Mo
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
    /// The text a region is made of: every curve round it (and in it) is a contour of that one text, whose tags are
    /// "<text id>#<contour>" (see Regenerator.sketchResult). Nil for a region that has other curves too.
    public func text(ofRegion index: Int) -> SketchText? {
        guard regions.indices.contains(index) else { return nil }
        var owner: Substring?
        for tag in regions[index].tags.split(separator: ",") {
            guard let hash = tag.firstIndex(of: "#") else { return nil }
            let id = tag[..<hash]
            if let owner, owner != id { return nil }
            owner = id
        }
        guard let owner else { return nil }
        return solved.texts.first { $0.id == owner }
    }

    /// The regions of a text that are its letters, as indexes into `regions`: the ink, without the counters (the
    /// inside of an O or a B is a region of its own, which a letter must not fill). A region is ink when an odd
    /// number of the text's contours enclose it.
    public func letterRegions(of text: SketchText, parameters: ParameterValues) -> [Int] {
        let contours = text.contours(in: solved, parameters: parameters).map { contour in
            contour.flatMap { TextOutline.flatten($0) }
        }
        func enclosing(_ p: SIMD2<Double>) -> Int {
            contours.filter { polygon in
                var inside = false
                var j = polygon.count - 1
                for i in polygon.indices {
                    let a = polygon[i], b = polygon[j]
                    if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
                    j = i
                }
                return inside
            }.count
        }
        return regions.indices.filter { text.id == self.text(ofRegion: $0)?.id && enclosing(regions[$0].sample) % 2 == 1 }
    }

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

/// Where a reference image lies: its middle and axes (x along the picture's top edge, y up it, both
/// already turned by the feature's angle) and its size, in mm.
public struct ImagePlacement: Sendable, Equatable {
    public var frame: Frame
    public var width: Double
    public var height: Double

    /// The corners in world space: top left, top right, bottom right, bottom left, as the picture reads.
    public var corners: [SIMD3<Double>] {
        let x = frame.xAxis * (width / 2), y = frame.yAxis * (height / 2)
        return [frame.origin - x + y, frame.origin + x + y, frame.origin + x - y, frame.origin - x - y]
    }
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
    /// Reference images, by the id of their Canvas feature.
    public var images: [FeatureID: ImagePlacement] = [:]
    /// For extrudes that start on a face: how far that plane lies from the sketch plane along the sketch's normal,
    /// so the handle can sit on it (the face itself may be gone once the extrude has joined it).
    public var extrudeStarts: [FeatureID: Double] = [:]
    /// For joins, cuts and intersects: the bodies the feature actually worked on (a cut skips bodies it doesn't reach),
    /// so the Inspector can show what an automatic choice came to.
    public var affectedBodies: [FeatureID: [FeatureID]] = [:]
    /// For projections: a point on the surface where the first profile landed and the way the surface faces
    /// there, for the height handle.
    public var projectionHandles: [FeatureID: (origin: SIMD3<Double>, normal: SIMD3<Double>)] = [:]
    public var duration: TimeInterval = 0
    /// How many threads a progressive rebuild left out (see `Regenerator.regenerate(progressiveThreads:)`); 0 for a full one.
    public var threadsLeftOut = 0
    /// The fillets built so far (feature name and radius), so a shell that fails can say which rounded
    /// edge its walls can't follow.
    public var rounds: [(feature: String, radius: Double)] = []

    public func body(_ id: FeatureID) -> KBody? { bodies.first { $0.id == id }?.body }

    public init() {}
}

/// What a rebuild had after each feature, keyed by everything that led up to it, so the next
/// rebuild can pick up at the first feature that changed (dragging a size near the end of the
/// timeline then rebuilds only that feature and what follows).
public final class RegenCache: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [(key: Int, result: RegenResult)] = []
    /// How long each thread feature took the last time it was built, in seconds.
    private var threadSeconds: [FeatureID: TimeInterval] = [:]
    public init() {}

    fileprivate func noteThread(_ id: FeatureID, seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        threadSeconds[id] = seconds
    }

    fileprivate func threadSeconds(of id: FeatureID) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return threadSeconds[id]
    }

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

/// Bodies read from STEP and STL files, so a rebuild (after any parameter change, say) doesn't read the
/// same file again. Kernel bodies never change once built, so sharing them is safe.
final class ImportCache: @unchecked Sendable {
    static let shared = ImportCache()
    private let lock = NSLock()
    private var bodies: [FeatureID: (data: Data, body: KBody)] = [:]

    func body(_ data: Data, featureID: FeatureID) throws -> KBody {
        lock.lock()
        if let hit = bodies[featureID], hit.data == data { lock.unlock(); return hit.body }
        lock.unlock()
        let body = try KBody.importModel(data, featureID: featureID)
        lock.lock(); defer { lock.unlock() }
        if bodies.count >= 16 { bodies.removeAll() }  // many imports (several open parts): start over
        bodies[featureID] = (data, body)
        return body
    }
}

public enum Regenerator {
    /// `progress` is told before each feature that has to be built (not those the cache still holds):
    /// how many are done, how many there are to build, and the one about to be.
    ///
    /// `draftAfter`: for a preview that is rebuilt over and over while a handle is dragged. The threads that come after
    /// that feature are left out (a thread is the slowest thing to build, a third of a second or more, and a drag
    /// only needs the shape); the rebuild that follows the drop puts them back. Their results are kept apart in the
    /// cache, so a full rebuild never picks up one without its thread.
    ///
    /// `progressiveThreads`: for a rebuild that will be followed by a full one. When the threads that have to be built
    /// (those from the first changed feature on) are expected to take at least this many seconds (the time they took
    /// last, or a second if they never have), they are left out, so the model can be shown at once and the threads put
    /// in by the full rebuild. `threadsLeftOut` on the result tells whether any were.
    public static func regenerate(_ doc: CADDocument, cache: RegenCache? = nil, draftAfter: FeatureID? = nil,
                                  progressiveThreads: TimeInterval? = nil,
                                  progress: (@Sendable (_ done: Int, _ total: Int, _ feature: Feature) -> Void)? = nil) -> RegenResult {
        let start = Date()
        var r = RegenResult()
        let parameters = ParameterEvaluator.evaluate(doc.parameters)
        r.parameters = parameters
        r.bodyNames = doc.bodyNames

        // Each feature's key covers the body names, every feature up to it, and the values of the parameters it
        // reads (so editing a parameter only rebuilds from the first feature that uses it).
        let features = Array(doc.activeFeatures)
        var hasher = Hasher()
        hasher.combine(doc.bodyNames)
        let base = hasher.finalize()
        var parameterWords: [String: Set<String>] = [:]
        for p in doc.parameters { parameterWords[p.name] = ParameterDependencies.words(in: p.expression) }
        let draftFrom = draftAfter.flatMap { id in features.firstIndex { $0.id == id } }
        var omitFrom: Int?
        func leftOut(_ index: Int, _ f: Feature) -> Bool {
            guard case .thread = f.kind else { return false }
            if let draftFrom, index > draftFrom { return true }
            if let omitFrom, index >= omitFrom { return true }
            return false
        }
        func makeKeys() -> [Int] {
            var keys: [Int] = []
            var previous = base
            for (index, f) in features.enumerated() {
                var own = Hasher()
                own.combine(f)
                let featureHash = own.finalize()
                var h = Hasher()
                h.combine(previous)
                h.combine(featureHash)
                if leftOut(index, f) { h.combine("draft") }
                if !parameterWords.isEmpty {
                    let words = ParameterDependencies.shared.words(of: f, hash: featureHash)
                    for name in ParameterDependencies.closure(of: words, inputs: parameterWords) {
                        h.combine(name)
                        if let q = r.parameters.values[name] {
                            h.combine(q.value.bitPattern); h.combine(q.length); h.combine(q.angle)
                        } else {
                            h.combine(r.parameters.errors[name] ?? "")
                        }
                    }
                }
                previous = h.finalize()
                keys.append(previous)
            }
            return keys
        }
        var keys = makeKeys()
        if let threshold = progressiveThreads, let cache {
            let changed = cache.valid(for: keys).count
            let expected = features.indices.filter { $0 >= changed && !features[$0].suppressed }.reduce(0.0) { sum, i in
                guard case .thread = features[i].kind else { return sum }
                return sum + (cache.threadSeconds(of: features[i].id) ?? 1)
            }
            if expected > 0, expected >= threshold {
                omitFrom = changed
                keys = makeKeys()
            }
        }
        // Pick up after the last feature that hasn't changed since the previous rebuild.
        var snapshots = cache?.valid(for: keys) ?? []
        if let last = snapshots.last {
            r = last.result
            r.parameters = parameters  // the snapshot's values may be from before an edit that nothing there reads
        }
        let first = snapshots.count

        for (index, feature) in features.enumerated() where index >= first {
            defer { if cache != nil { snapshots.append((keys[index], r)) } }
            guard !feature.suppressed else { continue }
            if leftOut(index, feature) { r.threadsLeftOut += 1; continue }
            progress?(index - first, features.count - first, feature)
            let began = Date()
            do {
                switch feature.kind {
                case .sketch(let f): r.sketches[feature.id] = try sketch(f, r)
                case .extrude(let f): try extrude(f, feature, &r)
                case .fillet(let f): try edgeFeature(f, feature, fillet: true, &r)
                case .chamfer(let f): try edgeFeature(f, feature, fillet: false, &r)
                case .revolve(let f): try revolve(f, feature, &r)
                case .sweep(let f): try sweep(f, feature, &r)
                case .loft(let f): try loft(f, feature, &r)
                case .twistSweep(let f): try twistSweep(f, feature, &r)
                case .rib(let f): try rib(f, feature, &r)
                case .hole(let f): try hole(f, feature, &r)
                case .thread(let f): try thread(f, feature, &r)
                case .primitive(let f): try primitive(f, feature, &r)
                case .pipe(let f): try pipe(f, feature, &r)
                case .move(let f): try move(f, feature, &r)
                case .rotate(let f): try rotate(f, feature, &r)
                case .scale(let f): try scale(f, feature, &r)
                case .combine(let f): try combine(f, feature, &r)
                case .plane(let f): r.planes[feature.id] = try plane(f, r)
                case .mirror(let f): try mirror(f, feature, &r)
                case .pattern(let f): try pattern(f, feature, &r)
                case .shell(let f): try shell(f, feature, &r)
                case .draft(let f): try draft(f, feature, &r)
                case .split(let f): try split(f, feature, &r)
                case .layOnFloor(let f): try layOnFloor(f, feature, &r)
                case .project(let f): try project(f, feature, &r)
                case .importBody(let f): try importBody(f, feature, &r)
                case .image(let f): r.images[feature.id] = try image(f, &r)
                }
            } catch {
                r.errors[feature.id] = "\(error)"
            }
            if case .thread = feature.kind { cache?.noteThread(feature.id, seconds: Date().timeIntervalSince(began)) }
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

    /// The plane a mirror along a line uses: it contains the line and stands square to the plane the line lies in.
    /// The X axis lies in the floor (so the plane is XZ, which swaps front and back), the Y axis too (YZ, left
    /// and right), the Z axis in the XZ plane (so YZ); an edge lies in its first flat face, or else the floor
    /// (or, for an upright edge, the XZ plane).
    public static func mirrorPlane(along line: PatternAxis, _ r: RegenResult) throws -> Frame {
        func plane(through origin: SIMD3<Double>, direction: SIMD3<Double>, lyingIn n: SIMD3<Double>) -> Frame {
            let normal = simd_normalize(simd_cross(simd_normalize(direction), simd_normalize(n)))
            return Frame(origin: origin, normal: normal, xAxis: simd_normalize(direction))
        }
        switch line {
        case .x: return plane(through: .zero, direction: SIMD3(1, 0, 0), lyingIn: SIMD3(0, 0, 1))
        case .y: return plane(through: .zero, direction: SIMD3(0, 1, 0), lyingIn: SIMD3(0, 0, 1))
        case .z: return plane(through: .zero, direction: SIMD3(0, 0, 1), lyingIn: SIMD3(0, 1, 0))
        case .edge(let e):
            guard let body = r.body(e.body) else { throw KernelError(message: "the body with the mirror edge is missing") }
            let l = try body.edgeLine(e.edge)
            let direction = simd_normalize(l.direction)
            var reference: SIMD3<Double>?
            for face in (try? body.edgeFaces(e.edge)) ?? [] {
                if let frame = try? body.faceFrame(face), abs(simd_dot(simd_normalize(frame.normal), direction)) < 0.999 {
                    reference = frame.normal
                    break
                }
            }
            let floor = abs(direction.z) < 0.999 ? SIMD3<Double>(0, 0, 1) : SIMD3<Double>(0, 1, 0)
            return plane(through: l.origin, direction: direction, lyingIn: reference ?? floor)
        }
    }

    static func mirror(_ f: MirrorFeature, _ feature: Feature, _ r: inout RegenResult) throws {
        let frame = try f.line.map { try mirrorPlane(along: $0, r) } ?? resolvePlane(f.plane, r)
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
        guard let i = r.bodies.firstIndex(where: { $0.id == f.body }) else {
            throw KernelError(message: "The body to shell is missing. Pick the faces to leave open again.")
        }
        // Recorded first, so the thickness handle still shows when the wall can't be built.
        r.featureInputs[feature.id, default: [:]][f.body] = r.bodies[i].body
        let thickness = try r.parameters.value(of: f.thickness, kind: .length)
        guard thickness > 1e-9 else { throw KernelError(message: "The wall thickness must be more than zero.") }
        let faces = f.faces.filter { $0.body == f.body }.map(\.face)
        let body = r.bodies[i].body
        let before = body.volume
        var kernelReason = ""
        var shelled: KBody?
        do { shelled = try body.shell(removing: faces, thickness: thickness, inside: f.inside, featureID: feature.id) }
        catch { kernelReason = "\(error)" }
        // Walls too thick for the body can come back as the unchanged body instead of an error.
        if let made = shelled {
            let after = made.volume
            if f.inside ? after < before - 1e-6 && after > 1e-6 : after > before + 1e-6 {
                r.bodies[i].body = made
                return
            }
        }
        throw KernelError(message: shellFailure(body, thickness: thickness, inside: f.inside, rounds: r.rounds, kernel: kernelReason))
    }

    static func draft(_ f: DraftFeature, _ feature: Feature, _ r: inout RegenResult) throws {
        guard let i = r.bodies.firstIndex(where: { $0.id == f.body }) else {
            throw KernelError(message: "The body to draft is missing. Pick the faces to draft again.")
        }
        // Recorded first, so the angle handle still shows when the draft can't be built.
        r.featureInputs[feature.id, default: [:]][f.body] = r.bodies[i].body
        let angle = try r.parameters.value(of: f.angle, kind: .angle)
        guard abs(angle) > 1e-9 else { return }  // a draft of nothing leaves the body as it is
        guard abs(angle) < 89.9 * .pi / 180 else { throw KernelError(message: "A draft angle has to be less than 90 degrees.") }
        let faces = f.faces.filter { $0.body == f.body }.map(\.face)
        guard !faces.isEmpty else { throw KernelError(message: "There are no faces to draft. Pick the faces again.") }
        guard let fixed = f.fixed, fixed.body == f.body else {
            throw KernelError(message: "Pick the flat face that stays put: the drafted faces lean away from it.")
        }
        do {
            r.bodies[i].body = try r.bodies[i].body.draft(faces: faces, fixed: fixed.face, angle: angle,
                                                          featureID: feature.id)
        } catch {
            throw KernelError(message: "Draft couldn't lean these faces by \(UnitKind.angle.format(angle)): \("\(error)".replacingOccurrences(of: "draft: ", with: "")). "
                              + "Try a smaller angle, other faces, or a different face to stay put.")
        }
    }

    /// What a split cuts with: a plane that runs on without end, or a curved face of a body as it is.
    enum SplitTool {
        case plane(origin: SIMD3<Double>, normal: SIMD3<Double>)
        case curved(body: FeatureID, face: String)
    }

    /// The id of piece number `k` (1, 2…) that a split of `body` leaves besides the one that keeps the body's own id.
    /// The body it came from is the part before the first "~" (see `rootBody`).
    public static func splitPieceID(of body: FeatureID, by feature: FeatureID, _ k: Int) -> FeatureID { "\(body)~\(feature)~\(k)" }

    /// The body a piece of a split came from, however many times it has been split; the body's own id for the rest.
    public static func rootBody(_ id: FeatureID) -> FeatureID { String(id.prefix { $0 != "~" }) }

    static func split(_ f: SplitFeature, _ feature: Feature, _ r: inout RegenResult) throws {
        let tool: SplitTool?, what: String
        switch f.tool {
        case .parts:
            tool = nil; what = "parts"
        case .plane(let ref):
            let frame = try resolvePlane(ref, r)
            tool = .plane(origin: frame.origin, normal: frame.normal); what = "plane"
        case .profile(let id):
            let frame = try sketchResult(id, r).frame
            tool = .plane(origin: frame.origin, normal: frame.normal); what = "profile's plane"
        case .face(let ref):
            guard let body = r.body(ref.body) else { throw KernelError(message: "The body with the face to split by is missing. Pick the face again.") }
            if let frame = try? body.faceFrame(ref.face) {
                tool = .plane(origin: frame.origin, normal: frame.normal); what = "face's plane"
            } else {
                tool = .curved(body: ref.body, face: ref.face); what = "face"
            }
        }
        guard !f.bodies.isEmpty else { throw KernelError(message: "There are no bodies to split. Pick the bodies again.") }
        var cutAny = false
        for id in f.bodies {
            guard let i = r.bodies.firstIndex(where: { $0.id == id }) else {
                throw KernelError(message: "A body to split is missing. Pick the bodies again.")
            }
            let whole = r.bodies[i].body
            r.featureInputs[feature.id, default: [:]][id] = whole
            let pieces: [KBody]
            do {
                switch tool {
                case nil:
                    pieces = try whole.splitIntoParts(featureID: feature.id)
                case .plane(let origin, let normal)?:
                    pieces = try whole.split(planeThrough: origin, normal: normal, featureID: feature.id)
                case .curved(let toolBody, let face)?:
                    guard toolBody != id, let toolShape = r.body(toolBody) else { continue }  // a body can't cut itself
                    pieces = try whole.split(byFace: face, of: toolShape, featureID: feature.id)
                }
            } catch {
                throw KernelError(message: "Split couldn't divide \(r.bodies[i].name): \("\(error)".replacingOccurrences(of: "split: ", with: "")).")
            }
            guard pieces.count > 1 else { continue }  // the tool misses this one: it stays as it is
            cutAny = true
            let parent = r.bodies[i]
            r.bodies[i].body = pieces[0]
            for (k, piece) in pieces.enumerated().dropFirst() {
                let pieceID = splitPieceID(of: id, by: feature.id, k)
                let name = r.bodyNames[pieceID] ?? (r.bodyNames[id] != nil ? "\(parent.name) \(k + 1)" : "Body\(r.bodies.count + 1)")
                r.bodies.insert(BodyResult(id: pieceID, name: name, body: piece), at: i + k)
            }
        }
        if !cutAny, tool == nil {
            throw KernelError(message: "\(f.bodies.count == 1 ? "The body is" : "None of the bodies is") made of a single part, so there is nothing to separate.")
        }
        if !cutAny {
            throw KernelError(message: "The \(what) doesn't cut through \(f.bodies.count == 1 ? "the body" : "any of the bodies"). "
                              + "Pick another \(what == "face" ? "face" : "plane or face"), or move the bodies.")
        }
    }

    /// Why walls of this thickness couldn't be built, as plainly as can be told.
    static func shellFailure(_ body: KBody, thickness: Double, inside: Bool, rounds: [(feature: String, radius: Double)],
                             kernel: String) -> String {
        func mm(_ x: Double) -> String { formatDimension(x, kind: .length) }
        let t = mm(thickness)
        if inside, let box = body.bounds {
            let size = box.max - box.min
            let narrowest = min(size.x, size.y, size.z)
            if thickness * 2 >= narrowest - 1e-6 {
                return "A \(t) wall doesn't fit: the body is only \(mm(narrowest)) across at its narrowest, "
                    + "so walls on both sides can be at most \(mm(narrowest / 2)) thick."
            }
        }
        if let tight = rounds.filter({ $0.radius <= thickness + 1e-9 }).min(by: { $0.radius < $1.radius }) {
            return "\(tight.feature) rounds an edge with a \(mm(tight.radius)) radius, no bigger than the \(t) wall. "
                + "A wall can't follow a corner tighter than it is thick, which is the likely reason. "
                + "Use a thinner wall, or move the shell earlier in the timeline, before the fillets."
        }
        var text = "The walls couldn't be built at \(t). Rounded, slanted or very small features can stop an offset like this: "
            + "try a thinner wall, open a different face, or shell earlier in the timeline, before fillets, chamfers and threads."
        let detail = kernel.replacingOccurrences(of: "shell: ", with: "")
        if !detail.isEmpty, !detail.hasPrefix("shell failed") { text += " (Kernel: \(detail))" }
        return text
    }

    /// Projects sketch profiles onto a body and raises them out of its surface or cuts them into it.
    static func project(_ f: ProjectFeature, _ feature: Feature, _ r: inout RegenResult) throws {
        guard let i = r.bodies.firstIndex(where: { $0.id == f.target }) else {
            throw KernelError(message: "The body to project onto is missing. Pick it again.")
        }
        let sk = try sketchResult(f.sketch, r)
        let profiles = try Self.profiles(f.profiles, in: sk)
        let height = try r.parameters.value(of: f.height, kind: .length)
        guard height > 1e-9 else { throw KernelError(message: "The height must be more than zero.") }
        let direction = f.flipped ? -sk.frame.normal : sk.frame.normal
        let faces = f.faces.filter { $0.body == f.target }.map(\.face)
        let target = r.bodies[i].body
        for face in faces where !target.hasFace(face) {
            throw KernelError(message: "A face it projects onto is gone. Pick the faces again.")
        }
        let relief: (body: KBody, origin: SIMD3<Double>, normal: SIMD3<Double>)
        func attempt(_ direction: SIMD3<Double>) throws -> (body: KBody, origin: SIMD3<Double>, normal: SIMD3<Double>) {
            try target.projectRelief(profiles, onto: faces, direction: direction,
                                     height: f.mode == .emboss ? height : -height,
                                     wrap: f.wrap ?? false, featureID: feature.id)
        }
        do {
            do {
                relief = try attempt(direction)
            } catch let error as KernelError where error.message.contains("nothing to project onto") {
                // Nothing lay that way: it may lie the other way (the sketch is on the far side), so that is tried
                // before the user is told to flip it.
                relief = try attempt(-direction)
            }
        } catch let error as KernelError where error.message.contains("nothing to project onto") {
            throw KernelError(message: "Nothing to project onto: no face that faces the sketch is under the profiles. "
                              + "Move the sketch so it sits in front of the body, over the face it should land on.")
        }
        r.projectionHandles[feature.id] = (relief.origin, relief.normal)
        try combine(relief.body, f.mode == .emboss ? .join : .cut, target: f.target, feature, &r)
    }

    /// Reads a STEP or STL file's contents into a body, the way an Import feature does, and keeps it
    /// for the rebuild that follows (so a file can be checked before it's added).
    public static func importedBody(_ data: Data, featureID: FeatureID) throws -> KBody {
        try ImportCache.shared.body(data, featureID: featureID)
    }

    static func importBody(_ f: ImportFeature, _ feature: Feature, _ r: inout RegenResult) throws {
        let body = try importedBody(f.data, featureID: feature.id)
        r.bodies.append(BodyResult(id: feature.id, name: r.bodyNames[feature.id] ?? "Body\(r.bodies.count + 1)", body: body))
    }

    /// Where a reference image lies on its plane. Like a sketch on a face, it reads upright as the view shows the plane.
    static func image(_ f: ImageFeature, _ r: inout RegenResult) throws -> ImagePlacement {
        let plane = try resolvePlane(f.plane, r)
        let base = f.plane.isFaceOrPlane ? plane.upright : plane
        let p = r.parameters
        let u = try p.value(of: f.u, kind: .length), v = try p.value(of: f.v, kind: .length)
        let width = try p.value(of: f.width, kind: .length)
        let angle = try p.value(of: f.angle, kind: .angle)
        guard width > 1e-9 else { throw KernelError(message: "The image's width must be more than zero.") }
        let normal = simd_normalize(base.normal)
        let x = simd_normalize(turned(base.xAxis, about: normal, by: angle))
        return ImagePlacement(frame: Frame(origin: base.point(u, v), normal: normal, xAxis: x), width: width, height: width * f.aspect)
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
        try followProjections(&solved, frame: frame, r)
        let solve = SketchSolver.solveLocally(&solved, dimensionValues: values)  // a changed parameter moves only what it drives
        guard solve.status == .solved else {
            let diagnosis = SketchSolver.diagnose(f.sketch, dimensionValues: values)
            if let names = f.sketch.conflictText(diagnosis.conflicting) {
                throw KernelError(message: "sketch cannot satisfy its constraints: \(names) cannot all hold (residual \(solve.maxResidual))")
            }
            throw KernelError(message: "sketch cannot satisfy its constraints (residual \(solve.maxResidual))")
        }
        if let problem = solved.refreshGenerated(r.parameters).values.sorted().first {
            throw KernelError(message: problem)
        }
        return try sketchResult(solved, solve: solve, frame: frame, parameters: r.parameters)
    }

    /// A circular edge of a body as it lands in a sketch frame: an arc running counter-clockwise from `start` to `end`,
    /// or a full circle through `start`. Nil when the edge isn't circular or isn't seen straight on (a circle turned
    /// to the plane lands as an ellipse or a line, which a projection doesn't carry).
    public static func roundEdgeSnap(_ body: KBody, edge: EdgeRef, frame: Frame) -> ModelSnap? {
        guard let c = try? body.edgeCircle(edge.edge), abs(simd_dot(c.axis, frame.normal)) > 1 - 1e-8 else { return nil }
        func local(_ w: SIMD3<Double>) -> SIMD2<Double> {
            SIMD2(simd_dot(w - frame.origin, frame.xAxis), simd_dot(w - frame.origin, frame.yAxis))
        }
        // Counter-clockwise about the edge's axis is clockwise on the sketch when the axis points into it.
        let flip = simd_dot(c.axis, frame.normal) < 0
        let a = local(c.start), b = local(c.end)
        let (start, end) = c.isFull ? (a, a) : flip ? (b, a) : (a, b)
        return ModelSnap(edge: edge, start: start, end: end, center: local(c.center), isFullCircle: c.isFull)
    }

    /// Puts a sketch's projected model edges where the edges are now, so geometry tied to them follows.
    public static func followProjections(_ sketch: inout Sketch, frame: Frame, _ r: RegenResult) throws {
        for p in sketch.projections {
            guard let body = r.body(p.edge.body) else {
                throw KernelError(message: "the body with the projected edge \(p.edge.edge) is missing")
            }
            func place(_ id: EntityID, _ uv: SIMD2<Double>) {
                guard let i = sketch.points.firstIndex(where: { $0.id == id }) else { return }
                sketch.points[i].x = uv.x; sketch.points[i].y = uv.y; sketch.points[i].fixed = true
            }
            if let center = p.center {
                guard let snap = roundEdgeSnap(body, edge: p.edge, frame: frame), let mid = snap.center else {
                    throw KernelError(message: "projected edge not found or no longer circular: \(p.edge.edge)")
                }
                place(center, mid); place(p.start, snap.start); place(p.end, snap.end)
                if let i = sketch.curves.firstIndex(where: { $0.id == p.line }), case .circle(let c, _) = sketch.curves[i].geometry {
                    sketch.curves[i].geometry = .circle(center: c, radius: simd_length(snap.start - mid))
                }
                continue
            }
            guard let ends = try? body.edgeEnds(p.edge.edge) else {
                throw KernelError(message: "projected edge not found: \(p.edge.edge)")
            }
            func local(_ w: SIMD3<Double>) -> SIMD2<Double> { SIMD2(simd_dot(w - frame.origin, frame.xAxis), simd_dot(w - frame.origin, frame.yAxis)) }
            place(p.start, local(ends.start)); place(p.end, local(ends.end))
        }
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
        case .ellipse(let center, let major, let minor):
            guard let pc = solved.point(center), let pu = solved.point(major), let pv = solved.point(minor) else { return }
            // Four cubic Béziers, a quarter turn each. An affine image of a circle's Béziers is the ellipse's, so
            // the handles are taken in the ellipse's own frame; they share the curve's tag, so it is one profile.
            let o = pc.position, u = pu.position - o, v = pv.position - o
            let k = 4.0 / 3.0 * tan(.pi / 8)  // handle length for a quarter turn of a unit circle
            func point(_ t: Double) -> SIMD2<Double> { o + u * cos(t) + v * sin(t) }
            func slope(_ t: Double) -> SIMD2<Double> { -u * sin(t) + v * cos(t) }
            for quarter in 0..<4 {
                let t0 = Double(quarter) * .pi / 2, t1 = t0 + .pi / 2
                try ks.addBezier(c.id, [point(t0), point(t0) + slope(t0) * k, point(t1) - slope(t1) * k, point(t1)])
            }
        }
    }

    /// Adds a feature's solid as a new body, or joins/cuts/intersects it with the target body.
    static func combine(_ tool: KBody, _ operation: BodyOperation, target: FeatureID?, _ feature: Feature,
                        _ r: inout RegenResult) throws {
        // A target that is gone falls back to the newest body, as it always did.
        var targets: [FeatureID]?
        if let target {
            targets = [r.bodies.contains { $0.id == target } ? target : r.bodies.last?.id ?? target]
        }
        try combine(tool, operation, targets: targets, feature, &r)
    }

    /// As above for a list of bodies to work on; nil = automatic (a cut goes through every body it reaches, a join
    /// or intersect takes the newest body). A join with several bodies merges them, and the tool, into the first.
    static func combine(_ tool: KBody, _ operation: BodyOperation, targets: [FeatureID]?, _ feature: Feature,
                        _ r: inout RegenResult) throws {
        if operation == .newBody {
            r.bodies.append(BodyResult(id: feature.id, name: r.bodyNames[feature.id] ?? "Body\(r.bodies.count + 1)", body: tool))
            return
        }
        let verb = operation.rawValue.lowercased()
        var chosen: [Int]
        if let targets {
            chosen = r.bodies.indices.filter { targets.contains(r.bodies[$0].id) }
            guard !chosen.isEmpty else {
                throw KernelError(message: targets.isEmpty ? "pick the bodies to \(verb)" : "the bodies to \(verb) are missing")
            }
        } else if operation == .cut {
            guard !r.bodies.isEmpty else { throw KernelError(message: "no body to cut") }
            chosen = Array(r.bodies.indices)
        } else {
            guard !r.bodies.isEmpty else { throw KernelError(message: "no body to \(verb)") }
            chosen = [r.bodies.count - 1]
        }
        switch operation {
        case .cut:
            guard let tb = tool.bounds else { return }
            chosen = chosen.filter { i in r.bodies[i].body.bounds.map { overlaps($0, tb) } ?? false }
            for i in chosen {
                let cut = try r.bodies[i].body.boolean(tool, SK_CUT)
                if cut.isEmpty { throw KernelError(message: "the cut removes all of \(r.bodies[i].name)") }
                r.bodies[i].body = cut
            }
            r.affectedBodies[feature.id] = chosen.map { r.bodies[$0].id }
        case .intersect:
            for i in chosen {
                let common = try r.bodies[i].body.boolean(tool, SK_COMMON)
                if common.isEmpty { throw KernelError(message: "the new shape doesn't overlap \(r.bodies[i].name)") }
                r.bodies[i].body = common
            }
            r.affectedBodies[feature.id] = chosen.map { r.bodies[$0].id }
        default:
            let first = chosen[0]
            var joined = try r.bodies[first].body.boolean(tool, SK_FUSE)
            for i in chosen.dropFirst() { joined = try joined.boolean(r.bodies[i].body, SK_FUSE) }
            r.bodies[first].body = joined
            r.affectedBodies[feature.id] = chosen.map { r.bodies[$0].id }
            for i in chosen.dropFirst().reversed() { r.bodies.remove(at: i) }
        }
    }

    static func extrude(_ f: ExtrudeFeature, _ feature: Feature, _ r: inout RegenResult) throws {
        /// One thing to extrude: profiles on a plane, and the body (for a face) it grows on.
        struct Job { var profiles: [KProfile]; var normal: SIMD3<Double>; var planeOrigin: SIMD3<Double>; var body: FeatureID? }
        var jobs: [Job] = []
        if f.face != nil {
            // Every face is read before any is pulled: the first join changes the body the others are read from.
            var inputs: [FeatureID: KBody] = [:]
            for face in f.allFaces {
                guard let body = r.body(face.body) else { throw KernelError(message: "the body with that face is missing") }
                inputs[face.body] = inputs[face.body] ?? body
                let frame = try body.faceFrame(face.face)
                jobs.append(Job(profiles: [try body.faceProfile(face.face)], normal: frame.normal, planeOrigin: frame.origin, body: face.body))
            }
            r.featureInputs[feature.id] = inputs  // the faces move once extruded; the handle stays on the inputs
        } else {
            let sk = try sketchResult(f.sketch, r)
            jobs = [Job(profiles: try Self.profiles(f.profiles, in: sk), normal: sk.frame.normal, planeOrigin: sk.frame.origin, body: nil)]
        }

        let p = r.parameters
        var tools: [(KBody, FeatureID?)] = []
        for job in jobs {
            let normal = job.normal, planeOrigin = job.planeOrigin
            let dir = f.flipped ? -normal : normal
            var origin = planeOrigin  // where the extrude starts: the sketch plane, or the face it starts from
            var startOffset = 0.0  // along `dir`, from the sketch plane to the face the extrude starts on
            if let ref = f.start, f.face == nil {
                guard let body = r.body(ref.body) else { throw KernelError(message: "the body with the face to start from is missing") }
                let face: Frame
                do { face = try body.faceFrame(ref.face) } catch { throw KernelError(message: "the face to start from is gone or isn't flat") }
                guard abs(simd_dot(face.normal, normal)) > 0.9999 else {
                    throw KernelError(message: "the face to start from isn't parallel to the sketch")
                }
                startOffset = simd_dot(face.origin - planeOrigin, dir)
                origin += dir * startOffset
                r.extrudeStarts[feature.id] = simd_dot(face.origin - planeOrigin, normal)
            }
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
                        far = max(far, simd_dot(corner - origin, dir))
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
                distance = simd_dot(face.origin - origin, dir); back = 0
                guard distance > 1e-9 else { throw KernelError(message: "the face is behind the sketch · flip the direction") }
            }
            let taper = try f.taper.map { try p.value(of: $0, kind: .angle) } ?? 0
            guard abs(taper) < 89.0 * .pi / 180 else { throw KernelError(message: "the taper angle must be under 90°") }
            tools.append((try KBody.extrude(job.profiles, direction: dir, distance: distance, back: back, taper: taper,
                                            startOffset: startOffset, featureID: feature.id), job.body))
        }
        let oneBody = Set(tools.compactMap(\.1)).count <= 1
        for (tool, body) in tools {
            if let targets = f.targets {
                try combine(tool, f.operation, targets: targets, feature, &r)
            } else {
                try combine(tool, f.operation, target: oneBody ? (f.target ?? body) : body, feature, &r)
            }
        }
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
        if let targets = f.targets {
            try combine(tool, f.operation, targets: targets, feature, &r)
        } else {
            try combine(tool, f.operation, target: f.target, feature, &r)
        }
    }

    static func loft(_ f: LoftFeature, _ feature: Feature, _ r: inout RegenResult) throws {
        guard f.sections.count >= 2 else { throw KernelError(message: "a loft needs at least two profiles") }
        let profiles = try f.sections.map { s in try Self.profiles([s.profile], in: try sketchResult(s.sketch, r))[0] }
        let tool = try KBody.loft(profiles, ruled: f.ruled, featureID: feature.id)
        try combine(tool, f.operation, target: f.target, feature, &r)
    }

    static func twistSweep(_ f: TwistSweepFeature, _ feature: Feature, _ r: inout RegenResult) throws {
        let sk = try sketchResult(f.sketch, r)
        let profiles = try profiles(f.profiles, in: sk)
        let p = r.parameters
        let distance = try p.value(of: f.distance, kind: .length)
        guard distance > 1e-9 else { throw KernelError(message: "the length of a twist sweep has to be more than zero") }
        let start = try p.value(of: f.startAngle, kind: .angle), end = try p.value(of: f.endAngle, kind: .angle)
        let curve = try p.value(of: f.curve, kind: .none)
        guard curve > 1e-6, curve < 1e6 else { throw KernelError(message: "the twist curve has to be more than zero (1 turns evenly)") }
        let shift = try p.value(of: f.shiftU, kind: .length) * sk.frame.xAxis + p.value(of: f.shiftV, kind: .length) * sk.frame.yAxis
        var pivot: SIMD3<Double>?
        if f.pivotU != nil || f.pivotV != nil {
            pivot = sk.frame.point(try f.pivotU.map { try p.value(of: $0, kind: .length) } ?? 0,
                                   try f.pivotV.map { try p.value(of: $0, kind: .length) } ?? 0)
        }
        // A section about every 3° of turn is smooth enough that the loft through them is not visibly faceted.
        let sections = min(max(Int((abs(end - start) * 180 / .pi / 3).rounded(.up)), 8), 80)
        // The turn is always about the sketch's normal, so a positive angle is counter-clockwise seen from the sketch's front
        // whichever way the sweep runs; a flipped sweep just goes the other way along the normal.
        let tool = try KBody.twistSweep(profiles, direction: sk.frame.normal, distance: f.flipped ? -distance : distance, pivot: pivot,
                                        startAngle: start, endAngle: end, power: curve, shift: shift, sections: sections,
                                        featureID: feature.id)
        if let targets = f.targets {
            try combine(tool, f.operation, targets: targets, feature, &r)
        } else {
            try combine(tool, f.operation, target: f.target, feature, &r)
        }
    }

    static func targetIndex(_ target: FeatureID?, _ r: RegenResult) throws -> Int {
        guard let i = target.flatMap({ t in r.bodies.firstIndex { $0.id == t } }) ?? (r.bodies.isEmpty ? nil : r.bodies.count - 1)
        else { throw KernelError(message: "there is no body to add it to") }
        return i
    }

    /// Grows the rib on its target body. Without a target it goes on the body the rib adds the most to: the newest
    /// body is not necessarily the one the line was drawn against (a lid made after the box it closes), and a body
    /// the line cannot reach is simply not a candidate.
    static func rib(_ f: RibFeature, _ feature: Feature, _ r: inout RegenResult) throws {
        let candidates = f.target != nil ? [try targetIndex(f.target, r)] : Array(r.bodies.indices.reversed())
        guard !candidates.isEmpty else { throw KernelError(message: "there is no body to add it to") }
        let thickness = try r.parameters.value(of: f.thickness, kind: .length)
        let path = try path(f.path, r).path
        var best: (index: Int, body: KBody, gain: Double)?
        var failures: [(body: String, reason: String)] = []
        for i in candidates {
            do {
                let grown = try r.bodies[i].body.rib(along: path, thickness: thickness, featureID: feature.id)
                let gain = grown.volume - r.bodies[i].body.volume
                if best == nil || gain > best!.gain * (1 + 1e-9) { best = (i, grown, gain) }
            } catch {
                let text = (error as? KernelError)?.message ?? "\(error)"
                failures.append((r.bodies[i].name, text.hasPrefix("rib: ") ? String(text.dropFirst(5)) : text))
            }
        }
        guard let best else {
            // With a target there is one reason; without one, each body says why the line does not close it off.
            if failures.count == 1 { throw KernelError(message: failures[0].reason) }
            throw KernelError(message: "the line closes off none of the bodies. "
                              + failures.map { "\($0.body): \($0.reason)" }.joined(separator: " · "))
        }
        r.bodies[best.index].body = best.body
    }

    /// Where a hole's top centre is: (u, v) in its face's frame, drilling against the face normal.
    /// On a finished build pass the hole's feature id: its face is then taken as it was before the cut, because the
    /// cut can merge it with a coplanar neighbour and leave the finished body without a face of that name.
    public static func holeFrame(_ f: HoleFeature, _ r: RegenResult, before id: FeatureID? = nil) throws -> Frame {
        try holeFrameAndLift(f, r, before: id, reach: 0).frame
    }

    /// The hole's frame on its face (on a curved face, on the surface with the normal there) and how far a curved surface
    /// rises above the frame's plane within `reach`.
    static func holeFrameAndLift(_ f: HoleFeature, _ r: RegenResult, before id: FeatureID? = nil, reach: Double) throws -> (frame: Frame, lift: Double) {
        guard let body = id.flatMap({ r.featureInputs[$0]?[f.face.body] }) ?? r.body(f.face.body) else {
            throw KernelError(message: "the body with the hole's face is missing")
        }
        let u = try r.parameters.value(of: f.u, kind: .length), v = try r.parameters.value(of: f.v, kind: .length)
        return try body.holeFrame(f.face.face, u: u, v: v, reach: reach)
    }

    static func hole(_ f: HoleFeature, _ feature: Feature, _ r: inout RegenResult) throws {
        guard let i = r.bodies.firstIndex(where: { $0.id == f.face.body }) else {
            throw KernelError(message: "the body with the hole's face is missing")
        }
        let p = r.parameters
        var reach = try p.value(of: f.diameter, kind: .length) / 2
        if f.kind != .simple { reach = max(reach, try p.value(of: f.headDiameter, kind: .length) / 2) }
        // On a curved face the tool starts `lift` above the surface point, so a concave surface leaves no skin over it.
        let (frame0, lift) = try holeFrameAndLift(f, r, reach: reach)
        var frame = frame0
        frame.origin += lift * frame.normal
        let depth: Double
        if let d = f.depth {
            depth = try p.value(of: d, kind: .length) + lift
        } else if let b = r.bodies[i].body.bounds {  // through all: longer than the body is wide
            let d = b.max - b.min
            depth = (d * d).sum().squareRoot() * 2 + 1 + lift
        } else {
            throw KernelError(message: "the body is empty")
        }
        let kind: KHole
        switch f.kind {
        case .simple: kind = .simple
        case .counterbore: kind = .counterbore(diameter: try p.value(of: f.headDiameter, kind: .length),
                                               depth: try p.value(of: f.headDepth, kind: .length) + lift)
        case .countersink:
            let angle = try p.value(of: f.headAngle, kind: .angle)
            kind = .countersink(diameter: try p.value(of: f.headDiameter, kind: .length) + 2 * lift * tan(angle / 2), angle: angle)
        }
        let tip = f.depth == nil ? 0 : try p.value(of: f.tipAngle, kind: .angle)
        let tool = try KBody.hole(at: frame, kind, diameter: try p.value(of: f.diameter, kind: .length), depth: depth,
                                  tipAngle: tip, featureID: feature.id)
        // The face as it was before the cut: its centre doesn't move with the hole (see the move dot).
        r.featureInputs[feature.id] = [f.face.body: r.bodies[i].body]
        r.bodies[i].body = try r.bodies[i].body.boolean(tool, SK_CUT)
    }

    static func thread(_ f: ThreadFeature, _ feature: Feature, _ r: inout RegenResult) throws {
        let length = try f.length.map { try r.parameters.value(of: $0, kind: .length) }
        if let length, length <= 0 { throw KernelError(message: "the thread length must be positive") }
        if f.faces.count > 1, threadTogether(f, feature, length: length, &r) { return }
        for (n, face) in f.faces.enumerated() {
            var spec = f.spec(at: n)
            guard let i = r.bodies.firstIndex(where: { $0.id == face.body }) else {
                throw KernelError(message: "the body with the thread's face is missing")
            }
            // A hole whose diameter comes from a parameter can change size under the thread: when the stored size no
            // longer suits the face, the thread is fitted to the face's present diameter instead of failing.
            if let cylinder = try? r.bodies[i].body.faceCylinder(face.face, flipped: f.flipped),
               let stored = try? f.size(of: spec, r.parameters),
               !ThreadFit.suits(stored, radius: cylinder.radius, isHole: cylinder.isHole),
               // Only a face that has drifted from its size; a plainly wrong pick (M20 on a Ø8 shaft) is still an error.
               (0.5...2).contains(2 * cylinder.radius / stored.diameter) {
                spec = ThreadSpec.suggested(forDiameter: 2 * cylinder.radius, hole: cylinder.isHole)
            }
            let size: ThreadSize
            do { size = try f.size(of: spec, r.parameters) } catch { throw KernelError(message: "\(error)") }
            let diameter = try f.modeledDiameter(of: size, r.parameters)
            if diameter <= size.pitch * 1.2 { throw KernelError(message: "the tolerance offset leaves the thread too thin") }
            // The body as it was: the faces (and so the length handle) are found on it.
            if r.featureInputs[feature.id]?[face.body] == nil {
                r.featureInputs[feature.id, default: [:]][face.body] = r.bodies[i].body
            }
            // The first face names its new faces after the feature, the rest "<id>.2", "<id>.3"...
            let body = r.bodies[i].body
            do {
                r.bodies[i].body = try body.thread(face: face.face, majorDiameter: diameter, pitch: size.pitch,
                                                   length: length, flipped: f.flipped, leftHanded: f.leftHanded,
                                                   featureID: n == 0 ? feature.id : "\(feature.id).\(n + 1)")
            } catch let error as KernelError {
                throw KernelError(message: error.message + threadSizeHint(f, spec, size, body: body, face: face.face, length: length, r))
            }
        }
    }

    /// All of the feature's faces in one go, when they are on one body: a thread is mostly the time it takes to go through
    /// the whole body, so one pass for the four holes of a feature takes about as long as one for a single hole. False
    /// when it can't be done (the faces are on different bodies, the threads reach each other, a size or a thread
    /// fails); nothing has then been changed, and the faces are threaded one at a time, which also tells what is wrong.
    private static func threadTogether(_ f: ThreadFeature, _ feature: Feature, length: Double?, _ r: inout RegenResult) -> Bool {
        guard let first = f.faces.first, f.faces.allSatisfy({ $0.body == first.body }),
              let i = r.bodies.firstIndex(where: { $0.id == first.body }) else { return false }
        var diameters: [Double] = [], pitches: [Double] = []
        for n in f.faces.indices {
            guard let size = try? f.size(of: f.spec(at: n), r.parameters),
                  let diameter = try? f.modeledDiameter(of: size, r.parameters), diameter > size.pitch * 1.2 else { return false }
            diameters.append(diameter)
            pitches.append(size.pitch)
        }
        let body = r.bodies[i].body
        guard let threaded = try? body.threads(faces: f.faces.map(\.face), majorDiameters: diameters, pitches: pitches, length: length,
                                               flipped: f.flipped, leftHanded: f.leftHanded, featureID: feature.id) else { return false }
        // The body as it was: the faces (and so the length handle) are found on it.
        if r.featureInputs[feature.id]?[first.body] == nil { r.featureInputs[feature.id, default: [:]][first.body] = body }
        r.bodies[i].body = threaded
        return true
    }

    /// For a thread that couldn't be built: other sizes that do build on the same face (a thread can fail at one
    /// size and not at the next), found by trying the nearest ones. Empty when none is found.
    private static func threadSizeHint(_ f: ThreadFeature, _ spec: ThreadSpec, _ size: ThreadSize, body: KBody, face: String, length: Double?,
                                       _ r: RegenResult) -> String {
        guard let cylinder = try? body.faceCylinder(face, flipped: f.flipped) else { return "" }
        let radius = cylinder.radius
        // The sizes the kernel accepts for this face (see sk_thread), nearest first, the same standard before others.
        let candidates = ThreadStandard.allCases.flatMap { standard in standard.sizes.map { (standard, $0) } }
            .filter { standard, s in
                let rMajor = s.diameter / 2, rMinor = s.minorDiameter / 2
                let fits = cylinder.isHole ? (radius > rMinor * 0.8 && radius < rMajor * 1.1)
                                           : (radius > rMajor * 0.8 && radius < rMajor * 1.25)
                return fits && !(standard == spec.standard && s.name == size.name)
            }
            .sorted { a, b in
                if (a.0 == spec.standard) != (b.0 == spec.standard) { return a.0 == spec.standard }
                return abs(a.1.diameter - size.diameter) < abs(b.1.diameter - size.diameter)
            }
        var working: [String] = []
        for (standard, candidate) in candidates.prefix(4) where working.count < 3 {
            guard let diameter = try? f.modeledDiameter(of: candidate, r.parameters),
                  diameter > candidate.pitch * 1.2,
                  (try? body.thread(face: face, majorDiameter: diameter, pitch: candidate.pitch, length: length,
                                    flipped: f.flipped, leftHanded: f.leftHanded, featureID: "hint")) != nil else { continue }
            let label = candidate.label(standard)
            working.append(standard == spec.standard || standard.isInch ? label : "\(label) (\(standard.rawValue))")
        }
        guard !working.isEmpty else { return "" }
        return ". Sizes that work on this face: " + working.joined(separator: ", ") + "."
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
    static func transformInputs(_ ids: [FeatureID], _ feature: Feature, _ r: inout RegenResult, verb: String = "moves") throws -> [Int] {
        let indices = try ids.map { id in
            guard let i = r.bodies.firstIndex(where: { $0.id == id }) else { throw KernelError(message: "a body it \(verb) is missing") }
            return i
        }
        guard !indices.isEmpty else { throw KernelError(message: "no body to \(verb.dropLast())") }
        for i in indices { r.featureInputs[feature.id, default: [:]][r.bodies[i].id] = r.bodies[i].body }
        return indices
    }

    static func move(_ f: MoveFeature, _ feature: Feature, _ r: inout RegenResult) throws {
        let p = r.parameters
        let d = SIMD3(try p.value(of: f.dx, kind: .length), try p.value(of: f.dy, kind: .length), try p.value(of: f.dz, kind: .length))
        let turn = SIMD3(try p.value(of: f.rx, kind: .angle), try p.value(of: f.ry, kind: .angle), try p.value(of: f.rz, kind: .angle))
        // Turns are about the pivot point if one is set, else the middle of what moves, as it was before this feature.
        let inputSketches = try f.sketches.map { id -> SketchResult in
            guard let sk = r.sketches[id] else { throw KernelError(message: "a sketch it moves failed or is missing") }
            return sk
        }
        let inputBodies = f.bodies.compactMap { id in r.bodies.first { $0.id == id }?.body }
        let pivot = try pivot(of: f, parameters: p, middle: center(of: inputBodies, sketches: inputSketches))
        let matrix = rotationMatrix(turn)
        for (id, sk) in zip(f.sketches, inputSketches) {
            r.sketchInputs[feature.id, default: [:]][id] = sk
            var frame = sk.frame
            frame.origin = pivot + matrix * (frame.origin - pivot) + d
            frame.normal = matrix * frame.normal
            frame.xAxis = matrix * frame.xAxis
            r.sketches[id] = try sketchResult(sk.solved, solve: sk.solve, frame: frame, parameters: p)
        }
        if f.bodies.isEmpty && !f.sketches.isEmpty { return }
        for i in try transformInputs(f.bodies, feature, &r) {
            var body = r.bodies[i].body
            for (axis, angle) in [(Axis3.x, turn.x), (.y, turn.y), (.z, turn.z)] where abs(angle) > 1e-12 {
                body = try body.rotated(about: pivot, axis: direction(axis), angle: angle)
            }
            r.bodies[i].body = abs(d.x) + abs(d.y) + abs(d.z) > 0 ? try body.translated(d) : body
        }
    }

    /// Where a move turns: its pivot point, or the middle of what it moves.
    public static func pivot(of f: MoveFeature, parameters p: ParameterValues, middle: SIMD3<Double>?) throws -> SIMD3<Double> {
        guard let e = f.pivot else { return middle ?? .zero }
        return SIMD3(try p.value(of: e[0], kind: .length), try p.value(of: e[1], kind: .length), try p.value(of: e[2], kind: .length))
    }

    /// Turning about X, then Y, then Z (all fixed world axes), as one matrix.
    public static func rotationMatrix(_ turn: SIMD3<Double>) -> simd_double3x3 {
        func about(_ a: SIMD3<Double>, _ t: Double) -> simd_double3x3 { simd_double3x3(simd_quatd(angle: t, axis: a)) }
        return about(SIMD3(0, 0, 1), turn.z) * about(SIMD3(0, 1, 0), turn.y) * about(SIMD3(1, 0, 0), turn.x)
    }

    static func scale(_ f: ScaleFeature, _ feature: Feature, _ r: inout RegenResult) throws {
        let p = r.parameters
        let k = try p.value(of: f.factor, kind: .none)
        guard k > 1e-9 else { throw KernelError(message: "the scale factor must be more than zero") }
        guard !f.sketches.isEmpty || !f.bodies.isEmpty else { throw KernelError(message: "nothing to scale") }
        for id in f.sketches {
            guard let sk = r.sketches[id] else { throw KernelError(message: "a sketch it scales failed or is missing") }
            r.sketchInputs[feature.id, default: [:]][id] = sk
            r.sketches[id] = try sketchResult(sk.solved.scaled(by: k, parameters: p), solve: sk.solve, frame: sk.frame, parameters: p)
        }
        // Bodies grow about the middle of them all, as they were before this feature.
        guard !f.bodies.isEmpty else { return }
        let indices = try transformInputs(f.bodies, feature, &r, verb: "scales")
        guard let pivot = center(of: indices.map { r.bodies[$0].body }) else { throw KernelError(message: "the body is empty") }
        for i in indices { r.bodies[i].body = try r.bodies[i].body.scaled(by: k, about: pivot) }
    }

    /// The turn that brings a face looking along `normal` to look straight down, about the shortest way: as an axis
    /// and an angle (nil when it already does). A face looking straight up has no shortest way; it turns about X.
    static func turnToFaceDown(_ normal: SIMD3<Double>) -> (axis: SIMD3<Double>, angle: Double)? {
        let n = normal / (normal * normal).sum().squareRoot()
        let down = SIMD3<Double>(0, 0, -1)
        let cosine = max(-1, min(1, (n * down).sum()))
        let side = SIMD3(n.y * down.z - n.z * down.y, n.z * down.x - n.x * down.z, n.x * down.y - n.y * down.x)
        let sine = (side * side).sum().squareRoot()
        if sine < 1e-9 { return cosine > 0 ? nil : (SIMD3(1, 0, 0), .pi) }
        return (side / sine, atan2(sine, cosine))
    }

    static func layOnFloor(_ f: LayOnFloorFeature, _ feature: Feature, _ r: inout RegenResult) throws {
        guard let i = r.bodies.firstIndex(where: { $0.id == f.face.body }) else {
            throw KernelError(message: "the body to lay on the floor is missing. Pick the face again")
        }
        let whole = r.bodies[i].body
        guard let frame = try? whole.faceFrame(f.face.face), let pivot = try? whole.faceOutlineCenter(f.face.face) else {
            throw KernelError(message: "only a flat face can lie on the floor. Pick a flat face")
        }
        // Turned about the middle of the face, which then drops straight down to the floor.
        var body = whole
        if let turn = turnToFaceDown(frame.normal) { body = try body.rotated(about: pivot, axis: turn.axis, angle: turn.angle) }
        r.bodies[i].body = abs(pivot.z) > 1e-12 ? try body.translated(SIMD3(0, 0, -pivot.z)) : body
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
        if f.operation != .join, body.isEmpty {
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
        // The face an edge came with (a picked face's edges), where a chamfer measures its first distance.
        var pickedFace: [FeatureID: [String: String]] = [:]
        func add(_ body: FeatureID, _ edge: String, from face: String? = nil) {
            if byBody[body] == nil { order.append(body) }
            if byBody[body]?.contains(edge) != true { byBody[body, default: []].append(edge) }
            if let face, pickedFace[body]?[edge] == nil { pickedFace[body, default: [:]][edge] = face }
        }
        for e in f.edges { add(e.body, e.edge) }
        // A face stands for every edge around it, as the face is now.
        for face in f.faces {
            guard let b = r.body(face.body) else { throw KernelError(message: "body is missing") }
            for edge in try b.faceEdges(face.face) { add(face.body, edge, from: face.face) }
        }
        // Record the inputs first, so the drag handle still shows when the size is invalid.
        for bodyID in order {
            if let b = r.body(bodyID) { r.edgeFeatureInputs[feature.id, default: [:]][bodyID] = b }
        }
        let size = try r.parameters.value(of: f.size, kind: .length)
        // A chamfer measured two ways has a second value: a distance on the other face, or an angle.
        var second = 0.0
        if !fillet, let kind = f.mode.secondKind { second = try r.parameters.value(of: f.second, kind: kind) }
        for bodyID in order {
            guard let i = r.bodies.firstIndex(where: { $0.id == bodyID }) else {
                throw KernelError(message: "body is missing")
            }
            let edges = byBody[bodyID]!
            let b = r.bodies[i].body
            let faces = edges.map { pickedFace[bodyID]?[$0] ?? "" }
            func round(_ scale: Double) throws -> KBody {
                if fillet { return try b.fillet(edges: edges, radius: size * scale, featureID: feature.id) }
                if f.mode == .equalDistance { return try b.chamfer(edges: edges, distance: size * scale, featureID: feature.id) }
                // A second distance scales with the first; an angle stays what it is.
                return try b.chamfer(edges: edges, faces: faces, mode: f.mode, first: size * scale,
                                     second: f.mode == .twoDistances ? second * scale : second, flipped: f.flipped, featureID: feature.id)
            }
            do {
                r.bodies[i].body = try round(1)
            } catch {
                // Two rounds that use up a whole face (half its width each, as on a 2 mm strip with 1 mm) leave
                // nothing between them, which the kernel can't build. A hair under that works and leaves a
                // sliver about 0.00002 mm wide; if that fails too, the size really is too large.
                guard let nudged = try? round(1 - 1e-5) else { throw error }
                r.bodies[i].body = nudged
            }
        }
        if fillet { r.rounds.append((feature.name, size)) }
    }
}

func overlaps(_ a: (min: SIMD3<Double>, max: SIMD3<Double>), _ b: (min: SIMD3<Double>, max: SIMD3<Double>)) -> Bool {
    let eps = 1e-6
    return a.min.x <= b.max.x + eps && b.min.x <= a.max.x + eps && a.min.y <= b.max.y + eps && b.min.y <= a.max.y + eps
        && a.min.z <= b.max.z + eps && b.min.z <= a.max.z + eps
}

@inline(__always) func vlength(_ v: SIMD2<Double>) -> Double { (v.x * v.x + v.y * v.y).squareRoot() }
