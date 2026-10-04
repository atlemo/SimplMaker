// SVG import: reads an SVG file's shapes and paths into a sketch (lines, arcs, circles and Bézier curves).
// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct SVGImportError: Error, Equatable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public enum SVGImport {
    public struct Result: Sendable {
        /// The shapes as a sketch in millimetres, y up, with the drawing's middle on the origin.
        public var sketch: Sketch
        /// Size of the drawing in millimetres.
        public var width: Double
        public var height: Double
        /// How many curves were made.
        public var curveCount: Int
        /// Things in the file that don't become geometry ("text", "images").
        public var skipped: [String]
    }

    /// Most curves one file may make; beyond this a sketch gets too slow to work in.
    public static let maxCurves = 20_000

    public static func sketch(from data: Data) throws -> Result {
        let root = try SVGElement.parse(data)
        guard root.name == "svg" else { throw SVGImportError("this isn't an SVG file") }
        var builder = Builder()
        builder.run(root)
        guard !builder.pieces.isEmpty else {
            throw SVGImportError("the file has no shapes or paths to import"
                                 + (builder.skipped.isEmpty ? "" : " (\(builder.skipped.sorted().joined(separator: " and ")) can't be imported)"))
        }
        return try builder.finish()
    }

    // MARK: geometry in millimetres, y up

    /// A run of connected segments; `closed` when the last one returns to the first one's start.
    fileprivate struct Path {
        var segments: [Segment] = []
        var closed = false
    }

    fileprivate enum Segment {
        case line(SIMD2<Double>, SIMD2<Double>)
        case cubic(SIMD2<Double>, SIMD2<Double>, SIMD2<Double>, SIMD2<Double>)
        /// Counter-clockwise from start to end around the centre (already flipped where the drawing runs clockwise).
        case arc(center: SIMD2<Double>, start: SIMD2<Double>, end: SIMD2<Double>)
        case circle(center: SIMD2<Double>, radius: Double)

        var start: SIMD2<Double> {
            switch self {
            case .line(let a, _), .cubic(let a, _, _, _), .arc(_, let a, _): return a
            case .circle(let c, let r): return c + SIMD2(r, 0)
            }
        }
        var end: SIMD2<Double> {
            switch self {
            case .line(_, let b), .cubic(_, _, _, let b), .arc(_, _, let b): return b
            case .circle(let c, let r): return c + SIMD2(r, 0)
            }
        }
    }

    // MARK: affine transforms

    fileprivate struct Matrix {
        var a = 1.0, b = 0.0, c = 0.0, d = 1.0, e = 0.0, f = 0.0
        static let identity = Matrix()
        static func translate(_ x: Double, _ y: Double) -> Matrix { Matrix(a: 1, b: 0, c: 0, d: 1, e: x, f: y) }
        static func scale(_ x: Double, _ y: Double) -> Matrix { Matrix(a: x, b: 0, c: 0, d: y, e: 0, f: 0) }
        static func rotate(_ degrees: Double) -> Matrix {
            let t = degrees * .pi / 180
            return Matrix(a: cos(t), b: sin(t), c: -sin(t), d: cos(t), e: 0, f: 0)
        }
        /// self applied after `o` (so `parent.then(child)` maps child coordinates through both).
        func concat(_ o: Matrix) -> Matrix {
            Matrix(a: a * o.a + c * o.b, b: b * o.a + d * o.b,
                   c: a * o.c + c * o.d, d: b * o.c + d * o.d,
                   e: a * o.e + c * o.f + e, f: b * o.e + d * o.f + f)
        }
        func apply(_ p: SIMD2<Double>) -> SIMD2<Double> { SIMD2(a * p.x + c * p.y + e, b * p.x + d * p.y + f) }
        var determinant: Double { a * d - b * c }
        /// The scale factor if this only rotates, mirrors and scales evenly (so circles stay circles).
        var uniformScale: Double? {
            let sx = (a * a + b * b).squareRoot(), sy = (c * c + d * d).squareRoot()
            guard sx > 1e-12, abs(sx - sy) <= 1e-9 * sx, abs(a * c + b * d) <= 1e-9 * sx * sy else { return nil }
            return sx
        }

        /// Parses a transform list: "translate(10 20) rotate(45)". Nil if malformed.
        static func parse(_ text: String) -> Matrix? {
            var m = Matrix.identity
            var scanner = SVGScanner(text)
            while true {
                scanner.skipSeparators()
                if scanner.atEnd { return m }
                guard let name = scanner.word(), scanner.consume("(") else { return nil }
                var args: [Double] = []
                while true {
                    scanner.skipSeparators()
                    if scanner.consume(")") { break }
                    guard let n = scanner.number() else { return nil }
                    args.append(n)
                }
                let t: Matrix
                switch (name, args.count) {
                case ("matrix", 6): t = Matrix(a: args[0], b: args[1], c: args[2], d: args[3], e: args[4], f: args[5])
                case ("translate", 1): t = .translate(args[0], 0)
                case ("translate", 2): t = .translate(args[0], args[1])
                case ("scale", 1): t = .scale(args[0], args[0])
                case ("scale", 2): t = .scale(args[0], args[1])
                case ("rotate", 1): t = .rotate(args[0])
                case ("rotate", 3): t = Matrix.translate(args[1], args[2]).concat(.rotate(args[0])).concat(.translate(-args[1], -args[2]))
                case ("skewX", 1): t = Matrix(a: 1, b: 0, c: tan(args[0] * .pi / 180), d: 1, e: 0, f: 0)
                case ("skewY", 1): t = Matrix(a: 1, b: tan(args[0] * .pi / 180), c: 0, d: 1, e: 0, f: 0)
                default: return nil
                }
                m = m.concat(t)
            }
        }
    }

    // MARK: walking the document

    fileprivate struct Builder {
        var pieces: [Path] = []
        var skipped: Set<String> = []
        /// User units → millimetres, with y flipped (SVG's y points down).
        var root = Matrix.identity
        var ids: [String: SVGElement] = [:]
        var useDepth = 0

        mutating func run(_ svg: SVGElement) {
            collectIDs(svg)
            // Size: width/height carry units; the viewBox says how many user units that spans.
            let vb = svg.attributes["viewBox"].flatMap { SVGScanner.numbers($0) }.flatMap { $0.count == 4 ? $0 : nil }
            let w = svg.attributes["width"].flatMap { Self.length($0) }
            let h = svg.attributes["height"].flatMap { Self.length($0) }
            let pxToMM = 25.4 / 96
            var scale = pxToMM
            if let vb, vb[2] > 0, vb[3] > 0 {
                var candidates: [Double] = []
                if let w { candidates.append(w / vb[2]) }
                if let h { candidates.append(h / vb[3]) }
                scale = candidates.min() ?? pxToMM
            }
            root = Matrix.scale(scale, -scale)
            if let vb { root = root.concat(.translate(-vb[0], -vb[1])) }
            for child in svg.children { visit(child, root, inherited: Style()) }
        }

        mutating func collectIDs(_ e: SVGElement) {
            if let id = e.attributes["id"] { ids[id] = e }
            for c in e.children { collectIDs(c) }
        }

        /// A length as millimetres (nil for percentages and garbage).
        static func length(_ text: String) -> Double? {
            var s = SVGScanner(text)
            s.skipSeparators()
            guard let n = s.number() else { return nil }
            switch s.rest.trimmingCharacters(in: .whitespaces).lowercased() {
            case "", "px": return n * 25.4 / 96
            case "mm": return n
            case "cm": return n * 10
            case "in": return n * 25.4
            case "pt": return n * 25.4 / 72
            case "pc": return n * 25.4 / 6
            case "q": return n * 0.25
            default: return nil
            }
        }

        struct Style {
            var hidden = false
        }

        mutating func visit(_ e: SVGElement, _ parent: Matrix, inherited: Style) {
            var style = inherited
            let css = e.style
            if e.attributes["display"] == "none" || css["display"] == "none" { return }
            if let v = css["visibility"] ?? e.attributes["visibility"] { style.hidden = v == "hidden" || v == "collapse" }
            var m = parent
            if let t = e.attributes["transform"] {
                guard let tm = Matrix.parse(t) else { return }
                m = m.concat(tm)
            }
            switch e.name {
            case "g", "a", "svg", "switch":
                for c in e.children { visit(c, m, inherited: style) }
            case "use":
                guard useDepth < 8, let ref = (e.attributes["href"] ?? e.attributes["xlink:href"]), ref.hasPrefix("#"),
                      let target = ids[String(ref.dropFirst())] else { return }
                let dx = e.number("x") ?? 0, dy = e.number("y") ?? 0
                useDepth += 1
                let placed = m.concat(.translate(dx, dy))
                if target.name == "symbol" {
                    for c in target.children { visit(c, placed, inherited: style) }
                } else {
                    visit(target, placed, inherited: style)
                }
                useDepth -= 1
            case "text", "tspan": skipped.insert("text")
            case "image": skipped.insert("images")
            case "path":
                guard !style.hidden else { return }
                pieces += PathData.parse(e.attributes["d"] ?? "", m)
            case "rect": if !style.hidden { rect(e, m) }
            case "circle":
                guard !style.hidden, let r = e.number("r"), r > 0 else { return }
                ellipse(cx: e.number("cx") ?? 0, cy: e.number("cy") ?? 0, rx: r, ry: r, m)
            case "ellipse":
                guard !style.hidden, let rx = e.number("rx"), let ry = e.number("ry"), rx > 0, ry > 0 else { return }
                ellipse(cx: e.number("cx") ?? 0, cy: e.number("cy") ?? 0, rx: rx, ry: ry, m)
            case "line":
                guard !style.hidden else { return }
                let a = m.apply(SIMD2(e.number("x1") ?? 0, e.number("y1") ?? 0))
                let b = m.apply(SIMD2(e.number("x2") ?? 0, e.number("y2") ?? 0))
                pieces.append(Path(segments: [.line(a, b)]))
            case "polyline", "polygon":
                guard !style.hidden, let n = SVGScanner.numbers(e.attributes["points"] ?? ""), n.count >= 4 else { return }
                let pts = stride(from: 0, to: n.count - 1, by: 2).map { m.apply(SIMD2(n[$0], n[$0 + 1])) }
                var path = Path()
                for i in 1..<pts.count { path.segments.append(.line(pts[i - 1], pts[i])) }
                if e.name == "polygon" { path.segments.append(.line(pts[pts.count - 1], pts[0])); path.closed = true }
                pieces.append(path)
            default:
                break  // defs, symbol, clipPath, style, metadata, gradients …
            }
        }

        mutating func rect(_ e: SVGElement, _ m: Matrix) {
            let x = e.number("x") ?? 0, y = e.number("y") ?? 0
            guard let w = e.number("width"), let h = e.number("height"), w > 0, h > 0 else { return }
            var rx = e.number("rx"), ry = e.number("ry")
            if rx == nil { rx = ry }
            if ry == nil { ry = rx }
            let cx = min(max(rx ?? 0, 0), w / 2), cy = min(max(ry ?? 0, 0), h / 2)
            var path = Path()
            path.closed = true
            if cx <= 0 || cy <= 0 {
                let c = [SIMD2(x, y), SIMD2(x + w, y), SIMD2(x + w, y + h), SIMD2(x, y + h)].map { m.apply($0) }
                for i in 0..<4 { path.segments.append(.line(c[i], c[(i + 1) % 4])) }
            } else {
                // Straight sides joined by quarter-ellipse corners, starting on the top edge.
                var pd = PathBuilder(m)
                pd.move(SIMD2(x + cx, y))
                pd.line(SIMD2(x + w - cx, y))
                pd.arc(rx: cx, ry: cy, rotation: 0, large: false, sweep: true, to: SIMD2(x + w, y + cy))
                pd.line(SIMD2(x + w, y + h - cy))
                pd.arc(rx: cx, ry: cy, rotation: 0, large: false, sweep: true, to: SIMD2(x + w - cx, y + h))
                pd.line(SIMD2(x + cx, y + h))
                pd.arc(rx: cx, ry: cy, rotation: 0, large: false, sweep: true, to: SIMD2(x, y + h - cy))
                pd.line(SIMD2(x, y + cy))
                pd.arc(rx: cx, ry: cy, rotation: 0, large: false, sweep: true, to: SIMD2(x + cx, y))
                pd.close()
                path = pd.finish().first ?? path
            }
            pieces.append(path)
        }

        mutating func ellipse(cx: Double, cy: Double, rx: Double, ry: Double, _ m: Matrix) {
            if rx == ry, let s = m.uniformScale {
                pieces.append(Path(segments: [.circle(center: m.apply(SIMD2(cx, cy)), radius: rx * s)], closed: true))
                return
            }
            var pd = PathBuilder(m)
            pd.move(SIMD2(cx + rx, cy))
            for (x, y) in [(cx, cy + ry), (cx - rx, cy), (cx, cy - ry), (cx + rx, cy)] {
                pd.arc(rx: rx, ry: ry, rotation: 0, large: false, sweep: true, to: SIMD2(x, y))
            }
            pd.close()
            pieces += pd.finish()
        }

        // MARK: into a sketch

        func finish() throws -> Result {
            // Bounding box from the ends and controls (a hair generous for curves that bulge).
            var lo = SIMD2(Double.infinity, Double.infinity), hi = -lo
            func grow(_ p: SIMD2<Double>) { lo.replace(with: p, where: p .< lo); hi.replace(with: p, where: p .> hi) }
            for path in pieces {
                for s in path.segments {
                    switch s {
                    case .line(let a, let b): grow(a); grow(b)
                    case .cubic(let a, let b, let c, let d):
                        for p in Bezier.flatten([a, b, c, d], steps: 16) { grow(p) }
                    case .arc(let c, let a, let b):
                        grow(a); grow(b)
                        let r = vlen(a - c)
                        // Extremes the arc passes through.
                        for k in 0..<4 {
                            let dir = SIMD2(cos(Double(k) * .pi / 2), sin(Double(k) * .pi / 2))
                            if arcContains(center: c, start: a, end: b, direction: dir) { grow(c + dir * r) }
                        }
                    case .circle(let c, let r): grow(c - SIMD2(r, r)); grow(c + SIMD2(r, r))
                    }
                }
            }
            let mid = (lo + hi) / 2
            var sketch = Sketch()
            // Random IDs are 32 bits; a big drawing has enough entities that two could collide.
            var used: Set<EntityID> = ["origin"]
            func fresh() -> EntityID {
                var id = IDs.make()
                while !used.insert(id).inserted { id = IDs.make() }
                return id
            }
            var pointIDs: [SIMD2<Int64>: EntityID] = [:]
            func newPoint(_ p: SIMD2<Double>) -> EntityID { sketch.addPoint(p.x - mid.x, p.y - mid.y, id: fresh()) }
            func endpoint(_ p: SIMD2<Double>) -> EntityID {
                let q = p - mid
                let key = SIMD2(Int64((q.x * 1e4).rounded()), Int64((q.y * 1e4).rounded()))
                if let id = pointIDs[key] { return id }
                let id = newPoint(p)
                pointIDs[key] = id
                return id
            }
            var count = 0
            for path in pieces {
                for s in path.segments {
                    count += 1
                    guard count <= SVGImport.maxCurves else {
                        throw SVGImportError("the drawing is too detailed (more than \(SVGImport.maxCurves) curves)")
                    }
                    switch s {
                    case .line(let a, let b):
                        let pa = endpoint(a), pb = endpoint(b)
                        if pa != pb { sketch.addLine(pa, pb, id: fresh()) }
                    case .cubic(let a, let c1, let c2, let b):
                        let pa = endpoint(a), pb = endpoint(b)
                        // A curve that collapsed to a point is nothing.
                        if pa == pb, vlen(c1 - a) < 1e-6, vlen(c2 - a) < 1e-6 { continue }
                        sketch.addBezier(start: pa, control1: newPoint(c1), control2: newPoint(c2), end: pb, id: fresh())
                    case .arc(let c, let a, let b):
                        let pa = endpoint(a), pb = endpoint(b)
                        guard pa != pb else { continue }
                        sketch.addArc(center: newPoint(c), start: pa, end: pb, id: fresh())
                    case .circle(let c, let r):
                        sketch.addCircle(center: newPoint(c), radius: r, id: fresh())
                    }
                }
            }
            return Result(sketch: sketch, width: hi.x - lo.x, height: hi.y - lo.y, curveCount: sketch.curves.count,
                          skipped: skipped.sorted())
        }

        /// Whether the counter-clockwise arc from `start` to `end` around `center` passes the given direction.
        func arcContains(center c: SIMD2<Double>, start a: SIMD2<Double>, end b: SIMD2<Double>, direction d: SIMD2<Double>) -> Bool {
            func angle(_ v: SIMD2<Double>) -> Double { atan2(v.y, v.x) }
            let a0 = angle(a - c)
            var sweep = angle(b - c) - a0
            if sweep <= 0 { sweep += 2 * .pi }
            var t = angle(d) - a0
            if t < 0 { t += 2 * .pi }
            return t < sweep
        }
    }

    // MARK: path data

    /// Turns path commands into segments in millimetre space (the matrix maps user units there).
    fileprivate struct PathBuilder {
        let m: Matrix
        var paths: [Path] = []
        var current = Path()
        var start = SIMD2<Double>.zero   // in user units
        var pen = SIMD2<Double>.zero     // in user units
        var hasPen = false

        init(_ m: Matrix) { self.m = m }

        mutating func move(_ p: SIMD2<Double>) {
            flush()
            start = p; pen = p; hasPen = true
        }

        mutating func line(_ p: SIMD2<Double>) {
            guard hasPen else { return }
            if p != pen { current.segments.append(.line(m.apply(pen), m.apply(p))) }
            pen = p
        }

        mutating func cubic(_ c1: SIMD2<Double>, _ c2: SIMD2<Double>, _ p: SIMD2<Double>) {
            guard hasPen else { return }
            current.segments.append(.cubic(m.apply(pen), m.apply(c1), m.apply(c2), m.apply(p)))
            pen = p
        }

        mutating func quad(_ c: SIMD2<Double>, _ p: SIMD2<Double>) {
            cubic(pen + (c - pen) * (2.0 / 3), p + (c - p) * (2.0 / 3), p)
        }

        mutating func close() {
            guard hasPen else { return }
            if pen != start { current.segments.append(.line(m.apply(pen), m.apply(start))) }
            current.closed = true
            pen = start
            flush()
            hasPen = true  // a command after Z continues from the start point
        }

        /// SVG elliptical arc: to `p` on an ellipse with radii rx, ry turned by `rotation` degrees.
        mutating func arc(rx: Double, ry: Double, rotation: Double, large: Bool, sweep: Bool, to p: SIMD2<Double>) {
            guard hasPen else { return }
            var rx = abs(rx), ry = abs(ry)
            guard p != pen else { return }
            guard rx > 1e-12, ry > 1e-12 else { line(p); return }
            let phi = rotation * .pi / 180, cp = cos(phi), sp = sin(phi)
            // Endpoint → centre parameterisation (SVG implementation notes, F.6.5).
            let d = (pen - p) / 2
            let x1 = cp * d.x + sp * d.y, y1 = -sp * d.x + cp * d.y
            let lambda = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
            if lambda > 1 { let s = lambda.squareRoot(); rx *= s; ry *= s }
            let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
            let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
            var coef = den > 0 ? (max(num / den, 0)).squareRoot() : 0
            if large == sweep { coef = -coef }
            let cxp = coef * rx * y1 / ry, cyp = -coef * ry * x1 / rx
            let center = SIMD2(cp * cxp - sp * cyp, sp * cxp + cp * cyp) + (pen + p) / 2
            func ang(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
                atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            }
            let theta1 = ang(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry)
            var delta = ang((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry)
            if !sweep, delta > 0 { delta -= 2 * .pi }
            if sweep, delta < 0 { delta += 2 * .pi }
            func point(_ t: Double) -> SIMD2<Double> {
                let x = rx * cos(t), y = ry * sin(t)
                return SIMD2(cp * x - sp * y, sp * x + cp * y) + center
            }
            // A true circle stays an arc.
            if abs(rx - ry) <= 1e-9 * rx, m.uniformScale != nil {
                let a = m.apply(pen), b = m.apply(p), c = m.apply(center)
                // Turning counter-clockwise in user units stays so unless the matrix mirrors.
                let ccw = (delta > 0) == (m.determinant > 0)
                current.segments.append(ccw ? .arc(center: c, start: a, end: b) : .arc(center: c, start: b, end: a))
                pen = p
                return
            }
            // Otherwise cubic pieces of at most a quarter turn.
            let pieces = max(1, Int((abs(delta) / (.pi / 2) - 1e-9).rounded(.up)))
            let step = delta / Double(pieces)
            let k = 4.0 / 3 * tan(step / 4)
            var t = theta1
            for i in 0..<pieces {
                let t2 = t + step
                func deriv(_ t: Double) -> SIMD2<Double> {
                    let x = -rx * sin(t), y = ry * cos(t)
                    return SIMD2(cp * x - sp * y, sp * x + cp * y)
                }
                let a = i == 0 ? pen : point(t), b = i == pieces - 1 ? p : point(t2)
                cubic(a + deriv(t) * k, b - deriv(t2) * k, b)
                t = t2
            }
            pen = p
        }

        mutating func flush() {
            if !current.segments.isEmpty { paths.append(current) }
            current = Path()
        }

        mutating func finish() -> [Path] { flush(); return paths }
    }

    fileprivate enum PathData {
        static func parse(_ d: String, _ m: Matrix) -> [Path] {
            var s = SVGScanner(d)
            var pb = PathBuilder(m)
            var cmd: Character = " "
            var lastCubicControl: SIMD2<Double>?, lastQuadControl: SIMD2<Double>?
            func number() -> Double? { s.number() }
            while true {
                s.skipSeparators()
                if s.atEnd { break }
                if let c = s.command() { cmd = c } else if cmd == " " || cmd == "z" || cmd == "Z" { break }
                // After the first pair, extra numbers repeat the command (moveto repeats as lineto).
                let rel = cmd.isLowercase
                func pt(_ x: Double, _ y: Double) -> SIMD2<Double> { rel ? pb.pen + SIMD2(x, y) : SIMD2(x, y) }
                var cubicControl: SIMD2<Double>?, quadControl: SIMD2<Double>?
                switch cmd {
                case "M", "m":
                    guard let x = number(), let y = number() else { return pb.finish() }
                    pb.move(pt(x, y))
                    cmd = rel ? "l" : "L"
                case "L", "l":
                    guard let x = number(), let y = number() else { return pb.finish() }
                    pb.line(pt(x, y))
                case "H", "h":
                    guard let x = number() else { return pb.finish() }
                    pb.line(SIMD2(rel ? pb.pen.x + x : x, pb.pen.y))
                case "V", "v":
                    guard let y = number() else { return pb.finish() }
                    pb.line(SIMD2(pb.pen.x, rel ? pb.pen.y + y : y))
                case "C", "c":
                    guard let a = number(), let b = number(), let c = number(), let dd = number(), let e = number(), let f = number()
                    else { return pb.finish() }
                    let base = pb.pen
                    let c1 = rel ? base + SIMD2(a, b) : SIMD2(a, b)
                    let c2 = rel ? base + SIMD2(c, dd) : SIMD2(c, dd)
                    pb.cubic(c1, c2, rel ? base + SIMD2(e, f) : SIMD2(e, f))
                    cubicControl = c2
                case "S", "s":
                    guard let c = number(), let dd = number(), let e = number(), let f = number() else { return pb.finish() }
                    let base = pb.pen
                    let c1 = lastCubicControl.map { 2 * base - $0 } ?? base
                    let c2 = rel ? base + SIMD2(c, dd) : SIMD2(c, dd)
                    pb.cubic(c1, c2, rel ? base + SIMD2(e, f) : SIMD2(e, f))
                    cubicControl = c2
                case "Q", "q":
                    guard let a = number(), let b = number(), let e = number(), let f = number() else { return pb.finish() }
                    let base = pb.pen
                    let c = rel ? base + SIMD2(a, b) : SIMD2(a, b)
                    pb.quad(c, rel ? base + SIMD2(e, f) : SIMD2(e, f))
                    quadControl = c
                case "T", "t":
                    guard let e = number(), let f = number() else { return pb.finish() }
                    let base = pb.pen
                    let c = lastQuadControl.map { 2 * base - $0 } ?? base
                    pb.quad(c, rel ? base + SIMD2(e, f) : SIMD2(e, f))
                    quadControl = c
                case "A", "a":
                    guard let rx = number(), let ry = number(), let rot = number(),
                          let large = s.flag(), let sweep = s.flag(), let x = number(), let y = number() else { return pb.finish() }
                    pb.arc(rx: rx, ry: ry, rotation: rot, large: large, sweep: sweep, to: pt(x, y))
                case "Z", "z":
                    pb.close()
                default:
                    return pb.finish()  // unknown command: keep what was read
                }
                lastCubicControl = cubicControl
                lastQuadControl = quadControl
            }
            return pb.finish()
        }
    }
}

// MARK: - text scanning

/// Reads the numbers, flags and command letters of SVG attribute values.
struct SVGScanner {
    private let chars: [Character]
    private var i = 0

    init(_ text: String) { chars = Array(text) }

    var atEnd: Bool { i >= chars.count }
    var rest: String { String(chars[min(i, chars.count)...]) }

    mutating func skipSeparators() {
        while i < chars.count, chars[i] == "," || chars[i].isWhitespace { i += 1 }
    }

    mutating func consume(_ c: Character) -> Bool {
        skipSeparators()
        guard i < chars.count, chars[i] == c else { return false }
        i += 1
        return true
    }

    /// A run of letters ("translate").
    mutating func word() -> String? {
        skipSeparators()
        let s = i
        while i < chars.count, chars[i].isLetter { i += 1 }
        return i > s ? String(chars[s..<i]) : nil
    }

    /// A path command letter, if that's next.
    mutating func command() -> Character? {
        skipSeparators()
        guard i < chars.count, chars[i].isLetter, "MmLlHhVvCcSsQqTtAaZz".contains(chars[i]) else { return nil }
        i += 1
        return chars[i - 1]
    }

    /// An arc flag: one "0" or "1", which may be written without a separator after it.
    mutating func flag() -> Bool? {
        skipSeparators()
        guard i < chars.count, chars[i] == "0" || chars[i] == "1" else { return nil }
        i += 1
        return chars[i - 1] == "1"
    }

    mutating func number() -> Double? {
        skipSeparators()
        let s = i
        if i < chars.count, chars[i] == "+" || chars[i] == "-" { i += 1 }
        var digits = 0
        while i < chars.count, chars[i].isASCII, chars[i].isNumber { i += 1; digits += 1 }
        if i < chars.count, chars[i] == "." {
            i += 1
            while i < chars.count, chars[i].isASCII, chars[i].isNumber { i += 1; digits += 1 }
        }
        guard digits > 0 else { i = s; return nil }
        if i < chars.count, chars[i] == "e" || chars[i] == "E" {
            // An exponent, but not the "em" / "ex" units.
            var j = i + 1
            if j < chars.count, chars[j] == "+" || chars[j] == "-" { j += 1 }
            if j < chars.count, chars[j].isASCII, chars[j].isNumber {
                while j < chars.count, chars[j].isASCII, chars[j].isNumber { j += 1 }
                i = j
            }
        }
        return Double(String(chars[s..<i]))
    }

    /// Every number in a list ("points" or "viewBox"); nil if anything else is in it.
    static func numbers(_ text: String) -> [Double]? {
        var s = SVGScanner(text), out: [Double] = []
        while true {
            s.skipSeparators()
            if s.atEnd { return out }
            guard let n = s.number() else { return nil }
            out.append(n)
        }
    }
}

// MARK: - XML

/// One element of the file, with attributes (namespace prefixes dropped, except xlink:href) and children.
final class SVGElement {
    var name: String
    var attributes: [String: String]
    var children: [SVGElement] = []

    init(name: String, attributes: [String: String]) { self.name = name; self.attributes = attributes }

    /// The element's `style` attribute as properties, with presentation attributes it overrides.
    var style: [String: String] {
        var out: [String: String] = [:]
        for part in (attributes["style"] ?? "").split(separator: ";") {
            let kv = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }

    /// A numeric attribute in user units ("10", "10px"; percentages and other units don't count).
    func number(_ key: String) -> Double? {
        guard let v = attributes[key] else { return nil }
        var s = SVGScanner(v)
        guard let n = s.number() else { return nil }
        let unit = s.rest.trimmingCharacters(in: .whitespaces)
        return unit.isEmpty || unit == "px" ? n : nil
    }

    static func parse(_ data: Data) throws -> SVGElement {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), let root = reader.root else { throw SVGImportError("the file isn't valid SVG (XML) text") }
        return root
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var root: SVGElement?
        var stack: [SVGElement] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
            var attrs: [String: String] = [:]
            for (k, v) in attributeDict {
                attrs[k == "xlink:href" ? k : (k.split(separator: ":").last.map(String.init) ?? k)] = v
            }
            let e = SVGElement(name: local, attributes: attrs)
            if let p = stack.last { p.children.append(e) } else if root == nil { root = e }
            stack.append(e)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            _ = stack.popLast()
        }
    }
}

extension Sketch {
    /// Adds another sketch's points and curves (not its origin) to this one, under new IDs where they'd clash.
    public mutating func merge(_ other: Sketch) {
        var used = Set(points.map(\.id)).union(curves.map(\.id)).union(constraints.map(\.id)).union(dimensions.map(\.id))
        var map: [EntityID: EntityID] = ["origin": "origin"]
        func remap(_ id: EntityID) -> EntityID {
            if let m = map[id] { return m }
            var new = id
            while !used.insert(new).inserted { new = IDs.make() }
            map[id] = new
            return new
        }
        for p in other.points where p.id != "origin" {
            var q = p; q.id = remap(p.id); points.append(q)
        }
        for c in other.curves {
            var d = c; d.id = remap(c.id)
            switch c.geometry {
            case .line(let a, let b): d.geometry = .line(start: remap(a), end: remap(b))
            case .circle(let m, let r): d.geometry = .circle(center: remap(m), radius: r)
            case .arc(let m, let a, let b): d.geometry = .arc(center: remap(m), start: remap(a), end: remap(b))
            case .bezier(let a, let c1, let c2, let b):
                d.geometry = .bezier(start: remap(a), control1: remap(c1), control2: remap(c2), end: remap(b))
            }
            curves.append(d)
        }
    }
}
