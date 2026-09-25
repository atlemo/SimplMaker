// Replays a document's timeline through the kernel. This is what makes SimplCAD parametric:
// change any parameter or feature, call regenerate, and every downstream feature is rebuilt.
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CKernel
import Foundation

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
    public var duration: TimeInterval = 0

    public func body(_ id: FeatureID) -> KBody? { bodies.first { $0.id == id }?.body }
}

public enum Regenerator {
    public static func regenerate(_ doc: CADDocument) -> RegenResult {
        let start = Date()
        var r = RegenResult()
        r.parameters = ParameterEvaluator.evaluate(doc.parameters)

        for feature in doc.activeFeatures where !feature.suppressed {
            do {
                switch feature.kind {
                case .sketch(let f): r.sketches[feature.id] = try sketch(f, r)
                case .extrude(let f): try extrude(f, feature, &r)
                case .fillet(let f): try edgeFeature(f, feature, fillet: true, &r)
                case .chamfer(let f): try edgeFeature(f, feature, fillet: false, &r)
                }
            } catch {
                r.errors[feature.id] = "\(error)"
            }
        }
        r.duration = Date().timeIntervalSince(start)
        return r
    }

    // MARK: features

    static func resolvePlane(_ plane: PlaneRef, _ r: RegenResult) throws -> Frame {
        switch plane {
        case .xy: return .xy
        case .xz: return .xz
        case .yz: return .yz
        case .face(let ref):
            guard let body = r.body(ref.body) else { throw KernelError(message: "the body this sketch is on is missing") }
            return try body.faceFrame(ref.face)
        }
    }

    static func sketch(_ f: SketchFeature, _ r: RegenResult) throws -> SketchResult {
        let frame = try resolvePlane(f.plane, r)
        var values: [EntityID: Double] = [:]
        for d in f.sketch.dimensions {
            do { values[d.id] = try r.parameters.value(of: d.expression, kind: d.unitKind) }
            catch { throw KernelError(message: "dimension '\(d.expression)': \(error)") }
        }
        var solved = f.sketch
        let solve = SketchSolver.solve(&solved, dimensionValues: values)
        guard solve.status == .solved else {
            throw KernelError(message: "sketch cannot satisfy its constraints (residual \(solve.maxResidual))")
        }

        let ks = try KSketch(frame: frame)
        for c in solved.curves where !c.construction {
            switch c.geometry {
            case .line(let a, let b):
                guard let pa = solved.point(a), let pb = solved.point(b) else { continue }
                try ks.addLine(c.id, pa.position, pb.position)
            case .circle(let center, let radius):
                guard let pc = solved.point(center) else { continue }
                try ks.addCircle(c.id, center: pc.position, radius: radius)
            case .arc(let center, let s, let e):
                guard let pc = solved.point(center), let ps = solved.point(s), let pe = solved.point(e) else { continue }
                let a0 = atan2(ps.y - pc.y, ps.x - pc.x), a1 = atan2(pe.y - pc.y, pe.x - pc.x)
                try ks.addArc(c.id, center: pc.position, radius: vlength(ps.position - pc.position), from: a0, to: a1)
            }
        }
        let regions = try ks.buildRegions()
        let meshes = regions.map { (try? ks.regionMesh($0.index)) ?? Mesh.empty }
        return SketchResult(frame: frame, solved: solved, solve: solve, regions: regions, regionMeshes: meshes,
                            kernelSketch: ks)
    }

    static func extrude(_ f: ExtrudeFeature, _ feature: Feature, _ r: inout RegenResult) throws {
        guard let sk = r.sketches[f.sketch] else { throw KernelError(message: "its sketch failed or is missing") }
        var profiles: [KProfile] = []
        for ref in f.profiles {
            let candidates = sk.regions.filter { $0.tags == ref.tagString }
            guard let region = candidates.min(by: {
                vlength($0.sample - SIMD2(ref.hintU, ref.hintV)) < vlength($1.sample - SIMD2(ref.hintU, ref.hintV))
            }) else { throw KernelError(message: "profile bounded by \(ref.tagString) no longer exists") }
            profiles.append(try sk.kernelSketch.profile(region.index))
        }

        let p = r.parameters
        var distance: Double, back: Double
        switch f.extent {
        case .distance(let d): distance = try p.value(of: d, kind: .length); back = 0
        case .symmetric(let d): distance = try p.value(of: d, kind: .length) / 2; back = distance
        case .twoSides(let d, let b): distance = try p.value(of: d, kind: .length); back = try p.value(of: b, kind: .length)
        }
        let dir = f.flipped ? -sk.frame.normal : sk.frame.normal
        let tool = try KBody.extrude(profiles, direction: dir, distance: distance, back: back, featureID: feature.id)

        if f.operation == .newBody {
            let n = r.bodies.count + 1
            r.bodies.append(BodyResult(id: feature.id, name: "Body\(n)", body: tool))
            return
        }
        guard let index = f.target.flatMap({ t in r.bodies.firstIndex { $0.id == t } }) ?? (r.bodies.isEmpty ? nil : r.bodies.count - 1)
        else { throw KernelError(message: "no body to \(f.operation.rawValue.lowercased())") }
        let op: SKBooleanOp = f.operation == .join ? SK_FUSE : f.operation == .cut ? SK_CUT : SK_COMMON
        r.bodies[index].body = try r.bodies[index].body.boolean(tool, op)
    }

    static func edgeFeature(_ f: EdgeFeature, _ feature: Feature, fillet: Bool, _ r: inout RegenResult) throws {
        let size = try r.parameters.value(of: f.size, kind: .length)
        // Group edges per body, keeping order.
        var order: [FeatureID] = []
        var byBody: [FeatureID: [String]] = [:]
        for e in f.edges {
            if byBody[e.body] == nil { order.append(e.body) }
            byBody[e.body, default: []].append(e.edge)
        }
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

@inline(__always) func vlength(_ v: SIMD2<Double>) -> Double { (v.x * v.x + v.y * v.y).squareRoot() }
