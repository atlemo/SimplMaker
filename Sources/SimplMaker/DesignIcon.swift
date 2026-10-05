// A design-system glyph: renders one of the vector icons in IconGlyphs.swift as a resizable,
// tintable SwiftUI view — the same role an SF Symbol Image plays, for names macOS doesn't ship.
// Copyright © 2026 Atle Mo. All rights reserved.
import SwiftUI

/// Line-glyph icon (Lucide set standing in for SF Symbols; see IconGlyphs.swift and the design
/// system's readme). Sizes like `Image`'s `.frame`; tints from the ambient `.foregroundStyle`.
struct Icon: View {
    let name: String
    var size: CGFloat = 16
    var weight: Weight = .regular
    /// When set, the stroke is this many points thick on screen whatever the icon's size (the glyph
    /// grid is 24 units, so the stroke is drawn thicker on the grid the smaller the icon is shown).
    var renderedStroke: CGFloat?
    @Environment(\.accent) private var accent

    /// The thickness of tool icons in the toolbars and their menus, in points as rendered.
    static let toolStroke: CGFloat = 1.2

    /// The stroke width in the glyph's 24-unit grid.
    var gridStrokeWidth: CGFloat { renderedStroke.map { $0 * 24 / size } ?? weight.strokeWidth }

    enum Weight {
        case ultralight, light, regular, medium, semibold, bold

        var strokeWidth: CGFloat {
            switch self {
            case .ultralight: return 1
            case .light: return 1.4
            case .regular: return 1.75
            case .medium: return 2
            case .semibold: return 2.25
            case .bold: return 2.5
            }
        }
    }

    init(_ name: String, size: CGFloat = 16, weight: Weight = .regular, renderedStroke: CGFloat? = nil) {
        self.name = name
        self.size = size
        self.weight = weight
        self.renderedStroke = renderedStroke
    }

    var body: some View {
        let elements = SVGGlyph.parse(IconGlyphs.table[name] ?? "")
        return ZStack(alignment: .topLeading) {
            ForEach(elements.indices, id: \.self) { i in
                let element = elements[i]
                if element.filled {
                    if let color = element.fillIsAccent ? accent : element.fillColor {
                        element.path.fill(color).opacity(element.opacity)
                    } else {
                        element.path.fill().opacity(element.opacity)
                    }
                }
                if !element.filled || element.alsoStroked {
                    let style = StrokeStyle(lineWidth: gridStrokeWidth * element.strokeWeight, lineCap: element.cap,
                                            lineJoin: element.join)
                    if let color = element.strokeIsAccent ? accent : element.strokeColor {
                        element.path.stroke(color, style: style).opacity(element.strokeOpacity)
                    } else {
                        element.path.stroke(style: style).opacity(element.strokeOpacity)
                    }
                }
            }
        }
        .frame(width: 24, height: 24, alignment: .topLeading)
        .scaleEffect(size / 24)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A `Label` whose icon is a design-system glyph instead of an SF Symbol.
@MainActor func toolLabel(_ title: String, _ icon: String) -> Label<Text, Icon> {
    Label(title: { Text(title) }, icon: { Icon(icon) })
}

/// One drawable piece of a glyph: a path from a `<path>`, `<rect>`, `<circle>`, `<ellipse>`,
/// `<line>`, `<polyline>` or `<polygon>` element, filled (a solid dot, or a see-through face with
/// `fill-opacity`) or stroked (everything else).
struct SVGPathElement {
    let path: Path
    let filled: Bool
    var opacity: Double = 1
    /// A stroked element can differ from the rest: a colour of its own (`stroke="#RRGGBB"` or `"accent"`; otherwise the
    /// glyph's ink), a fraction of its opacity (`stroke-opacity`), a multiple of the glyph's stroke width
    /// (`stroke-weight`) and its own caps and joins.
    var strokeColor: Color?
    /// The stroke is the app's accent colour (`stroke="accent"`).
    var strokeIsAccent = false
    /// A filled element takes the glyph's ink unless it names a colour (`fill="#RRGGBB"` or `"accent"`).
    var fillColor: Color?
    var fillIsAccent = false
    /// A filled element is also outlined when it names a stroke (`stroke="accent"`); otherwise it is only filled.
    var alsoStroked = false
    var strokeOpacity: Double = 1
    var strokeWeight: Double = 1
    var cap: CGLineCap = .round
    var join: CGLineJoin = .round
}

/// Parses the tiny, self-closing-tags-only SVG fragments in IconGlyphs.table into drawable paths.
/// Not a general SVG parser: it covers exactly the element and path-command vocabulary Lucide's
/// static export uses (see lucide-static 0.460.0), including elliptical arcs for rounded corners.
enum SVGGlyph {
    static func parse(_ fragment: String) -> [SVGPathElement] {
        var elements: [SVGPathElement] = []
        let chars = Array(fragment)
        var i = 0
        while i < chars.count {
            guard chars[i] == "<" else { i += 1; continue }
            guard let close = chars[i...].firstIndex(of: ">") else { break }
            let tag = String(chars[(i + 1)..<close])
            i = close + 1
            let body = tag.hasSuffix("/") ? String(tag.dropLast()) : tag
            guard let space = body.firstIndex(of: " ") else { continue }
            let tagName = String(body[body.startIndex..<space])
            let attrs = String(body[space...])  // keeps the leading space, so lookups can require a word boundary
            let fillAttr = attribute(attrs, "fill")
            let filled = fillAttr == "currentColor" || fillAttr == "accent" || fillAttr.flatMap(color(hex:)) != nil
            let opacity = number(attrs, "fill-opacity") ?? 1
            let first = elements.count
            defer {
                for k in first..<elements.count {
                    elements[k].fillColor = fillAttr.flatMap(color(hex:))
                    elements[k].fillIsAccent = fillAttr == "accent"
                    elements[k].alsoStroked = filled && attribute(attrs, "stroke").map { $0 != "none" } == true
                    elements[k].strokeColor = attribute(attrs, "stroke").flatMap(color(hex:))
                    elements[k].strokeIsAccent = attribute(attrs, "stroke") == "accent"
                    elements[k].strokeOpacity = number(attrs, "stroke-opacity") ?? 1
                    elements[k].strokeWeight = number(attrs, "stroke-weight") ?? 1
                    switch attribute(attrs, "stroke-linecap") {
                    case "butt": elements[k].cap = .butt
                    case "square": elements[k].cap = .square
                    default: break
                    }
                    if attribute(attrs, "stroke-linejoin") == "miter" { elements[k].join = .miter }
                }
            }

            switch tagName {
            case "path":
                if let d = attribute(attrs, "d") {
                    elements.append(SVGPathElement(path: parsePathData(d), filled: filled, opacity: opacity))
                }
            case "rect":
                let x = number(attrs, "x") ?? 0, y = number(attrs, "y") ?? 0
                let w = number(attrs, "width") ?? 0, h = number(attrs, "height") ?? 0
                let r = number(attrs, "rx") ?? number(attrs, "ry") ?? 0
                var p = Path()
                if r > 0 {
                    p.addRoundedRect(in: CGRect(x: x, y: y, width: w, height: h), cornerSize: CGSize(width: r, height: r))
                } else {
                    p.addRect(CGRect(x: x, y: y, width: w, height: h))
                }
                elements.append(SVGPathElement(path: p, filled: filled, opacity: opacity))
            case "circle":
                let cx = number(attrs, "cx") ?? 0, cy = number(attrs, "cy") ?? 0, r = number(attrs, "r") ?? 0
                var p = Path()
                p.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
                elements.append(SVGPathElement(path: p, filled: filled, opacity: opacity))
            case "ellipse":
                let cx = number(attrs, "cx") ?? 0, cy = number(attrs, "cy") ?? 0
                let rx = number(attrs, "rx") ?? 0, ry = number(attrs, "ry") ?? 0
                var p = Path()
                p.addEllipse(in: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
                elements.append(SVGPathElement(path: p, filled: filled, opacity: opacity))
            case "line":
                let x1 = number(attrs, "x1") ?? 0, y1 = number(attrs, "y1") ?? 0
                let x2 = number(attrs, "x2") ?? 0, y2 = number(attrs, "y2") ?? 0
                var p = Path()
                p.move(to: CGPoint(x: x1, y: y1))
                p.addLine(to: CGPoint(x: x2, y: y2))
                elements.append(SVGPathElement(path: p, filled: false))
            case "polyline", "polygon":
                if let pts = attribute(attrs, "points") {
                    let coords = pts.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
                    var p = Path()
                    var j = 0
                    var first = true
                    while j + 1 < coords.count {
                        let point = CGPoint(x: coords[j], y: coords[j + 1])
                        if first { p.move(to: point); first = false } else { p.addLine(to: point) }
                        j += 2
                    }
                    if tagName == "polygon" { p.closeSubpath() }
                    elements.append(SVGPathElement(path: p, filled: filled, opacity: opacity))
                }
            default:
                break
            }
        }
        return elements
    }

    /// `attrs` keeps its leading space, so searching for `" name=\""` requires a word boundary
    /// before the name — otherwise looking up "x" would also match inside "rx" or "y1".
    private static func attribute(_ attrs: String, _ name: String) -> String? {
        guard let range = attrs.range(of: " \(name)=\"") else { return nil }
        let rest = attrs[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[rest.startIndex..<end])
    }

    /// "#RRGGBB" or "accent" (the app's accent colour), or nil (also for "none" and "currentColor", which are
    /// the glyph's ink).
    private static func color(hex: String) -> Color? {
        guard hex.hasPrefix("#"), hex.count == 7, let v = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return Color(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    private static func number(_ attrs: String, _ name: String) -> Double? {
        attribute(attrs, name).flatMap(Double.init)
    }
}

// MARK: - SVG path data ("d" attribute)

private func parsePathData(_ d: String) -> Path {
    var path = Path()
    var scanner = PathDataScanner(d)
    var current = CGPoint.zero
    var subpathStart = CGPoint.zero
    var lastCubicControl: CGPoint?
    var lastQuadControl: CGPoint?

    func point(_ x: Double, _ y: Double, relative: Bool) -> CGPoint {
        relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
    }

    while let commandChar = scanner.nextCommand() {
        let relative = commandChar.isLowercase
        switch Character(commandChar.lowercased()) {
        case "m":
            guard let x = scanner.nextNumber(), let y = scanner.nextNumber() else { continue }
            let p = point(x, y, relative: relative)
            path.move(to: p)
            current = p; subpathStart = p
            lastCubicControl = nil; lastQuadControl = nil
            while scanner.peekIsNumber() {
                guard let xx = scanner.nextNumber(), let yy = scanner.nextNumber() else { break }
                let np = point(xx, yy, relative: relative)
                path.addLine(to: np)
                current = np
            }
        case "l":
            repeat {
                guard let x = scanner.nextNumber(), let y = scanner.nextNumber() else { break }
                let p = point(x, y, relative: relative)
                path.addLine(to: p); current = p
            } while scanner.peekIsNumber()
            lastCubicControl = nil; lastQuadControl = nil
        case "h":
            repeat {
                guard let x = scanner.nextNumber() else { break }
                let p = relative ? CGPoint(x: current.x + x, y: current.y) : CGPoint(x: x, y: current.y)
                path.addLine(to: p); current = p
            } while scanner.peekIsNumber()
            lastCubicControl = nil; lastQuadControl = nil
        case "v":
            repeat {
                guard let y = scanner.nextNumber() else { break }
                let p = relative ? CGPoint(x: current.x, y: current.y + y) : CGPoint(x: current.x, y: y)
                path.addLine(to: p); current = p
            } while scanner.peekIsNumber()
            lastCubicControl = nil; lastQuadControl = nil
        case "c":
            repeat {
                guard let x1 = scanner.nextNumber(), let y1 = scanner.nextNumber(),
                      let x2 = scanner.nextNumber(), let y2 = scanner.nextNumber(),
                      let x = scanner.nextNumber(), let y = scanner.nextNumber() else { break }
                let c1 = point(x1, y1, relative: relative), c2 = point(x2, y2, relative: relative)
                let p = point(x, y, relative: relative)
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p; lastCubicControl = c2; lastQuadControl = nil
            } while scanner.peekIsNumber()
        case "s":
            repeat {
                guard let x2 = scanner.nextNumber(), let y2 = scanner.nextNumber(),
                      let x = scanner.nextNumber(), let y = scanner.nextNumber() else { break }
                let c2 = point(x2, y2, relative: relative)
                let p = point(x, y, relative: relative)
                let c1 = lastCubicControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p; lastCubicControl = c2; lastQuadControl = nil
            } while scanner.peekIsNumber()
        case "q":
            repeat {
                guard let x1 = scanner.nextNumber(), let y1 = scanner.nextNumber(),
                      let x = scanner.nextNumber(), let y = scanner.nextNumber() else { break }
                let c1 = point(x1, y1, relative: relative)
                let p = point(x, y, relative: relative)
                path.addQuadCurve(to: p, control: c1)
                current = p; lastQuadControl = c1; lastCubicControl = nil
            } while scanner.peekIsNumber()
        case "t":
            repeat {
                guard let x = scanner.nextNumber(), let y = scanner.nextNumber() else { break }
                let p = point(x, y, relative: relative)
                let c1 = lastQuadControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                path.addQuadCurve(to: p, control: c1)
                current = p; lastQuadControl = c1; lastCubicControl = nil
            } while scanner.peekIsNumber()
        case "a":
            repeat {
                guard let rx = scanner.nextNumber(), let ry = scanner.nextNumber(),
                      let rotation = scanner.nextNumber() else { break }
                let largeArc = scanner.nextFlag(), sweep = scanner.nextFlag()
                guard let x = scanner.nextNumber(), let y = scanner.nextNumber() else { break }
                let p = point(x, y, relative: relative)
                appendArc(to: &path, from: current, to: p, rx: rx, ry: ry,
                          xAxisRotationDeg: rotation, largeArc: largeArc, sweep: sweep)
                current = p
            } while scanner.peekIsNumber()
            lastCubicControl = nil; lastQuadControl = nil
        case "z":
            path.closeSubpath()
            current = subpathStart
            lastCubicControl = nil; lastQuadControl = nil
        default:
            break
        }
    }
    return path
}

/// Scans an SVG path `d` string: command letters, and numbers separated by whitespace, commas,
/// or nothing at all (e.g. a sign or a second decimal point implicitly starts the next number).
private struct PathDataScanner {
    private let chars: [Character]
    private var i = 0

    init(_ s: String) { chars = Array(s) }

    private mutating func skipSeparators() {
        while i < chars.count, chars[i] == " " || chars[i] == "," || chars[i] == "\n" || chars[i] == "\t" || chars[i] == "\r" {
            i += 1
        }
    }

    mutating func nextCommand() -> Character? {
        skipSeparators()
        guard i < chars.count, chars[i].isLetter else { return nil }
        defer { i += 1 }
        return chars[i]
    }

    mutating func peekIsNumber() -> Bool {
        var j = i
        while j < chars.count, chars[j] == " " || chars[j] == "," || chars[j] == "\n" || chars[j] == "\t" || chars[j] == "\r" {
            j += 1
        }
        guard j < chars.count else { return false }
        let c = chars[j]
        return c.isNumber || c == "-" || c == "+" || c == "."
    }

    mutating func nextNumber() -> Double? {
        skipSeparators()
        var j = i
        var sawDot = false, sawDigit = false
        if j < chars.count, chars[j] == "-" || chars[j] == "+" { j += 1 }
        while j < chars.count {
            if chars[j].isNumber { sawDigit = true; j += 1 }
            else if chars[j] == "." && !sawDot { sawDot = true; j += 1 }
            else { break }
        }
        if j < chars.count, chars[j] == "e" || chars[j] == "E" {
            var k = j + 1
            if k < chars.count, chars[k] == "-" || chars[k] == "+" { k += 1 }
            var sawExpDigit = false
            while k < chars.count, chars[k].isNumber { sawExpDigit = true; k += 1 }
            if sawExpDigit { j = k }
        }
        guard sawDigit, j > i else { return nil }
        defer { i = j }
        return Double(String(chars[i..<j]))
    }

    /// Arc flags are a single '0'/'1' digit that can butt directly against the next number.
    mutating func nextFlag() -> Bool {
        skipSeparators()
        guard i < chars.count else { return false }
        defer { i += 1 }
        return chars[i] == "1"
    }
}

/// Standard SVG elliptical-arc-to-cubic-Bezier conversion (endpoint to center parameterization,
/// SVG 1.1 appendix F.6), split into segments of at most 90° for a good Bezier approximation.
private func appendArc(to path: inout Path, from p0: CGPoint, to p1: CGPoint,
                        rx rxIn: Double, ry ryIn: Double, xAxisRotationDeg: Double,
                        largeArc: Bool, sweep: Bool) {
    var rx = abs(rxIn), ry = abs(ryIn)
    if rx == 0 || ry == 0 || (p0.x == p1.x && p0.y == p1.y) {
        path.addLine(to: p1)
        return
    }
    let phi = xAxisRotationDeg * .pi / 180
    let cosPhi = cos(phi), sinPhi = sin(phi)
    let dx2 = (p0.x - p1.x) / 2, dy2 = (p0.y - p1.y) / 2
    let x1p = cosPhi * dx2 + sinPhi * dy2
    let y1p = -sinPhi * dx2 + cosPhi * dy2

    let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
    if lambda > 1 {
        let s = sqrt(lambda)
        rx *= s; ry *= s
    }

    let sign: Double = (largeArc != sweep) ? 1 : -1
    let num = max(0, rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p)
    let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
    let co = den > 0 ? sign * sqrt(num / den) : 0
    let cxp = co * (rx * y1p / ry)
    let cyp = -co * (ry * x1p / rx)

    let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
    let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2

    func vectorAngle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
        let dot = ux * vx + uy * vy
        let len = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
        var a = len > 0 ? acos(max(-1, min(1, dot / len))) : 0
        if ux * vy - uy * vx < 0 { a = -a }
        return a
    }

    let theta1 = vectorAngle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
    var dtheta = vectorAngle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
    if !sweep && dtheta > 0 { dtheta -= 2 * .pi }
    if sweep && dtheta < 0 { dtheta += 2 * .pi }

    func ellipsePoint(_ angle: Double) -> CGPoint {
        let ex = rx * cos(angle), ey = ry * sin(angle)
        return CGPoint(x: cosPhi * ex - sinPhi * ey + cx, y: sinPhi * ex + cosPhi * ey + cy)
    }
    func ellipseDerivative(_ angle: Double) -> CGPoint {
        let ex = -rx * sin(angle), ey = ry * cos(angle)
        return CGPoint(x: cosPhi * ex - sinPhi * ey, y: sinPhi * ex + cosPhi * ey)
    }

    let segments = max(1, Int(ceil(abs(dtheta) / (.pi / 2))))
    let delta = dtheta / Double(segments)
    let alpha = (4.0 / 3.0) * tan(delta / 4)
    var t = theta1
    for _ in 0..<segments {
        let t2 = t + delta
        let start = ellipsePoint(t), end = ellipsePoint(t2)
        let d1 = ellipseDerivative(t), d2 = ellipseDerivative(t2)
        let c1 = CGPoint(x: start.x + alpha * d1.x, y: start.y + alpha * d1.y)
        let c2 = CGPoint(x: end.x - alpha * d2.x, y: end.y - alpha * d2.y)
        path.addCurve(to: end, control1: c1, control2: c2)
        t = t2
    }
}
