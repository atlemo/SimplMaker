// DXF: reads a drawing's lines, arcs, circles, polylines and ellipses into a sketch, and writes a sketch as DXF for laser
// cutters, CNC and other CAD programs. Only the plain-text form of the format is read; the file is mm unless it says otherwise.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum DXFImport {
    public typealias Result = SVGImport.Result

    /// Most curves one file may make, as for SVG.
    public static var maxCurves: Int { SVGImport.maxCurves }

    public static func sketch(from data: Data) throws -> Result {
        guard data.count < 400_000_000 else { throw SVGImportError("the file is too large") }
        if data.starts(with: Data("AutoCAD Binary DXF".utf8)) {
            throw SVGImportError("this is a binary DXF; save it as an ASCII (text) DXF first")
        }
        let text = String(decoding: data, as: UTF8.self)
        let pairs = Pairs(text)
        guard pairs.looksLikeDXF else { throw SVGImportError("this isn't a DXF file") }
        var reader = Reader(pairs)
        try reader.run()
        guard !reader.pieces.isEmpty else {
            throw SVGImportError("the file has no lines, arcs or circles to import"
                                 + (reader.skipped.isEmpty ? "" : " (\(reader.skipped.sorted().joined(separator: " and ")) can't be imported)"))
        }
        return try reader.finish()
    }

    // MARK: group-code pairs

    /// A DXF file is a list of (group code, value) pairs on alternate lines.
    struct Pairs {
        var codes: [Int] = []
        var values: [String] = []
        var count: Int { codes.count }

        init(_ text: String) {
            var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            if lines.last?.isEmpty == true { lines.removeLast() }
            var i = 0
            while i + 1 < lines.count {
                if let code = Int(lines[i].trimmingCharacters(in: .whitespaces)) {
                    codes.append(code)
                    values.append(lines[i + 1].trimmingCharacters(in: .whitespaces))
                    i += 2
                } else {
                    i += 1  // a stray line: look for the next pair rather than refuse the whole file
                }
            }
        }

        var looksLikeDXF: Bool {
            codes.contains(0) && values.contains("SECTION") && (values.contains("ENTITIES") || values.contains("EOF"))
        }
    }

    // MARK: shapes in the file's units, before the middle is moved to the origin

    enum Piece {
        case line(SIMD2<Double>, SIMD2<Double>)
        case arc(center: SIMD2<Double>, start: SIMD2<Double>, end: SIMD2<Double>)
        case circle(center: SIMD2<Double>, radius: Double)
        case ellipse(center: SIMD2<Double>, major: SIMD2<Double>, minor: SIMD2<Double>)
        case bezier(SIMD2<Double>, SIMD2<Double>, SIMD2<Double>, SIMD2<Double>)
    }

    struct Reader {
        let pairs: Pairs
        var pieces: [Piece] = []
        var skipped: Set<String> = []
        var scale = 1.0

        init(_ pairs: Pairs) { self.pairs = pairs }

        /// One entity's pairs, from its "0" line to just before the next.
        struct Entity {
            var type: String
            var pairs: [(code: Int, value: String)]
            func first(_ code: Int) -> Double? {
                for p in pairs where p.code == code { if let v = Double(p.value), v.isFinite { return v } }
                return nil
            }
            func int(_ code: Int) -> Int? { pairs.first { $0.code == code }.flatMap { Int($0.value) } }
            func all(_ code: Int) -> [Double] { pairs.filter { $0.code == code }.compactMap { Double($0.value) } }
        }

        mutating func run() throws {
            var i = 0
            var section = ""
            // Header: the drawing units.
            var entities: [Entity] = []
            while i < pairs.count {
                if pairs.codes[i] == 0 && pairs.values[i] == "SECTION", i + 1 < pairs.count, pairs.codes[i + 1] == 2 {
                    section = pairs.values[i + 1]
                    i += 2
                    continue
                }
                if pairs.codes[i] == 0 && pairs.values[i] == "ENDSEC" { section = ""; i += 1; continue }
                if pairs.codes[i] == 0 && pairs.values[i] == "EOF" { break }
                if section == "HEADER", pairs.codes[i] == 9, pairs.values[i] == "$INSUNITS", i + 1 < pairs.count,
                   let units = Int(pairs.values[i + 1]) {
                    scale = Self.millimetres(perUnit: units)
                }
                if section == "ENTITIES", pairs.codes[i] == 0 {
                    var entity = Entity(type: pairs.values[i], pairs: [])
                    i += 1
                    while i < pairs.count, pairs.codes[i] != 0 {
                        entity.pairs.append((pairs.codes[i], pairs.values[i]))
                        i += 1
                    }
                    entities.append(entity)
                    if entities.count > 5_000_000 { throw SVGImportError("the drawing is too detailed") }
                    continue
                }
                i += 1
            }
            try convert(entities)
        }

        /// Millimetres in one drawing unit, by the $INSUNITS code. Unitless and unknown codes are taken as mm.
        static func millimetres(perUnit code: Int) -> Double {
            switch code {
            case 1: return 25.4          // inches
            case 2: return 304.8         // feet
            case 3: return 1_609_344     // miles
            case 4: return 1             // millimetres
            case 5: return 10            // centimetres
            case 6: return 1000          // metres
            case 7: return 1_000_000     // kilometres
            case 8: return 25.4e-6       // microinches
            case 9: return 0.0254        // mils
            case 10: return 914.4        // yards
            case 14: return 100          // decimetres
            default: return 1
            }
        }

        mutating func convert(_ entities: [Entity]) throws {
            var i = 0
            while i < entities.count {
                let e = entities[i]
                i += 1
                // Counts as hostile input: a file can name any number of entities, so stop at the cap.
                guard pieces.count <= DXFImport.maxCurves else { throw SVGImportError("the drawing is too detailed (more than \(DXFImport.maxCurves) curves)") }
                // A mirrored drawing plane (extrusion direction z < 0) flips x.
                let flip = (e.first(230) ?? 1) < 0
                func pt(_ x: Double?, _ y: Double?) -> SIMD2<Double>? {
                    guard let x, let y else { return nil }
                    return SIMD2((flip ? -x : x) * scale, y * scale)
                }
                switch e.type {
                case "LINE":
                    if let a = pt(e.first(10), e.first(20)), let b = pt(e.first(11), e.first(21)), a != b { pieces.append(.line(a, b)) }
                case "CIRCLE":
                    if let c = pt(e.first(10), e.first(20)), let r = e.first(40), r > 0 { pieces.append(.circle(center: c, radius: r * scale)) }
                case "ARC":
                    guard let c = pt(e.first(10), e.first(20)), let r = e.first(40), r > 0, let a0 = e.first(50), let a1 = e.first(51) else { continue }
                    var from = a0 * .pi / 180, to = a1 * .pi / 180
                    if flip { (from, to) = (.pi - to, .pi - from) }
                    if abs(to - from).truncatingRemainder(dividingBy: 2 * .pi) < 1e-9 { pieces.append(.circle(center: c, radius: r * scale)); continue }
                    let rs = r * scale
                    pieces.append(.arc(center: c, start: c + rs * SIMD2(cos(from), sin(from)), end: c + rs * SIMD2(cos(to), sin(to))))
                case "LWPOLYLINE":
                    var vertices: [(SIMD2<Double>, Double)] = []
                    var x: Double?, y: Double?
                    func commit() { if let p = pt(x, y) { vertices.append((p, 0)) }; x = nil; y = nil }
                    for p in e.pairs {
                        guard let v = Double(p.value), v.isFinite else { continue }
                        switch p.code {
                        case 10: if x != nil { commit() }; x = v
                        case 20: y = v; commit()
                        case 42: if !vertices.isEmpty { vertices[vertices.count - 1].1 = flip ? -v : v }
                        default: break
                        }
                    }
                    polyline(vertices, closed: (e.int(70) ?? 0) & 1 == 1)
                case "POLYLINE":
                    // Old-style: VERTEX entities follow, up to SEQEND.
                    let closed = (e.int(70) ?? 0) & 1 == 1
                    let isMesh = (e.int(70) ?? 0) & (16 | 64) != 0
                    var vertices: [(SIMD2<Double>, Double)] = []
                    while i < entities.count, entities[i].type != "SEQEND" {
                        if entities[i].type == "VERTEX", !isMesh, let p = pt(entities[i].first(10), entities[i].first(20)) {
                            vertices.append((p, flip ? -(entities[i].first(42) ?? 0) : (entities[i].first(42) ?? 0)))
                        }
                        i += 1
                    }
                    if i < entities.count { i += 1 }
                    if isMesh { skipped.insert("3D meshes") } else { polyline(vertices, closed: closed) }
                case "ELLIPSE":
                    guard let c = pt(e.first(10), e.first(20)), let mx = e.first(11), let my = e.first(21), let ratio = e.first(40), ratio > 0 else { continue }
                    let major = SIMD2((flip ? -mx : mx) * scale, my * scale)
                    let t0 = e.first(41) ?? 0, t1 = e.first(42) ?? 2 * .pi
                    // Some programs write 6.28318 for a whole turn, so this is not strict.
                    guard abs((t1 - t0) - 2 * .pi) < 1e-3 else { skipped.insert("elliptical arcs"); continue }
                    pieces.append(.ellipse(center: c, major: major, minor: ratio * SIMD2(-major.y, major.x)))
                case "SPLINE":
                    if !spline(e, flip: flip) { skipped.insert("splines") }
                case "TEXT", "MTEXT": skipped.insert("text")
                case "INSERT": skipped.insert("blocks")
                case "HATCH": skipped.insert("hatches")
                case "DIMENSION", "LEADER", "MLEADER": skipped.insert("dimensions")
                case "SOLID", "3DFACE", "POINT", "IMAGE", "VIEWPORT", "SEQEND", "VERTEX", "ATTRIB", "ATTDEF": break
                default: skipped.insert("some \(e.type.lowercased()) objects")
                }
            }
        }

        /// A cubic or quadratic B-spline with control points and a clamped knot vector, as Bézier curves. False if it is
        /// some other kind (rational, periodic, only fit points), which is left out.
        mutating func spline(_ e: Entity, flip: Bool) -> Bool {
            let degree = e.int(71) ?? 0
            guard degree == 2 || degree == 3, e.all(41).isEmpty || Set(e.all(41)).count == 1 else { return false }
            var knots: [Double] = [], points: [SIMD2<Double>] = []
            var x: Double?
            for p in e.pairs {
                guard let v = Double(p.value), v.isFinite else { continue }
                switch p.code {
                case 40: knots.append(v)
                case 10: x = v
                case 20: if let px = x { points.append(SIMD2((flip ? -px : px) * scale, v * scale)); x = nil }
                default: break
                }
            }
            guard points.count >= degree + 1, knots.count == points.count + degree + 1, knots == knots.sorted(),
                  knots[0] == knots[degree], knots[knots.count - 1] == knots[knots.count - 1 - degree],
                  knots[degree] < knots[knots.count - 1 - degree], points.count <= 10_000 else { return false }
            var u = knots, pts = points
            // Insert each inner knot until it has the full multiplicity: then every span is a Bézier curve.
            var i = degree + 1
            while i < u.count - degree - 1 {
                let value = u[i]
                var multiplicity = 0
                while i + multiplicity < u.count - degree - 1, u[i + multiplicity] == value { multiplicity += 1 }
                for _ in 0..<(degree - multiplicity) where multiplicity < degree {
                    // The span the knot is in: the last knot not above it.
                    let k = (0..<u.count - 1).last { u[$0] <= value && u[$0] < u[$0 + 1] } ?? degree
                    var q: [SIMD2<Double>] = []
                    let s0 = u[(k - degree + 1)...k].filter { $0 == value }.count
                    for j in 0...pts.count {
                        if j <= k - degree { q.append(pts[j]) }
                        else if j <= k - s0 {
                            let alpha = (value - u[j]) / (u[j + degree] - u[j])
                            q.append(alpha * pts[j] + (1 - alpha) * pts[j - 1])
                        } else { q.append(pts[j - 1]) }
                    }
                    pts = q
                    u.insert(value, at: k + 1)
                    multiplicity += 1
                }
                i += multiplicity
            }
            guard (pts.count - 1) % degree == 0 else { return false }
            var start = 0
            while start + degree < pts.count {
                let a = pts[start], b = pts[start + degree]
                if degree == 3 {
                    pieces.append(.bezier(a, pts[start + 1], pts[start + 2], b))
                } else {
                    let m = pts[start + 1]
                    pieces.append(.bezier(a, a + (m - a) * (2.0 / 3), b + (m - b) * (2.0 / 3), b))
                }
                start += degree
            }
            return true
        }

        /// Segments of a polyline; a bulge makes a segment an arc.
        mutating func polyline(_ v: [(SIMD2<Double>, Double)], closed: Bool) {
            guard v.count >= 2 else { return }
            let last = closed ? v.count : v.count - 1
            for k in 0..<last {
                let (a, bulge) = v[k]
                let b = v[(k + 1) % v.count].0
                guard a != b else { continue }
                if abs(bulge) < 1e-9 { pieces.append(.line(a, b)); continue }
                let chord = vlen(b - a)
                let u = (b - a) / chord
                let normal = SIMD2(-u.y, u.x)
                let h = chord * (1 - bulge * bulge) / (4 * bulge)
                let center = (a + b) / 2 + normal * h
                pieces.append(bulge > 0 ? .arc(center: center, start: a, end: b) : .arc(center: center, start: b, end: a))
            }
        }

        // MARK: into a sketch

        func finish() throws -> Result {
            var lo = SIMD2(Double.infinity, Double.infinity), hi = -lo
            func grow(_ p: SIMD2<Double>) { lo = pointwiseMin(lo, p); hi = pointwiseMax(hi, p) }
            for piece in pieces {
                switch piece {
                case .line(let a, let b): grow(a); grow(b)
                case .circle(let c, let r): grow(c - SIMD2(r, r)); grow(c + SIMD2(r, r))
                case .arc(let c, let a, let b):
                    grow(a); grow(b)
                    let r = vlen(a - c)
                    for k in 0..<4 {
                        let dir = SIMD2(cos(Double(k) * .pi / 2), sin(Double(k) * .pi / 2))
                        if Self.arcContains(center: c, start: a, end: b, direction: dir) { grow(c + dir * r) }
                    }
                case .bezier(let a, let b, let c, let d):
                    for q in Bezier.flatten([a, b, c, d], steps: 16) { grow(q) }
                case .ellipse(let c, let major, let minor):
                    let half = SIMD2((major.x * major.x + minor.x * minor.x).squareRoot(), (major.y * major.y + minor.y * minor.y).squareRoot())
                    grow(c - half); grow(c + half)
                }
            }
            guard lo.x.isFinite, hi.x.isFinite, lo.y.isFinite, hi.y.isFinite else { throw SVGImportError("the drawing has no usable coordinates") }
            let mid = (lo + hi) / 2
            var sketch = Sketch()
            var used: Set<EntityID> = ["origin"]
            func fresh() -> EntityID {
                var id = IDs.make()
                while !used.insert(id).inserted { id = IDs.make() }
                return id
            }
            // Ends that meet in the file share one point, as they do in an SVG import.
            var pointIDs: [SIMD2<Int64>: EntityID] = [:]
            func newPoint(_ p: SIMD2<Double>) -> EntityID { sketch.addPoint(p.x - mid.x, p.y - mid.y, id: fresh()) }
            func endpoint(_ p: SIMD2<Double>) -> EntityID {
                let q = p - mid
                let key = SIMD2(Int64((max(min(q.x, 1e12), -1e12) * 1e4).rounded()), Int64((max(min(q.y, 1e12), -1e12) * 1e4).rounded()))
                if let id = pointIDs[key] { return id }
                let id = newPoint(p)
                pointIDs[key] = id
                return id
            }
            for piece in pieces {
                switch piece {
                case .line(let a, let b):
                    let pa = endpoint(a), pb = endpoint(b)
                    if pa != pb { sketch.addLine(pa, pb, id: fresh()) }
                case .arc(let c, let a, let b):
                    let pa = endpoint(a), pb = endpoint(b)
                    if pa != pb { sketch.addArc(center: newPoint(c), start: pa, end: pb, id: fresh()) }
                case .circle(let c, let r):
                    sketch.addCircle(center: newPoint(c), radius: r, id: fresh())
                case .bezier(let a, let c1, let c2, let b):
                    let pa = endpoint(a), pb = endpoint(b)
                    if pa == pb, vlen(c1 - a) < 1e-6, vlen(c2 - a) < 1e-6 { continue }
                    sketch.addBezier(start: pa, control1: newPoint(c1), control2: newPoint(c2), end: pb, id: fresh())
                case .ellipse(let c, let major, let minor):
                    sketch.curves.append(SketchCurve(id: fresh(), .ellipse(center: newPoint(c), major: newPoint(c + major), minor: newPoint(c + minor))))
                }
            }
            return Result(sketch: sketch, width: hi.x - lo.x, height: hi.y - lo.y, curveCount: sketch.curves.count, skipped: skipped.sorted())
        }

        static func arcContains(center c: SIMD2<Double>, start a: SIMD2<Double>, end b: SIMD2<Double>, direction d: SIMD2<Double>) -> Bool {
            func angle(_ v: SIMD2<Double>) -> Double { atan2(v.y, v.x) }
            let a0 = angle(a - c)
            var sweep = angle(b - c) - a0
            if sweep <= 0 { sweep += 2 * .pi }
            var t = angle(d) - a0
            if t < 0 { t += 2 * .pi }
            return t <= sweep
        }
    }
}

/// Writes a sketch as an ASCII DXF (release 12, which everything reads): lines, arcs and circles as themselves, curves that
/// DXF has no plain form for (Bézier curves, ellipses) as fine polylines. Construction geometry is left out.
public enum DXFExport {
    public static func data(_ sketch: Sketch) -> Data { Data(text(sketch).utf8) }

    public static func text(_ sketch: Sketch) -> String {
        var out = "0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1009\n9\n$INSUNITS\n70\n4\n0\nENDSEC\n"
        // A layer table with layer 0, which some readers complain about missing.
        out += "0\nSECTION\n2\nTABLES\n0\nTABLE\n2\nLAYER\n70\n1\n0\nLAYER\n2\n0\n70\n0\n62\n7\n6\nCONTINUOUS\n0\nENDTAB\n0\nENDSEC\n"
        out += "0\nSECTION\n2\nENTITIES\n"
        let points = Dictionary(sketch.points.map { ($0.id, $0.position) }, uniquingKeysWith: { a, _ in a })
        func p(_ id: EntityID) -> SIMD2<Double>? { points[id] }

        for curve in sketch.curves where !curve.construction {
            switch curve.geometry {
            case .line(let a, let b):
                if let a = p(a), let b = p(b) { out += line(a, b) }
            case .circle(let c, let r):
                if let c = p(c) { out += "0\nCIRCLE\n8\n0\n10\n\(n(c.x))\n20\n\(n(c.y))\n30\n0\n40\n\(n(r))\n" }
            case .arc(let c, let s, let e):
                if let c = p(c), let s = p(s), let e = p(e) {
                    let a0 = atan2(s.y - c.y, s.x - c.x), a1 = atan2(e.y - c.y, e.x - c.x)
                    func deg(_ a: Double) -> Double { var d = a * 180 / .pi; if d < 0 { d += 360 }; return d }
                    out += "0\nARC\n8\n0\n10\n\(n(c.x))\n20\n\(n(c.y))\n30\n0\n40\n\(n(vlen(s - c)))\n50\n\(n(deg(a0)))\n51\n\(n(deg(a1)))\n"
                }
            case .bezier(let a, let c1, let c2, let b):
                if let a = p(a), let c1 = p(c1), let c2 = p(c2), let b = p(b) { out += polyline(Bezier.flatten([a, c1, c2, b], steps: 48), closed: false) }
            case .ellipse(let c, let major, let minor):
                if let c = p(c), let mj = p(major), let mn = p(minor) {
                    let u = mj - c, v = mn - c
                    let steps = 120
                    let ring = (0..<steps).map { k -> SIMD2<Double> in
                        let t = 2 * Double.pi * Double(k) / Double(steps)
                        return c + u * cos(t) + v * sin(t)
                    }
                    out += polyline(ring, closed: true)
                }
            }
        }
        out += "0\nENDSEC\n0\nEOF\n"
        return out
    }

    private static func line(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> String {
        "0\nLINE\n8\n0\n10\n\(n(a.x))\n20\n\(n(a.y))\n30\n0\n11\n\(n(b.x))\n21\n\(n(b.y))\n31\n0\n"
    }

    private static func polyline(_ points: [SIMD2<Double>], closed: Bool) -> String {
        var s = "0\nPOLYLINE\n8\n0\n66\n1\n70\n\(closed ? 1 : 0)\n"
        for q in points { s += "0\nVERTEX\n8\n0\n10\n\(n(q.x))\n20\n\(n(q.y))\n30\n0\n" }
        return s + "0\nSEQEND\n8\n0\n"
    }

    private static func n(_ v: Double) -> String {
        v.isFinite ? String(format: "%.6f", v == 0 ? 0 : v) : "0.000000"
    }
}
