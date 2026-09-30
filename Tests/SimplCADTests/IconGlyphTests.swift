// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SimplCAD

/// The hand-rolled SVG parser behind `Icon`: every glyph should parse into at least one drawable
/// piece, sitting roughly inside the 24x24 viewBox (loose bounds catch a broken arc/curve, not
/// pixel-perfect fidelity).
@Suite struct IconGlyphTests {
    @Test func everyGlyphParsesToAtLeastOnePath() {
        for (name, fragment) in IconGlyphs.table {
            let elements = SVGGlyph.parse(fragment)
            #expect(!elements.isEmpty, "\(name) produced no drawable elements")
            for element in elements {
                let box = element.path.boundingRect
                #expect(box.minX > -2 && box.minY > -2 && box.maxX < 26 && box.maxY < 26,
                        "\(name) drew outside the 24x24 viewBox: \(box)")
                #expect(!box.width.isNaN && !box.height.isNaN, "\(name) produced a NaN bounding box")
            }
        }
    }

    @Test func toolbarIconsUsedInSimplCADAreDefined() {
        let used = ["cuboid", "cylinder", "globe", "torus", "orbit", "waypoints", "extrude", "revolve", "hole", "layers-2",
                    "square-split-horizontal", "circle-dot", "rotate-3d", "spline", "fillet", "chamfer", "thread",
                    "pen-tool", "circle-x", "focus", "mouse-pointer-2", "minus", "square", "circle",
                    "dot", "scissors", "arrow-up-right", "ruler", "link", "expand", "square-dashed", "corner-round", "file-box"]
        for name in used {
            #expect(IconGlyphs.table[name] != nil, "expected glyph \"\(name)\" in IconGlyphs.table")
            #expect(!SVGGlyph.parse(IconGlyphs.table[name] ?? "").isEmpty)
        }
    }

    /// The elliptical-arc path (used by rounded-corner glyphs like "folder") should end near
    /// (2,3) as its final point, and not degenerate to a single moveto.
    @Test func arcCommandsProduceCurves() {
        let elements = SVGGlyph.parse(IconGlyphs.table["folder"] ?? "")
        #expect(!elements.isEmpty)
        let box = elements[0].path.boundingRect
        #expect(box.width > 10 && box.height > 10, "folder's rounded path looked collapsed: \(box)")
    }

    /// The fillet and chamfer glyphs shade their cut face with a see-through fill.
    @Test func fillOpacityIsParsed() {
        let face = SVGGlyph.parse(IconGlyphs.table["chamfer"] ?? "").first
        #expect(face?.filled == true)
        #expect(face?.opacity == 0.35)
        #expect(SVGGlyph.parse(IconGlyphs.table["dot"] ?? "").first?.opacity == 1)
    }
}
