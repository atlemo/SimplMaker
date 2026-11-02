// An advanced example part: a manifold block, an O-ring, a flange with a curved pipe, and four threaded bolts.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension CADDocument {
    /// A flanged pipe bolted to a manifold block, in five colour-coded bodies: the block (a groove cut by a
    /// revolve, a tapped side port, tapped bolt holes, rounded corners), an O-ring revolved from a circle, the
    /// flange (bore, clearance holes, a chamfer), a hollow pipe swept along a line-arc-line path, and four
    /// M8 bolts with real threads, copied round the flange with a circular pattern. The sizes are parameters;
    /// the pipe's straight lengths and the bolts' sockets are fixed.
    public static func manifoldDemo() -> CADDocument {
        var doc = CADDocument()
        doc.parameters = [
            Parameter("block", "100 mm", comment: "square block, side"),
            Parameter("block_h", "25 mm"),
            Parameter("bore_d", "28 mm", comment: "the flow bore, in block, flange and pipe"),
            Parameter("flange_d", "90 mm"),
            Parameter("flange_t", "12 mm"),
            Parameter("pipe_d", "34 mm", comment: "outer diameter"),
            Parameter("pipe_wall", "3 mm"),
            Parameter("bolt_x", "24 mm", comment: "bolts sit at (±bolt_x, ±bolt_x)"),
            Parameter("oring_r", "22 mm", comment: "radius of the O-ring's centre line"),
            Parameter("oring_d", "3 mm", comment: "cord diameter"),
            Parameter("gap", "oring_d", comment: "flange stands this far above the block"),
            Parameter("bend_r", "40 mm", comment: "pipe bend radius"),
            Parameter("corner_r", "6 mm"),
        ]

        // --- Manifold block: a box with rounded corners, a flow bore, an O-ring groove, tapped holes -----------
        let block = Feature(id: "block", name: "Manifold Block", .primitive(PrimitiveFeature(
            kind: .box, plane: .xy, width: "block", length: "block", height: "block_h")))
        let corners = Feature(id: "corners", name: "Corner Fillets", .fillet(EdgeFeature(
            edges: ["back|block.right", "back|block.left", "front|block.right", "front|block.left"].map {
                EdgeRef(body: "block", edge: "block.\($0)")
            },
            size: "corner_r")))
        func bore(_ id: String, _ name: String, on plane: PlaneRef, target: FeatureID) -> Feature {
            Feature(id: id, name: name, .primitive(PrimitiveFeature(
                kind: .cylinder, plane: plane, height: "block_h * 4", diameter: "bore_d", operation: .cut, target: target)))
        }
        let flowBore = bore("flowbore", "Flow Bore", on: .xy, target: "block")

        // The O-ring groove: a small rectangle revolved about the vertical axis and cut from the top face.
        var g = Sketch()
        let r = g.addRectangle(20.35, 23.5, 23.65, 26, lineIDs: ["G0", "G1", "G2", "G3"])
        g.dimension(.horizontalDistance("origin", r.corners[0]), "oring_r - oring_d * 0.55")
        g.dimension(.verticalDistance("origin", r.corners[0]), "block_h - oring_d / 2")
        g.dimension(.horizontalDistance("origin", r.corners[2]), "oring_r + oring_d * 0.55")
        g.dimension(.verticalDistance("origin", r.corners[2]), "block_h + 1 mm")
        let grooveSketch = Feature(id: "groovesk", name: "Groove Sketch", .sketch(SketchFeature(plane: .xz, sketch: g)))
        let groove = Feature(id: "groove", name: "O-Ring Groove", .revolve(RevolveFeature(
            sketch: "groovesk", profiles: [ProfileRef(curves: ["G0", "G1", "G2", "G3"])], axis: .sketchY,
            operation: .cut, target: "block")))

        let bolts = [("a", 1.0, 1.0), ("b", -1.0, 1.0), ("c", -1.0, -1.0), ("d", 1.0, -1.0)]
        // A box's top face starts at its corner, so a point is measured from there: block / 2 ± bolt_x.
        let tapped = bolts.map { id, sx, sy in
            Feature(id: "tap\(id)", name: "Tap Hole \(id.uppercased())", .hole(HoleFeature(
                face: FaceRef(body: "block", face: "block.top"),
                u: "block / 2 \(sx > 0 ? "+" : "-") bolt_x", v: "block / 2 \(sy > 0 ? "+" : "-") bolt_x",
                diameter: "6.8 mm", depth: "14 mm", tipAngle: "0 deg")))
        }

        let tapThread = Feature(id: "tapthread", name: "M8 Thread", .thread(ThreadFeature(
            face: FaceRef(body: "block", face: "tapa.hole.wall"),
            moreFaces: ["tapb", "tapc", "tapd"].map { FaceRef(body: "block", face: "\($0).hole.wall") },
            size: "M8x1.25", length: "12 mm")))

        // A tapped side port into the flow bore, drilled from the front face. That face starts at its lower
        // corner, with u running up and v running to the left, so the middle is at v = -block / 2.
        let port = Feature(id: "port", name: "Side Port", .hole(HoleFeature(
            face: FaceRef(body: "block", face: "block.front"), u: "block_h / 2", v: "-block / 2",
            diameter: "10.2 mm", depth: "block / 2", tipAngle: "0 deg")))
        let portChamfer = Feature(id: "portchamfer", name: "Port Chamfer", .chamfer(EdgeFeature(
            edges: [EdgeRef(body: "block", edge: "block.front|port.hole.wall")], size: "1 mm")))
        let portThread = Feature(id: "portthread", name: "G1/4 Port Thread", .thread(ThreadFeature(
            face: FaceRef(body: "block", face: "port.hole.wall"), standard: .metric, size: "M12x1.75", length: "18 mm")))

        // --- O-ring: a circle revolved about the vertical axis ------------------------------------------------
        var o = Sketch()
        let oc = o.addPoint(22, 25)
        o.addCircle(center: oc, radius: 1.5, id: "OC")
        o.dimension(.diameter("OC"), "oring_d")
        o.dimension(.horizontalDistance("origin", oc), "oring_r")
        o.dimension(.verticalDistance("origin", oc), "block_h")
        let oringSketch = Feature(id: "oringsk", name: "O-Ring Sketch", .sketch(SketchFeature(plane: .xz, sketch: o)))
        let oring = Feature(id: "oring", name: "O-Ring", .revolve(RevolveFeature(
            sketch: "oringsk", profiles: [ProfileRef(curves: ["OC"])], axis: .sketchY)))

        // --- Flange: a disc standing just above the O-ring, with the bore, a chamfer and four clearance holes --
        let flangePlane = Feature(id: "flangeplane", name: "Flange Plane", .plane(PlaneFeature(base: .xy, offset: "block_h + gap")))
        let flange = Feature(id: "flange", name: "Flange", .primitive(PrimitiveFeature(
            kind: .cylinder, plane: .plane("flangeplane"), height: "flange_t", diameter: "flange_d")))
        let flangeBore = bore("flangebore", "Flange Bore", on: .plane("flangeplane"), target: "flange")
        let flangeChamfer = Feature(id: "flangechamfer", name: "Flange Chamfer", .chamfer(EdgeFeature(
            edges: [EdgeRef(body: "flange", edge: "flange.side|flange.top")], size: "2 mm")))
        let clearance = bolts.map { id, sx, sy in
            Feature(id: "clear\(id)", name: "Clearance Hole \(id.uppercased())", .hole(HoleFeature(
                face: FaceRef(body: "flange", face: "flange.top"),
                u: "\(sx > 0 ? "" : "-")bolt_x", v: "\(sy > 0 ? "" : "-")bolt_x", diameter: "9 mm", depth: nil)))
        }

        // --- Pipe: a hollow tube swept along a path of a line, a quarter-circle arc and a line --------------
        // The sketch is on the front plane (x across, z up). It starts at the top of the flange.
        var p = Sketch()
        let top = 40.0  // block_h + gap + flange_t, at the default sizes
        let pa = p.addPoint(0, top), pb = p.addPoint(0, top + 30), pc = p.addPoint(40, top + 30)
        let ps = p.addPoint(40, top + 70), pd = p.addPoint(110, top + 70)
        p.addLine(pa, pb, id: "P1")
        p.addArc(center: pc, start: ps, end: pb, id: "P2")
        p.addLine(ps, pd, id: "P3")
        let rise = "block_h + gap + flange_t"
        p.dimension(.horizontalDistance("origin", pa), "0 mm"); p.dimension(.verticalDistance("origin", pa), rise)
        p.dimension(.horizontalDistance("origin", pb), "0 mm"); p.dimension(.verticalDistance("origin", pb), "\(rise) + 30 mm")
        p.dimension(.horizontalDistance("origin", pc), "bend_r"); p.dimension(.verticalDistance("origin", pc), "\(rise) + 30 mm")
        p.dimension(.horizontalDistance("origin", ps), "bend_r"); p.dimension(.verticalDistance("origin", ps), "\(rise) + 30 mm + bend_r")
        p.dimension(.horizontalDistance("origin", pd), "bend_r + 70 mm"); p.dimension(.verticalDistance("origin", pd), "\(rise) + 30 mm + bend_r")
        let pathSketch = Feature(id: "pathsk", name: "Pipe Path", .sketch(SketchFeature(plane: .xz, sketch: p)))
        let pipe = Feature(id: "pipe", name: "Pipe", .pipe(PipeFeature(
            path: CurveRef(sketch: "pathsk", curves: ["P1", "P2", "P3"]), diameter: "pipe_d", wall: "pipe_wall")))

        // --- Bolt: a shaft with an M8 thread at its tip, a head with a socket, copied round the flange ----------
        let boltPlane = Feature(id: "boltplane", name: "Bolt Tip Plane", .plane(PlaneFeature(base: .xy, offset: "block_h - 13 mm")))
        let headPlane = Feature(id: "headplane", name: "Bolt Head Plane", .plane(PlaneFeature(base: .xy, offset: "block_h + gap + flange_t")))
        let socketPlane = Feature(id: "socketplane", name: "Socket Plane", .plane(PlaneFeature(base: .xy, offset: "block_h + gap + flange_t + 2 mm")))
        let shaft = Feature(id: "bolt", name: "Bolt", .primitive(PrimitiveFeature(
            kind: .cylinder, plane: .plane("boltplane"), u: "bolt_x", v: "bolt_x", height: "flange_t + gap + 13 mm", diameter: "8 mm")))
        let boltThread = Feature(id: "boltthread", name: "Bolt Thread", .thread(ThreadFeature(
            face: FaceRef(body: "bolt", face: "bolt.side"), size: "M8x1.25", length: "12 mm")))
        let head = Feature(id: "boltheadcyl", name: "Bolt Head", .primitive(PrimitiveFeature(
            kind: .cylinder, plane: .plane("headplane"), u: "bolt_x", v: "bolt_x", height: "5 mm", diameter: "13 mm",
            operation: .join, target: "bolt")))
        let socket = Feature(id: "socket", name: "Socket", .primitive(PrimitiveFeature(
            kind: .cylinder, plane: .plane("socketplane"), u: "bolt_x", v: "bolt_x", height: "4 mm", diameter: "5 mm",
            operation: .cut, target: "bolt")))
        let headChamfer = Feature(id: "headchamfer", name: "Head Chamfer", .chamfer(EdgeFeature(
            edges: [EdgeRef(body: "bolt", edge: "boltheadcyl.side|boltheadcyl.top")], size: "0.8 mm")))
        let copies = Feature(id: "bolts", name: "Bolt Pattern", .pattern(PatternFeature(
            kind: .circular, bodies: ["bolt"], axis: .z, count: "4", spacing: "360 deg", operation: .newBody)))

        doc.bodyNames = ["block": "Manifold Block", "oring": "O-Ring", "flange": "Flange", "pipe": "Pipe",
                         "bolt": "Bolt", "bolts": "Bolts (copies)"]
        doc.bodyColors = [
            "block": BodyColor(hex: "#9FB1C4")!,   // anodised aluminium
            "oring": BodyColor(hex: "#2F6FED")!,   // blue rubber
            "flange": BodyColor(hex: "#5D6570")!,  // steel
            "pipe": BodyColor(hex: "#C97B3D")!,    // copper
            "bolt": BodyColor(hex: "#25282D")!,    // black oxide
            "bolts": BodyColor(hex: "#25282D")!,
        ]

        doc.features = [block, corners, flowBore, grooveSketch, groove] + tapped
            + [tapThread, port, portChamfer, portThread, oringSketch, oring, flangePlane, flange, flangeBore, flangeChamfer] + clearance
            + [pathSketch, pipe, boltPlane, headPlane, socketPlane, shaft, boltThread, head, socket, headChamfer, copies]
        return doc
    }
}
