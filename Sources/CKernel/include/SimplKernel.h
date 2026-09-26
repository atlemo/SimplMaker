// SimplKernel — the C API between SimplCAD (Swift) and OpenCASCADE (C++).
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
// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef SIMPL_KERNEL_H
#define SIMPL_KERNEL_H

#include <stdbool.h>
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
void sk_release(SKHandle h);

// ---------------------------------------------------------------- sketches ---
/// Starts collecting 2D curves on `frame`. Coordinates below are (u, v) in the frame.
SKHandle sk_sketch_new(SKFrame frame);
/// `tag` identifies the curve (use the sketch entity's UUID); it becomes part of face names.
bool sk_sketch_add_line(SKHandle sketch, const char *tag, double u1, double v1, double u2, double v2);
bool sk_sketch_add_circle(SKHandle sketch, const char *tag, double cu, double cv, double r);
/// Counter-clockwise arc from angle a0 to a1 (radians).
bool sk_sketch_add_arc(SKHandle sketch, const char *tag, double cu, double cv, double r, double a0, double a1);
/// Splits the plane by all curves and finds the closed regions (profiles). Returns count or -1.
int sk_sketch_build_regions(SKHandle sketch);
/// Sorted, comma-separated tags of the curves bounding region i (stable across edits).
const char *sk_sketch_region_tags(SKHandle sketch, int i);
double sk_sketch_region_area(SKHandle sketch, int i);
/// A point strictly inside region i, in frame (u, v) coordinates.
bool sk_sketch_region_sample(SKHandle sketch, int i, double *u, double *v);
/// A profile handle for region i, usable by sk_extrude.
SKHandle sk_sketch_region_profile(SKHandle sketch, int i);

// ---------------------------------------------------------------- features ---
/// Extrudes profiles along `dir` from -distanceBack to +distance. Faces are named
/// "<featureId>.start|end|side.<tag>". Returns a body.
SKHandle sk_extrude(const SKHandle *profiles, int count, double dx, double dy, double dz,
                    double distance, double distanceBack, const char *featureId);
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

/// Boolean between two bodies; names from both operands are carried through.
SKHandle sk_boolean(SKHandle target, SKHandle tool, SKBooleanOp op);
/// Constant-radius fillet on the named edges. New faces: "<featureId>.fillet.<edgeName>".
SKHandle sk_fillet(SKHandle body, const char *const *edgeNames, int count, double radius, const char *featureId);
/// Equal-distance chamfer on the named edges. New faces: "<featureId>.chamfer.<edgeName>".
SKHandle sk_chamfer(SKHandle body, const char *const *edgeNames, int count, double distance, const char *featureId);

// ----------------------------------------------------------------- queries ---
int sk_body_face_count(SKHandle body);
const char *sk_body_face_name(SKHandle body, int i);  // i matches SKMesh.triangleFace
int sk_body_edge_count(SKHandle body);
const char *sk_body_edge_name(SKHandle body, int i);  // i matches SKMesh.segmentEdge
int sk_body_find_face(SKHandle body, const char *name);  // -1 if not found
int sk_body_find_edge(SKHandle body, const char *name);  // -1 if not found
/// A planar face of a body as a profile, e.g. to extrude it (press-pull). Its edges are tagged with
/// the body's edge names, so the sides are named "<featureId>.side.<edgeName>".
SKHandle sk_body_face_profile(SKHandle body, const char *faceName);
/// Centre of mass of a face.
bool sk_body_face_center(SKHandle body, const char *faceName, double out[3]);
/// Frame of a planar face (normal points out of the material). False if missing / not planar.
bool sk_body_face_frame(SKHandle body, const char *faceName, SKFrame *out);
/// Drag handle for a fillet/chamfer on an edge: out[0..2] = edge midpoint, out[3..5] = unit
/// direction the rounding grows in (into the material for outside corners, into the air for
/// inside corners). False if the edge doesn't join two faces at an angle.
bool sk_body_edge_handle(SKHandle body, const char *edgeName, double out[6]);
double sk_body_volume(SKHandle body);
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

// ------------------------------------------------------------------ export ---
bool sk_export_step(const SKHandle *bodies, int count, const char *path);
bool sk_export_stl(const SKHandle *bodies, int count, const char *path, double linearDeflection);

#ifdef __cplusplus
}
#endif
#endif
