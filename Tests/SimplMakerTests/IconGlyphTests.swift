// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import Testing
@testable import SimplMaker

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

    @Test func toolbarIconsUsedInSimplMakerAreDefined() {
        let used = ["cuboid", "cylinder", "globe", "torus", "orbit", "waypoints", "extrude", "extrude-two", "extrude-mirrored", "revolve", "hole", "layers-2",
                    "square-split-horizontal", "circle-dot", "rotate-3d", "spline", "fillet", "chamfer", "chamfer-equal", "chamfer-angle", "chamfer-two", "thread",
                    "pen-tool", "circle-x", "focus", "mouse-pointer-2", "minus", "square", "circle",
                    "dot", "scissors", "arrow-up-right", "ruler", "link", "offset", "project", "square-dashed", "corner-round", "file-box"]
        for name in used {
            #expect(IconGlyphs.table[name] != nil, "expected glyph \"\(name)\" in IconGlyphs.table")
            #expect(!SVGGlyph.parse(IconGlyphs.table[name] ?? "").isEmpty)
        }
    }

    /// Every constraint has its own glyph in the Constrain menu.
    @Test func everyConstraintHasAGlyph() {
        for c in ConstraintTool.allCases {
            #expect(IconGlyphs.table[c.icon] != nil, "missing glyph \"\(c.icon)\" for \(c.rawValue)")
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

    /// Tool icons render 1.2 pt thick whatever size they are shown at.
    @Test @MainActor func toolIconsRenderTheSameThicknessAtEverySize() {
        for size in [14.0, 16, 18] as [CGFloat] {
            let icon = Icon("move", size: size, renderedStroke: Icon.toolStroke)
            #expect(abs(icon.gridStrokeWidth * size / 24 - 1.2) < 1e-9, "\(size)")
        }
        #expect(Icon("move", size: 18).gridStrokeWidth == 1.75, "without a rendered width the weight decides")
        #expect(Icon("move", size: 18, weight: .bold).gridStrokeWidth == 2.5)
    }
}
