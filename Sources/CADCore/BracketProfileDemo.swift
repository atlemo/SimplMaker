// An example part for trying the sketch solver: a dimensioned bracket profile.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension CADDocument {
    /// An L-bracket drawn as one closed profile and extruded to its width. Every edge is horizontal or
    /// vertical except the slanted top of the upright, and every size is a dimension driven by a parameter.
    /// The slant's low corner has no dimension, so dragging it shows the solver keeping the rest in place.
    public static func bracketProfileDemo() -> CADDocument {
        var doc = CADDocument()
        doc.parameters = [
            Parameter("foot_len", "50 mm", comment: "how far the foot reaches"),
            Parameter("wall_h", "60 mm", comment: "height of the upright"),
            Parameter("base_t", "6 mm", comment: "foot thickness"),
            Parameter("wall_t", "6 mm", comment: "upright thickness"),
            Parameter("bracket_w", "40 mm", comment: "how wide the bracket is"),
        ]

        // On the front plane the sketch's first coordinate runs left to right and its second runs up.
        var s = Sketch()
        let p = [s.addPoint(0, 0), s.addPoint(50, 0), s.addPoint(50, 6),
                 s.addPoint(6, 6), s.addPoint(6, 60), s.addPoint(0, 46)]
        let ids = ["foot", "toe", "top", "inner", "slant", "back"]
        for i in 0..<6 { s.addLine(p[i], p[(i + 1) % 6], id: ids[i]) }
        s.constrain(.coincident(p[0], "origin"))
        s.constrain(.horizontal("foot")); s.constrain(.vertical("toe")); s.constrain(.horizontal("top"))
        s.constrain(.vertical("inner")); s.constrain(.vertical("back"))
        s.dimension(.horizontalDistance("origin", p[1]), "foot_len")
        s.dimension(.verticalDistance("origin", p[2]), "base_t")
        s.dimension(.horizontalDistance("origin", p[3]), "wall_t")
        s.dimension(.verticalDistance("origin", p[4]), "wall_h")

        let profile = Feature(id: "profile", name: "Bracket Profile", .sketch(SketchFeature(plane: .xz, sketch: s)))
        let bracket = Feature(id: "bracket", name: "Bracket", .extrude(ExtrudeFeature(
            sketch: "profile", profiles: [ProfileRef(curves: ids)], extent: .symmetric("bracket_w"))))
        doc.features = [profile, bracket]
        return doc
    }
}
