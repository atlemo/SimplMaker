// Spur gear outlines (the sketch Gear tool): the involute tooth profile, fitted with cubic Béziers.
//
// A flank is a piece of an involute of the base circle. It is cut into a few cubic Béziers whose end
// points and end tangents are exact (a Hermite fit in the involute's unrolling angle), so a segment can't
// overshoot, and `flankTolerance` bounds how far the fitted flank strays from the true involute.
// Tips and roots are arcs about the gear's centre. Where the root circle lies
// inside the base circle (below about 41 teeth at 20°): the flank then starts with a short radial line down
// to the root. There is no undercut or root fillet.
// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation

public struct GearSpec: Equatable, Sendable {
    public var teeth: Int
    /// Tooth size: pitch diameter / teeth, in mm. Gears that mesh share a module and a pressure angle.
    public var module: Double
    /// Radians. 20° is the usual value.
    public var pressureAngle: Double
    /// How much thinner each tooth is made at the pitch circle, in mm, so printed gears can turn.
    public var backlash: Double
    /// Diameter of the hole through the centre, in mm; 0 for none.
    public var boreDiameter: Double

    public init(teeth: Int, module: Double, pressureAngle: Double = 20 * .pi / 180, backlash: Double = 0, boreDiameter: Double = 0) {
        self.teeth = teeth; self.module = module; self.pressureAngle = pressureAngle
        self.backlash = backlash; self.boreDiameter = boreDiameter
    }

    public static let minTeeth = 6, maxTeeth = 200

    public var pitchRadius: Double { module * Double(teeth) / 2 }
    public var baseRadius: Double { pitchRadius * cos(pressureAngle) }
    public var tipRadius: Double { pitchRadius + module }
    /// 1.25 modules below the pitch circle. When that is only just under the base circle (a 40-tooth gear at 20°
    /// is 0.04 mm under) the root stays on the base circle, so there is no sliver of a radial line to draw.
    public var rootRadius: Double {
        let r = pitchRadius - 1.25 * module
        return r < baseRadius && baseRadius - r < 0.05 * module ? baseRadius : r
    }
    /// Distance between the centres of two gears that mesh: the sum of their pitch radii, which is (teeth + other teeth) / 2 · module when the modules match.
    public func centerDistance(with other: GearSpec) -> Double { (pitchRadius + other.pitchRadius) }
}

public struct GearError: Error, Equatable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public enum GearProfile {
    /// One piece of the outline. Pieces follow each other counter-clockwise and each starts where the last ended.
    public enum Piece: Equatable, Sendable {
        case line(SIMD2<Double>, SIMD2<Double>)
        /// Counter-clockwise about the gear's centre.
        case arc(from: SIMD2<Double>, to: SIMD2<Double>)
        /// Cubic Bézier: start, two handles, end.
        case bezier(SIMD2<Double>, SIMD2<Double>, SIMD2<Double>, SIMD2<Double>)

        var start: SIMD2<Double> {
            switch self {
            case .line(let a, _), .arc(let a, _), .bezier(let a, _, _, _): return a
            }
        }
        var end: SIMD2<Double> {
            switch self {
            case .line(_, let b), .arc(_, let b), .bezier(_, _, _, let b): return b
            }
        }
    }

    /// How far (mm) a fitted flank may stray from the true involute.
    public static let flankTolerance = 0.002

    /// The closed outline with the gear's centre at the origin and the first tooth on the +x axis.
    public static func outline(_ spec: GearSpec) throws -> [Piece] {
        let z = spec.teeth
        guard z >= GearSpec.minTeeth, z <= GearSpec.maxTeeth else {
            throw GearError("a gear needs \(GearSpec.minTeeth) to \(GearSpec.maxTeeth) teeth (not \(z))")
        }
        guard spec.module > 0 else { throw GearError("the module must be more than 0") }
        guard spec.pressureAngle > 0.1, spec.pressureAngle < 0.6 else {
            throw GearError("the pressure angle must be between 6° and 34°")
        }
        let rb = spec.baseRadius, ra = spec.tipRadius, rf = spec.rootRadius, r = spec.pitchRadius
        guard spec.boreDiameter / 2 < rf - 0.5 * spec.module else { throw GearError("the hole is too big for this gear") }

        func inv(_ t: Double) -> Double { t - atan(t) }  // polar angle of the involute at unrolling angle t
        func unroll(_ radius: Double) -> Double { max((radius / rb) * (radius / rb) - 1, 0).squareRoot() }

        // Half the angle a tooth spans at the base circle (the involute starts there).
        let halfBase = .pi / (2 * Double(z)) - spec.backlash / (2 * r) + inv(tan(spec.pressureAngle))
        let undercut = rf < rb - 1e-9
        let t0 = undercut ? 0 : unroll(rf), t1 = unroll(ra)
        let halfTip = halfBase - inv(t1)
        guard halfTip > 0.002 else { throw GearError("the teeth would come to a point: use more teeth or a smaller pressure angle") }
        let halfRoot = halfBase - inv(t0)
        guard halfRoot < .pi / Double(z) - 0.002 else { throw GearError("the teeth are too thin at the root: lower the backlash") }

        func polar(_ radius: Double, _ angle: Double) -> SIMD2<Double> { SIMD2(radius * cos(angle), radius * sin(angle)) }
        func rotate(_ p: SIMD2<Double>, _ a: Double) -> SIMD2<Double> {
            SIMD2(p.x * cos(a) - p.y * sin(a), p.x * sin(a) + p.y * cos(a))
        }

        // The right flank (the one at the smaller angle) from root to tip, as Béziers.
        func involute(_ t: Double) -> SIMD2<Double> { rotate(SIMD2(rb * (cos(t) + t * sin(t)), rb * (sin(t) - t * cos(t))), -halfBase) }
        func velocity(_ t: Double) -> SIMD2<Double> { rotate(SIMD2(rb * t * cos(t), rb * t * sin(t)), -halfBase) }
        func segments(_ n: Int) -> [[SIMD2<Double>]] {
            (0..<n).map { i in
                let a = t0 + (t1 - t0) * Double(i) / Double(n), b = t0 + (t1 - t0) * Double(i + 1) / Double(n)
                let h = (b - a) / 3
                return [involute(a), involute(a) + velocity(a) * h, involute(b) - velocity(b) * h, involute(b)]
            }
        }
        func deviation(_ segs: [[SIMD2<Double>]]) -> Double {
            var worst = 0.0
            for s in segs {
                for k in 0...16 {
                    let q = Bezier.point(s, Double(k) / 16)
                    let rho = vlen(q)
                    guard rho > rb else { continue }
                    var d = atan2(q.y, q.x) - (inv(unroll(rho)) - halfBase)
                    d = atan2(sin(d), cos(d))
                    worst = max(worst, abs(d) * rho)
                }
            }
            return worst
        }
        var flank = segments(1)
        for n in 1...16 {
            flank = segments(n)
            if deviation(flank) < flankTolerance { break }
        }

        // One tooth, then the root arc to the next one.
        let rootAngle = undercut ? -halfBase : -halfRoot
        let rootRight = polar(rf, rootAngle)
        let mirror = { (p: SIMD2<Double>) in SIMD2(p.x, -p.y) }
        var tooth: [Piece] = []
        if undercut { tooth.append(.line(rootRight, flank[0][0])) }
        for s in flank { tooth.append(.bezier(s[0], s[1], s[2], s[3])) }
        let tipRight = flank[flank.count - 1][3]
        tooth.append(.arc(from: tipRight, to: mirror(tipRight)))
        for s in flank.reversed() { tooth.append(.bezier(mirror(s[3]), mirror(s[2]), mirror(s[1]), mirror(s[0]))) }
        if undercut { tooth.append(.line(mirror(flank[0][0]), mirror(rootRight))) }

        let step = 2 * Double.pi / Double(z)
        var out: [Piece] = []
        for k in 0..<z {
            let a = step * Double(k)
            func turned(_ p: Piece) -> Piece {
                switch p {
                case .line(let p, let q): return .line(rotate(p, a), rotate(q, a))
                case .arc(let p, let q): return .arc(from: rotate(p, a), to: rotate(q, a))
                case .bezier(let p, let c, let d, let q): return .bezier(rotate(p, a), rotate(c, a), rotate(d, a), rotate(q, a))
                }
            }
            out.append(contentsOf: tooth.map(turned))
            // Root arc: from this tooth's left root to the next tooth's right root.
            let from = rotate(mirror(rootRight), a), to = rotate(rootRight, a + step)
            out.append(.arc(from: from, to: to))
        }
        return out
    }

    /// The most the Bézier flanks stray from the true involute, in mm (for tests and diagnostics).
    public static func flankError(_ spec: GearSpec) throws -> Double {
        let rb = spec.baseRadius
        let halfBase = .pi / (2 * Double(spec.teeth)) - spec.backlash / (2 * spec.pitchRadius) + (tan(spec.pressureAngle) - spec.pressureAngle)
        var worst = 0.0
        for piece in try outline(spec) {
            guard case .bezier(let a, let b, let c, let d) = piece else { continue }
            for k in 0...32 {
                let q = Bezier.point([a, b, c, d], Double(k) / 32)
                let rho = vlen(q)
                guard rho > rb else { continue }
                let t = ((rho / rb) * (rho / rb) - 1).squareRoot()
                // Right flank has polar angle inv(t) - halfBase; left flank is its mirror image about the tooth axis.
                let step = 2 * Double.pi / Double(spec.teeth)
                var phi = atan2(q.y, q.x)
                phi -= (phi / step).rounded() * step  // angle from the nearest tooth axis, -step/2 ... step/2
                let expected = (t - atan(t)) - halfBase
                worst = max(worst, min(abs(phi - expected), abs(phi + expected)) * rho)
            }
        }
        return worst
    }
}

/// A gear in a sketch: a stored definition, like a pattern. The outline itself is generated (see
/// `Sketch.refreshGenerated`): fixed points and curves whose ids start with the gear's id and a "~", which the
/// solver, snapping and picking leave alone. Changing an expression (or a parameter it uses) makes the
/// outline again. The centre is an ordinary sketch point, so it can be dragged, dimensioned and constrained.
public struct SketchGearDef: Codable, Hashable, Sendable, Identifiable {
    public var id: EntityID
    /// The sketch point the gear is turned about.
    public var center: EntityID
    /// Whether the Gear tool made the centre point (so deleting the gear takes it too).
    public var ownsCenter: Bool
    public var teeth: String, module: String, pressureAngle: String, backlash: String, bore: String

    public init(id: EntityID = IDs.make(), center: EntityID = "origin", ownsCenter: Bool = false, teeth: String = "20", module: String = "1.5 mm",
                pressureAngle: String = "20 deg", backlash: String = "0 mm", bore: String = "0 mm") {
        self.id = id; self.center = center; self.ownsCenter = ownsCenter
        self.teeth = teeth; self.module = module; self.pressureAngle = pressureAngle; self.backlash = backlash; self.bore = bore
    }

    /// The gear the expressions come to, or what is wrong with them.
    public func spec(_ p: ParameterValues) throws -> GearSpec {
        let z = try p.value(of: teeth, kind: .none)
        guard abs(z - z.rounded()) < 1e-9, z >= Double(GearSpec.minTeeth), z <= Double(GearSpec.maxTeeth) else {
            throw GearError("the teeth must be a whole number from \(GearSpec.minTeeth) to \(GearSpec.maxTeeth) (not \(teeth))")
        }
        let bore = try p.value(of: bore, kind: .length)
        guard bore >= 0 else { throw GearError("the bore can't be negative") }
        return GearSpec(teeth: Int(z.rounded()), module: try p.value(of: module, kind: .length),
                        pressureAngle: try p.value(of: pressureAngle, kind: .angle), backlash: try p.value(of: backlash, kind: .length),
                        boreDiameter: bore)
    }
}

extension Sketch {
    /// The gear that made a generated entity, if one did.
    public func gear(ofGenerated id: EntityID) -> EntityID? {
        guard let g = Sketch.pattern(ofGenerated: id), gears.contains(where: { $0.id == g }) else { return nil }
        return g
    }

    /// Makes the outline of every gear again (see `refreshGenerated`). A gear whose centre is gone is dropped.
    mutating func refreshGears(_ parameters: ParameterValues) -> [EntityID: String] {
        let present = Set(points.map(\.id))
        gears.removeAll { !present.contains($0.center) }
        var problems: [EntityID: String] = [:]
        for def in gears {
            do { try generate(def, spec: try def.spec(parameters)) } catch { problems[def.id] = "gear: \(error)" }
        }
        return problems
    }

    private mutating func generate(_ def: SketchGearDef, spec: GearSpec) throws {
        guard let c = point(def.center)?.position else { return }
        let pieces = try GearProfile.outline(spec)
        let prefix = def.id + "~"
        func fixed(_ name: String, _ p: SIMD2<Double>) -> EntityID {
            points.append(SketchPoint(id: prefix + name, x: p.x + c.x, y: p.y + c.y, fixed: true)); return prefix + name
        }
        let anchors = pieces.enumerated().map { fixed("p\($0.offset)", $0.element.start) }
        for (i, piece) in pieces.enumerated() {
            let a = anchors[i], b = anchors[(i + 1) % pieces.count], id = prefix + "c\(i)"
            switch piece {
            case .line: curves.append(SketchCurve(id: id, .line(start: a, end: b)))
            case .arc: curves.append(SketchCurve(id: id, .arc(center: def.center, start: a, end: b)))
            case .bezier(_, let h1, let h2, _):
                curves.append(SketchCurve(id: id, .bezier(start: a, control1: fixed("h\(i)a", h1), control2: fixed("h\(i)b", h2), end: b)))
            }
        }
        if spec.boreDiameter > 0 { curves.append(SketchCurve(id: prefix + "bore", .circle(center: def.center, radius: spec.boreDiameter / 2))) }
    }

    /// Adds a gear to the sketch and draws it. Returns the new definition, or what is wrong with it.
    @discardableResult
    public mutating func addGear(_ def: SketchGearDef, _ parameters: ParameterValues = ParameterValues()) throws -> SketchGearDef {
        try generate(def, spec: try def.spec(parameters))  // refuses a gear that can't be made
        takeGeneratedGear(def.id)
        gears.append(def)
        _ = refreshGenerated(parameters)
        return def
    }

    private mutating func takeGeneratedGear(_ id: EntityID) {
        points.removeAll { $0.id.hasPrefix(id + "~") }
        curves.removeAll { $0.id.hasPrefix(id + "~") }
    }

    /// Takes a gear out, with the centre point if the Gear tool made it and nothing else uses it.
    public mutating func removeGear(_ id: EntityID) {
        guard let def = gears.first(where: { $0.id == id }) else { return }
        gears.removeAll { $0.id == id }
        takeGeneratedGear(id)
        let used = curves.contains { !Sketch.isGenerated($0.id) && pointIDs(of: $0).contains(def.center) }
            || gears.contains { $0.center == def.center } || patterns.contains { $0.center == def.center }
        if def.ownsCenter, def.center != "origin", !used { delete([def.center]) }
    }
}
