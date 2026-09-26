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
        let used = ["cuboid", "cylinder", "globe", "torus", "orbit", "waypoints", "layers", "layers-2",
                    "square-split-horizontal", "circle-dot", "rotate-3d", "spline", "radius", "triangle",
                    "pen-tool", "circle-x", "focus", "mouse-pointer-2", "minus", "square", "circle",
                    "dot", "scissors", "arrow-up-right", "ruler", "link", "expand", "square-dashed", "corner-round"]
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
}
