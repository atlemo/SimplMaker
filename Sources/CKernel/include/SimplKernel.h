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
