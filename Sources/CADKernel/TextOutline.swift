// Letter outlines for sketch text, from Core Text: each glyph's contours as lines and Bézier
// curves in sketch (u, v) coordinates, used both to build profiles and to draw the text.
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import simd
#if canImport(CoreText)
import CoreText
#endif

public enum TextOutline {
    /// One piece of a contour: 2 points = line, 3 = quadratic, 4 = cubic Bézier.
    public typealias Segment = [SIMD2<Double>]

    /// The closed contours of `text` in `fontName`, with capital letters `height` tall, starting at
    /// `origin` on the baseline. Empty where Core Text isn't available.
    public static func contours(_ text: String, fontName: String, height: Double, origin: SIMD2<Double>) -> [[Segment]] {
        #if canImport(CoreText)
        guard !text.isEmpty, height > 0 else { return [] }
        let size: CGFloat = 100
        let font = CTFontCreateWithName(fontName as CFString, size, nil)
        let cap = CTFontGetCapHeight(font)
        let scale = height / Double(cap > 0 ? cap : size * 0.7)
        let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(attributed)
        var contours: [[Segment]] = []
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont? ?? font
            for (glyph, position) in zip(glyphs, positions) {
                guard let path = CTFontCreatePathForGlyph(runFont, glyph, nil) else { continue }
                let offset = SIMD2(Double(position.x), Double(position.y))
                contours += Self.contours(of: path) { p in origin + (SIMD2(Double(p.x), Double(p.y)) + offset) * scale }
            }
        }
        return contours
        #else
        return []
        #endif
    }

    #if canImport(CoreText)
    /// Splits a glyph path into closed contours; zero-length pieces are dropped.
    static func contours(of path: CGPath, _ map: (CGPoint) -> SIMD2<Double>) -> [[Segment]] {
        var out: [[Segment]] = [], current: [Segment] = []
        var start = SIMD2<Double>.zero, last = SIMD2<Double>.zero
        func add(_ seg: Segment) {
            guard let a = seg.first, let b = seg.last, simd_length_squared(b - a) > 1e-12 || seg.count > 2 else { return }
            current.append(seg)
            last = b
        }
        func close() {
            if simd_length_squared(last - start) > 1e-12, !current.isEmpty { current.append([last, start]) }
            if !current.isEmpty { out.append(current) }
            current = []
        }
        path.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint:
                close()
                start = map(e.points[0]); last = start
            case .addLineToPoint:
                add([last, map(e.points[0])])
            case .addQuadCurveToPoint:
                add([last, map(e.points[0]), map(e.points[1])])
            case .addCurveToPoint:
                add([last, map(e.points[0]), map(e.points[1]), map(e.points[2])])
            case .closeSubpath:
                close()
            @unknown default:
                break
            }
        }
        close()
        return out
    }
    #endif

    /// A segment as a polyline, for drawing.
    public static func flatten(_ seg: Segment, steps: Int = 8) -> [SIMD2<Double>] {
        switch seg.count {
        case 3:
            return (0...steps).map { i in
                let t = Double(i) / Double(steps), u = 1 - t
                return u * u * seg[0] + 2 * u * t * seg[1] + t * t * seg[2]
            }
        case 4:
            return (0...steps).map { i in
                let t = Double(i) / Double(steps), u = 1 - t
                return u * u * u * seg[0] + 3 * u * u * t * seg[1] + 3 * u * t * t * seg[2] + t * t * t * seg[3]
            }
        default:
            return seg
        }
    }
}

extension SketchText {
    /// This text's letter outlines in a solved sketch, with the parameters for its height.
    public func contours(in sketch: Sketch, parameters: ParameterValues) -> [[TextOutline.Segment]] {
        guard let origin = sketch.point(position)?.position,
              let h = try? parameters.value(of: height, kind: .length) else { return [] }
        return TextOutline.contours(text, fontName: font, height: h, origin: origin)
    }
}
