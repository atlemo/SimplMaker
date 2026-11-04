// The tools an AI client sees. Few, and designed for an AI rather than mirroring the CAD functions: the descriptions
// say what a tool does, when to use it, what it needs and returns, and what can go wrong, because that text is all the
// model has to go on. Each tool calls CADService, which owns the behaviour; nothing here touches a document.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation

enum AITools {
    static let serverInstructions = """
    SimplMaker is a parametric CAD application. A part is a timeline of features (sketches, extrudes, fillets…) that \
    SimplMaker rebuilds whenever anything changes. The user has the part open in a window and sees everything you read and \
    change, as it happens.

    Before designing anything bigger than a plain block, read the guide: get_design_guide (no topic lists them; "workflow", \
    "parameters" and the topic that fits the request, such as "snap_fit_lid" for a box with a lid). It has the numbers that matter \
    for printing and recipes that are known to build. After building something meant to be printed, run check_design.

    Do everything through these tools, never by clicking or typing in the SimplMaker window or controlling the screen: the \
    tools are exact and undoable, and the window updates by itself. If a tool you need is not in your list, say so instead of \
    falling back to the screen: the user may need to restart this chat client so that it reloads SimplMaker's tools.

    Work in this order: understand (list_documents, get_document), inspect (get_feature, list_parameters, get_selection, get_viewport_image), \
    plan, change, and then check the result (including a picture). Look before you act. Prefer changing an existing feature or parameter over \
    making a new one: "make it 20 mm wider" means modify_feature on the box, not a new box.

    Units: lengths are millimetres and angles are degrees, always. A size you send is a number (mm or degrees) or an \
    expression with a unit ("2 in", "wall * 2"). Every size comes back as {expression, value, unit}; an expression that names \
    a parameter means the size follows that parameter, so change the parameter (set_parameter), not the number.

    Parameters first: this is a parametric CAD program, and the user expects a part they can resize afterwards by changing a \
    number, not a pile of fixed sizes. For anything you build, start the batch with set_parameter steps for every dimension that \
    matters (width, depth, height, wall, corner_radius, clearance, hole_diameter, fillet_radius, lid_height…), put derived values \
    in terms of the others ("inner_radius" = "corner_radius - wall", "lid_width" = "width - 2 * clearance"), and then write \
    those names, or expressions made of them, wherever a size is asked for: box sizes, sketch shapes, extrude distances, fillet \
    and chamfer sizes, shell thickness, hole diameters. Use plain numbers only for something that really is a one-off. Later \
    steps in the same batch see the parameters made by the earlier ones. When the user asks for a change afterwards ("make it \
    5 mm wider", "thicker walls"), change the parameter with set_parameter and everything follows. Tell the user which \
    parameters you made and what each one does.

    Building: for a plain block use create_box. For anything else draw first and extrude after: create_sketch on a plane or on \
    a flat face (get_body shows each face's "facing", "+z" is a top face), edit_sketch to add shapes (rectangle, circle, polygon, \
    line, polyline, spline, arc, text; a rectangle with corner_radius of half its shorter side is a slot), then create_extrude of the \
    profiles. Text is a shape: centre it with anchor "center" and check the profile bounds that come back to be sure it fits. \
    Give the things you create your own short ids ("outline", "hole"), and size them with the parameters you made (see above), so a \
    later "make it longer" is a single change. Anything made of several steps goes in ONE batch: the user gets one Undo, and a failing step \
    leaves nothing behind. Check the result with get_document, get_body and measure, and LOOK at it with get_viewport_image (iso first, then the view \
    that matters): numbers do not show a lid on upside down or text in the wrong place. Say so plainly when it is not what was asked. \
    A picture can cut the part open (section), show only some bodies (only) and draw sketches: use the section to check walls, hollows \
    and snap fits.

    More than extrudes: create_revolve, create_sweep and create_pipe follow a path or an axis; create_loft blends sections; create_twist_sweep \
    pushes a profile straight along a line while it turns (a twisted bar, a propeller or fan blade); create_rib \
    braces a corner; create_project puts text or a logo on a curved surface; create_split cuts a body into pieces and \
    create_lay_on_floor sets how each sits for printing; set_body names, colours or hides a body; create_image places a reference picture \
    to trace. The guide has recipes and numbers for these (hinges, screw-post cases, multi-part prints). To rebuild an imported STL or any \
    body you cannot read the sizes of, cut it with slice_body (sections along an axis: outline, thickness, tilt, centre) and draw it again in \
    features; the guide's topic "scan_to_part" shows how.

    Changes: every change tool needs document_id (never guess which part), is applied whole or not at all, and is one step \
    in the user's Undo (named "AI: …"). It answers with the part as it is now and its new revision. Pass expected_revision \
    (the revision you last saw) to be sure the user has not edited the part in between. If the user is in the middle of \
    something you get USER_BUSY: wait and try again. If a change would leave anything unbuildable you get REBUILD_FAILED \
    with the reason, and nothing was changed.

    Ids: features, sketches and bodies are named by their id (a body by the id of the feature that made it). Faces, edges, \
    profiles and curves use prefixed ids such as "face:<body>/<name>"; take them from what you read, never make them up. Face \
    and edge names can change when the part upstream changes, so read them again after any edit.

    Errors come back as {success: false, error: {code, message, reason, recoverable}}. Read the reason and adjust.
    """

    private static func object(_ properties: [String: JSONValue], _ required: [String]) -> JSONValue {
        ["type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) }),
         "additionalProperties": false]
    }

    private static let documentID: JSONValue = [
        "type": "string",
        "description": "The id of the document, from list_documents. Optional: without it the part in the front window is used. Needed when several parts are open and none is in front.",
    ]

    static func make(service: CADService) -> [MCPTool] {
        [
            MCPTool(
                name: "list_documents", title: "List open documents",
                description: """
                Lists the parts (documents) open in SimplMaker, with the id each can be addressed by. Use it first when you do \
                not know what the user is working on, or when more than one part may be open.

                Arguments: none. Read-only: it changes nothing.

                Returns {documents: [{id, name, path, is_active, feature_count}]}. path is null for a part that has not been \
                saved; is_active marks the part in the front window. An empty list means no part is open.
                """,
                inputSchema: object([:], []), readOnly: true,
                handler: { _ in try JSONValue(encoding: try await service.listDocuments()) }),

            MCPTool(
                name: "get_document", title: "Describe a document",
                description: """
                Describes one part: its units, its named parameters, the feature tree (every feature with its type, status and \
                settings) and the bodies it produces (volume, bounding box, number of faces and edges). Use it before changing \
                anything, and again afterwards to check the result.

                Arguments: document_id (optional, see list_documents).

                Read-only. Waits until SimplMaker has finished rebuilding the part, so the answer matches the model on screen.

                Returns {document_id, name, path, units: "mm", revision, timeline_marker, parameters, features, bodies}. \
                units is always "mm" (angles in degrees). revision changes whenever the part does. timeline_marker is null \
                normally; a number means the user rolled the timeline back and later features are not built. Each feature \
                has id, type, name, index, status ("ok", "error", "suppressed" or "rolled_back"), error (the reason, when the \
                status is "error"), creates_body, parameters, dependencies (the features it is built from) and children \
                (the features built from it). In parameters, a size is {expression, value, unit}: an expression such as \
                "wall" means it follows the parameter of that name. Each body has an id, to use wherever a body is asked for.

                Fails with NO_ACTIVE_DOCUMENT (no part open, or several and none in front: pass document_id) or \
                DOCUMENT_NOT_FOUND.
                """,
                inputSchema: object(["document_id": documentID], []), readOnly: true,
                handler: { args in
                    try JSONValue(encoding: try await service.getDocument(id: try string(args, "document_id")))
                }),

            MCPTool(
                name: "get_feature", title: "Describe one feature",
                description: """
                Describes one feature of a part in full: its settings, what it depends on and what depends on it. For a sketch \
                it also returns the sketch's dimensions (each with its expression and value), its profiles (the closed regions \
                that can be extruded; use their ids when asked for a profile) and how many degrees of freedom are left \
                (0 means fully constrained). Use it to see exactly what a feature is made of before changing it.

                Arguments: feature_id (required, from get_document); document_id (optional).

                Read-only. Returns {document_id, revision, feature, sketch}; sketch is null unless the feature is a sketch. \
                Fails with FEATURE_NOT_FOUND (the id does not exist; ids of deleted features are not reused), \
                NO_ACTIVE_DOCUMENT or DOCUMENT_NOT_FOUND.
                """,
                inputSchema: object(["document_id": documentID,
                                     "feature_id": ["type": "string", "description": "The id of the feature, from get_document."]],
                                    ["feature_id"]),
                readOnly: true,
                handler: { args in
                    guard let id = try string(args, "feature_id") else {
                        throw AIError(.invalidArguments, "feature_id is required.", reason: "Take it from the features list of get_document.")
                    }
                    return try JSONValue(encoding: try await service.getFeature(documentID: try string(args, "document_id"), featureID: id))
                }),

            MCPTool(
                name: "get_selection", title: "What the user has selected",
                description: """
                Returns what the user has selected in SimplMaker's viewport, as ids you can use: bodies, faces, edges, sketch \
                profiles, sketch curves and planes. Use it for requests that point at things ("fillet the edges I just \
                selected", "make this hole bigger").

                Arguments: document_id (optional).

                Read-only. Returns {document_id, revision, entities: [{id, type, feature_id}], selected_feature}. type is one \
                of body, face, edge, profile, curve, plane; feature_id is the feature the entity belongs to; selected_feature \
                is a feature selected in the browser or timeline rather than in the viewport. An empty list means nothing is \
                selected: ask the user to select what they mean, or describe it with get_document. The selection can change \
                at any moment, so read it again right before you use it.

                Fails with NO_ACTIVE_DOCUMENT or DOCUMENT_NOT_FOUND.
                """,
                inputSchema: object(["document_id": documentID], []), readOnly: true,
                handler: { args in
                    try JSONValue(encoding: try await service.getSelection(documentID: try string(args, "document_id")))
                }),

            MCPTool(
                name: "list_parameters", title: "List named parameters",
                description: """
                Lists a part's named parameters (the user's own variables such as "width" or "wall"). Features and sketch \
                dimensions refer to them by name, so changing one parameter resizes everything that uses it. Use it to find \
                the value that controls a dimension before changing individual features.

                Arguments: document_id (optional).

                Read-only. Returns {parameters: [{name, expression, unit, value, comment, error, used_by}]}. expression is \
                what the user typed (it may use other parameters, "depth / 4"); value is what it comes to, in mm or degrees \
                (unit says which; "" for a plain number); error says why a parameter has no value; used_by lists the features \
                that use it, in timeline order.

                Fails with NO_ACTIVE_DOCUMENT or DOCUMENT_NOT_FOUND.
                """,
                inputSchema: object(["document_id": documentID], []), readOnly: true,
                handler: { args in
                    let list = try await service.listParameters(documentID: try string(args, "document_id"))
                    return .object(["parameters": try JSONValue(encoding: list)])
                }),

            MCPTool(
                name: "create_box", title: "Create a box",
                description: """
                Creates a box (a rectangular solid) as a normal SimplMaker Box feature: it appears in the user's timeline and body \
                list, and its sizes can be changed later with modify_feature or by the user. Use it when the user asks for a \
                rectangular block, plate or slab. Do not use it to resize a box that exists: use modify_feature.

                Arguments: document_id (required); width, length, height (required, each a number in mm or an expression such \
                as "2 in" or "wall * 2"; width is along the plane's x axis, length along its y axis, height away from the plane); \
                plane (optional, default "xy": "xy", "xz", "yz", "plane:<construction plane id>" or a flat face "face:<body>/<name>"); \
                u, v (optional, default 0: where the middle of the box's footprint stands on the plane, in mm); name (optional, \
                default "Box1"…); id (optional: your own short id for the feature, such as "base"; otherwise one is made); \
                operation (optional: "new_body" by default, or "join", "cut", "intersect" to combine with an existing body); \
                target (optional: the body id to combine with, default the newest body); expected_revision (optional).

                The box stands on the plane with its footprint centred at (u, v) and rises along the plane's normal; on "xy" the \
                bottom is at z = 0. Changes the document: adds one feature, in one undo step named "AI: Create …".

                Returns {success, document_id, revision, message, feature, changes, bodies}. feature.id is the id to pass to \
                modify_feature; the new body has the same id (see bodies, which also gives its bounding box and volume). Fails \
                with INVALID_VALUE (a size that is zero, negative or not a valid expression), INVALID_ARGUMENTS, \
                TIMELINE_ROLLED_BACK, USER_BUSY, STALE_REVISION or REBUILD_FAILED; on any failure nothing is changed.
                """,
                inputSchema: object([
                    "document_id": ["type": "string", "description": "The part to change, from list_documents."],
                    "width": quantity("Size along the plane's x axis, mm."), "length": quantity("Size along the plane's y axis, mm."),
                    "height": quantity("Size away from the plane, mm."),
                    "plane": ["type": "string", "description": "\"xy\" (default), \"xz\", \"yz\", \"plane:<id>\" or \"face:<body>/<name>\"."],
                    "u": quantity("Where the footprint's middle is along the plane's x axis, mm (default 0)."),
                    "v": quantity("Where the footprint's middle is along the plane's y axis, mm (default 0)."),
                    "name": ["type": "string", "description": "A name for the feature (default Box1, Box2…)."],
                    "id": ["type": "string", "description": "Your own id for the feature: 1–40 letters, digits, _ or -."],
                    "operation": ["type": "string", "enum": ["new_body", "join", "cut", "intersect"], "description": "How it meets existing bodies (default new_body)."],
                    "target": ["type": "string", "description": "The body to combine with (default the newest)."],
                    "expected_revision": expectedRevision,
                ], ["document_id", "width", "length", "height"]),
                readOnly: false, destructive: false, idempotent: false,
                handler: { args in try await changeTool("create_box", service: service, args) }),

            MCPTool(
                name: "modify_feature", title: "Change a feature's settings",
                description: """
                Changes settings of an existing feature, such as the width of a box, and rebuilds the part. The feature stays the \
                same feature (same id, same place in the timeline, everything built from it follows), so this is how to make \
                "10 mm taller" or "a bigger hole". Never delete and recreate a feature to change it.

                Arguments: document_id (required); feature_id (required, from get_document); parameters (required: an object \
                from setting name to new value, for example {"width": 120, "height": "wall * 4"}; each value is a number in mm \
                (degrees for angles) or an expression); unlink (optional, default false: see below); expected_revision (optional). \
                get_feature lists the settings a feature accepts under "editable". Box, Cylinder, Sphere, Torus and Coil features can be \
                changed (width, length, height, diameter, tube, pitch, turns, u, v as they apply); a Sketch's settings are its dimensions by \
                the ids edit_sketch gave them ("plate.width", "ring_hole.diameter", "name.height"); an Extrude has distance and taper; a Fillet or Chamfer has size (and second, for the two-value chamfer modes); a Hole has diameter, depth, u, v (and head sizes); a Shell has thickness; a Revolve has angle; a Pattern has count and spacing. \
                Changing a text's height or words ("name.text") keeps the middle of its letters where it was, so a name centred on a \
                plate stays centred. New words change which regions the letters make, so an extrude made from the old letters stops \
                building and the change is refused (REBUILD_FAILED): do it in a batch that deletes that extrude (delete_feature), changes \
                the text, and extrudes again. Other features answer UNSUPPORTED_FEATURE_TYPE.

                If a setting follows a named parameter (its expression is a parameter name or uses one), sending a plain number \
                is refused with PARAMETER_LINKED rather than silently cutting the link: change the parameter with set_parameter, \
                or send an expression that keeps the link, or set unlink to true to replace it with the fixed number.

                Changes the document in one undo step named "AI: Change …". All values apply together or none do. Returns \
                {success, document_id, revision, message, feature, changes: [{field, before, after}], bodies}. Fails with \
                FEATURE_NOT_FOUND, UNKNOWN_FIELD (lists the valid names), INVALID_VALUE, PARAMETER_LINKED, \
                UNSUPPORTED_FEATURE_TYPE, REBUILD_FAILED (the new value would make this or a later feature unbuildable, with the \
                reason; the part is unchanged), USER_BUSY or STALE_REVISION.
                """,
                inputSchema: object([
                    "document_id": ["type": "string", "description": "The part to change, from list_documents."],
                    "feature_id": ["type": "string", "description": "The feature, from get_document."],
                    "parameters": ["type": "object", "description": "Setting name → new value (number in mm/degrees, or an expression).",
                                   "additionalProperties": ["type": ["number", "string"]]],
                    "unlink": ["type": "boolean", "description": "Replace a parameter link with a fixed number (default false)."],
                    "expected_revision": expectedRevision,
                ], ["document_id", "feature_id", "parameters"]),
                readOnly: false, destructive: true, idempotent: true,
                handler: { args in try await changeTool("modify_feature", service: service, args) }),

            MCPTool(
                name: "set_parameter", title: "Set or create a named parameter",
                description: """
                Sets the value of one of the part's named parameters, or creates it. A parameter is a named variable such as \
                "wall" or "width" that features and sketch dimensions can use, so changing it resizes everything that uses it \
                in one step. Use it when list_parameters or a feature shows a size that follows a parameter, and to give an \
                important dimension a name when you build something that may need adjusting.

                Arguments: document_id (required); name (required: a letter or underscore, then letters, digits or underscores; \
                not a unit or function name such as mm or sin); value (required: a number, or an expression that may use other \
                parameters, such as "wall * 2" or "2 in"); unit (optional: "mm", "deg" or "none"; a number is read in this unit, \
                default the parameter's own, or mm for a new one; an expression that is plainly a length or an angle sets it); \
                comment (optional); expected_revision (optional).

                Changes the document in one undo step named "AI: Set …". Returns {success, document_id, revision, message, \
                parameter, bodies}. Fails with INVALID_ARGUMENTS (bad name), INVALID_VALUE (the expression is invalid, circular, \
                or would leave another parameter without a value), REBUILD_FAILED (a feature that uses it would no longer build; \
                the part is unchanged), USER_BUSY or STALE_REVISION.
                """,
                inputSchema: object([
                    "document_id": ["type": "string", "description": "The part to change, from list_documents."],
                    "name": ["type": "string", "description": "The parameter's name."],
                    "value": quantity("A number or an expression."),
                    "unit": ["type": "string", "enum": ["mm", "deg", "none"], "description": "The unit a number is read in."],
                    "comment": ["type": "string"],
                    "expected_revision": expectedRevision,
                ], ["document_id", "name", "value"]),
                readOnly: false, destructive: true, idempotent: true,
                handler: { args in try await changeTool("set_parameter", service: service, args) }),

            MCPTool(
                name: "create_sketch", title: "Create a sketch",
                description: """
                Creates an empty sketch on a plane or on a flat face of a body. A sketch is where 2D shapes are drawn (with \
                edit_sketch) before they are turned into a solid (with create_extrude). Use it to start any shape that is not a plain \
                box, cylinder or sphere.

                Arguments: document_id (required); plane (optional, default "xy": "xy", "xz", "yz", "plane:<construction plane id>", or a \
                flat face "face:<body>/<name>", for example the top of a plate: get_body shows each face's "facing"); name (optional, \
                default Sketch1…); id (optional: your own short id such as "outline", used by edit_sketch and create_extrude); \
                expected_revision (optional).

                The sketch's own coordinates, used by every shape you draw in it: on "xy" the sketch x axis is the model's X and y is the \
                model's Y, normal along +Z; "xz" has x = X and y = Z, normal toward -Y; "yz" has x = Y and y = Z, normal toward +X. On a face, \
                x runs level and y runs upward as the face is seen, the origin is the model's origin projected onto the face's plane.

                Changes the document (one undo step "AI: Create …"). Returns {success, document_id, revision, message, feature, created: \
                {sketch_id}, sketch}. Fails with INVALID_ARGUMENTS (an unknown plane or a face that is not flat), TIMELINE_ROLLED_BACK, \
                USER_BUSY or STALE_REVISION.
                """,
                inputSchema: object([
                    "document_id": ["type": "string", "description": "The part to change, from list_documents."],
                    "plane": ["type": "string", "description": "\"xy\" (default), \"xz\", \"yz\", \"plane:<id>\" or \"face:<body>/<name>\"."],
                    "name": ["type": "string"], "id": ["type": "string", "description": "Your own id for the sketch: 1–40 letters, digits, _ or -."],
                    "expected_revision": expectedRevision,
                ], ["document_id"]),
                readOnly: false, destructive: false, idempotent: false,
                handler: { args in try await changeTool("create_sketch", service: service, args) }),

            MCPTool(
                name: "edit_sketch", title: "Draw shapes in a sketch",
                description: """
                Adds shapes to a sketch. Every size and position becomes a named dimension that can be changed later with modify_feature, \
                and accepts an expression that uses the part's parameters. Several shapes can be drawn in one call; they all succeed or none \
                does. Use it after create_sketch.

                Arguments: document_id (required); sketch_id (required); add (required): a list of shapes, each an object with a "type" and \
                an optional "id" (default rect1, circle1…; the shape's dimensions are named "<id>.width" and so on). Positions are [x, y] in \
                the sketch's coordinates, in mm or expressions; sizes are numbers (mm) or expressions. expected_revision (optional).
                Shapes:
                - rectangle: width, height, and either center [x, y] (default the origin) or corner [x, y] (the lower left corner); \
                  optional corner_radius. A corner_radius of exactly half the shorter side makes a slot (stadium), which is how to draw a \
                  key ring's rounded plate. Dimensions: <id>.width, <id>.height, <id>.radius (not for a slot), <id>.x, <id>.y (the center, or the corner).
                - circle: center, and exactly one of diameter or radius. Dimensions: <id>.diameter (or .radius), <id>.x, <id>.y. Use it for holes.
                - polygon: center, radius (to the corners), sides (3–64), optional rotation (degrees).
                - line: from, to. polyline: points (a list of positions), closed (default false). arc: from, through, to (three points on it).
                - spline: points (a list of positions the smooth curve passes through), closed (default false: true comes back round to the \
                  first point). Use it for any organic outline (a sole, a leaf, a handle) instead of many short lines: a curve traced with \
                  dozens of short straight pieces cannot be rounded (fillet) or chamfered, a spline can. 8 to 40 points are enough.
                - text: text, at, height (cap height, default 5 mm), optional font (PostScript name, default Helvetica-Bold), angle, and \
                  anchor: "start" (default: at is where the baseline begins) or "center" (at is the middle of the letters, which is how to \
                  centre a name on a plate). Dimensions: <id>.x, <id>.y (where it starts), <id>.height (its size, via modify_feature).

                Closed shapes make profiles: the regions you can extrude. Where shapes overlap or sit inside each other the regions are split, \
                so a circle inside a plate makes the plate a profile with a hole and the circle's disc a profile of its own. Letters are \
                profiles too (and so are the insides of letters such as o and a).

                Changes the document (one undo step "AI: Edit …"). Returns {success, document_id, revision, message, feature, created: \
                {shapes: [{id, type, dimensions, curves}]}, sketch: {points, curves, constraints, dimensions, profiles: [{id, area, inside, \
                bounds}], degrees_of_freedom}}. bounds is [min x, min y, max x, max y] of the profile in the sketch: use it to check that \
                text fits. Fails with INVALID_ARGUMENTS (a missing or unknown setting, a repeated id), INVALID_VALUE (a size that is \
                zero, too large, or a corner radius over half the shorter side), FEATURE_NOT_FOUND, REBUILD_FAILED, USER_BUSY or \
                STALE_REVISION.
                """,
                inputSchema: object([
                    "document_id": ["type": "string", "description": "The part to change, from list_documents."],
                    "sketch_id": ["type": "string", "description": "The sketch, from create_sketch or get_document."],
                    "add": ["type": "array", "description": "Shapes to draw.", "items": [
                        "type": "object",
                        "properties": [
                            "type": ["type": "string", "enum": ["rectangle", "circle", "polygon", "line", "polyline", "spline", "arc", "text"]],
                            "id": ["type": "string"],
                            "center": position("Where the middle is."), "corner": position("A rectangle's lower left corner."),
                            "width": quantity("A rectangle's width."), "height": quantity("A rectangle's height, or a text's cap height."),
                            "corner_radius": quantity("A rectangle's corner radius; half the shorter side makes a slot."),
                            "diameter": quantity("A circle's diameter."), "radius": quantity("A circle's or polygon's radius."),
                            "sides": ["type": "integer"], "rotation": quantity("A polygon's turn, degrees."),
                            "from": position("A line's or arc's start."), "to": position("A line's or arc's end."), "through": position("A point on the arc."),
                            "points": ["type": "array", "items": position("A point of the path.")], "closed": ["type": "boolean"],
                            "text": ["type": "string"], "at": position("Where the text is placed."), "font": ["type": "string"],
                            "angle": quantity("A text's turn, degrees."), "anchor": ["type": "string", "enum": ["start", "center"]],
                        ],
                        "required": ["type"],
                    ]],
                    "expected_revision": expectedRevision,
                ], ["document_id", "sketch_id", "add"]),
                readOnly: false, destructive: false, idempotent: false,
                handler: { args in try await changeTool("edit_sketch", service: service, args) }),

            MCPTool(
                name: "create_extrude", title: "Extrude sketch profiles into a solid",
                description: """
                Turns profiles of a sketch into a solid, or cuts them out of one: the step that makes a flat drawing three-dimensional. \
                Use it after edit_sketch. For a plate with a hole, extrude the plate's profile; for raised letters, extrude the letter \
                profiles from a sketch on the plate's top face with operation "join".

                Arguments: document_id (required); sketch_id (required); profiles (required): which regions to extrude, each either a profile \
                id from get_feature or edit_sketch ("profile:<sketch>/<curves>") or {"at": [x, y]} for whichever profile contains that point \
                of the sketch (get_feature gives a point inside each profile as "inside"); distance (a number in mm or an expression), or \
                through_all: true to cut right through everything (only for a cut); direction (optional: "forward" along the sketch's normal, \
                the default; "backward"; or "symmetric", with distance the total, centred on the sketch); operation (optional: "new_body" by \
                default, or "join" to add to a body, "cut" to remove from it, "intersect"); target (optional: the body to join, cut or \
                intersect, default the newest); start_face (optional: "face:<body>/<name>": start from that flat face instead of the sketch \
                plane); name, id (optional); expected_revision (optional).

                "through_all" goes one way from the sketch plane (the direction chosen); to cut through a body that lies on both sides of the \
                sketch, cut twice, once each way. The sketch is hidden once used, as in the interface. Changes the document (one undo step \
                "AI: Create …"). Returns {success, document_id, revision, message, feature, created: {profiles}, bodies}; the new body has \
                the feature's id. Fails with FEATURE_NOT_FOUND, INVALID_ARGUMENTS (no profile at that point, a profile of another sketch, a \
                missing distance), INVALID_VALUE, REBUILD_FAILED (the result would not build), TIMELINE_ROLLED_BACK, USER_BUSY or \
                STALE_REVISION.
                """,
                inputSchema: object([
                    "document_id": ["type": "string", "description": "The part to change, from list_documents."],
                    "sketch_id": ["type": "string", "description": "The sketch whose profiles to use."],
                    "profiles": ["type": "array", "description": "Profile ids, or {\"at\": [x, y]} points.", "items": ["oneOf": [["type": "string"], ["type": "object"]]]],
                    "distance": quantity("How far to extrude."), "through_all": ["type": "boolean", "description": "Cut through everything (cut only)."],
                    "direction": ["type": "string", "enum": ["forward", "backward", "symmetric"]],
                    "operation": ["type": "string", "enum": ["new_body", "join", "cut", "intersect"]],
                    "target": ["type": "string"], "start_face": ["type": "string"], "name": ["type": "string"], "id": ["type": "string"],
                    "expected_revision": expectedRevision,
                ], ["document_id", "sketch_id", "profiles"]),
                readOnly: false, destructive: false, idempotent: false,
                handler: { args in try await changeTool("create_extrude", service: service, args) }),

            MCPTool(
                name: "create_fillet", title: "Round edges (fillet)",
                description: """
                Rounds edges of a body with a fillet of a given radius, like the Fillet tool. Use it for smooth, printable, comfortable \
                edges: the rim of a lid, the corners of a plate, the top edge of a button. Rounding the edges of a body BEFORE cutting holes or \
                adding text into it is more reliable than after.

                Arguments: document_id (required); size (required: the radius, a number in mm or an expression); edges (optional: edge ids \
                "edge:<body>/<name>" from get_body); faces (optional: face ids "face:<body>/<name>"; every edge around the face is rounded, \
                and keeps following the face if the part changes). At least one of edges and faces. name, id, expected_revision (optional). \
                A radius that is too large for the edges or the neighbouring faces fails with REBUILD_FAILED and leaves the part unchanged; \
                try a smaller one. Check the result with measure or get_body: the kernel may accept a radius that is larger than the \
                part's walls allow.

                Changes the document (one undo step "AI: Create Fillet…"). Returns {success, document_id, revision, message, feature, \
                changes, bodies}. The radius can be changed later with modify_feature ("size"). Fails with FEATURE_NOT_FOUND (an edge or \
                face that does not exist), INVALID_ARGUMENTS, INVALID_VALUE, REBUILD_FAILED, TIMELINE_ROLLED_BACK, USER_BUSY or \
                STALE_REVISION.
                """,
                inputSchema: object([
                    "document_id": ["type": "string", "description": "The part to change, from list_documents."],
                    "size": quantity("The fillet radius."),
                    "edges": ["type": "array", "items": ["type": "string"], "description": "Edge ids to round, from get_body."],
                    "faces": ["type": "array", "items": ["type": "string"], "description": "Face ids whose every edge is rounded, from get_body."],
                    "name": ["type": "string", "description": "A name for the feature (default Fillet1, Fillet2…)."],
                    "id": ["type": "string", "description": "Your own id for the feature: 1–40 letters, digits, _ or -."],
                    "expected_revision": expectedRevision,
                ], ["document_id", "size"]),
                readOnly: false, destructive: false, idempotent: false,
                handler: { args in try await changeTool("create_fillet", service: service, args) }),

            MCPTool(
                name: "create_chamfer", title: "Bevel edges (chamfer)",
                description: """
                Bevels edges of a body with a flat cut, like the Chamfer tool. Use it where a flat 45° edge is wanted: the entry of a hole, \
                the bottom edge of a print (an "elephant's foot" bevel), a decorative edge. For a rounded edge use create_fillet.

                Arguments: document_id (required); size (required: the distance from the edge, a number in mm or an expression); edges \
                (optional: edge ids "edge:<body>/<name>" from get_body); faces (optional: face ids; every edge around the face is bevelled). \
                At least one of edges and faces. mode (optional): "equal_distance" (default; the same distance on both faces), \
                "two_distances" (size on one face, second on the other) or "distance_angle" (size on one face, second is the angle in degrees \
                to it). second (required for those two modes). flipped (optional, default false): put size on the other of the edge's two \
                faces; without it, on the picked face when faces were given. name, id, expected_revision (optional). A distance that is too large \
                fails with REBUILD_FAILED and leaves the part unchanged.

                Changes the document (one undo step). Returns {success, document_id, revision, message, feature, changes, bodies}. size and \
                second can be changed later with modify_feature. Fails like create_fillet.
                """,
                inputSchema: object([
                    "document_id": ["type": "string", "description": "The part to change, from list_documents."],
                    "size": quantity("The chamfer distance."),
                    "edges": ["type": "array", "items": ["type": "string"], "description": "Edge ids to bevel, from get_body."],
                    "faces": ["type": "array", "items": ["type": "string"], "description": "Face ids whose every edge is bevelled, from get_body."],
                    "mode": ["type": "string", "enum": ["equal_distance", "two_distances", "distance_angle"], "description": "How the chamfer is measured (default equal_distance)."],
                    "second": ["type": ["number", "string"], "description": "The distance on the other face (two_distances, mm) or the angle (distance_angle, degrees)."],
                    "flipped": ["type": "boolean", "description": "Put size on the other face of the edge (default false)."],
                    "name": ["type": "string", "description": "A name for the feature (default Chamfer1, Chamfer2…)."],
                    "id": ["type": "string", "description": "Your own id for the feature: 1–40 letters, digits, _ or -."],
                    "expected_revision": expectedRevision,
                ], ["document_id", "size"]),
                readOnly: false, destructive: false, idempotent: false,
                handler: { args in try await changeTool("create_chamfer", service: service, args) }),

            MCPTool(
                name: "create_hole", title: "Drill a hole",
                description: """
                Drills a round hole into a flat face of a body, like the Hole tool: a plain hole, a counterbore (a wider flat-bottomed step \
                for a screw head) or a countersink (a cone for a flat-head screw). Use it for screw holes, pegs' sockets and pass-throughs; \
                to cut any other shape, sketch it on the face and use create_extrude with operation "cut".

                Arguments: document_id, face (required: a flat face id "face:<body>/<name>" from get_body; the hole goes into the body from \
                that face); diameter (required); depth (how far the full diameter goes, mm) OR through_all: true (one of them is required); \
                where: at = [x, y, z] a point in the part's coordinates (it is projected onto the face; the easy way), or u and v in the \
                face's own frame; with neither, the hole is in the middle of the face. kind: "simple" (default), "counterbore" (needs \
                head_diameter and head_depth) or "countersink" (needs head_diameter, head_angle defaults to 90). tip_angle (blind holes: the \
                drill point, default 118; 0 gives a flat bottom). name, id, expected_revision. For several holes make one create_hole each, \
                or one hole and create_pattern.

                Changes the document (one undo step). Returns {success, document_id, revision, message, feature, changes, bodies}. The \
                size, depth and position can be changed later with modify_feature. Fails with FEATURE_NOT_FOUND, INVALID_ARGUMENTS (a curved \
                face; a position outside the face), INVALID_VALUE, REBUILD_FAILED, USER_BUSY or STALE_REVISION.
                """,
                inputSchema: object([
                    "document_id": ["type": "string", "description": "The part to change, from list_documents."],
                    "face": ["type": "string", "description": "A flat face id from get_body."],
                    "diameter": quantity("The hole diameter."),
                    "depth": quantity("How deep the full diameter goes (omit with through_all)."),
                    "through_all": ["type": "boolean", "description": "Drill through the whole body instead of a depth."],
                    "at": ["type": "array", "items": ["type": "number"], "minItems": 3, "maxItems": 3, "description": "[x, y, z] in mm, projected onto the face."],
                    "u": quantity("Position along the face's own x axis (alternative to at)."),
                    "v": quantity("Position along the face's own y axis (alternative to at)."),
                    "kind": ["type": "string", "enum": ["simple", "counterbore", "countersink"], "description": "Default simple."],
                    "head_diameter": quantity("Diameter of the counterbore or countersink."),
                    "head_depth": quantity("Depth of the counterbore step."),
                    "head_angle": ["type": ["number", "string"], "description": "Countersink cone angle in degrees (default 90)."],
                    "tip_angle": ["type": ["number", "string"], "description": "Drill point angle in degrees for a blind hole (default 118; 0 = flat)."],
                    "name": ["type": "string", "description": "A name for the feature (default Hole1…)."],
                    "id": ["type": "string", "description": "Your own id for the feature: 1–40 letters, digits, _ or -."],
                    "expected_revision": expectedRevision,
                ], ["document_id", "face", "diameter"]),
                readOnly: false, destructive: false, idempotent: false,
                handler: { args in try await changeTool("create_hole", service: service, args) }),

            MCPTool(
                name: "create_shell", title: "Hollow out a body (shell)",
                description: """
                Hollows a body into a thin-walled box or cup, like the Shell tool: the faces you name are removed (left open) and the rest \
                becomes walls of the given thickness. Use it for boxes, lids, cups, covers and enclosures. Shell BEFORE adding fillets to the \
                outside is not required, but a wall thicker than the body can hold, or rounds smaller than the wall, make it fail: when \
                it does, the error says why. Do the shell before fillets and chamfers where you can.

                Arguments: document_id; body (required: the body id from get_document); open_faces (required: face ids "face:<body>/<name>" \
                to leave open, at least one, for example the top face of a box); thickness (required, mm); inside (optional, default true: \
                the walls grow into the body, so outside size stays; false grows them outwards); name, id, expected_revision.

                Changes the document (one undo step). Returns {success, document_id, revision, message, feature, changes, bodies}. The thickness \
                can be changed later with modify_feature. Fails with FEATURE_NOT_FOUND, INVALID_ARGUMENTS, INVALID_VALUE, REBUILD_FAILED \
                (the wall is too thick for the shape; the part is unchanged), USER_BUSY or STALE_REVISION.
                """,
                inputSchema: object([
                    "document_id": ["type": "string", "description": "The part to change, from list_documents."],
                    "body": ["type": "string", "description": "The body to hollow, from get_document."],
                    "open_faces": ["type": "array", "items": ["type": "string"], "description": "Face ids to leave open, from get_body."],
                    "thickness": quantity("The wall thickness."),
                    "inside": ["type": "boolean", "description": "Walls grow inwards (default true) or outwards."],
                    "name": ["type": "string", "description": "A name for the feature (default Shell1…)."],
                    "id": ["type": "string", "description": "Your own id for the feature: 1–40 letters, digits, _ or -."],
                    "expected_revision": expectedRevision,
                ], ["document_id", "body", "open_faces", "thickness"]),
                readOnly: false, destructive: false, idempotent: false,
                handler: { args in try await changeTool("create_shell", service: service, args) }),

            MCPTool(
                name: "create_mirror", title: "Mirror bodies",
                description: """
                Mirrors bodies across a plane, or along an axis or a straight edge, like the Mirror tool. Use it for symmetric parts: \
                model one half, mirror it, and the two halves are joined into one body.

                Arguments: document_id; bodies (required: body ids); plane ("xy", "xz", "yz", a construction plane as \
                "plane:<id>", or a flat face id) or line ("x", "y", "z" or a straight edge id): give one of the two. A line mirrors \
                with the plane that holds the line and stands square to the plane the line lies in (for an edge, its first flat face; \
                for "x" and "y" the floor, so "x" swaps front and back and "y" left and right; for "z" the XZ plane, so left and right). operation (optional: "join" (default) adds each mirrored copy to its own body; \
                "new_body" keeps all the copies together as a new body with the id of this feature); name, id, expected_revision. The \
                origin planes pass through the origin: "yz" mirrors left/right (x → -x), "xz" front/back, "xy" top/bottom.

                Changes the document (one undo step). Returns {success, document_id, revision, message, feature, changes, bodies}. Fails with \
                FEATURE_NOT_FOUND, INVALID_ARGUMENTS, REBUILD_FAILED (for join: the copy does not touch the body), USER_BUSY or STALE_REVISION.
                """,
                inputSchema: object([
                    "document_id": ["type": "string", "description": "The part to change, from list_documents."],
                    "bodies": ["type": "array", "items": ["type": "string"], "description": "The bodies to mirror, from get_document."],
                    "plane": ["type": "string", "description": "xy, xz, yz, plane:<id> or a flat face id."],
                    "line": ["type": "string", "description": "x, y, z or a straight edge id: mirror along it instead of across a plane."],
                    "operation": ["type": "string", "enum": ["join", "new_body"], "description": "Join the copy to its body (default) or keep it as a new body."],
                    "name": ["type": "string", "description": "A name for the feature (default Mirror1…)."],
                    "id": ["type": "string", "description": "Your own id for the feature: 1–40 letters, digits, _ or -."],
                    "expected_revision": expectedRevision,
                ], ["document_id", "bodies"]),
                readOnly: false, destructive: false, idempotent: false,
                handler: { args in try await changeTool("create_mirror", service: service, args) }),

            MCPTool(
                name: "create_pattern", title: "Repeat bodies in a row or a circle",
                description: """
                Makes copies of bodies, like the Pattern tools: a LINEAR pattern puts them in a row, a CIRCULAR one spreads them around an \
                axis. Use it for rows of pegs, ribs and teeth, and bolt circles (a hole plus a circular pattern of the tool body).

                Arguments: document_id; kind ("linear" (default) or "circular"); bodies (required: body ids); axis (required: "x", "y", "z" or \
                a straight edge id; linear: the direction of the row; circular: the axis of rotation, which passes through the ORIGIN for x, \
                y and z, so a body to be repeated around its own centre must be centred on the origin, or use an edge as the axis); count \
                (required: the number of bodies in all, the original included, 2 to 500); spacing (linear: the distance between copies, \
                required; circular: the angle they are spread over, default 360 = all the way round); operation ("join" (default) adds the copies \
                to their body, "new_body" collects them in a new body); name, id, expected_revision.

                Changes the document (one undo step). Returns {success, document_id, revision, message, feature, changes, bodies}. count and \
                spacing can be changed later with modify_feature. Fails with FEATURE_NOT_FOUND, INVALID_ARGUMENTS, INVALID_VALUE, \
                REBUILD_FAILED (for join: a copy does not touch the body), USER_BUSY or STALE_REVISION.
                """,
                inputSchema: object([
                    "document_id": ["type": "string", "description": "The part to change, from list_documents."],
                    "kind": ["type": "string", "enum": ["linear", "circular"], "description": "Default linear."],
                    "bodies": ["type": "array", "items": ["type": "string"], "description": "The bodies to repeat, from get_document."],
                    "axis": ["type": "string", "description": "x, y, z or a straight edge id."],
                    "count": ["type": ["integer", "string"], "description": "Number of bodies in all, the original included."],
                    "spacing": ["type": ["number", "string"], "description": "Linear: distance between copies in mm. Circular: total angle in degrees (default 360)."],
                    "operation": ["type": "string", "enum": ["join", "new_body"], "description": "Join the copies to their body (default) or make a new body."],
                    "name": ["type": "string", "description": "A name for the feature (default Pattern1…)."],
                    "id": ["type": "string", "description": "Your own id for the feature: 1–40 letters, digits, _ or -."],
                    "expected_revision": expectedRevision,
                ], ["document_id", "bodies", "axis", "count"]),
                readOnly: false, destructive: false, idempotent: false,
                handler: { args in try await changeTool("create_pattern", service: service, args) }),

            MCPTool(
                name: "create_combine", title: "Combine bodies (join, cut, intersect)",
                description: """
                Combines bodies with each other, like the Combine tool: JOIN fuses the tool bodies into the target, CUT removes them from \
                it (a body used as a cutter), INTERSECT keeps only where they overlap. Use it to cut a shape made as its own body out of \
                another, or to merge separate pieces. (When a new shape is made by extrude, revolve or box, its own operation setting does this \
                already.)

                Arguments: document_id; target (required: the body that keeps its id); tools (required: other body ids); operation ("join" \
                (default), "cut" or "intersect"); keep_tools (optional, default false: the tool bodies are used up; true keeps them as they \
                are); name, id, expected_revision.

                Changes the document (one undo step). Returns {success, document_id, revision, message, feature, changes, bodies}. Fails with \
                FEATURE_NOT_FOUND, INVALID_ARGUMENTS, REBUILD_FAILED (the cut removes everything, or the bodies do not overlap), USER_BUSY or \
                STALE_REVISION.
                """,
                inputSchema: object([
                    "document_id": ["type": "string", "description": "The part to change, from list_documents."],
                    "target": ["type": "string", "description": "The body that is kept, from get_document."],
                    "tools": ["type": "array", "items": ["type": "string"], "description": "The bodies combined into the target."],
                    "operation": ["type": "string", "enum": ["join", "cut", "intersect"], "description": "Default join."],
                    "keep_tools": ["type": "boolean", "description": "Keep the tool bodies (default false: they are used up)."],
                    "name": ["type": "string", "description": "A name for the feature (default Combine1…)."],
                    "id": ["type": "string", "description": "Your own id for the feature: 1–40 letters, digits, _ or -."],
                    "expected_revision": expectedRevision,
                ], ["document_id", "target", "tools"]),
                readOnly: false, destructive: false, idempotent: false,
                handler: { args in try await changeTool("create_combine", service: service, args) }),

            MCPTool(
                name: "create_revolve", title: "Revolve sketch profiles around an axis",
                description: """
                Spins closed sketch profiles around an axis into a solid, like the Revolve tool. Use it for anything round: vases, bowls, \
                knobs, pulleys, rings, pegs, a lathe-turned part. Draw HALF of the cross-section on one side of the axis in a sketch (a \
                polyline or lines and arcs) and revolve it; the profile must not cross the axis.

                Arguments: document_id; sketch_id (required); profiles (required, as for create_extrude: "solid", ids, or {"at": [u, v]}); \
                axis (required: "x", "y", "z" (the origin axes), "sketch_x" or "sketch_y" (the sketch's own horizontal and vertical axis \
                through its origin), or a straight line drawn in the sketch as "curve:<sketch id>/<line id>"); angle (optional, degrees, \
                default 360); operation ("new_body" (default), "join", "cut", "intersect") and target as for create_extrude; name, id, \
                expected_revision. Example: a sketch on plane "xz" with a rectangle from x = 5 to 15 and z = 0 to 20, revolved about \
                "sketch_y" (the vertical axis of that sketch, at u = 0), makes a tube 20 mm tall with an inner radius of 5 and an outer radius of 15.

                Changes the document (one undo step). Returns {success, document_id, revision, message, feature, changes, bodies}. The angle \
                can be changed later with modify_feature. Fails with FEATURE_NOT_FOUND, INVALID_ARGUMENTS, INVALID_VALUE, REBUILD_FAILED \
                (for instance when the profile crosses the axis), USER_BUSY or STALE_REVISION.
                """,
                inputSchema: object([
                    "document_id": ["type": "string", "description": "The part to change, from list_documents."],
                    "sketch_id": ["type": "string", "description": "The sketch whose profiles are revolved."],
                    "profiles": ["description": "\"solid\", or a list of profile ids and {\"at\": [u, v]} points, as for create_extrude."],
                    "axis": ["type": "string", "description": "x, y, z, sketch_x, sketch_y or curve:<sketch>/<line id>."],
                    "angle": ["type": ["number", "string"], "description": "Degrees, default 360."],
                    "operation": ["type": "string", "enum": ["new_body", "join", "cut", "intersect"], "description": "Default new_body."],
                    "target": ["type": "string", "description": "The body to combine with (default the newest)."],
                    "name": ["type": "string", "description": "A name for the feature (default Revolve1…)."],
                    "id": ["type": "string", "description": "Your own id for the feature: 1–40 letters, digits, _ or -."],
                    "expected_revision": expectedRevision,
                ], ["document_id", "sketch_id", "profiles", "axis"]),
                readOnly: false, destructive: false, idempotent: false,
                handler: { args in try await changeTool("create_revolve", service: service, args) }),

            MCPTool(
                name: "create_sweep", title: "Sweep a profile along a path",
                description: """
                Pulls a closed sketch profile along a path, like the Sweep tool. Use it for pipes, rails, handles, wires, rims and trim: \
                a circle swept along a curved path is a bent tube; a rectangle swept along a line is a bar. The PROFILE and the PATH are \
                drawn in two different sketches: the profile on a plane square to the start of the path, the path on the plane it runs in \
                (a line, a polyline or arcs; the curves must connect).

                Arguments: document_id; sketch_id (required: the sketch with the profile); profiles (required, as for create_extrude: \
                "solid", ids, or {"at": [u, v]}); path_sketch (required: the sketch with the path); path (required: the curve ids of the path \
                in order, as edit_sketch returned them under "curves", for example ["rail.1", "rail.2"]; "curve:<sketch>/<id>" also works); \
                operation ("new_body" (default), "join", "cut", "intersect") and target as for create_extrude; name, id, expected_revision.

                Changes the document (one undo step). Returns {success, document_id, revision, message, feature, changes, bodies}. Fails with \
                FEATURE_NOT_FOUND, INVALID_ARGUMENTS (profile and path in the same sketch), REBUILD_FAILED (the path turns too sharply for the \
                profile; try a smaller profile or gentler curves), USER_BUSY or STALE_REVISION.
                """,
                inputSchema: object([
                    "document_id": ["type": "string", "description": "The part to change, from list_documents."],
                    "sketch_id": ["type": "string", "description": "The sketch with the profile."],
                    "profiles": ["description": "\"solid\", or a list of profile ids and {\"at\": [u, v]} points."],
                    "path_sketch": ["type": "string", "description": "The sketch with the path."],
                    "path": ["type": "array", "items": ["type": "string"], "description": "Curve ids of the path, in order."],
                    "operation": ["type": "string", "enum": ["new_body", "join", "cut", "intersect"], "description": "Default new_body."],
                    "target": ["type": "string", "description": "The body to combine with (default the newest)."],
                    "name": ["type": "string", "description": "A name for the feature (default Sweep1…)."],
                    "id": ["type": "string", "description": "Your own id for the feature: 1–40 letters, digits, _ or -."],
                    "expected_revision": expectedRevision,
                ], ["document_id", "sketch_id", "profiles", "path"]),
                readOnly: false, destructive: false, idempotent: false,
                handler: { args in try await changeTool("create_sweep", service: service, args) }),

            MCPTool(
                name: "create_loft", title: "Loft between sections",
                description: """
                Blends a solid through two or more closed sketch profiles at different places, like the Loft tool. Use it for shapes that \
                change along their length: a bottle neck, a funnel, a square-to-round adapter, a boat hull. Draw each section in its own \
                sketch (on planes at different heights: create_plane makes one) and pass them in order, bottom to top.

                Arguments: document_id; sections (required: at least two, in order; each {sketch_id, profile} where profile is a profile \
                id from get_feature, "solid" when the sketch has just one shape, or {"at": [u, v]}); ruled (optional, default false: straight \
                sides between sections instead of a smooth blend); operation ("new_body" (default), "join", "cut", "intersect"), target, \
                name, id, expected_revision. Sections with a similar number of corners blend best.

                Changes the document (one undo step). Returns {success, document_id, revision, message, feature, changes, bodies}. Fails with \
                FEATURE_NOT_FOUND, INVALID_ARGUMENTS, REBUILD_FAILED, USER_BUSY or STALE_REVISION.
                """,
                inputSchema: object([
                    "document_id": ["type": "string", "description": "The part to change, from list_documents."],
                    "sections": ["type": "array", "minItems": 2, "description": "The sections in order.", "items": [
                        "type": "object", "properties": ["sketch_id": ["type": "string"], "profile": ["description": "Profile id, \"solid\" or {\"at\": [u, v]}."]],
                        "required": ["sketch_id", "profile"]]],
                    "ruled": ["type": "boolean", "description": "Straight sides between sections (default false: smooth)."],
                    "operation": ["type": "string", "enum": ["new_body", "join", "cut", "intersect"], "description": "Default new_body."],
                    "target": ["type": "string", "description": "The body to combine with (default the newest)."],
                    "name": ["type": "string", "description": "A name for the feature (default Loft1…)."],
                    "id": ["type": "string", "description": "Your own id for the feature: 1–40 letters, digits, _ or -."],
                    "expected_revision": expectedRevision,
                ], ["document_id", "sections"]),
                readOnly: false, destructive: false, idempotent: false,
                handler: { args in try await changeTool("create_loft", service: service, args) }),

            MCPTool(
                name: "create_twist_sweep", title: "Sweep a profile along a line while it twists",
                description: """
                Pushes a closed sketch profile straight along the sketch's normal while it TURNS about that line (and, if you like, slides \
                sideways), like the Twist Sweep tool. Use it for anything twisted: a twisted bar or ribbon, a drill or screw-like shape, a \
                spiral vase, and above all a PROPELLER, FAN or TURBINE BLADE, whose section turns from tip to root. Build such a blade from \
                two features: a twisted flat plate (this tool, a thin rectangle as the profile) and the blade's outline extruded straight \
                through it (create_extrude with operation "intersect" and target the plate); the result has the outline's vertical edges and \
                the plate's twist. To copy a scanned blade, read its sections first with slice_body (major_axis_degrees gives the tilt at each \
                station, centroid the rise) and fit start_angle, end_angle, curve and shift to them.

                Arguments: document_id; sketch_id (required: the sketch with the profile, on the plane the sweep starts from, square to the \
                direction it runs: e.g. the "yz" plane, or a create_plane offset of it, to sweep along X); profiles ("solid", ids, or {"at": [u, v]}, \
                as for create_extrude); distance (required: how far it runs along the sketch's normal, mm; flipped: true runs against it); \
                end_angle (required: the turn at the far end, degrees, counter-clockwise seen from the sketch's front); start_angle (optional, \
                default 0: the turn at the start, from the profile as drawn); curve (optional, default 1: 1 turns evenly; 2 keeps the start \
                flat and turns mostly toward the end, like a blade's pitch growing toward the hub; 0.5 turns early); shift (optional [u, v] \
                mm: how far the profile has slid by the end, in the sketch's x and y: a lean, or a blade's rise along its length); pivot \
                (optional [u, v]: the sketch point it turns about; default the middle of the profile); operation ("new_body" (default), \
                "join", "cut", "intersect"); target; name; id; expected_revision. The turn at a fraction t of the way is start_angle + \
                (end_angle - start_angle) * t^curve, and the slide is shift * t. Smooth: a loft through a section about every 3 degrees of turn.

                Changes the document (one undo step). Returns {success, document_id, revision, message, feature, changes, bodies}. Fails with \
                FEATURE_NOT_FOUND, INVALID_ARGUMENTS, INVALID_VALUE, REBUILD_FAILED (a profile that turns through itself or a twist too sharp), \
                USER_BUSY or STALE_REVISION. modify_feature changes distance, start_angle, end_angle, curve, shift_u, shift_v (and pivot_u, pivot_v).
                """,
                inputSchema: object([
                    "document_id": ["type": "string", "description": "The part to change, from list_documents."],
                    "sketch_id": ["type": "string", "description": "The sketch with the profile."],
                    "profiles": ["description": "\"solid\", or a list of profile ids and {\"at\": [u, v]} points."],
                    "distance": ["type": ["number", "string"], "description": "How far it runs, mm."],
                    "end_angle": ["type": ["number", "string"], "description": "The turn at the far end, degrees."],
                    "start_angle": ["type": ["number", "string"], "description": "The turn at the start, degrees (default 0)."],
                    "curve": ["type": ["number", "string"], "description": "How the turn is spread: 1 even, above 1 late, below 1 early (default 1)."],
                    "shift": position("How far the profile has slid by the end, in the sketch's x and y (default none)."),
                    "pivot": position("The sketch point it turns about (default the profile's middle)."),
                    "flipped": ["type": "boolean", "description": "Run against the sketch's normal."],
                    "operation": ["type": "string", "enum": ["new_body", "join", "cut", "intersect"], "description": "Default new_body."],
                    "target": ["type": "string", "description": "The body to combine with (default the newest)."],
                    "name": ["type": "string", "description": "A name for the feature (default Twist Sweep1…)."],
                    "id": ["type": "string", "description": "Your own id for the feature: 1–40 letters, digits, _ or -."],
                    "expected_revision": expectedRevision,
                ], ["document_id", "sketch_id", "profiles", "distance", "end_angle"]),
                readOnly: false, destructive: false, idempotent: false,
                handler: { args in try await changeTool("create_twist_sweep", service: service, args) }),

            MCPTool(
                name: "create_thread", title: "Cut a screw thread",
                description: """
                Cuts a real screw thread into a round face, like the Thread tool: the outside of a shaft or the inside of a hole. The face is \
                sized to the thread first (a shaft turned to the major diameter, a hole bored to the minor one). Use it for bolts, nuts, \
                bottle necks and screw-on lids. Threads are slow to build; add them last.

                Arguments: document_id; faces (required: face ids of cylindrical faces from get_body, shape "cylinder"; several faces get \
                the same thread); size (required: a size name from the standard: "M6x1", "M8x1.25"… (metric), "M8x1" (metric_fine), "1/4-20" (unc), \
                "1/4-28" (unf); a wrong name answers with the list); standard (optional: "metric" (default), "metric_fine", "unc", "unf"); \
                length (optional: how far along the face; default all of it); flipped (start from the other end); left_handed; \
                tolerance (optional, for 3D printing: how much larger the thread is modelled than nominal; a share of the diameter, or mm \
                with tolerance_unit "mm"; negative makes it smaller; a nut thread wants a positive offset around 2–4 %); name, id, \
                expected_revision.

                Changes the document (one undo step). Returns {success, document_id, revision, message, feature, changes, bodies}. Fails with \
                FEATURE_NOT_FOUND, INVALID_ARGUMENTS (not a round face, unknown size), REBUILD_FAILED (the size does not fit that face; the \
                reason lists sizes that do), USER_BUSY or STALE_REVISION.
                """,
                inputSchema: object([
                    "document_id": ["type": "string", "description": "The part to change, from list_documents."],
                    "faces": ["type": "array", "items": ["type": "string"], "description": "Cylindrical face ids from get_body."],
                    "size": ["type": "string", "description": "Thread size such as M6x1 or 1/4-20."],
                    "standard": ["type": "string", "enum": ["metric", "metric_fine", "unc", "unf"], "description": "Default metric."],
                    "length": quantity("How far along the face the thread runs (default all)."),
                    "flipped": ["type": "boolean", "description": "Start from the other end of the face."],
                    "left_handed": ["type": "boolean", "description": "Left-hand thread."],
                    "tolerance": ["type": ["number", "string"], "description": "Printing offset: percent of the diameter (default) or mm."],
                    "tolerance_unit": ["type": "string", "enum": ["percent", "mm"], "description": "Unit of tolerance (default percent)."],
                    "name": ["type": "string", "description": "A name for the feature (default Thread1…)."],
                    "id": ["type": "string", "description": "Your own id for the feature: 1–40 letters, digits, _ or -."],
                    "expected_revision": expectedRevision,
                ], ["document_id", "faces", "size"]),
                readOnly: false, destructive: false, idempotent: false,
                handler: { args in try await changeTool("create_thread", service: service, args) }),

            MCPTool(
                name: "create_draft", title: "Lean faces by a draft angle",
                description: """
                Leans side faces over by a small angle so a part can be pulled out of a mould or printed with a slight taper, like the Draft \
                tool. Each face keeps the line where it meets the fixed face and tilts away from it, so the body gets narrower the further \
                it is from that face. Use it for moulded and cast parts, and stackable cups.

                Arguments: document_id; body (required); faces (required: face ids of that body to lean, for example its four walls); \
                fixed_face (required: a flat face of the body that stays put, such as the bottom); angle (required, degrees, usually 1–5; \
                negative leans the other way); name, id, expected_revision. Do it before fillets on those walls.

                Changes the document (one undo step). Returns {success, document_id, revision, message, feature, changes, bodies}. The angle \
                can be changed later with modify_feature. Fails with FEATURE_NOT_FOUND, INVALID_ARGUMENTS, INVALID_VALUE, REBUILD_FAILED \
                (try a smaller angle), USER_BUSY or STALE_REVISION.
                """,
                inputSchema: object([
                    "document_id": ["type": "string", "description": "The part to change, from list_documents."],
                    "body": ["type": "string", "description": "The body to draft."],
                    "faces": ["type": "array", "items": ["type": "string"], "description": "Face ids to lean, from get_body."],
                    "fixed_face": ["type": "string", "description": "A flat face that stays put."],
                    "angle": ["type": ["number", "string"], "description": "Draft angle in degrees."],
                    "name": ["type": "string", "description": "A name for the feature (default Draft1…)."],
                    "id": ["type": "string", "description": "Your own id for the feature: 1–40 letters, digits, _ or -."],
                    "expected_revision": expectedRevision,
                ], ["document_id", "body", "faces", "fixed_face", "angle"]),
                readOnly: false, destructive: false, idempotent: false,
                handler: { args in try await changeTool("create_draft", service: service, args) }),

            MCPTool(
                name: "create_plane", title: "Make a construction plane",
                description: """
                Makes a plane of your own to sketch on, mirror across or build another plane from: another plane moved along its normal \
                and/or tilted. Use it where no face or origin plane is where you need one: a section halfway up for a loft, a sloped plane \
                for an angled cut, a mid-plane for a mirror.

                Arguments: document_id; base (optional, default "xy": "xy", "xz", "yz", "plane:<id>" or a flat face id); offset (optional, mm \
                along the base's normal, default 0); angle (optional, degrees to tilt, default 0); axis (optional: "horizontal" (default) tilts \
                about the base's x axis, "vertical" about its y axis); name, id (give it an id: later steps use "plane:<id>"), expected_revision.

                Changes the document (one undo step). Returns {success, document_id, revision, message, feature, changes, bodies}; use \
                "plane:<id of the feature>" as plane in create_sketch, create_mirror and create_plane. offset and angle can be changed later with \
                modify_feature. Fails with FEATURE_NOT_FOUND, INVALID_ARGUMENTS, INVALID_VALUE, USER_BUSY or STALE_REVISION.
                """,
                inputSchema: object([
                    "document_id": ["type": "string", "description": "The part to change, from list_documents."],
                    "base": ["type": "string", "description": "xy (default), xz, yz, plane:<id> or a flat face id."],
                    "offset": quantity("Distance along the base's normal (default 0)."),
                    "angle": ["type": ["number", "string"], "description": "Tilt in degrees (default 0)."],
                    "axis": ["type": "string", "enum": ["horizontal", "vertical"], "description": "Tilt about the base's x (horizontal) or y (vertical) axis."],
                    "name": ["type": "string", "description": "A name for the feature (default Plane1…)."],
                    "id": ["type": "string", "description": "Your own id for the feature: 1–40 letters, digits, _ or -."],
                    "expected_revision": expectedRevision,
                ], ["document_id"]),
                readOnly: false, destructive: false, idempotent: false,
                handler: { args in try await changeTool("create_plane", service: service, args) }),

            MCPTool(
                name: "create_move", title: "Move and turn bodies",
                description: """
                Moves and/or turns bodies (and sketches) as a feature in the timeline, like the Move tool. The turns happen first, about the \
                middle of what moves, or about the point px, py, pz when you give one (rx about X, then ry about Y, then rz about Z), then the move by dx, dy, dz. Use it to place parts \
                next to each other, stand a body on its side, or lay out a print plate. To change where something is later, change this \
                feature's values with modify_feature rather than adding another.

                Arguments: document_id; bodies and/or sketches (ids; at least one); dx, dy, dz (mm, default 0); rx, ry, rz (degrees, \
                default 0); px, py, pz (mm, the world point the turns are about; give all three or none; default the middle of what moves); \
                at least one value must be non-zero; name, id, expected_revision.

                Changes the document (one undo step). Returns {success, document_id, revision, message, feature, changes, bodies}. Fails with \
                FEATURE_NOT_FOUND, INVALID_ARGUMENTS, REBUILD_FAILED, USER_BUSY or STALE_REVISION.
                """,
                inputSchema: object([
                    "document_id": ["type": "string", "description": "The part to change, from list_documents."],
                    "bodies": ["type": "array", "items": ["type": "string"], "description": "Body ids to move."],
                    "sketches": ["type": "array", "items": ["type": "string"], "description": "Sketch ids to move."],
                    "dx": quantity("Move along X."), "dy": quantity("Move along Y."), "dz": quantity("Move along Z."),
                    "rx": ["type": ["number", "string"], "description": "Turn about X, degrees."],
                    "ry": ["type": ["number", "string"], "description": "Turn about Y, degrees."],
                    "rz": ["type": ["number", "string"], "description": "Turn about Z, degrees."],
                    "px": quantity("Pivot point X: the turns are about this world point (give px, py and pz together)."),
                    "py": quantity("Pivot point Y."), "pz": quantity("Pivot point Z."),
                    "name": ["type": "string", "description": "A name for the feature (default Move1…)."],
                    "id": ["type": "string", "description": "Your own id for the feature: 1–40 letters, digits, _ or -."],
                    "expected_revision": expectedRevision,
                ], ["document_id"]),
                readOnly: false, destructive: false, idempotent: false,
                handler: { args in try await changeTool("create_move", service: service, args) }),

            MCPTool(
                name: "create_scale", title: "Scale bodies or sketches",
                description: """
                Scales bodies (about the middle of their bounding box, all together) and/or sketches (about their own origins) evenly, like \
                the Scale tool. Use it to make a copy of a part bigger or smaller by a factor (2 = twice as big, 0.5 = half). To make ONE \
                dimension longer, change that dimension instead; scaling changes every dimension at once.

                Arguments: document_id; bodies and/or sketches (ids; at least one); factor (required, more than 0 and not 1; a number or an \
                expression); name, id, expected_revision.

                Changes the document (one undo step). Returns {success, document_id, revision, message, feature, changes, bodies}. factor can \
                be changed later with modify_feature. Fails with FEATURE_NOT_FOUND, INVALID_ARGUMENTS, INVALID_VALUE, REBUILD_FAILED, USER_BUSY or \
                STALE_REVISION.
                """,
                inputSchema: object([
                    "document_id": ["type": "string", "description": "The part to change, from list_documents."],
                    "bodies": ["type": "array", "items": ["type": "string"], "description": "Body ids to scale."],
                    "sketches": ["type": "array", "items": ["type": "string"], "description": "Sketch ids to scale."],
                    "factor": ["type": ["number", "string"], "description": "The scale factor, for example 2 or 0.5."],
                    "name": ["type": "string", "description": "A name for the feature (default Scale1…)."],
                    "id": ["type": "string", "description": "Your own id for the feature: 1–40 letters, digits, _ or -."],
                    "expected_revision": expectedRevision,
                ], ["document_id", "factor"]),
                readOnly: false, destructive: false, idempotent: false,
                handler: { args in try await changeTool("create_scale", service: service, args) }),

            MCPTool(
                name: "create_rib", title: "Add a rib",
                description: """
                Adds a thin supporting wall (a rib) along an open sketch line or curve, grown until it meets the body, like the Rib tool. Use it \
                to stiffen a corner, a shelf or a boss: draw the rib's centre line in a sketch on a plane that cuts through the body (a line or \
                a polyline from one wall to another), then make the rib along it. The rib is thickened across the sketch plane.

                Arguments: document_id; path (required: curve ids "curve:<sketch>/<id>" from get_feature, or bare curve ids together with \
                path_sketch); path_sketch (optional); thickness (optional, mm, default 2); target (optional body id; default: the most recent \
                body); name, id, expected_revision.

                Changes the document (one undo step). Returns {success, document_id, revision, message, feature, changes, bodies}. thickness can \
                be changed later with modify_feature. Fails with FEATURE_NOT_FOUND, INVALID_ARGUMENTS, INVALID_VALUE, REBUILD_FAILED (the line does not \
                touch the body, or it is closed), USER_BUSY or STALE_REVISION.
                """,
                inputSchema: object([
                    "document_id": ["type": "string", "description": "The part to change, from list_documents."],
                    "path": ["type": "array", "items": ["type": "string"], "description": "Curve ids of the centre line, all from one sketch."],
                    "path_sketch": ["type": "string", "description": "The sketch of the path, when the curve ids are bare."],
                    "thickness": quantity("The rib's thickness (default 2 mm)."),
                    "target": ["type": "string", "description": "The body to add the rib to (default: the most recent body)."],
                    "name": ["type": "string", "description": "A name for the feature (default Rib1…)."],
                    "id": ["type": "string", "description": "Your own id for the feature: 1–40 letters, digits, _ or -."],
                    "expected_revision": expectedRevision,
                ], ["document_id", "path"]),
                readOnly: false, destructive: false, idempotent: false,
                handler: { args in try await changeTool("create_rib", service: service, args) }),

            MCPTool(
                name: "create_pipe", title: "Make a pipe along a path",
                description: """
                Makes a round pipe (or rod) along a sketch path, like the Pipe tool: tubing, handles, wire frames, cable runs. Give a wall \
                thickness for a hollow pipe, leave it out for a solid rod. For a shape other than round use create_sweep.

                Arguments: document_id; path (required: curve ids "curve:<sketch>/<id>" forming one connected path, or bare ids with \
                path_sketch); path_sketch; diameter (required, mm, outside); wall (optional, mm: makes it hollow; twice the wall must be less than \
                the diameter); operation ("new_body" (default), "join", "cut", "intersect"), target, name, id, expected_revision.

                Changes the document (one undo step). Returns {success, document_id, revision, message, feature, changes, bodies}. diameter and wall can \
                be changed later with modify_feature. Fails with FEATURE_NOT_FOUND, INVALID_ARGUMENTS, INVALID_VALUE, REBUILD_FAILED (a bend tighter than \
                the pipe, say), USER_BUSY or STALE_REVISION.
                """,
                inputSchema: object([
                    "document_id": ["type": "string", "description": "The part to change, from list_documents."],
                    "path": ["type": "array", "items": ["type": "string"], "description": "Curve ids of the path, all from one sketch."],
                    "path_sketch": ["type": "string", "description": "The sketch of the path, when the curve ids are bare."],
                    "diameter": quantity("Outside diameter."),
                    "wall": quantity("Wall thickness; leave out for a solid rod."),
                    "operation": ["type": "string", "enum": ["new_body", "join", "cut", "intersect"], "description": "Default new_body."],
                    "target": ["type": "string", "description": "The body to join, cut or intersect with (default: the most recent body)."],
                    "name": ["type": "string", "description": "A name for the feature (default Pipe1…)."],
                    "id": ["type": "string", "description": "Your own id for the feature: 1–40 letters, digits, _ or -."],
                    "expected_revision": expectedRevision,
                ], ["document_id", "path", "diameter"]),
                readOnly: false, destructive: false, idempotent: false,
                handler: { args in try await changeTool("create_pipe", service: service, args) }),

            MCPTool(
                name: "create_split", title: "Split bodies into pieces",
                description: """
                Divides bodies into separate bodies along a plane, a face or a sketch's plane, like the Split tool. Use it to cut a print in \
                halves (so each half can lie flat), to separate a lid from a base made as one, or to make a cutaway. A plane or a flat face cuts \
                all the way through (it runs on without end); a curved face cuts only where it is. A body the tool does not cross is left as \
                it is. The first piece keeps the body's id; the others get ids of their own, which get_document lists afterwards.

                Arguments: document_id; bodies (required: body ids); exactly ONE of plane ("xy", "xz", "yz", "plane:<id>" (create_plane makes one \
                at any offset or tilt: to cut at a height, make a plane first)), face (a face id) or sketch_id (cut along the plane that sketch \
                lies on) or parts (true: no cut, a body that is really several loose pieces becomes one body per piece, biggest first); name, id, expected_revision.

                Changes the document (one undo step). Returns {success, document_id, revision, message, feature, changes, bodies}. Fails with \
                FEATURE_NOT_FOUND, INVALID_ARGUMENTS, REBUILD_FAILED (the tool misses every body), USER_BUSY or STALE_REVISION.
                """,
                inputSchema: object([
                    "document_id": ["type": "string", "description": "The part to change, from list_documents."],
                    "bodies": ["type": "array", "items": ["type": "string"], "description": "Body ids to split."],
                    "plane": ["type": "string", "description": "xy, xz, yz or plane:<id>."],
                    "face": ["type": "string", "description": "A face id: its plane if flat, the face itself if curved."],
                    "sketch_id": ["type": "string", "description": "Split along the plane this sketch lies on."],
                    "parts": ["type": "boolean", "description": "true: separate the loose pieces of each body into bodies of their own (no cut)."],
                    "name": ["type": "string", "description": "A name for the feature (default Split1…)."],
                    "id": ["type": "string", "description": "Your own id for the feature: 1–40 letters, digits, _ or -."],
                    "expected_revision": expectedRevision,
                ], ["document_id", "bodies"]),
                readOnly: false, destructive: false, idempotent: false,
                handler: { args in try await changeTool("create_split", service: service, args) }),

            MCPTool(
                name: "create_lay_on_floor", title: "Lay a body flat on the floor",
                description: """
                Turns a body so that a chosen flat face looks straight down and sits flat on the floor (the XY plane, z = 0, Z is up), like the \
                Lay on Floor tool. Use it to set the orientation for printing: pick the biggest flat face, or the one that avoids overhangs. The \
                body stays where it is sideways. check_design says when printing the other way up would avoid overhangs.

                Arguments: document_id; face (required: a flat face id from get_body, shape "plane"); name, id, expected_revision.

                Changes the document (one undo step). Returns {success, document_id, revision, message, feature, changes, bodies}. Fails with \
                FEATURE_NOT_FOUND, INVALID_ARGUMENTS (not a flat face), REBUILD_FAILED, USER_BUSY or STALE_REVISION.
                """,
                inputSchema: object([
                    "document_id": ["type": "string", "description": "The part to change, from list_documents."],
                    "face": ["type": "string", "description": "The flat face that should sit on the floor."],
                    "name": ["type": "string", "description": "A name for the feature (default LayOnFloor1…)."],
                    "id": ["type": "string", "description": "Your own id for the feature: 1–40 letters, digits, _ or -."],
                    "expected_revision": expectedRevision,
                ], ["document_id", "face"]),
                readOnly: false, destructive: false, idempotent: false,
                handler: { args in try await changeTool("create_lay_on_floor", service: service, args) }),

            MCPTool(
                name: "create_project", title: "Project text or shapes onto a surface",
                description: """
                Throws the profiles of a sketch (lettering, a logo outline, a pattern) onto a body the way a projector throws a picture on a \
                wall, and either raises them (emboss) or cuts them in (deboss). Unlike a plain extrude it follows a curved surface, so use it for \
                a name on a cylinder or a logo on a rounded lid. The projection runs along the sketch's normal (against it with flipped) and \
                lands on the faces that face the sketch.

                Arguments: document_id; sketch_id (required: the sketch with the text or shapes); profiles (required: "solid", or a list of \
                profile ids from get_feature and {"at": [u, v]} points); target (required: the body to project onto); faces (optional: face ids of \
                the target; default every face that faces the sketch); mode ("emboss" (default) or "deboss"); height (optional, mm, default 1: how \
                far it stands out or sinks in); flipped (optional, default false); name, id, expected_revision.

                Changes the document (one undo step). Returns {success, document_id, revision, message, feature, changes, bodies}. height and mode \
                can be changed later with modify_feature. Fails with FEATURE_NOT_FOUND, INVALID_ARGUMENTS, REBUILD_FAILED (nothing to project onto: \
                flip it, or move the sketch to the other side of the body), USER_BUSY or STALE_REVISION.
                """,
                inputSchema: object([
                    "document_id": ["type": "string", "description": "The part to change, from list_documents."],
                    "sketch_id": ["type": "string", "description": "The sketch with the profiles to project."],
                    "profiles": ["description": "\"solid\", or a list of profile ids and {\"at\": [u, v]} points."],
                    "target": ["type": "string", "description": "The body to project onto."],
                    "faces": ["type": "array", "items": ["type": "string"], "description": "Faces of the target to project onto (default: all that face the sketch)."],
                    "mode": ["type": "string", "enum": ["emboss", "deboss"], "description": "emboss raises (default), deboss cuts in."],
                    "height": quantity("How far it stands out or sinks in (default 1 mm)."),
                    "flipped": ["type": "boolean", "description": "Project against the sketch's normal."],
                    "name": ["type": "string", "description": "A name for the feature (default Project1…)."],
                    "id": ["type": "string", "description": "Your own id for the feature: 1–40 letters, digits, _ or -."],
                    "expected_revision": expectedRevision,
                ], ["document_id", "sketch_id", "profiles", "target"]),
                readOnly: false, destructive: false, idempotent: false,
                handler: { args in try await changeTool("create_project", service: service, args) }),

            MCPTool(
                name: "set_body", title: "Name, colour or hide a body",
                description: """
                Changes how a body looks and what it is called, without changing its shape: a name (shown in the browser and kept in exports), \
                a colour, shown or hidden. Use it to tell the pieces of a multi-part print apart (base orange, lid yellow) and to hide a body \
                that is only there as a tool for a cut. Does not rebuild anything.

                Arguments: document_id; body (required: a body id from get_document); name (optional; "" goes back to the default name); color \
                (optional: "#RRGGBB", or "default"); visible (optional: true or false); at least one of name, color, visible; expected_revision.

                Changes the document (one undo step). Returns {success, document_id, revision, message, bodies}. Fails with FEATURE_NOT_FOUND, \
                INVALID_ARGUMENTS, INVALID_VALUE, USER_BUSY or STALE_REVISION.
                """,
                inputSchema: object([
                    "document_id": ["type": "string", "description": "The part to change, from list_documents."],
                    "body": ["type": "string", "description": "The body id."],
                    "name": ["type": "string", "description": "A new name (\"\" for the default)."],
                    "color": ["type": "string", "description": "#RRGGBB, or \"default\"."],
                    "visible": ["type": "boolean", "description": "Show or hide the body."],
                    "expected_revision": expectedRevision,
                ], ["document_id", "body"]),
                readOnly: false, destructive: false, idempotent: false,
                handler: { args in try await changeTool("set_body", service: service, args) }),

            MCPTool(
                name: "create_image", title: "Place a reference picture",
                description: """
                Puts a picture file from this Mac on a plane or flat face as a reference image (a Canvas), like the Canvas tool: to trace over \
                in a sketch, or to hold a photo of an object at a known size so its outline can be copied. It builds nothing and is not drawn \
                by get_viewport_image. A photo only gives true sizes if the width given here matches how wide the thing really is in the \
                photo: ask the user for one measured length first.

                Arguments: document_id; path (required: absolute path of a PNG, JPEG, HEIC or TIFF file, at most 30 MB); plane (optional, default \
                "xy": "xy", "xz", "yz", "plane:<id>" or a flat face id); u, v (optional, mm: where its middle goes on the plane, default 0); \
                width (optional, mm across the plane's x axis, default 100; the height follows the picture's proportions); angle (optional, \
                degrees, default 0); opacity (optional, 0 to 1, default 0.5); name, id, expected_revision.

                Changes the document (one undo step). Returns {success, document_id, revision, message, feature, changes, bodies}. u, v, width and \
                angle can be changed later with modify_feature. Fails with INVALID_ARGUMENTS (no such file, not a picture), INVALID_VALUE, USER_BUSY or \
                STALE_REVISION.
                """,
                inputSchema: object([
                    "document_id": ["type": "string", "description": "The part to change, from list_documents."],
                    "path": ["type": "string", "description": "Absolute path of the picture file."],
                    "plane": ["type": "string", "description": "xy (default), xz, yz, plane:<id> or a flat face id."],
                    "u": quantity("Where the middle goes, across the plane (default 0)."), "v": quantity("Where the middle goes, up the plane (default 0)."),
                    "width": quantity("Width across the plane (default 100 mm)."),
                    "angle": ["type": ["number", "string"], "description": "Turn about the middle, degrees (default 0)."],
                    "opacity": ["type": "number", "minimum": 0, "maximum": 1, "description": "0 see-through to 1 solid (default 0.5)."],
                    "name": ["type": "string", "description": "A name for the feature (default Canvas1…)."],
                    "id": ["type": "string", "description": "Your own id for the feature: 1–40 letters, digits, _ or -."],
                    "expected_revision": expectedRevision,
                ], ["document_id", "path"]),
                readOnly: false, destructive: false, idempotent: false,
                handler: { args in try await changeTool("create_image", service: service, args) }),

            MCPTool(
                name: "import_file", title: "Import a STEP or STL file",
                description: """
                Adds a STEP (.step, .stp) or STL (.stl) file from this Mac to the part as a body of its own, like Import. Use it to \
                build on a part someone else made, or a mesh. An STL must be watertight and is read in millimetres; the file is stored \
                inside the part, so it opens without the original. Only these file types are read, up to 100 MB.

                Arguments: document_id; path (required: the absolute path of the file, such as /Users/me/Downloads/bracket.step); name \
                (optional: the body's name, default the file's name); id (optional); expected_revision. Faces and edges of an imported body \
                are named by the file, so read them with get_body before using them.

                Changes the document (one undo step). Returns {success, document_id, revision, message, feature, changes, bodies}. Fails with \
                INVALID_ARGUMENTS (not an absolute path, not a STEP/STL file, missing, too large), REBUILD_FAILED (the kernel cannot make a body \
                of it, for instance an STL with holes), USER_BUSY or STALE_REVISION.
                """,
                inputSchema: object([
                    "document_id": ["type": "string", "description": "The part to change, from list_documents."],
                    "path": ["type": "string", "description": "Absolute path of a .step, .stp or .stl file."],
                    "name": ["type": "string", "description": "The body's name (default the file's name)."],
                    "id": ["type": "string", "description": "Your own id for the feature: 1–40 letters, digits, _ or -."],
                    "expected_revision": expectedRevision,
                ], ["document_id", "path"]),
                readOnly: false, destructive: false, idempotent: false,
                handler: { args in try await changeTool("import_file", service: service, args) }),

            MCPTool(
                name: "export_file", title: "Export bodies to STL, 3MF or STEP",
                description: """
                Writes the part's bodies to an STL or 3MF file (for 3D printing; 3MF also keeps units and body colours) or a STEP file (for other CAD programs), like Export. The file is \
                written to the folder "SimplMaker Exports" in the user's Documents folder, never over a file that is already there (a number \
                is added to the name instead). Tell the user where it is. The part itself does not change.

                Arguments: document_id (required); format (required: "stl", "3mf" or "step"); bodies (optional: body ids; default every body); \
                file_name (optional: a name without folders; default the part's name). For a print with several parts, either export them \
                together or one file per body with bodies.

                Returns {success, document_id, message, path, format, bytes, bodies}. Fails with INVALID_ARGUMENTS (no bodies, bad format), \
                FEATURE_NOT_FOUND (a body that does not exist).
                """,
                inputSchema: object([
                    "document_id": ["type": "string", "description": "The part to export, from list_documents."],
                    "format": ["type": "string", "enum": ["stl", "3mf", "step"], "description": "stl or 3mf for printing, step for CAD."],
                    "bodies": ["type": "array", "items": ["type": "string"], "description": "Body ids to export (default all)."],
                    "file_name": ["type": "string", "description": "File name without folders (default the part's name)."],
                ], ["document_id", "format"]),
                readOnly: false, destructive: false, idempotent: false,
                handler: { args in
                    let a = AIArguments(args)
                    try a.rejectUnknown(["document_id", "format", "bodies", "file_name"], in: "export_file")
                    let ids: [String]? = try a.array("bodies")?.enumerated().map { index, item in
                        guard let text = item.string else { throw AIError(.invalidArguments, "bodies[\(index)] must be a body id.") }
                        return text
                    }
                    return try JSONValue(encoding: try await service.exportFile(documentID: try a.requiredDocumentID(), bodyIDs: ids,
                                                                                format: try a.requiredString("format", hint: "\"stl\", \"3mf\" or \"step\"."),
                                                                                fileName: try a.string("file_name")))
                }),

            MCPTool(
                name: "delete_feature", title: "Delete a feature",
                description: """
                Removes a feature (a box, a sketch, an extrude…) from the part. Use it to take away something that is wrong or no longer \
                wanted, or to remake something: delete it and create it again, in one batch. To change a size, use modify_feature instead.

                Arguments: document_id (required); feature_id (required, from get_document); with_children (optional, default false); \
                expected_revision (optional). Features built from the one deleted (the extrude of a sketch, a fillet of a body) would lose \
                what they stand on, so they are listed and nothing is deleted unless with_children is true, which deletes them too. A \
                sketch that was hidden because the deleted feature used it is shown again.

                Changes the document (one undo step "AI: Delete …"). Returns {success, document_id, revision, message, bodies}. Fails with \
                FEATURE_NOT_FOUND, HAS_DEPENDENTS (the message lists them), USER_BUSY, STALE_REVISION or REBUILD_FAILED.
                """,
                inputSchema: object([
                    "document_id": ["type": "string", "description": "The part to change, from list_documents."],
                    "feature_id": ["type": "string", "description": "The feature to delete, from get_document."],
                    "with_children": ["type": "boolean", "description": "Also delete everything built from it (default false)."],
                    "expected_revision": expectedRevision,
                ], ["document_id", "feature_id"]),
                readOnly: false, destructive: true, idempotent: false,
                handler: { args in try await changeTool("delete_feature", service: service, args) }),

            MCPTool(
                name: "batch", title: "Make several changes as one",
                description: """
                Runs a list of change tools in order as ONE transaction and ONE undo step: if any step fails, none is applied. Use it for \
                anything made of several steps, such as a key ring (sketch, shapes, extrude, text sketch, extrude), so the user gets a \
                single Undo and never sees a half-built model. Each step sees what the earlier ones made, so a step can extrude a profile \
                found by {"at": [x, y]} or use a face of a body an earlier step created.

                Start a batch that builds something with set_parameter steps for the dimensions that matter (width, wall, radius…), and \
                write those names as the sizes in the later steps: later steps see the parameters earlier ones made, and the user can \
                then resize the whole part by changing one number.

                Arguments: document_id (required); operations (required): a list of {tool, arguments}, where tool is one of create_box, \
                create_sketch, edit_sketch, create_extrude, create_revolve, create_fillet, create_chamfer, create_hole, create_shell, create_mirror, create_pattern, create_combine, create_sweep, create_twist_sweep, create_loft, create_thread, create_draft, create_plane, create_move, create_scale, create_rib, create_pipe, create_split, create_lay_on_floor, create_project, create_image, set_body, import_file, modify_feature, set_parameter, delete_feature and arguments are that tool's arguments WITHOUT \
                document_id; label (optional: the name of the undo step); expected_revision (optional). Give your own ids to what you create \
                (id: "outline") so later steps can name it; ids made for you cannot be known in advance.

                Changes the document. Returns {success, document_id, revision, message, steps: [{step, tool, message, feature, changes, \
                created, sketch}], bodies}. On failure the error says which step failed ("Step 3 of 5 (create_extrude): …") and that nothing \
                was applied; fix that step and send the batch again. Fails like the tools it contains, and with INVALID_ARGUMENTS for a \
                tool a batch cannot run (reading tools, undo, redo, batch).
                """,
                inputSchema: object([
                    "document_id": ["type": "string", "description": "The part to change, from list_documents."],
                    "operations": ["type": "array", "description": "The steps, in order.", "items": [
                        "type": "object",
                        "properties": ["tool": ["type": "string", "enum": .array(AIOperationParser.changeTools.map { .string($0) })], "arguments": ["type": "object"]],
                        "required": ["tool", "arguments"],
                    ]],
                    "label": ["type": "string", "description": "The undo step's name, such as \"Key ring\"."],
                    "expected_revision": expectedRevision,
                ], ["document_id", "operations"]),
                readOnly: false, destructive: true, idempotent: false,
                handler: { args in
                    let a = AIArguments(args)
                    try a.rejectUnknown(["document_id", "operations", "label", "expected_revision"], in: "batch")
                    let documentID = try a.requiredDocumentID()
                    guard let steps = try a.array("operations"), !steps.isEmpty else {
                        throw AIError(.invalidArguments, "operations is required: a list of steps.", reason: "For example [{\"tool\": \"create_box\", \"arguments\": {\"width\": 10, \"length\": 10, \"height\": 5}}].")
                    }
                    guard steps.count <= 40 else { throw AIError(.invalidArguments, "A batch can have at most 40 steps (this has \(steps.count)).") }
                    let names = await service.featureNames(documentID: documentID)
                    var operations: [any AIOperation] = []
                    for (n, step) in steps.enumerated() {
                        guard let tool = step["tool"]?.string else {
                            throw AIError(.invalidArguments, "operations[\(n)] needs a \"tool\".", reason: "One of: \(AIOperationParser.changeTools.joined(separator: ", ")).")
                        }
                        var arguments = step["arguments"] ?? .object([:])
                        guard var object = arguments.object else { throw AIError(.invalidArguments, "operations[\(n)].arguments must be an object.") }
                        guard object["document_id"] == nil, object["expected_revision"] == nil else {
                            throw AIError(.invalidArguments, "operations[\(n)].arguments must not have document_id or expected_revision: they are given once for the whole batch.")
                        }
                        object["document_id"] = .string(documentID)  // so the single-tool rules about arguments apply as they are
                        arguments = .object(object)
                        do { operations.append(try AIOperationParser.parse(tool: tool, arguments: arguments, names: names)) } catch var error as AIError {
                            error.message = "Step \(n + 1) of \(steps.count) (\(tool)): " + error.message
                            error.reason = (error.reason.map { $0 + " " } ?? "") + "None of the steps was applied."
                            throw error
                        }
                    }
                    return try JSONValue(encoding: try await service.batch(documentID: documentID, expectedRevision: try a.expectedRevision(),
                                                                           label: try a.string("label"), operations))
                }),

            MCPTool(
                name: "get_body", title: "Describe a body's faces and edges",
                description: """
                Lists the faces and edges of one body with their ids, shape and position, so you can refer to "the top face" or "the hole's \
                edge" exactly. Use it before putting a sketch on a face, starting an extrude from a face, or measuring a part of the body.

                Arguments: body_id (required: from get_document's bodies); document_id (optional).

                Read-only. Returns {document_id, revision, body, faces, edges, truncated}. Each face has id ("face:<body>/<name>"), shape \
                ("plane", "cylinder", "cone", "sphere", "torus"), area, facing (for a flat face square to an axis: "+z" is a top face, "-z" a \
                bottom face, "+x", "-y"…), direction (a flat face's normal out of the material, a round face's axis), center, radius (round \
                faces) and bounds. Each edge has id, shape ("line", "circle", "arc"), length, start, end, center and radius (circles), and the \
                two faces it lies between. Coordinates are model coordinates in mm. Face and edge names can change when the part is edited: \
                read them again after any change. truncated is true when there were more than 300 faces or 600 edges.

                Fails with FEATURE_NOT_FOUND (no such body), NO_ACTIVE_DOCUMENT or DOCUMENT_NOT_FOUND.
                """,
                inputSchema: object(["document_id": documentID, "body_id": ["type": "string", "description": "The body, from get_document."]], ["body_id"]),
                readOnly: true,
                handler: { args in
                    let a = AIArguments(args)
                    return try JSONValue(encoding: try await service.getBody(documentID: try a.string("document_id"),
                                                                              bodyID: try a.requiredString("body_id", hint: "Take it from the bodies of get_document.")))
                }),

            MCPTool(
                name: "measure", title: "Measure bodies, faces and edges",
                description: """
                Measures one thing, or the distance and angle between two. Use it to check your work: that two holes are 60 mm apart, that a \
                wall is as thick as asked, how big a part came out.

                Arguments: a (required) and b (optional): each a body id, a face "face:<body>/<name>" or an edge "edge:<body>/<name>" (get_body \
                lists them); document_id (optional).

                Read-only. Returns {document_id, revision, a, b, distance, closest_point_a, closest_point_b, angle_degrees, normals_angle_degrees}. \
                Each of a and b has kind and what applies: area (a body's or face's), length (an edge's), volume (a body's), perimeter (a face's), \
                radius and diameter (round things), center, direction, start/end (an edge), bounds_min, bounds_max and extent (size along x, y, z). \
                With two things: distance is the shortest distance between them (0 if they touch) with the two closest points; angle_degrees is the \
                angle between their directions (normals, axes, edges) ignoring sense, 0 to 90; normals_angle_degrees is the angle between two flat \
                faces' outward normals, 0 to 180. To measure the distance between the centres of two holes, measure the two round faces: their \
                center values give it, or measure their edges (circles) and use distance minus the radii. All in mm and degrees.

                Fails with FEATURE_NOT_FOUND (no such body, face or edge: names change after edits), INVALID_ARGUMENTS, NO_ACTIVE_DOCUMENT or \
                DOCUMENT_NOT_FOUND.
                """,
                inputSchema: object(["document_id": documentID,
                                     "a": ["type": "string", "description": "A body id, \"face:<body>/<name>\" or \"edge:<body>/<name>\"."],
                                     "b": ["type": "string", "description": "A second thing, to measure the distance and angle to."]], ["a"]),
                readOnly: true,
                handler: { args in
                    let a = AIArguments(args)
                    return try JSONValue(encoding: try await service.measure(documentID: try a.string("document_id"),
                                                                              a: try a.requiredString("a"), b: try a.string("b")))
                }),

            MCPTool(
                name: "slice_body", title: "Cut a body with a plane and read the outline",
                description: """
                Cuts a body with a plane square to X, Y or Z, at one or several positions, and returns the outline of each cut as closed \
                loops of points, with the cut's area, centre, bounds, longest direction, length and width. Use it to READ a shape you \
                cannot read from its features: above all an imported STL, which is a lump of triangles with no feature tree. Slice it \
                along its length, read each section's chord (length), thickness (width), tilt (major_axis_degrees) and offset, and draw the \
                same sections again (create_plane + create_sketch + edit_sketch + create_loft, or create_twist_sweep for a twisted plate). It \
                works on any body, so it also measures what you built: compare a slice of your part with a slice of the original.

                Arguments: body_id (required: from get_document's bodies); axis (required: "x", "y" or "z": the plane is square to it); \
                the positions as either offsets: [mm, …] or from, to and count (evenly spaced, count 2 to 100, both ends included); \
                tolerance (optional, mm, default 0.02: corners within this of a straight line are dropped, 0 keeps every point; raise it \
                to 0.1–0.3 for a rough outline of a scan); points (optional, default true: false leaves the points out and returns just \
                the sizes, which is much shorter); document_id (optional).

                Read-only. Returns {document_id, revision, body, axis, plane, coordinates, body_range, tolerance, sections}. body_range is \
                how far the body reaches along the axis, to choose offsets in. Each section has offset, loops ([{area, hole, closed, points}]: \
                outer outlines run counter-clockwise, holes clockwise; closed false means the mesh has a gap), and when the plane hits the \
                body: area, centroid [u, v], bounds [min u, min v, max u, max v], major_axis_degrees (the direction the cut is longest in, from \
                the u axis, -90 to 90: a thin plate's tilt), length (along it: a plate's chord) and width (across it: its thickness). u and v \
                are the sketch coordinates of the plane: axis x → plane "yz" with u = Y, v = Z; axis y → "xz" with u = X, v = Z; axis z → "xy" \
                with u = X, v = Y. So a point from a slice can go straight into edit_sketch on a sketch made on a plane (create_plane, \
                base = that plane, offset = the slice's offset). A plane that misses the body gives an empty section.

                Fails with FEATURE_NOT_FOUND (no such body), INVALID_ARGUMENTS, INVALID_VALUE, NO_ACTIVE_DOCUMENT or DOCUMENT_NOT_FOUND.
                """,
                inputSchema: object([
                    "document_id": documentID,
                    "body_id": ["type": "string", "description": "The body, from get_document."],
                    "axis": ["type": "string", "enum": ["x", "y", "z"], "description": "The plane is square to this axis."],
                    "offsets": ["type": "array", "items": ["type": "number"], "description": "Positions along the axis, mm."],
                    "from": ["type": "number", "description": "First position, mm (with to and count)."],
                    "to": ["type": "number", "description": "Last position, mm."],
                    "count": ["type": "integer", "description": "How many evenly spaced positions, 2 to 100."],
                    "tolerance": ["type": "number", "description": "Drop corners within this of a straight line, mm (default 0.02; 0 keeps all)."],
                    "points": ["type": "boolean", "description": "Include the outline points (default true)."],
                ], ["body_id", "axis"]),
                readOnly: true,
                handler: { args in
                    let a = AIArguments(args)
                    try a.rejectUnknown(["document_id", "body_id", "axis", "offsets", "from", "to", "count", "tolerance", "points"], in: "slice_body")
                    var offsets: [Double] = []
                    if let list = try a.array("offsets") {
                        offsets = try list.enumerated().map { index, item in
                            guard let n = item.number else { throw AIError(.invalidArguments, "offsets[\(index)] must be a number (mm).") }
                            return n
                        }
                    }
                    let hasRange = args["from"] != nil || args["to"] != nil || args["count"] != nil
                    guard offsets.isEmpty != hasRange else {
                        throw AIError(.invalidArguments, offsets.isEmpty ? "Send offsets, or from, to and count." : "Send either offsets or from/to/count, not both.",
                                      reason: "For example offsets: [-200, -150, -100], or from: -230, to: -80, count: 16.")
                    }
                    if hasRange {
                        guard let from = args["from"]?.number, let to = args["to"]?.number, let count = try a.integer("count"), count >= 2 else {
                            throw AIError(.invalidArguments, "from, to and count (2 or more) are all needed for evenly spaced positions.")
                        }
                        guard count <= CADService.maxSliceOffsets else {
                            throw AIError(.invalidArguments, "count can be at most \(CADService.maxSliceOffsets) (ask for fewer, or slice twice).")
                        }
                        offsets = (0..<count).map { from + (to - from) * Double($0) / Double(count - 1) }
                    }
                    let tolerance = args["tolerance"]?.number ?? 0.02
                    return try JSONValue(encoding: try await service.sliceBody(
                        documentID: try a.string("document_id"), bodyID: try a.requiredString("body_id", hint: "Take it from the bodies of get_document."),
                        axis: try a.requiredString("axis", hint: "\"x\", \"y\" or \"z\"."), offsets: offsets, tolerance: tolerance,
                        includePoints: try a.bool("points") ?? true))
                }),

            MCPTool(
                name: "get_viewport_image", title: "Look at the part (picture)",
                description: """
                Returns a PICTURE of the part as the app draws it: shaded, with its edges, framed to fit, with the X (red), Y (green) \
                and Z (blue) axes through the origin. Use it to LOOK at what you built: after any build, check that it looks like what \
                was asked (is the lid on the right way up, is the text where it should be, does the handle reach the body), and when a \
                number looks right but something feels off. Numbers from get_body and measure do not show shapes; the picture does. Look \
                from more than one direction for anything three-dimensional: iso first, then front, top or the side that matters.

                Arguments: document_id (optional, default the front window); view (optional: "iso" (default), "front", "back", "left", \
                "right", "top", "bottom"); azimuth and elevation (optional, degrees: your own angle instead of view; azimuth turns about Z \
                from the right side (+X), elevation tilts up from the XY plane); width, height (optional pixels, default 1024 × 768); axes \
                (optional, default true). The picture shows visible bodies only, unless you ask for more:
                - only (optional): a list of body ids to show, and nothing else (hidden bodies too). Use it to look at one part of an \
                assembly on its own, such as the lid without the box.
                - section (optional): cuts the part open to show the inside, like Section Analysis: {axis ("x", "y" or "z"), offset (mm \
                along that axis; default the middle of what is shown), cut_away ("positive" or "negative": which side to remove; default the \
                side facing the camera, so you see the cut face)}. Use it to check wall thickness, internal cavities, a snap fit or a thread; \
                the cut face is hatched. The picture is the same view otherwise: choose a view that looks along the cut.
                - sketches (optional): a list of sketch ids to draw as thin lines, hidden ones too (a sketch is hidden once an extrude has \
                used it). Use it to see where a path or a profile lies.

                Read-only: does not change the part or the user's own view. Returns the image and {document_id, revision, view, width, \
                height, orientation (which way X, Y and Z run in this picture), bodies}. Fails with INVALID_ARGUMENTS (nothing to show, bad \
                size) or DOCUMENT_NOT_FOUND.
                """,
                inputSchema: object([
                    "document_id": documentID,
                    "view": ["type": "string", "enum": .array(SnapshotDirection.allCases.map { .string($0.rawValue) }), "description": "Direction to look from (default iso)."],
                    "azimuth": ["type": "number", "description": "Your own angle about Z in degrees (0 = from +X, -90 = from the front)."],
                    "elevation": ["type": "number", "description": "Your own tilt above the XY plane in degrees (-89…89)."],
                    "width": ["type": "integer", "description": "Picture width in pixels (256–1600, default 1024)."],
                    "height": ["type": "integer", "description": "Picture height in pixels (192–1200, default 768)."],
                    "axes": ["type": "boolean", "description": "Draw the X, Y, Z axes (default true)."],
                    "only": ["type": "array", "items": ["type": "string"], "description": "Show only these bodies (ids), hidden ones too."],
                    "section": ["type": "object", "description": "Cut the part open.", "properties": [
                        "axis": ["type": "string", "enum": ["x", "y", "z"]], "offset": ["type": "number", "description": "mm along the axis (default the middle)."],
                        "cut_away": ["type": "string", "enum": ["positive", "negative"], "description": "Which side to remove (default: the side facing the camera)."]],
                        "required": ["axis"]],
                    "sketches": ["type": "array", "items": ["type": "string"], "description": "Sketch ids to draw as lines."],
                ], []),
                readOnly: true,
                handler: { args in
                    let a = AIArguments(args)
                    try a.rejectUnknown(["document_id", "view", "azimuth", "elevation", "width", "height", "axes", "only", "section", "sketches"], in: "get_viewport_image")
                    var options = SnapshotOptions()
                    if let only = try a.array("only") {
                        options.only = try only.enumerated().map { index, item in
                            guard let text = item.string else { throw AIError(.invalidArguments, "only[\(index)] must be a body id.") }
                            return text
                        }
                        if options.only?.isEmpty == true { throw AIError(.invalidArguments, "only is empty.", reason: "Leave it out to show every visible body.") }
                    }
                    options.sketches = try (a.array("sketches") ?? []).enumerated().map { index, item in
                        guard let text = item.string else { throw AIError(.invalidArguments, "sketches[\(index)] must be a sketch id.") }
                        return text
                    }
                    if let cut = try a.object("section") {
                        try AIArguments(.object(cut)).rejectUnknown(["axis", "offset", "cut_away"], in: "section")
                        guard let axisText = cut["axis"]?.string, let axis = SnapshotSection.axisNames.firstIndex(of: axisText.lowercased()) else {
                            throw AIError(.invalidArguments, "section.axis must be \"x\", \"y\" or \"z\".")
                        }
                        var offset: Double?
                        if let v = cut["offset"], v != .null {
                            guard let n = v.number, n.isFinite else { throw AIError(.invalidArguments, "section.offset must be a number of mm.") }
                            offset = n
                        }
                        var positive: Bool?
                        if let v = cut["cut_away"], v != .null {
                            guard let text = v.string, text == "positive" || text == "negative" else {
                                throw AIError(.invalidArguments, "section.cut_away must be \"positive\" or \"negative\".")
                            }
                            positive = text == "positive"
                        }
                        options.section = SnapshotSection(axis: axis, offset: offset, cutPositive: positive)
                    }
                    let viewText = try a.string("view") ?? "iso"
                    guard let direction = SnapshotDirection(rawValue: viewText) else {
                        throw AIError(.invalidArguments, "view \"\(viewText)\" is not one of \(SnapshotDirection.allCases.map(\.rawValue).joined(separator: ", ")).")
                    }
                    func number(_ key: String) throws -> Double? {
                        guard let v = args[key], v != .null else { return nil }
                        guard let n = v.number, n.isFinite else { throw AIError(.invalidArguments, "\(key) must be a number of degrees.") }
                        return n
                    }
                    let azimuth = try number("azimuth"), elevation = try number("elevation")
                    let r = try await service.viewportImage(documentID: try a.string("document_id"), direction: direction, azimuth: azimuth,
                                                            elevation: elevation, width: try a.integer("width") ?? 1024,
                                                            height: try a.integer("height") ?? 768, axes: try a.bool("axes") ?? true, options: options)
                    let custom = azimuth != nil || elevation != nil
                    let orientation = custom
                        ? "Your own angle (azimuth \(azimuth.map { AIValues.number($0) } ?? "of the \(direction.rawValue) view"), elevation \(elevation.map { AIValues.number($0) } ?? "of the \(direction.rawValue) view") degrees). Axes: X red, Y green, Z blue."
                        : r.direction.orientation + " Axes: X red, Y green, Z blue."
                    var answer: [String: JSONValue] = [
                        "success": true, "document_id": .string(r.documentID), "revision": .int(r.revision),
                        "view": .string(custom ? "custom" : r.direction.rawValue), "width": .int(r.image.width), "height": .int(r.image.height),
                        "orientation": .string(orientation),
                        "bodies": .array(r.bodies.map { .string($0) }),
                        "_images": [["data": .string(r.image.png.base64EncodedString()), "mime_type": "image/png"]],
                    ]
                    if let section = r.image.section { answer["section"] = .string(section) }
                    if !r.sketches.isEmpty { answer["sketches"] = .array(r.sketches.map { .string($0) }) }
                    return .object(answer)
                }),

            MCPTool(
                name: "check_design", title: "Check the part for printing problems",
                description: """
                Looks over the part like an experienced designer would before it goes to the printer, and lists what is likely to go wrong: \
                features that do not build, invalid solids, walls thinner than a 0.4 mm nozzle can make (default 1.2 mm), gaps that will fuse \
                shut, overhangs that need support (and whether printing a body upside down avoids them), parts too big for the bed, the \
                clearance between separate bodies (a lid and its box), and sizes that are fixed numbers although they should follow parameters. \
                Use it after building anything meant to be printed, and fix what it finds before you say you are done. The checks are \
                heuristics on flat faces: a finding is a reason to look (get_viewport_image, measure), not a verdict.

                Arguments: document_id (optional, default the front window); bed (optional: [x, y, z] mm, default [220, 220, 250]); \
                min_wall (optional: mm, default 1.2). Read-only. Returns {success, document_id, revision, summary, findings: [{severity \
                ("error", "warning", "note"), code, message, about (ids), fix}], bed, min_wall}. Fails with INVALID_ARGUMENTS or \
                DOCUMENT_NOT_FOUND.
                """,
                inputSchema: object([
                    "document_id": documentID,
                    "bed": ["type": "array", "items": ["type": "number"], "minItems": 3, "maxItems": 3, "description": "Printer bed [x, y, z] in mm (default [220, 220, 250])."],
                    "min_wall": ["type": "number", "description": "Thinnest wall to accept, in mm (default 1.2)."],
                ], []),
                readOnly: true,
                handler: { args in
                    let a = AIArguments(args)
                    try a.rejectUnknown(["document_id", "bed", "min_wall"], in: "check_design")
                    var bed: [Double]?
                    if let list = try a.array("bed") {
                        let numbers = list.compactMap(\.number)
                        guard numbers.count == list.count else { throw AIError(.invalidArguments, "bed must be three numbers [x, y, z] in mm.") }
                        bed = numbers
                    }
                    let wall: Double?
                    if let v = args["min_wall"], v != .null {
                        guard let n = v.number else { throw AIError(.invalidArguments, "min_wall must be a number of mm.") }
                        wall = n
                    } else { wall = nil }
                    return try JSONValue(encoding: try await service.checkDesign(documentID: try a.string("document_id"), bed: bed, minWall: wall))
                }),

            MCPTool(
                name: "get_design_guide", title: "Read the design guide",
                description: """
                A short guide, a topic at a time, to designing well in SimplMaker: how to go from a request to a finished part, how to use \
                parameters, the numbers that matter for 3D printing (wall thickness, clearances, overhangs), hole and thread sizes, the \
                order of fillets, shells and holes, how to find faces and edges, how to recreate a part from a photo, how to fix a failing \
                step, and RECIPES that are known to build: a rounded box with a snap-fit lid, a rounded open box, a name tag with raised text. \
                Use it BEFORE designing anything bigger than a plain block, and again when a step fails. Without a topic it lists the \
                topics; ask for "workflow" and "parameters" first, then the ones that fit the request ("snap_fit_lid" for a box with a lid).

                Arguments: topic (optional: a topic id from the list). Read-only; needs no document. Returns {topics: [{id, title, when}]} or \
                {topic, title, guide}. A recipe in a guide is the exact list of steps for the batch tool: change the numbers in the first \
                set_parameter steps to the user's and send the rest as they are.
                """,
                inputSchema: object(["topic": ["type": "string", "description": "A topic id from the list (omit to list them)."]], []),
                readOnly: true,
                handler: { args in
                    let a = AIArguments(args)
                    try a.rejectUnknown(["topic"], in: "get_design_guide")
                    return try await service.designGuide(topic: try a.string("topic"))
                }),

            MCPTool(
                name: "undo", title: "Undo the last change",
                description: """
                Undoes the most recent step in the part's undo history, exactly like the user choosing Edit ▸ Undo. Use it to take \
                back a change you made that turned out wrong, or when the user asks you to. It undoes the latest step whoever \
                made it, so check get_document first if the user may have edited the part since your last change: the step's name \
                comes back so you can tell ("AI: Create Box1" is yours).

                Arguments: document_id (required); expected_revision (optional: refuse if the part is not at the revision you \
                last saw, which stops you undoing something of the user's).

                Changes the document. Returns {success, document_id, revision, message, step, feature_count, bodies}. Fails with \
                NOTHING_TO_UNDO, UNDO_UNAVAILABLE, USER_BUSY or STALE_REVISION.
                """,
                inputSchema: object(["document_id": ["type": "string", "description": "The part, from list_documents."], "expected_revision": expectedRevision],
                                    ["document_id"]),
                readOnly: false, destructive: true, idempotent: false,
                handler: { args in
                    let a = AIArguments(args)
                    return try JSONValue(encoding: try await service.undo(documentID: try a.requiredDocumentID(), expectedRevision: try a.expectedRevision()))
                }),

            MCPTool(
                name: "redo", title: "Redo an undone change",
                description: """
                Redoes the step that undo just took back, like Edit ▸ Redo. It works only right after undo, before anything else \
                changes the part.

                Arguments: document_id (required); expected_revision (optional).

                Changes the document. Returns {success, document_id, revision, message, step, feature_count, bodies}. Fails with \
                NOTHING_TO_REDO, UNDO_UNAVAILABLE, USER_BUSY or STALE_REVISION.
                """,
                inputSchema: object(["document_id": ["type": "string", "description": "The part, from list_documents."], "expected_revision": expectedRevision],
                                    ["document_id"]),
                readOnly: false, destructive: false, idempotent: false,
                handler: { args in
                    let a = AIArguments(args)
                    return try JSONValue(encoding: try await service.redo(documentID: try a.requiredDocumentID(), expectedRevision: try a.expectedRevision()))
                }),
        ]
    }

    /// A change tool: parsed like every operation, run as one transaction.
    private static func changeTool(_ tool: String, service: CADService, _ args: JSONValue) async throws -> JSONValue {
        let a = AIArguments(args)
        let documentID = try a.requiredDocumentID()
        let operation = try AIOperationParser.parse(tool: tool, arguments: args, names: await service.featureNames(documentID: documentID))
        return try JSONValue(encoding: try await service.change(documentID: documentID, expectedRevision: try a.expectedRevision(), operation))
    }

    private static let expectedRevision: JSONValue = [
        "type": "integer",
        "description": "The revision you last read. The call is refused if the part has changed since (the user edited it).",
    ]

    /// A position in a sketch: [x, y].
    private static func position(_ description: String) -> JSONValue {
        ["type": "array", "items": ["type": ["number", "string"]], "minItems": 2, "maxItems": 2,
         "description": .string(description + " [x, y] in mm (numbers or expressions).")]
    }

    /// A size: a number (mm) or an expression text.
    private static func quantity(_ description: String) -> JSONValue {
        ["type": ["number", "string"], "description": .string(description + " A number is millimetres; text is an expression such as \"2 in\" or \"wall * 2\".")]
    }

    /// An optional string argument; anything else is refused.
    private static func string(_ args: JSONValue, _ key: String) throws -> String? {
        guard let value = args[key], value != .null else { return nil }
        guard let s = value.string else { throw AIError(.invalidArguments, "\(key) must be a string.", recoverable: true) }
        return s
    }

    static func makeServer(service: CADService, version: String,
                           onInitialize: (@Sendable (String, String) -> Void)? = nil,
                           onToolCall: (@Sendable (MCPToolCall) -> Void)? = nil) -> MCPServer {
        MCPServer(name: "SimplMaker", version: version, instructions: serverInstructions, tools: make(service: service),
                  describeFailure: { AIError.describing($0) }, onInitialize: onInitialize, onToolCall: onToolCall)
    }
}
