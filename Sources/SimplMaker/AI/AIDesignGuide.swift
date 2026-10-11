// What an experienced designer knows and an assistant does not start out knowing: how to plan a part in SimplMaker, the numbers that
// matter for 3D printing, and recipes that are known to build. Served by get_design_guide, a topic at a time so each answer is short.
// The recipes' steps come from AIRecipes, which the tests run.
// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation

struct DesignTopic: Sendable {
    var id: String
    var title: String
    /// One line: when to read it.
    var summary: String
    var body: String
}

enum AIDesignGuide {
    static func topic(_ id: String) -> DesignTopic? { topics.first { $0.id == id.lowercased() } }

    static let topics: [DesignTopic] = [workflow, parameters, printBasics, snapFitLid, roundedBox, nameTag, holesAndFasteners, threads,
                                        featureOrder, facesAndEdges, textAndLabels, photoToPart, fixingErrors]

    // MARK: how to work

    static let workflow = DesignTopic(
        id: "workflow", title: "How to go from a request to a finished part",
        summary: "Read first for anything bigger than a plain block.",
        body: """
        1. Understand the request. Ask ONE short question only if something that changes the design is missing and cannot be \
        assumed (what it is for, a size that matters, how it will be made). Otherwise choose sensible values, build, and say what you \
        assumed. A user who asks for "a box with a lid" wants a good box with a lid, not a quiz.
        2. Read the part first (list_documents, get_document): never build over something that is already there.
        3. Plan in parameters. Name every dimension that matters before drawing anything (see topic "parameters"). Derived \
        values are expressions of the others.
        4. Build in ONE batch where you can (one undo step; nothing half-built if a step fails). Give everything your own ids. \
        Where a step needs a face or edge id you cannot know yet, build up to that point, read get_body, and finish in a second batch \
        (see "faces_and_edges").
        5. Look: get_viewport_image (iso, then another view). Numbers do not show an upside-down lid. If it does not look right, fix it \
        before you report.
        6. For anything meant to be printed, run check_design and deal with what it finds.
        7. Report briefly: what you made, the sizes, the assumptions, and which parameters change what ("wall" is the wall thickness, \
        "clr" the clearance of the lid). Mention what you could not do or are unsure of; never claim a fit works that you only calculated.

        Prefer changing an existing feature or parameter over building again. If a step fails with REBUILD_FAILED, read the reason \
        (topic "fixing_errors"); do not retry the same thing.
        """)

    static let parameters = DesignTopic(
        id: "parameters", title: "Parameters: make the part follow a few numbers",
        summary: "Always: how to name, derive and use parameters.",
        body: """
        A parametric part is one the user can resize later by changing a number. Start every build with set_parameter steps in the \
        batch, then write names or expressions wherever a size is asked for (box sizes, sketch shapes, extrude distances, fillet and \
        chamfer sizes, shell thickness, hole diameters, positions).

        Name them for what they mean: width, depth, height, wall, floor, corner_r, lid_t, clr (clearance), hole_d, bottom_r. Names \
        start with a letter or underscore, use letters, digits and underscores, and cannot be unit or function names (round, min, \
        max, sin, mm, in…; use "edge_r", not "round").

        Derive, do not repeat: inner_w = "width - 2 * wall"; inner_r = "corner_r - wall" (an inside corner radius is the outside one \
        minus the wall); lid_w = "width - 2 * clr". Then a change to "wall" or "width" moves everything that depends on it.

        Units: a bare number is mm (degrees for angles); "2 in" and "5 deg" also work. Counts are plain numbers.

        Plain numbers are fine only for true one-offs that nobody would change. After building, tell the user which parameters you \
        made. A later "make it 5 mm wider" is set_parameter, never a rebuild; modify_feature refuses to replace a parameter-driven \
        size with a fixed number (PARAMETER_LINKED), which is the right result.
        """)

    // MARK: printing

    static let printBasics = DesignTopic(
        id: "print_basics", title: "FDM 3D printing numbers (0.4 mm nozzle)",
        summary: "Wall thickness, clearances, overhangs, orientation: read before designing anything to be printed.",
        body: """
        Walls: at least 1.2 mm (three perimeters); 1.6–2 mm for a box that is handled; 0.8 mm only for decoration. Floors and lids \
        1.2 mm or more (6+ layers at 0.2 mm). Details smaller than 0.4 mm do not print; thin text strokes should be 0.8 mm or more.
        Clearances (per side) for parts that must fit together: 0.1–0.15 tight press fit, 0.2 snug sliding, 0.3 easy, 0.4–0.5 \
        loose or moving. State the clearance as a parameter ("clr") so the user can tune it for their printer and filament: this is \
        the number they will change most.
        Holes print a little small and round shapes slightly off: make a hole 0.2 mm larger than the pin or screw it takes. Very \
        small holes (under 3 mm) get 0.3 mm extra.
        Overhangs: a surface leaning more than 45° from vertical needs support. Use 45° chamfers instead of flat undersides \
        (a chamfer under a bead, the top of a hole turned into a teardrop or chamfered). A flat roof over a gap of up to about 5 mm \
        bridges; longer needs support. First layer: a 0.4–0.6 mm chamfer on the bottom edge keeps "elephant's foot" from squashing \
        outwards; rounding the bottom edge with a radius works too.
        Orientation: the best face down is a large flat one. Lids print upside down (plate on the bed). Tall thin parts are weak \
        across the layer lines: strength is along the print, not across it.
        Bed: assume 220 × 220 × 250 mm unless told otherwise; check_design takes a different bed.
        Snap fits and thin hooks bend across layers: make a snap's flexing part print along its length, with 1.5 mm or more of wall.
        Do not model support or the printer: model the part, and say how it should be oriented.
        """)

    // MARK: recipes

    static var snapFitLid: DesignTopic {
        DesignTopic(
            id: "snap_fit_lid", title: "Rounded box with a snap-fit lid (verified recipe)",
            summary: "A box and a lid that clicks shut, printable without supports. Also the plain friction-fit lid.",
            body: """
            Design: the base is a rounded block, hollowed from the top. The lid is a plate with a skirt that plugs into the base with \
            "clr" clearance per side. A bead (a small ring) on the skirt snaps into a matching groove in the base's inner wall. Both \
            bodies sit in their assembled positions (base z 0…base_h, lid on top), which is what the batch below makes. Sizes here are an \
            example (45 × 50 × 30 closed height); put the user's own numbers in the first set_parameter steps and keep everything else.

            Why it is built this way: the base is hollowed BEFORE its bottom edge is rounded (a round smaller than the wall breaks a \
            shell that comes after it). The groove and the bead are rings made from two nested rounded rectangles in one sketch, \
            extruded with profiles "solid" (the ring, not the hole filling). The bead's inner outline sits 0.4 mm inside the skirt wall \
            so it fuses with it. Face ids like face:base/base.start (the bottom) and face:lid/lid.end (the top) are known in advance \
            for a body made by extruding a sketch.

            PHASE 1, one batch (label "Snap-fit box"):
            [
            \(AIRecipes.text(AIRecipes.snapFitBoxPhaseOne))
            ]

            PHASE 2: the 45° lead-in. Call get_body for "base" and "lid". In the base, take the edges that lie flat at the groove's \
            bottom (z = bead_z, 22 here) and top (z = bead_z + bead_h, 23.5), on the loop farthest from the centre (the back wall of \
            the groove, whose end points are farther out than the wall). In the lid take the same two heights on the bead's OUTER loop. \
            There are two loops of 8 edges (4 lines, 4 arcs) at each height; each loop is 16 edges when both heights are taken. Then, \
            in one batch: create_chamfer on the base's 16 edges and one on the lid's 16, size 0.4 (less than bead_d, so a flat is left; \
            equal to it fails). Chamfering the groove's concave corners fills them, so the groove gets sloped sides: that is intended. \
            The bead's chamfers take its corners off. Both give the 45° slopes that guide the lid in and print without support.

            Tuning: if it is too tight or too loose, change "clr" (0.1 tighter, 0.3 looser) and "bead_d" (0.3–0.6). Changing "clr" \
            moves the skirt and the bead together; the groove stays. Friction fit instead of a snap: leave out the groove, the bead and the \
            chamfers, and use clr 0.15.

            Then look (get_viewport_image iso, front) and run check_design: after phase 2 it should report no overhang and no thin wall, and a clearance of \
            0.2 mm ("snug"). Before the chamfers it reports the groove's and the bead's flat undersides as overhangs, which is what they are. Tell the user to print the base upright and the lid \
            upside down (plate on the bed); offer to lay them out for printing with create_move (turn the lid 180° with rx 180, then lower it to the bed with dz).
            """)
    }

    static var roundedBox: DesignTopic {
        DesignTopic(
            id: "rounded_box", title: "A rounded open box (verified recipe)",
            summary: "The base of any box, tray, cup holder or organiser.",
            body: """
            A rounded rectangle sketch, extruded, hollowed from the top, bottom edge rounded. The shell goes BEFORE the fillet (a \
            round smaller than the wall breaks a later shell). One batch:
            [
            \(AIRecipes.text(AIRecipes.roundedOpenBox))
            ]
            Variations: inner dividers are extruded rectangles joined to the box (profiles of a sketch on the inside floor: \
            create_sketch on the face id of the floor read from get_body, then create_extrude operation "join" with target "box"); a \
            finger notch is a cut extrude; feet or a label recess are a cut extrude of a shallow rectangle or the text.
            Rounded corners: the rectangle shape's corner_radius (half the shorter side makes a slot or capsule). Keep an inside \
            corner radius at least 0.5 mm: it is corner_r - wall, so corner_r must be bigger than wall.
            """)
    }

    static var nameTag: DesignTopic {
        DesignTopic(
            id: "name_tag", title: "Name tag or key ring with raised text (verified recipe)",
            summary: "A plate with a hole and centred raised text: key rings, tags, labels.",
            body: """
            A capsule plate (a rectangle with corner_radius of half its height) with a hole near one end, and the name as text on top, \
            centred, extruded 1 mm up and joined to the plate. One batch:
            [
            \(AIRecipes.text(AIRecipes.nameTag))
            ]
            After it, look at the picture and read the text's profile bounds from the edit_sketch answer: the lettering has to fit between \
            the hole and the far end (here the hole is at x = -17.5 and the tag ends at x = 30, so the lettering is centred at x = 3 and should stay under about 40 mm wide). If it is \
            too wide, make "text_h" smaller or the tag longer (tag_w); the text keeps its middle where it was. Text strokes \
            thinner than 0.8 mm will not print: use a bold font (the text shape's "font" setting takes a font name) or a larger text_h. Keep the hole 2 mm or more from the edge and from the letters.
            """)
    }

    // MARK: parts

    static let holesAndFasteners = DesignTopic(
        id: "holes_and_fasteners", title: "Holes, screws, inserts, magnets",
        summary: "Hole sizes for screws and inserts when printing.",
        body: """
        Printed hole diameters (mm), clearance for a screw to pass freely / counterbore for the head (diameter × depth):
        M2: 2.4 / 4.4 × 2 · M2.5: 2.9 / 5.2 × 2.5 · M3: 3.4 / 6.2 × 3 · M4: 4.5 / 8.2 × 4 · M5: 5.5 / 9.8 × 5 · M6: 6.6 / 11.5 × 6 · M8: 9 / 15 × 8.
        Screw into plastic directly (self-tapping): hole 0.3–0.5 mm under the thread diameter, at least 6 mm deep: M3 → 2.6.
        Heat-set insert (brass): M2 → 3.2, M3 → 4.2, M4 → 5.6 hole diameter, depth the insert's length + 1 mm; wall at least 1.6 mm round it.
        Magnets: hole 0.2 mm larger than the magnet's diameter, 0.1–0.2 mm deeper; leave at least 0.4 mm of floor between magnet and \
        the outside, or print a pause so it can be placed.
        A countersunk head: kind "countersink", head_diameter 2 × the screw, head_angle 90.
        Use create_hole on a flat face for these, with at = [x, y, z] (a point of the face) or none for the middle; several holes: one \
        create_hole each, or one hole and create_pattern of its body. Put holes in BEFORE rounding the edges they meet. A hole through a wall that is \
        2 mm thick needs no support if its axis is vertical; a horizontal hole over 6 mm should be a teardrop or have a chamfered top.
        Screw posts for a case: after the shell, a circle sketch on the floor face (get_body gives its id), extruded and joined to the \
        box, outside diameter 2 × the hole; then a hole in the post's top face.
        """)

    static let threads = DesignTopic(
        id: "threads", title: "Screw threads for printing",
        summary: "Printed threads, jar lids, bolts and nuts.",
        body: """
        Use create_thread on a cylindrical face (get_body shape "cylinder"): outside of a shaft or inside of a hole. Add threads \
        last (they are slow to build). Size the shaft or hole first; the thread tool resizes the face to the thread.
        Printable sizes: M8 and larger in coarse pitch (M8x1.25, M10x1.5, M12x1.75…) print reliably; M6 is marginal; below M5 do not print \
        threads, use a screw into a hole instead. For a lid on a jar use a coarse thread, 20 mm or more across, 3–4 turns.
        Tolerance: model the OUTER part (bolt) at 0 and the INNER part (nut, hole) with tolerance 3 (percent) so they turn \
        freely; for a tight fit use 1.5–2. The offset goes on the part that must be bigger: a nut gets +3 %, a bolt stays nominal.
        Print the thread axis vertical. Start with a 0.5–1 mm chamfer at the thread's end so it starts.
        left_handed for a left-hand thread. A thread that fails with REBUILD_FAILED lists sizes that do fit that face: use one of those or \
        change the diameter of the face.
        """)

    static let featureOrder = DesignTopic(
        id: "feature_order", title: "Order of fillets, chamfers, shells and holes",
        summary: "Why a step fails and what to do first: the order that works.",
        body: """
        Do features in this order: 1) base shape (extrude, revolve, box) · 2) cuts and holes · 3) shell · 4) draft · 5) fillets and \
        chamfers on the OUTSIDE · 6) small details · 7) threads, text last.
        Shell before rounding: a fillet radius smaller than the wall thickness makes a later shell fail. Hollow first, round after.
        Fillet radius: smaller than the faces it runs along; on the outside of a hollowed part up to about the wall thickness is usual; \
        a radius that is too big fails (REBUILD_FAILED): halve it. An equal chamfer distance must be smaller than the faces it cuts into.
        Inside corner radius = outside radius - wall; if it would be 0 or less, leave the inside square or make the outside radius bigger.
        A chamfer on a CONCAVE corner (inside a groove, a step) fills it; on a CONVEX corner it cuts it. Both are normal.
        Fillet the faces (faces: ["face:body/<face>"]) to round every edge around a face and follow it when the part changes; use \
        edges when only some should be rounded.
        Cuts through a filleted wall are easier before the fillet than after it.
        """)

    static let facesAndEdges = DesignTopic(
        id: "faces_and_edges", title: "Finding faces and edges you need",
        summary: "How ids are named, which ones you know in advance, and how to pick edges from get_body.",
        body: """
        Known in advance, for a body made by extruding a sketch with id "x": face:x/x.start is the face on the sketch's plane, \
        face:x/x.end the far end, face:x/x.side.<curve id> a wall (the curve ids are the ones edit_sketch returned). A box made with \
        create_box has named faces too, but read them. After a shell, fillet or cut the names of untouched faces stay the same. A face \
        you cannot predict: build up to it, then read get_body.
        get_body lists every face (shape, area, facing "+z" = top, center, direction, bounds) and edge (shape, length, start, end, \
        center, radius, faces on either side). To pick edges: filter by what you can see in the numbers, for example "lines with both \
        ends at z = 22" (flat at a height), "arcs of radius 4 whose center z = 0" (a corner), "edges of face X". For a ring (two \
        loops of edges at one height) tell the loops apart by how far from the centre their end points are.
        Concave or convex: a groove's back wall corner is concave. Ask for the picture (get_viewport_image) when in doubt.
        Edge and face names can change when the part upstream changes: read them again after any edit, and prefer faces: [...] to \
        edges where you mean "all around".
        """)

    static let textAndLabels = DesignTopic(
        id: "text_and_labels", title: "Text on parts",
        summary: "Raised or engraved text, sizes, centring, fonts.",
        body: """
        Text is a shape in a sketch: {"type": "text", "text": "...", "at": [x, y], "height": h, "anchor": "center"}. "height" is the \
        text size. Put the sketch on a flat face or plane; the profiles it makes are the letters (and the insides of \
        o, a, e as separate profiles): extrude with profiles "solid" to get the letters themselves, never the fillings of the o's.
        Raised: operation "join", 0.6–1 mm (1.2 for big letters). Engraved: operation "cut" 0.6–1 mm deep. Letters of 8 mm or taller \
        read well; strokes need 0.8 mm. Check the profile bounds that edit_sketch returns: the text must fit where it goes. After \
        changing text words, the extrude of the old letters breaks: delete it and extrude again in a batch.
        A mirrored or underside text: sketch it on the face from outside; for text on the bottom face the sketch's x runs the other way: \
        read the picture.
        """)

    static let photoToPart = DesignTopic(
        id: "photo_to_part", title: "Recreating a part from a photo or drawing",
        summary: "When the user shares a picture and wants it modelled.",
        body: """
        A photo gives shape, not size. 1) Find one real dimension: ask the user for one length (an overall width, a hole spacing) \
        unless something in the photo has a known size (a coin, a ruler, a standard screw). Everything else is proportions from that \
        one number. State the dimension you used.
        2) Decompose: name the simple shapes the part is made of (a plate, a cylinder, a rounded block, a hollow, holes, ribs, fillets). \
        Decide which is the base body. Note symmetry (mirror one half).
        3) Estimate sizes as ratios of the known dimension; make them parameters so the user can correct them in one place.
        4) Build the base first, then add features one at a time, in the order in "feature_order", in a batch per group.
        5) Compare: get_viewport_image from the same direction as the photo (azimuth and elevation if it is a three-quarter view) \
        and describe the differences you can see honestly. Fix the largest first.
        6) Tell the user what you assumed and what the photo could not tell you (thickness, hidden sides, hole depths), and ask for \
        those numbers rather than guessing silently. An approximate model that says so is better than a confident wrong one.
        For a flat outline, a sketch of lines, arcs and polylines extruded gets the shape; do not try to trace curves by many tiny lines: \
        use arcs through three points.
        """)

    static let fixingErrors = DesignTopic(
        id: "fixing_errors", title: "When a step fails",
        summary: "REBUILD_FAILED and other errors: what to try.",
        body: """
        Every failing change leaves the part untouched, so you can try again safely. Read "reason" and fix what it says.
        Fillet or chamfer fails: the size is too big for the faces it runs along; try half. Fillet before a thin shell, or round \
        after the shell (see feature_order). A chamfer equal to the face width it eats fails: use 80 %.
        Shell fails: the wall is too thick for the thinnest part, or fillets on the inside are smaller than the wall. Make the wall \
        thinner, shell earlier, or open another face.
        Join does not touch: "the bodies don't overlap" means the new shape only touches or misses: make it overlap by at least 0.4 mm.
        Extrude of text fails after changing the words: delete the extrude and make it again (batch).
        "profile not found" / no profiles: the sketch is empty or its shapes are not closed; read get_feature for the sketch.
        STALE_REVISION or USER_BUSY: the user is working; wait and read the part again.
        UNSUPPORTED_FEATURE_TYPE: that feature cannot be changed through the tools yet; delete and recreate it, or ask the user.
        Never loop on the same failing call: change the size, the order, or the approach, and say what you changed.
        """)
}
