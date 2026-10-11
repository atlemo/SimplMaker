// The tools an AI client sees. Few, and designed for an AI rather than mirroring the CAD functions: the descriptions
// say what a tool does, when to use it, what it needs and returns, and what can go wrong, because that text is all the
// model has to go on. Each tool calls CADService, which owns the behaviour; nothing here touches a document.
// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import Foundation

enum AITools {
    static let serverInstructions = """
    SimplMaker is a parametric CAD application. A part is a timeline of features (sketches, extrudes, fillets…) that \
    SimplMaker rebuilds whenever anything changes. The user has the part open in a window and sees everything you read and \
    change, as it happens.

    Do everything through these tools, never by clicking or typing in the SimplMaker window or controlling the screen: the \
    tools are exact and undoable, and the window updates by itself. If a tool you need is not in your list, say so instead of \
    falling back to the screen: the user may need to restart this chat client so that it reloads SimplMaker's tools.

    Work in this order: understand (list_documents, get_document), inspect (get_feature, list_parameters, get_selection), \
    plan, change, and then check the result. Look before you act. Prefer changing an existing feature or parameter over \
    making a new one: "make it 20 mm wider" means modify_feature on the box, not a new box.

    Units: lengths are millimetres and angles are degrees, always. A size you send is a number (mm or degrees) or an \
    expression with a unit ("2 in", "wall * 2"). Every size comes back as {expression, value, unit}; an expression that names \
    a parameter means the size follows that parameter, so change the parameter (set_parameter), not the number.

    Building: for a plain block use create_box. For anything else draw first and extrude after: create_sketch on a plane or on \
    a flat face (get_body shows each face's "facing", "+z" is a top face), edit_sketch to add shapes (rectangle, circle, polygon, \
    line, polyline, arc, text; a rectangle with corner_radius of half its shorter side is a slot), then create_extrude of the \
    profiles. Text is a shape: centre it with anchor "center" and check the profile bounds that come back to be sure it fits. \
    Give the things you create your own short ids ("outline", "hole") and sizes that matter a name with set_parameter, so a later \
    "make it longer" is a single change. Anything made of several steps goes in ONE batch: the user gets one Undo, and a failing step \
    leaves nothing behind. Check the result with get_document, get_body and measure, and say so plainly when it is not what was asked.

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
                saved; is_active marks the part in the front window. An empty list means no part is open. Requires a valid \
                SimplMaker license or trial (otherwise LICENSE_REQUIRED).
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

                Fails with NO_ACTIVE_DOCUMENT (no part open, or several and none in front: pass document_id), \
                DOCUMENT_NOT_FOUND or LICENSE_REQUIRED.
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
                NO_ACTIVE_DOCUMENT, DOCUMENT_NOT_FOUND or LICENSE_REQUIRED.
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

                Fails with NO_ACTIVE_DOCUMENT, DOCUMENT_NOT_FOUND or LICENSE_REQUIRED.
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

                Fails with NO_ACTIVE_DOCUMENT, DOCUMENT_NOT_FOUND or LICENSE_REQUIRED.
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
                TIMELINE_ROLLED_BACK, USER_BUSY, STALE_REVISION, REBUILD_FAILED or LICENSE_REQUIRED; on any failure nothing is changed.
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
                the ids edit_sketch gave them ("plate.width", "ring_hole.diameter", "name.height"); an Extrude has distance and taper. \
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
                reason; the part is unchanged), USER_BUSY, STALE_REVISION or LICENSE_REQUIRED.
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
                the part is unchanged), USER_BUSY, STALE_REVISION or LICENSE_REQUIRED.
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
                USER_BUSY, STALE_REVISION or LICENSE_REQUIRED.
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
                zero, too large, or a corner radius over half the shorter side), FEATURE_NOT_FOUND, REBUILD_FAILED, USER_BUSY, \
                STALE_REVISION or LICENSE_REQUIRED.
                """,
                inputSchema: object([
                    "document_id": ["type": "string", "description": "The part to change, from list_documents."],
                    "sketch_id": ["type": "string", "description": "The sketch, from create_sketch or get_document."],
                    "add": ["type": "array", "description": "Shapes to draw.", "items": [
                        "type": "object",
                        "properties": [
                            "type": ["type": "string", "enum": ["rectangle", "circle", "polygon", "line", "polyline", "arc", "text"]],
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
                missing distance), INVALID_VALUE, REBUILD_FAILED (the result would not build), TIMELINE_ROLLED_BACK, USER_BUSY, \
                STALE_REVISION or LICENSE_REQUIRED.
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
                name: "delete_feature", title: "Delete a feature",
                description: """
                Removes a feature (a box, a sketch, an extrude…) from the part. Use it to take away something that is wrong or no longer \
                wanted, or to remake something: delete it and create it again, in one batch. To change a size, use modify_feature instead.

                Arguments: document_id (required); feature_id (required, from get_document); with_children (optional, default false); \
                expected_revision (optional). Features built from the one deleted (the extrude of a sketch, a fillet of a body) would lose \
                what they stand on, so they are listed and nothing is deleted unless with_children is true, which deletes them too. A \
                sketch that was hidden because the deleted feature used it is shown again.

                Changes the document (one undo step "AI: Delete …"). Returns {success, document_id, revision, message, bodies}. Fails with \
                FEATURE_NOT_FOUND, HAS_DEPENDENTS (the message lists them), USER_BUSY, STALE_REVISION, REBUILD_FAILED or LICENSE_REQUIRED.
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

                Arguments: document_id (required); operations (required): a list of {tool, arguments}, where tool is one of create_box, \
                create_sketch, edit_sketch, create_extrude, modify_feature, set_parameter and arguments are that tool's arguments WITHOUT \
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

                Fails with FEATURE_NOT_FOUND (no such body), NO_ACTIVE_DOCUMENT, DOCUMENT_NOT_FOUND or LICENSE_REQUIRED.
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

                Fails with FEATURE_NOT_FOUND (no such body, face or edge: names change after edits), INVALID_ARGUMENTS, NO_ACTIVE_DOCUMENT, \
                DOCUMENT_NOT_FOUND or LICENSE_REQUIRED.
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
                name: "undo", title: "Undo the last change",
                description: """
                Undoes the most recent step in the part's undo history, exactly like the user choosing Edit ▸ Undo. Use it to take \
                back a change you made that turned out wrong, or when the user asks you to. It undoes the latest step whoever \
                made it, so check get_document first if the user may have edited the part since your last change: the step's name \
                comes back so you can tell ("AI: Create Box1" is yours).

                Arguments: document_id (required); expected_revision (optional: refuse if the part is not at the revision you \
                last saw, which stops you undoing something of the user's).

                Changes the document. Returns {success, document_id, revision, message, step, feature_count, bodies}. Fails with \
                NOTHING_TO_UNDO, UNDO_UNAVAILABLE, USER_BUSY, STALE_REVISION or LICENSE_REQUIRED.
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
                NOTHING_TO_REDO, UNDO_UNAVAILABLE, USER_BUSY, STALE_REVISION or LICENSE_REQUIRED.
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

    static func makeServer(service: CADService, version: String) -> MCPServer {
        MCPServer(name: "SimplMaker", version: version, instructions: serverInstructions, tools: make(service: service),
                  describeFailure: { AIError.describing($0) })
    }
}
