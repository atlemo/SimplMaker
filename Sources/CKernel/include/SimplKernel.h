// SimplKernel — the C API between SimplMaker (Swift) and OpenCASCADE (C++).
//
// Design rules:
//  * Plain C: Swift imports it without C++ interop, so OCCT headers never reach Swift.
//  * Every object lives in a kernel-side arena and is referred to by an opaque
//    64-bit handle (0 = invalid). Release handles with sk_release().
//  * Bodies carry *persistent names* for their faces and edges (see PLAN.md §6.1):
//      faces: "<feature>.start", "<feature>.end", "<feature>.side.<curveTag>",
//             "<feature>.fillet.<edgeName>", "<feature>.chamfer.<edgeName>", ...
//      edges: "<faceNameA>|<faceNameB>" (sorted), "#n" suffix when ambiguous.
//    Names survive regeneration because they are built from stable IDs + kernel history.
//  * On failure a function returns 0 / NULL / false and sk_last_error() says why.
//
// Copyright © 2026 Atle Mo. All rights reserved.
#ifndef SIMPL_KERNEL_H
#define SIMPL_KERNEL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef uint64_t SKHandle;

/// A sketch plane: origin, unit normal, unit x-direction (y = normal × x).
typedef struct SKFrame {
  double ox, oy, oz;
  double nx, ny, nz;
  double xx, xy, xz;
} SKFrame;

typedef enum SKBooleanOp { SK_FUSE = 0, SK_CUT = 1, SK_COMMON = 2 } SKBooleanOp;

/// Last error message for the calling thread ("" if none).
const char *sk_last_error(void);
/// Version of the linked OpenCASCADE Technology, e.g. "8.0.1" (for the About panel).
const char *sk_occt_version(void);
void sk_release(SKHandle h);

// ---------------------------------------------------------------- sketches ---
/// Starts collecting 2D curves on `frame`. Coordinates below are (u, v) in the frame.
SKHandle sk_sketch_new(SKFrame frame);
/// `tag` identifies the curve (use the sketch entity's UUID); it becomes part of face names.
bool sk_sketch_add_line(SKHandle sketch, const char *tag, double u1, double v1, double u2, double v2);
bool sk_sketch_add_circle(SKHandle sketch, const char *tag, double cu, double cv, double r);
/// Counter-clockwise arc from angle a0 to a1 (radians).
bool sk_sketch_add_arc(SKHandle sketch, const char *tag, double cu, double cv, double r, double a0, double a1);
/// A Bézier curve through `count` control points (u0, v0, u1, v1, ...): 3 = quadratic, 4 = cubic.
bool sk_sketch_add_bezier(SKHandle sketch, const char *tag, const double *uv, int count);
/// Splits the plane by all curves and finds the closed regions (profiles). Returns count or -1.
int sk_sketch_build_regions(SKHandle sketch);
/// Sorted, comma-separated tags of the curves bounding region i (stable across edits).
const char *sk_sketch_region_tags(SKHandle sketch, int i);
double sk_sketch_region_area(SKHandle sketch, int i);
/// A point strictly inside region i, in frame (u, v) coordinates.
// Whether sketch point (u, v) lies inside region i (not on its boundary or in a hole).
bool sk_sketch_region_contains(SKHandle sketch, int i, double u, double v);
bool sk_sketch_region_sample(SKHandle sketch, int i, double *u, double *v);
/// A profile handle for region i, usable by sk_extrude.
SKHandle sk_sketch_region_profile(SKHandle sketch, int i);

// ---------------------------------------------------------------- features ---
/// Extrudes profiles along `dir` from -distanceBack to +distance. Faces are named
/// "<featureId>.start|end|side.<tag>". Returns a body.
SKHandle sk_extrude(const SKHandle *profiles, int count, double dx, double dy, double dz,
                    double distance, double distanceBack, const char *featureId);
/// The same, with the side faces leaned by `taper` radians (positive: out as they go, negative: in). Each side of
/// the profile plane tapers away from it, so a two-sided extrude has a ridge along the plane. Fails when the taper
/// would close the shape up, or on a profile whose sides can't lean (anything but straight and round edges).
SKHandle sk_extrude_tapered(const SKHandle *profiles, int count, double dx, double dy, double dz, double distance,
                            double distanceBack, double taper, const char *featureId);
/// The same, starting from a plane `startOffset` along `dir` from the profile's own plane (the profile is carried
/// there first, so the ends, the taper and the two-sided ridge all sit on that plane).
SKHandle sk_extrude_from(const SKHandle *profiles, int count, double dx, double dy, double dz, double startOffset,
                         double distance, double distanceBack, double taper, const char *featureId);
/// Revolves profiles about the axis through (ox, oy, oz) along (dx, dy, dz) by `angle` radians
/// (2π or more = a full turn). Faces: "<featureId>.start|end|side.<tag>".
SKHandle sk_revolve(const SKHandle *profiles, int count, double ox, double oy, double oz, double dx, double dy,
                    double dz, double angle, const char *featureId);
/// A path made of the sketch curves with these tags; they must connect end to end.
SKHandle sk_sketch_path(SKHandle sketch, const char *const *tags, int count);
/// Sweeps profiles along a path. Faces: "<featureId>.start|end|side.<tag>".
SKHandle sk_sweep(const SKHandle *profiles, int count, SKHandle path, const char *featureId);
/// Round pipe along a path; wall > 0 makes it hollow. Faces: "<featureId>.start|end|outer|inner".
SKHandle sk_pipe(SKHandle path, double diameter, double wall, const char *featureId);
/// Loft through the outer boundaries of profiles, in order. Faces: "<featureId>.start|end|side.<tag>".
SKHandle sk_loft(const SKHandle *profiles, int count, bool ruled, const char *featureId);
/// Adds a rib to `body`: the open path (in its sketch plane) is thickened symmetrically across the
/// plane and extended until it meets the body. New faces: "<featureId>.rib".
SKHandle sk_rib(SKHandle body, SKHandle path, double thickness, const char *featureId);

typedef enum SKHoleKind { SK_HOLE_SIMPLE = 0, SK_HOLE_COUNTERBORE = 1, SK_HOLE_COUNTERSINK = 2 } SKHoleKind;
/// The solid to cut for a hole: its top centre at the frame origin, going against the frame normal.
/// Counterbore: head diameter and depth. Countersink: head diameter and angle (radians).
/// tipAngle > 0 adds a drill point. Faces: "<featureId>.hole.wall|tip|head|floor|top".
SKHandle sk_hole(SKFrame at, SKHoleKind kind, double diameter, double depth, double tipAngle,
                 double headDiameter, double headDepth, double headAngle, const char *featureId);

typedef enum SKPrimitive { SK_BOX = 0, SK_CYLINDER = 1, SK_SPHERE = 2, SK_TORUS = 3, SK_COIL = 4 } SKPrimitive;
/// A primitive standing on the frame's plane, centred at its origin (the normal is "up"):
///   box: a = width (x), b = length (y), c = height     cylinder: a = diameter, c = height
///   sphere: a = diameter (centre on the plane)          torus: a = diameter, b = tube diameter
///   coil: a = diameter, b = section diameter, c = pitch, d = revolutions
/// Faces: "<featureId>.top|bottom|left|right|front|back|side|start|end".
SKHandle sk_primitive(SKPrimitive kind, SKFrame frame, double a, double b, double c, double d, const char *featureId);

/// A round face (the side of a shaft or the wall of a hole): out[0..2] = the point on its axis at the end a
/// thread starts from (an end with air beyond it; `flipped` takes the other), out[3..5] = the unit axis
/// direction from there along the face, out[6] = radius, out[7] = length, out[8] = 1 for a hole, else 0.
bool sk_body_face_cylinder(SKHandle body, const char *faceName, bool flipped, double out[9]);
/// Cuts a 60° thread (ISO metric or unified basic profile) into a round face: external on a shaft,
/// internal in a hole. The face is turned down or bored out to the thread's diameters first (or
/// filled out to them). length <= 0 = the whole face; the thread starts at the end
/// sk_body_face_cylinder names. New faces: "<featureId>.thread", "<featureId>.thread.crest".
SKHandle sk_thread(SKHandle body, const char *faceName, double majorDiameter, double pitch, double length, bool flipped,
                   bool leftHanded, const char *featureId);
/// The same for several round faces of one body at once, each with its own diameter and pitch: one pass over the body
/// instead of one per face, which is much faster on a body that already has threads. The first face's new faces are named
/// after the feature, the next ones "<featureId>.2", "<featureId>.3"... Fails (leaving it to the caller to thread the faces
/// one at a time) if the threads would reach each other or any of them can't be made.
SKHandle sk_thread_many(SKHandle body, int count, const char *const *faceNames, const double *majorDiameters,
                        const double *pitches, double length, bool flipped, bool leftHanded, const char *featureId);

/// A copy of a body moved by (dx, dy, dz), or turned by `angle` radians about the axis through
/// (ox, oy, oz) along (ax, ay, az). Face and edge names are kept.
SKHandle sk_translate(SKHandle body, double dx, double dy, double dz);
SKHandle sk_rotate(SKHandle body, double ox, double oy, double oz, double ax, double ay, double az, double angle);
/// A copy of a body enlarged (or shrunk) evenly by `factor` about the point (ox, oy, oz). Names are kept.
SKHandle sk_scale(SKHandle body, double ox, double oy, double oz, double factor);
// Copies for mirror and pattern features: moved, turned or mirrored, every face name prefixed
// with `prefix` so the copy's faces stay distinct from the original's once joined.
SKHandle sk_translate_copy(SKHandle body, double dx, double dy, double dz, const char *prefix);
SKHandle sk_rotate_copy(SKHandle body, double ox, double oy, double oz, double ax, double ay, double az, double angle,
                        const char *prefix);
SKHandle sk_mirror_copy(SKHandle body, double ox, double oy, double oz, double nx, double ny, double nz, const char *prefix);
// Hollows a body: removes the named faces and keeps walls `thickness` thick (inside the body when
// `inside`, else outside it). New wall faces are named "<featureId>.shell…".
SKHandle sk_shell(SKHandle body, const char *const *faceNames, int count, double thickness, bool inside, const char *featureId);
// Leans the named faces by a draft angle (radians) about the plane of `fixedFace`, a flat face of the same body: the
// faces keep the line where they meet that plane and tilt so that, for a positive angle, the body gets narrower
// going away from it; a negative angle widens it. New faces: "<featureId>.draft…".
SKHandle sk_draft(SKHandle body, const char *const *faceNames, int count, const char *fixedFace, double angle,
                  const char *featureId);
// Projects sketch profiles onto a body along (dx, dy, dz), the way a slide projector throws them on a wall, and
// returns the relief: a solid that follows the surface, `height` thick along its normals. A positive height
// stands out of the surface (emboss, to join to the body), a negative one goes into it (deboss, to cut out of
// it). It is built on the faces named (all of them when `faceCount` is 0) that face against the direction, so a
// round face gets the profile on its sketch side only. handle[0..2] = a point on the surface in the middle of the
// first patch, handle[3..5] = the unit normal pointing out of the body there. Faces: "<featureId>.relief".
SKHandle sk_project_relief(SKHandle body, const char *const *faceNames, int faceCount, const SKHandle *profiles, int count,
                           double dx, double dy, double dz, double height, const char *featureId, double handle[6]);
// A straight edge's line: a point on it and its direction (out[0..2], out[3..5]); false if it's curved.
bool sk_body_edge_line(SKHandle body, const char *edgeName, double out[6]);
// A straight edge's two ends (out[0..2] = where it starts, out[3..5] = where it ends); false if it's curved.
bool sk_body_edge_ends(SKHandle body, const char *edgeName, double out[6]);

/// Boolean between two bodies; names from both operands are carried through.
SKHandle sk_boolean(SKHandle target, SKHandle tool, SKBooleanOp op);
/// Splits a body into the pieces a tool cuts it into. The tool is the infinite plane through (ox, oy, oz) with normal
/// (nx, ny, nz) when `toolBody` is 0, else the face `toolFace` of `toolBody`, as it is. Writes the handles of the
/// pieces to `out` (at most `max`) and returns how many: 1 when the tool misses the body or only touches it, 0 on
/// failure. The pieces come in a fixed order (along the normal, then by position). Names of the body's faces are
/// kept; the faces the cut makes are "<featureId>.split".
int sk_split(SKHandle body, SKHandle toolBody, const char *toolFace, double ox, double oy, double oz, double nx, double ny,
             double nz, const char *featureId, SKHandle *out, int max);
/// Constant-radius fillet on the named edges. New faces: "<featureId>.fillet.<edgeName>".
SKHandle sk_fillet(SKHandle body, const char *const *edgeNames, int count, double radius, const char *featureId);
/// Equal-distance chamfer on the named edges. New faces: "<featureId>.chamfer.<edgeName>".
SKHandle sk_chamfer(SKHandle body, const char *const *edgeNames, int count, double distance, const char *featureId);

typedef enum SKChamferMode { SK_CHAMFER_EQUAL = 0, SK_CHAMFER_TWO_DISTANCES = 1, SK_CHAMFER_DISTANCE_ANGLE = 2 } SKChamferMode;
/// Chamfer with its sides measured separately. Of the two faces at an edge, `faceNames[i]` (when it is one of them)
/// is the face the first distance is measured on; otherwise the face with the smaller name is. `flip` takes the other.
///   SK_CHAMFER_TWO_DISTANCES: `first` on that face, `second` on the other.
///   SK_CHAMFER_DISTANCE_ANGLE: `first` on that face, at `second` (radians, 0 to 90 degrees exclusive) to it.
/// SK_CHAMFER_EQUAL ignores the faces and `second`. New faces: "<featureId>.chamfer.<edgeName>".
SKHandle sk_chamfer_ex(SKHandle body, const char *const *edgeNames, const char *const *faceNames, int count,
                       SKChamferMode mode, double first, double second, bool flip, const char *featureId);

/// The smallest radius of a rounded corner that a chamfer along the named edges (and the edges that continue them
/// tangentially) would shrink, like a plate's rounded corner when its top edge is chamfered. An equal-distance
/// chamfer at or above it can't be built (a fillet can). Writes it to `out` and returns true, or false if no corner limits the size.
bool sk_edge_round_limit(SKHandle body, const char *const *edgeNames, int count, double *out);

// ----------------------------------------------------------------- queries ---
int sk_body_face_count(SKHandle body);
const char *sk_body_face_name(SKHandle body, int i);  // i matches SKMesh.triangleFace
int sk_body_edge_count(SKHandle body);
const char *sk_body_edge_name(SKHandle body, int i);  // i matches SKMesh.segmentEdge
int sk_body_find_face(SKHandle body, const char *name);  // -1 if not found
int sk_body_find_edge(SKHandle body, const char *name);  // -1 if not found
// Edges bounding a face (indices as in sk_body_edge_name; seams left out). Writes up to `max`
// indices to `out` and returns how many there are, or -1 if the face isn't found.
int sk_body_face_edges(SKHandle body, const char *faceName, int *out, int max);
// Faces on either side of an edge (indices as in sk_body_face_name); returns how many, or -1.
int sk_body_edge_faces(SKHandle body, const char *edgeName, int *out, int max);
// The edges of the loop of `faceName` that contains `edgeName` (seams left out); returns how many, or -1.
int sk_body_loop_edges(SKHandle body, const char *faceName, const char *edgeName, int *out, int max);
/// A planar face of a body as a profile, e.g. to extrude it (press-pull). Its edges are tagged with
/// the body's edge names, so the sides are named "<featureId>.side.<edgeName>".
SKHandle sk_body_face_profile(SKHandle body, const char *faceName);
/// Centre of mass of a face.
bool sk_body_face_center(SKHandle body, const char *faceName, double out[3]);
/// Centre of the area inside a face's outer boundary (holes in the face ignored).
bool sk_body_face_outline_center(SKHandle body, const char *faceName, double out[3]);
/// Frame of a planar face (normal points out of the material). False if missing / not planar.
bool sk_body_face_frame(SKHandle body, const char *faceName, SKFrame *out);
/// Drag handle for a fillet/chamfer on an edge: out[0..2] = edge midpoint, out[3..5] = unit
/// direction the rounding grows in (into the material for outside corners, into the air for
/// inside corners). False if the edge doesn't join two faces at an angle.
bool sk_body_edge_handle(SKHandle body, const char *edgeName, double out[6]);
/// Drag handles for a chamfer measured on each face (sides picked as in sk_chamfer_ex): out[0..2] = edge midpoint,
/// out[3..5] = unit direction along the first face, away from the edge, out[6..8] = the same along the other face,
/// out[9..11] = the first face's outward normal. False if the edge doesn't join two faces.
bool sk_body_chamfer_handle(SKHandle body, const char *edgeName, const char *faceName, bool flip, double out[12]);
/// What a measured piece of a body is, for sk_measure_element.
typedef enum SKGeom {
  SK_GEOM_OTHER = 0,
  SK_GEOM_BODY = 1,
  SK_GEOM_PLANE = 2,
  SK_GEOM_CYLINDER = 3,
  SK_GEOM_CONE = 4,
  SK_GEOM_SPHERE = 5,
  SK_GEOM_TORUS = 6,
  SK_GEOM_LINE = 7,
  SK_GEOM_CIRCLE = 8,  // a full circle
  SK_GEOM_ARC = 9      // part of a circle
} SKGeom;

/// A measured piece of a body: the whole body, one face or one edge. Fields that don't apply are 0.
typedef struct SKMeasure {
  int geom;              // SKGeom
  double size;           // body or face: area; edge: length
  double volume;         // body only
  double perimeter;      // face: the length of all its edges
  double radius;         // cylinder, cone (at the start), sphere, torus (major), circle, arc
  double radius2;        // torus: the tube's radius; cone: the radius at the other end
  double angle;          // arc: the angle it spans; cone: half the opening angle (radians)
  double length;         // cylinder and cone: the length along the axis
  bool hasCenter;
  double center[3];      // circle, arc, sphere, torus: the centre; cylinder, cone: a point on the axis; other faces and bodies: the centre of mass
  double centroid[3];    // the centre of mass of the body, face or edge
  bool hasDirection;
  double direction[3];   // plane: the normal out of the material; cylinder, cone, torus: the axis; line: along it; circle, arc: the normal
  bool hasEnds;
  double start[3], end[3];  // edge: where it starts and ends
  double bounds[6];      // xmin ymin zmin xmax ymax zmax
} SKMeasure;
/// Measures a face, an edge, or (with a null name) the whole body. `isFace` says which kind `name` is.
bool sk_measure_element(SKHandle body, bool isFace, const char *name, SKMeasure *out);
/// The shortest distance between two measured pieces and the points that are that far apart:
/// out[0] = the distance, out[1..3] = the point on the first, out[4..6] = the point on the second.
/// A null name stands for the whole body. False if either is missing or the search fails.
bool sk_measure_distance(SKHandle bodyA, bool isFaceA, const char *nameA, SKHandle bodyB, bool isFaceB, const char *nameB,
                         double out[7]);
double sk_body_volume(SKHandle body);
/// Whether nothing is left of a body: no faces, or a volume of at most 1e-9 mm³ (the volume is only measured for a
/// body with up to 64 faces, as one with more is not a speck; measuring one with threads takes long).
bool sk_body_is_empty(SKHandle body);
bool sk_body_bounds(SKHandle body, double out[6]);  // xmin ymin zmin xmax ymax zmax
bool sk_body_is_valid(SKHandle body);

// ------------------------------------------------------------ tessellation ---
typedef struct SKMesh {
  uint32_t vertexCount;
  float *positions;        // xyz * vertexCount
  float *normals;          // xyz * vertexCount
  uint32_t triangleCount;
  uint32_t *indices;       // 3 * triangleCount
  uint32_t *triangleFace;  // face index per triangle
  uint32_t segmentCount;
  float *segments;         // 2 points (6 floats) per edge segment
  uint32_t *segmentEdge;   // edge index per segment
} SKMesh;

/// Tessellates a body. linearDeflection in model units, angularDeflection in radians.
SKMesh *sk_body_tessellate(SKHandle body, double linearDeflection, double angularDeflection);
void sk_mesh_free(SKMesh *mesh);

/// Triangulates sketch region i for display (faces only; segments are empty).
SKMesh *sk_sketch_region_tessellate(SKHandle sketch, int i, double linearDeflection);

// ------------------------------------------------------------------ import ---
/// Reads the contents of a STEP file (`size` bytes) into one body holding all its solids, in mm.
/// Faces without solids are sewn into solids where they close up. Faces are named
/// "<featureId>.face<n>" (n from 1, in the file's order), so a rebuild names them the same.
SKHandle sk_import_step(const char *data, size_t size, const char *featureId);

/// Reads an STL file's contents (`size` bytes, binary or ASCII) into one body, in mm. The triangles are sewn into
/// a closed shell and the coplanar ones merged into single faces; the mesh must be watertight. Faces are named
/// "<featureId>.face<n>" like a STEP import's.
SKHandle sk_import_stl(const char *data, size_t size, const char *featureId);

/// The most triangles sk_import_stl accepts. Sewing each one takes a while, and the body is slow to work with after.
enum { SK_STL_MAX_TRIANGLES = 100000 };

/// How many triangles an STL file (binary or ASCII) holds, or -1 if it can't be read as one.
long sk_stl_triangle_count(const char *data, size_t size);

/// Reduces an STL file to about `target` triangles (flat areas and sharp edges are kept, curves get coarser) and
/// returns the result as a binary STL, `*outSize` bytes, to be freed with sk_buffer_free. NULL if the file can't be
/// read. More triangles than asked for are left if the mesh can't be reduced further without folding it over. Small holes
/// in the mesh are filled, so a mesh that is nearly closed comes out closed.
char *sk_stl_simplify(const char *data, size_t size, int target, size_t *outSize);
/// How far the reduction under way (or the last one) has got, from 0 to 1. For showing a progress bar from another thread.
double sk_stl_simplify_progress(void);
void sk_buffer_free(char *buffer);

// ------------------------------------------------------------------ export ---
bool sk_export_step(const SKHandle *bodies, int count, const char *path);
bool sk_export_stl(const SKHandle *bodies, int count, const char *path, double linearDeflection);

#ifdef __cplusplus
}
#endif
#endif
