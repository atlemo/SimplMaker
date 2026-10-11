// Recipes the design guide shows, as the exact steps an assistant would send to `batch`. The guide prints them and the tests run them,
// so what the guide teaches is what builds.
// Copyright © 2026 Atle Mo. All rights reserved.
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

    static func text(_ steps: [JSONValue]) -> String { steps.map { "  " + $0.text() }.joined(separator: ",\n") }
}
