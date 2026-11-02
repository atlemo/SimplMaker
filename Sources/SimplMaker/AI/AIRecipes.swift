// Recipes the design guide shows, as the exact steps an assistant would send to `batch`. The guide prints them and the tests run them,
// so what the guide teaches is what builds.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum AIRecipes {
    private static func step(_ tool: String, _ arguments: JSONValue) -> JSONValue { ["tool": .string(tool), "arguments": arguments] }
    private static func param(_ name: String, _ value: JSONValue) -> JSONValue { step("set_parameter", ["name": .string(name), "value": value]) }
    private static func rounded(_ id: String, _ w: String, _ d: String, _ r: String) -> JSONValue {
        ["type": "rectangle", "id": .string(id), "center": [0, 0], "width": .string(w), "height": .string(d), "corner_radius": .string(r)]
    }

    /// Where the bead and groove sit, measured up from the base's floor (mm), for the chamfer step.
    static let snapFitBeadZ = 22.0

    /// A rounded box with a snap-fit lid, phase 1: every step that needs no face or edge id read from the model. Both bodies sit in
    /// their assembled positions: the base from z = 0 to base_h, the lid on top of it with a skirt reaching down into the base.
    static let snapFitBoxPhaseOne: [JSONValue] = [
        param("width", 45), param("depth", 50), param("height", 30), param("wall", 2), param("corner_r", 4), param("lid_t", 3),
        param("clr", 0.2), param("skirt_h", 6), param("skirt_w", 1.6), param("bead_h", 1.5), param("bead_d", 0.5), param("groove_d", 0.6),
        param("bottom_r", 1.5),
        param("base_h", "height - lid_t"), param("inner_w", "width - 2 * wall"), param("inner_d", "depth - 2 * wall"),
        param("inner_r", "corner_r - wall"), param("skirt_out_w", "inner_w - 2 * clr"), param("skirt_out_d", "inner_d - 2 * clr"),
        param("skirt_out_r", "inner_r - clr"), param("bead_z", "base_h - skirt_h + 1"),
        // base: a rounded block hollowed from the top, then its bottom edges rounded (shell first: a round smaller than the wall breaks it)
        step("create_sketch", ["plane": "xy", "id": "base_sk"]),
        step("edit_sketch", ["sketch_id": "base_sk", "add": [rounded("outline", "width", "depth", "corner_r")]]),
        step("create_extrude", ["sketch_id": "base_sk", "profiles": "solid", "distance": "base_h", "id": "base"]),
        step("create_shell", ["body": "base", "open_faces": ["face:base/base.end"], "thickness": "wall", "id": "base_shell"]),
        step("create_fillet", ["faces": ["face:base/base.start"], "size": "bottom_r", "id": "base_round"]),
        // the groove in the inner wall: a ring cut level with the bead
        step("create_plane", ["base": "xy", "offset": "bead_z", "id": "bead_plane"]),
        step("create_sketch", ["plane": "plane:bead_plane", "id": "groove_sk"]),
        step("edit_sketch", ["sketch_id": "groove_sk", "add": [
            rounded("groove_out", "inner_w + 2 * groove_d", "inner_d + 2 * groove_d", "inner_r + groove_d"),
            rounded("groove_in", "inner_w", "inner_d", "inner_r")]]),
        step("create_extrude", ["sketch_id": "groove_sk", "profiles": "solid", "distance": "bead_h", "operation": "cut", "target": "base", "id": "groove"]),
        // lid: the plate on top of the base, its top edge rounded
        step("create_plane", ["base": "xy", "offset": "base_h", "id": "lid_plane"]),
        step("create_sketch", ["plane": "plane:lid_plane", "id": "lid_sk"]),
        step("edit_sketch", ["sketch_id": "lid_sk", "add": [rounded("lid_outline", "width", "depth", "corner_r")]]),
        step("create_extrude", ["sketch_id": "lid_sk", "profiles": "solid", "distance": "lid_t", "id": "lid"]),
        step("create_fillet", ["faces": ["face:lid/lid.end"], "size": "bottom_r", "id": "lid_round"]),
        // the skirt that plugs into the base, hanging down from the plate
        step("create_sketch", ["plane": "plane:lid_plane", "id": "skirt_sk"]),
        step("edit_sketch", ["sketch_id": "skirt_sk", "add": [
            rounded("skirt_out", "skirt_out_w", "skirt_out_d", "skirt_out_r"),
            rounded("skirt_in", "skirt_out_w - 2 * skirt_w", "skirt_out_d - 2 * skirt_w", "skirt_out_r - skirt_w")]]),
        step("create_extrude", ["sketch_id": "skirt_sk", "profiles": "solid", "distance": "skirt_h", "direction": "backward", "operation": "join", "target": "lid", "id": "skirt"]),
        // the bead on the skirt, level with the groove (its inner outline sits inside the skirt wall so it fuses)
        step("create_sketch", ["plane": "plane:bead_plane", "id": "bead_sk"]),
        step("edit_sketch", ["sketch_id": "bead_sk", "add": [
            rounded("bead_out", "skirt_out_w + 2 * bead_d", "skirt_out_d + 2 * bead_d", "skirt_out_r + bead_d"),
            rounded("bead_in", "skirt_out_w - 0.8", "skirt_out_d - 0.8", "skirt_out_r - 0.4")]]),
        step("create_extrude", ["sketch_id": "bead_sk", "profiles": "solid", "distance": "bead_h", "operation": "join", "target": "lid", "id": "bead"]),
    ]

    /// A plain rounded box with a hollow inside, open on top.
    static let roundedOpenBox: [JSONValue] = [
        param("width", 60), param("depth", 40), param("height", 25), param("wall", 2), param("corner_r", 5), param("bottom_r", 1.5),
        step("create_sketch", ["plane": "xy", "id": "box_sk"]),
        step("edit_sketch", ["sketch_id": "box_sk", "add": [rounded("outline", "width", "depth", "corner_r")]]),
        step("create_extrude", ["sketch_id": "box_sk", "profiles": "solid", "distance": "height", "id": "box"]),
        step("create_shell", ["body": "box", "open_faces": ["face:box/box.end"], "thickness": "wall", "id": "box_shell"]),
        step("create_fillet", ["faces": ["face:box/box.start"], "size": "bottom_r", "id": "box_round"]),
    ]

    /// A name tag with a hole and raised, centred text.
    static let nameTag: [JSONValue] = [
        param("tag_w", 60), param("tag_h", 25), param("tag_t", 3), param("hole_d", 5), param("text_h", 9), param("text_t", 1),
        step("create_sketch", ["plane": "xy", "id": "tag_sk"]),
        step("edit_sketch", ["sketch_id": "tag_sk", "add": [
            rounded("tag", "tag_w", "tag_h", "tag_h / 2"),
            ["type": "circle", "id": "hole", "center": ["-tag_w / 2 + tag_h / 2", 0], "diameter": "hole_d"]]]),
        step("create_extrude", ["sketch_id": "tag_sk", "profiles": "solid", "distance": "tag_t", "id": "plate"]),
        step("create_sketch", ["plane": "face:plate/plate.end", "id": "text_sk"]),
        step("edit_sketch", ["sketch_id": "text_sk", "add": [["type": "text", "id": "label", "text": "Jane Doe", "at": [3, 0], "height": "text_h", "anchor": "center"]]]),
        step("create_extrude", ["sketch_id": "text_sk", "profiles": "solid", "distance": "text_t", "operation": "join", "target": "plate", "id": "lettering"]),
    ]

    /// A box with four screw posts and a flat lid, its holes lined up with the posts: M3 screws into the posts (pilot holes for self-tapping)
    /// and through the lid (clearance holes). Posts are made from circles on a plane just under the floor's top, so they overlap the floor
    /// and fuse with it; the pilot holes are cut down from a plane at the posts' tops. Nothing in it needs a face or edge id read from the model.
    static let screwPostCase: [JSONValue] = [
        param("width", 60), param("depth", 40), param("height", 25), param("wall", 2), param("corner_r", 5), param("lid_t", 2.5),
        param("post_d", 7), param("post_off", 5), param("pilot_d", 2.6), param("pilot_depth", 10), param("clear_d", 3.4),
        param("post_x", "width / 2 - post_off"), param("post_y", "depth / 2 - post_off"), param("post_h", "height - wall - 0.5"),
        step("create_sketch", ["plane": "xy", "id": "case_sk"]),
        step("edit_sketch", ["sketch_id": "case_sk", "add": [rounded("outline", "width", "depth", "corner_r")]]),
        step("create_extrude", ["sketch_id": "case_sk", "profiles": "solid", "distance": "height", "id": "case"]),
        step("create_shell", ["body": "case", "open_faces": ["face:case/case.end"], "thickness": "wall", "id": "case_shell"]),
        // the posts stand on the floor, 0.4 mm of them sunk into it, and touch the walls (the overlap fuses them)
        step("create_plane", ["base": "xy", "offset": "wall - 0.4", "id": "post_plane"]),
        step("create_sketch", ["plane": "plane:post_plane", "id": "post_sk"]),
        step("edit_sketch", ["sketch_id": "post_sk", "add": .array(postCircles("post", "post_d"))]),
        step("create_extrude", ["sketch_id": "post_sk", "profiles": "solid", "distance": "post_h + 0.4", "operation": "join", "target": "case", "id": "posts"]),
        // pilot holes down the middle of each post, from the posts' tops
        step("create_plane", ["base": "xy", "offset": "wall + post_h", "id": "post_top"]),
        step("create_sketch", ["plane": "plane:post_top", "id": "pilot_sk"]),
        step("edit_sketch", ["sketch_id": "pilot_sk", "add": .array(postCircles("pilot", "pilot_d"))]),
        step("create_extrude", ["sketch_id": "pilot_sk", "profiles": "solid", "distance": "pilot_depth", "direction": "backward", "operation": "cut", "target": "case", "id": "pilots"]),
        // the lid: a plate on the rim with a clearance hole over each post
        step("create_plane", ["base": "xy", "offset": "height", "id": "lid_plane"]),
        step("create_sketch", ["plane": "plane:lid_plane", "id": "lid_sk"]),
        step("edit_sketch", ["sketch_id": "lid_sk", "add": .array([rounded("lid_outline", "width", "depth", "corner_r")] + postCircles("lid_hole", "clear_d"))]),
        step("create_extrude", ["sketch_id": "lid_sk", "profiles": "solid", "distance": "lid_t", "id": "lid"]),
    ]

    /// Four circles at the corners, named "<prefix>_1" … "<prefix>_4", positions from the parameters post_x and post_y.
    private static func postCircles(_ prefix: String, _ diameter: String) -> [JSONValue] {
        [("1", "post_x", "post_y"), ("2", "-post_x", "post_y"), ("3", "-post_x", "-post_y"), ("4", "post_x", "-post_y")].map { n, x, y in
            ["type": "circle", "id": .string("\(prefix)_\(n)"), "center": [.string(x), .string(y)], "diameter": .string(diameter)]
        }
    }

    /// A pin hinge that prints in place: leaf A has the two outer knuckles and the pin through all three, leaf B the middle knuckle with a
    /// hole that clears the pin by "clr" all round, and a gap of "gap" between the knuckles. Everything is measured along the hinge axis
    /// from the plane the sketches are on (their normal), so the recipe does not depend on which way that points.
    static let printInPlaceHinge: [JSONValue] = [
        param("k", 10), param("gap", 0.4), param("hr", 4), param("pin_r", 1.5), param("clr", 0.4), param("leaf_w", 20), param("leaf_t", 2),
        param("step_len", "k + gap"),
        // leaf A: knuckle 1, the pin along the whole hinge, knuckle 3, and a plate behind each outer knuckle
        step("create_sketch", ["plane": "xz", "id": "a1_sk"]),
        step("edit_sketch", ["sketch_id": "a1_sk", "add": [
            ["type": "circle", "id": "knuckle", "center": [0, "hr"], "diameter": "2 * hr"],
            ["type": "circle", "id": "pin", "center": [0, "hr"], "diameter": "2 * pin_r"]]]),
        // two nested circles are a ring: the pin is its own sketch, so the knuckle below is solid
        step("create_extrude", ["sketch_id": "a1_sk", "profiles": [["at": ["hr - 0.5", "hr"]]], "distance": "k", "id": "hinge_a"]),
        step("create_extrude", ["sketch_id": "a1_sk", "profiles": [["at": [0, "hr"]]], "distance": "3 * k + 2 * gap", "operation": "join", "target": "hinge_a", "id": "pin_rod"]),
        step("create_plane", ["base": "xz", "offset": "2 * step_len", "id": "third"]),
        step("create_sketch", ["plane": "plane:third", "id": "a3_sk"]),
        step("edit_sketch", ["sketch_id": "a3_sk", "add": [["type": "circle", "id": "knuckle", "center": [0, "hr"], "diameter": "2 * hr"]]]),
        step("create_extrude", ["sketch_id": "a3_sk", "profiles": "solid", "distance": "k", "operation": "join", "target": "hinge_a", "id": "knuckle_3"]),
        step("create_sketch", ["plane": "xz", "id": "a_leaf1_sk"]),
        step("edit_sketch", ["sketch_id": "a_leaf1_sk", "add": [["type": "rectangle", "id": "leaf", "corner": ["-leaf_w", 0], "width": "leaf_w", "height": "leaf_t"]]]),
        step("create_extrude", ["sketch_id": "a_leaf1_sk", "profiles": "solid", "distance": "k", "operation": "join", "target": "hinge_a", "id": "leaf_a1"]),
        step("create_sketch", ["plane": "plane:third", "id": "a_leaf3_sk"]),
        step("edit_sketch", ["sketch_id": "a_leaf3_sk", "add": [["type": "rectangle", "id": "leaf", "corner": ["-leaf_w", 0], "width": "leaf_w", "height": "leaf_t"]]]),
        step("create_extrude", ["sketch_id": "a_leaf3_sk", "profiles": "solid", "distance": "k", "operation": "join", "target": "hinge_a", "id": "leaf_a3"]),
        // leaf B: the middle knuckle, a ring round the pin with clearance, and its plate on the other side
        step("create_plane", ["base": "xz", "offset": "step_len", "id": "second"]),
        step("create_sketch", ["plane": "plane:second", "id": "b_sk"]),
        step("edit_sketch", ["sketch_id": "b_sk", "add": [
            ["type": "circle", "id": "knuckle", "center": [0, "hr"], "diameter": "2 * hr"],
            ["type": "circle", "id": "bore", "center": [0, "hr"], "diameter": "2 * (pin_r + clr)"],
            ["type": "rectangle", "id": "leaf", "corner": [0, 0], "width": "leaf_w", "height": "leaf_t"]]]),
        step("create_extrude", ["sketch_id": "b_sk", "profiles": "solid", "distance": "k", "id": "hinge_b"]),
    ]

    static func text(_ steps: [JSONValue]) -> String { steps.map { "  " + $0.text() }.joined(separator: ",\n") }
}
