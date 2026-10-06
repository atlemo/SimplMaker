// An example part built around the Rib feature.
// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation

extension CADDocument {
    /// An L-bracket: a base plate and an upright wall, braced by two triangular ribs that each grow
    /// from a sketched slanted line, with a mounting hole at each front corner of the plate.
    public static func ribDemo() -> CADDocument {
        var doc = CADDocument()
        doc.parameters = [
            Parameter("base_w", "80 mm", comment: "width of the bracket"),
            Parameter("base_d", "60 mm", comment: "depth of the base plate"),
            Parameter("base_t", "6 mm", comment: "plate thickness"),
            Parameter("wall_t", "6 mm", comment: "wall thickness"),
            Parameter("wall_h", "50 mm", comment: "height of the wall"),
            Parameter("rib_t", "4 mm", comment: "rib thickness"),
            Parameter("rib_x", "22 mm", comment: "distance of each rib from the middle"),
            Parameter("rib_h", "32 mm", comment: "how far up the wall a rib reaches"),
            Parameter("rib_run", "30 mm", comment: "how far out along the plate a rib reaches"),
            Parameter("hole_d", "6 mm"),
        ]

        let plate = Feature(id: "plate", name: "Base Plate", .primitive(PrimitiveFeature(
            kind: .box, plane: .xy, width: "base_w", length: "base_d", height: "base_t")))
        let wall = Feature(id: "wall", name: "Wall", .primitive(PrimitiveFeature(
            kind: .box, plane: .xy, v: "(base_d - wall_t) / 2", width: "base_w", length: "wall_t", height: "wall_h",
            operation: .join, target: "plate")))

        // One rib sketch, on a plane through each rib's middle. In a Y-Z sketch the first coordinate runs
        // along the plate and the second up the wall; the line's ends sit on the wall and on the plate.
        func ribFeatures(_ id: String, _ name: String, offset: String) -> [Feature] {
            var s = Sketch()
            let a = s.addPoint(24, 38), b = s.addPoint(-6, 6)
            s.addLine(a, b, id: "R")
            s.dimension(.horizontalDistance("origin", a), "(base_d - wall_t * 2) / 2")
            s.dimension(.verticalDistance("origin", a), "base_t + rib_h")
            s.dimension(.horizontalDistance("origin", b), "(base_d - wall_t * 2) / 2 - rib_run")
            s.dimension(.verticalDistance("origin", b), "base_t")
            return [
                Feature(id: "\(id)plane", name: "\(name) Plane", .plane(PlaneFeature(base: .yz, offset: offset))),
                Feature(id: "\(id)sk", name: "\(name) Sketch", .sketch(SketchFeature(plane: .plane("\(id)plane"), sketch: s))),
                Feature(id: id, name: name, .rib(RibFeature(path: CurveRef(sketch: "\(id)sk", curves: ["R"]),
                                                            thickness: "rib_t", target: "plate"))),
            ]
        }

        func hole(_ id: String, _ name: String, u: String) -> Feature {
            Feature(id: id, name: name, .primitive(PrimitiveFeature(
                kind: .cylinder, plane: .xy, u: u, v: "-(base_d / 2 - 10 mm)", height: "base_t * 2", diameter: "hole_d",
                operation: .cut, target: "plate")))
        }

        doc.features = [plate, wall]
            + ribFeatures("ribleft", "Left Rib", offset: "-rib_x")
            + ribFeatures("ribright", "Right Rib", offset: "rib_x")
            + [hole("holeleft", "Left Hole", u: "-(base_w / 2 - 10 mm)"), hole("holeright", "Right Hole", u: "base_w / 2 - 10 mm")]
        return doc
    }
}
