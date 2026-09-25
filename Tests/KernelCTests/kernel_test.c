// Kernel regression test in plain C (also proves SimplKernel.h is valid C).
// Build + run: scripts/test-kernel.sh
// SPDX-License-Identifier: GPL-3.0-or-later
#include "SimplKernel.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0;
#define CHECK(cond, ...)                                              \
  do {                                                                \
    if (!(cond)) {                                                    \
      failures++;                                                     \
      printf("  FAIL %s:%d: ", __FILE__, __LINE__);                   \
      printf(__VA_ARGS__);                                            \
      printf("  [kernel error: %s]\n", sk_last_error());              \
    }                                                                 \
  } while (0)
#define NEAR(a, b, tol) (fabs((a) - (b)) <= (tol) * fmax(1.0, fabs(b)))

static const SKFrame XY = {0, 0, 0, 0, 0, 1, 1, 0, 0};

static int find_region(SKHandle sketch, int n, const char *tags) {
  for (int i = 0; i < n; i++)
    if (strcmp(sk_sketch_region_tags(sketch, i), tags) == 0) return i;
  return -1;
}

typedef struct { double w, d, h, hole, pin, fillet, chamfer; } Params;
typedef struct { double volBeforeFillet, volAfterFillet, volFinal; SKHandle finalBody; } Result;

/// The same document as spike/parametric_spike.py, plus fillet + chamfer features.
static Result build(Params p) {
  Result res = {0};
  // Sketch1 on XY: rectangle + centred hole
  SKHandle s1 = sk_sketch_new(XY);
  sk_sketch_add_line(s1, "L0", 0, 0, p.w, 0);
  sk_sketch_add_line(s1, "L1", p.w, 0, p.w, p.d);
  sk_sketch_add_line(s1, "L2", p.w, p.d, 0, p.d);
  sk_sketch_add_line(s1, "L3", 0, p.d, 0, 0);
  sk_sketch_add_circle(s1, "C0", p.w / 2, p.d / 2, p.hole / 2);
  int n = sk_sketch_build_regions(s1);
  CHECK(n == 2, "expected 2 regions, got %d\n", n);
  int ri = find_region(s1, n, "C0,L0,L1,L2,L3");
  CHECK(ri >= 0, "plate region not found\n");
  CHECK(NEAR(sk_sketch_region_area(s1, ri), p.w * p.d - M_PI * p.hole * p.hole / 4, 1e-9), "region area\n");
  SKHandle prof = sk_sketch_region_profile(s1, ri);

  // Extrude E1
  SKHandle e1 = sk_extrude(&prof, 1, 0, 0, 1, p.h, 0, "E1");
  CHECK(e1, "extrude E1\n");
  CHECK(sk_body_face_count(e1) == 7, "E1 faces %d\n", sk_body_face_count(e1));
  CHECK(sk_body_find_face(e1, "E1.side.L2") >= 0, "E1.side.L2 missing\n");

  // Sketch2 on persistent face E1.end, cut a pin hole through
  SKFrame top;
  CHECK(sk_body_face_frame(e1, "E1.end", &top), "face frame\n");
  CHECK(NEAR(top.oz, p.h, 1e-12) && NEAR(top.nz, 1, 1e-12), "top frame z=%g nz=%g\n", top.oz, top.nz);
  SKHandle s2 = sk_sketch_new(top);
  sk_sketch_add_circle(s2, "C1", p.w * 0.2, p.d * 0.5, p.pin / 2);
  int n2 = sk_sketch_build_regions(s2);
  CHECK(n2 == 1 && find_region(s2, n2, "C1") == 0, "pin region\n");
  SKHandle prof2 = sk_sketch_region_profile(s2, 0);
  SKHandle tool = sk_extrude(&prof2, 1, -top.nx, -top.ny, -top.nz, 2 * p.h, 0, "E2");
  SKHandle body = sk_boolean(e1, tool, SK_CUT);
  CHECK(body, "cut\n");
  res.volBeforeFillet = sk_body_volume(body);
  double expected = (p.w * p.d - M_PI * (p.hole * p.hole + p.pin * p.pin) / 4) * p.h;
  CHECK(NEAR(res.volBeforeFillet, expected, 1e-6), "volume %f vs %f\n", res.volBeforeFillet, expected);
  CHECK(sk_body_find_face(body, "E2.side.C1") >= 0, "pin wall name lost through boolean\n");

  // Fillet F1: two vertical corner edges, addressed by persistent edge names
  const char *corners[] = {"E1.side.L0|E1.side.L1", "E1.side.L2|E1.side.L3"};
  SKHandle filleted = sk_fillet(body, corners, 2, p.fillet, "F1");
  CHECK(filleted, "fillet\n");
  res.volAfterFillet = sk_body_volume(filleted);
  double removed = 2 * (p.fillet * p.fillet - M_PI * p.fillet * p.fillet / 4) * p.h;
  CHECK(NEAR(res.volAfterFillet, expected - removed, 1e-6), "fillet volume %f vs %f\n", res.volAfterFillet,
        expected - removed);
  CHECK(sk_body_find_face(filleted, "F1.fillet.E1.side.L0|E1.side.L1") >= 0, "fillet face name\n");
  CHECK(sk_body_find_face(filleted, "E1.end") >= 0, "E1.end lost through fillet\n");

  // Chamfer CH1 on the top edge along L3 (tangent chain continues into the fillet)
  const char *topEdge[] = {"E1.end|E1.side.L3"};
  SKHandle chamfered = sk_chamfer(filleted, topEdge, 1, p.chamfer, "CH1");
  CHECK(chamfered, "chamfer\n");
  CHECK(sk_body_is_valid(chamfered), "chamfer valid\n");
  res.volFinal = sk_body_volume(chamfered);
  CHECK(res.volFinal < res.volAfterFillet, "chamfer should remove material\n");
  CHECK(sk_body_find_face(chamfered, "CH1.chamfer.E1.end|E1.side.L3") >= 0, "chamfer face name\n");
  CHECK(sk_body_find_face(chamfered, "CH1.chamfer.E1.end|E1.side.L2") >= 0, "tangent-chain chamfer face name\n");
  CHECK(sk_body_find_face(chamfered, "CH1.chamfer.face") < 0, "no fallback names expected\n");

  res.finalBody = chamfered;
  SKHandle tmp[] = {s1, prof, e1, s2, prof2, tool, body, filleted};
  for (int i = 0; i < 8; i++) sk_release(tmp[i]);
  return res;
}

static void print_names(SKHandle b) {
  printf("  faces (%d):", sk_body_face_count(b));
  for (int i = 0; i < sk_body_face_count(b); i++) printf(" %s", sk_body_face_name(b, i));
  printf("\n");
}

int main(void) {
  printf("== initial document\n");
  Params p = {60, 40, 10, 10, 6, 5, 1.5};
  Result a = build(p);
  print_names(a.finalBody);
  printf("  volume: cut %.3f  filleted %.3f  chamfered %.3f\n", a.volBeforeFillet, a.volAfterFillet, a.volFinal);

  printf("== edit parameters, regenerate (same feature definitions / names)\n");
  Params q = {90, 50, 25, 12.5, 6, 8, 2};
  Result b = build(q);
  print_names(b.finalBody);
  printf("  volume: cut %.3f  filleted %.3f  chamfered %.3f\n", b.volBeforeFillet, b.volAfterFillet, b.volFinal);
  CHECK(sk_body_face_count(a.finalBody) == sk_body_face_count(b.finalBody), "topology changed on edit\n");
  for (int i = 0; i < sk_body_face_count(a.finalBody); i++)
    CHECK(sk_body_find_face(b.finalBody, sk_body_face_name(a.finalBody, i)) >= 0, "name %s did not survive\n",
          sk_body_face_name(a.finalBody, i));

  printf("== tessellation + export\n");
  SKMesh *m = sk_body_tessellate(b.finalBody, 0.05, 0.3);
  CHECK(m && m->triangleCount > 100 && m->segmentCount > 50, "mesh\n");
  uint32_t maxFace = 0;
  for (uint32_t t = 0; m && t < m->triangleCount; t++) maxFace = m->triangleFace[t] > maxFace ? m->triangleFace[t] : maxFace;
  CHECK(m && (int)maxFace == sk_body_face_count(b.finalBody) - 1, "every face tessellated\n");
  if (m) printf("  %u vertices, %u triangles, %u edge segments\n", m->vertexCount, m->triangleCount, m->segmentCount);
  sk_mesh_free(m);
  CHECK(sk_export_step(&b.finalBody, 1, "/tmp/simplcad_test.step"), "step\n");
  CHECK(sk_export_stl(&b.finalBody, 1, "/tmp/simplcad_test.stl", 0.05), "stl\n");

  printf("== join of two flush extrusions merges coplanar faces, so the outer edge can be filleted\n");
  SKHandle s = sk_sketch_new(XY);
  sk_sketch_add_line(s, "A0", 0, 0, 20, 0);
  sk_sketch_add_line(s, "A1", 20, 0, 20, 10);
  sk_sketch_add_line(s, "A2", 20, 10, 0, 10);
  sk_sketch_add_line(s, "A3", 0, 10, 0, 0);
  sk_sketch_add_line(s, "B0", 20, 0, 40, 0);
  sk_sketch_add_line(s, "B1", 40, 0, 40, 10);
  sk_sketch_add_line(s, "B2", 40, 10, 20, 10);
  int nr = sk_sketch_build_regions(s);
  CHECK(nr == 2, "two regions, got %d\n", nr);
  SKHandle profs[2] = {sk_sketch_region_profile(s, 0), sk_sketch_region_profile(s, 1)};
  SKHandle j = sk_extrude(profs, 2, 0, 0, 1, 5, 0, "J1");
  CHECK(j && sk_body_face_count(j) == 6, "joined box should have 6 faces, has %d\n", sk_body_face_count(j));
  print_names(j);
  CHECK(fabs(sk_body_volume(j) - 2000) < 1e-6, "joined volume\n");

  printf("== symmetric extrude + errors\n");
  SKHandle sym = sk_extrude(profs, 1, 0, 0, 1, 3, 3, "S1");
  double bb[6];
  CHECK(sym && sk_body_bounds(sym, bb) && NEAR(bb[2], -3, 1e-6) && NEAR(bb[5], 3, 1e-6), "symmetric bounds\n");
  const char *bad[] = {"J1.nonexistent|edge"};
  CHECK(sk_fillet(j, bad, 1, 1, "F9") == 0 && strstr(sk_last_error(), "edge not found"), "missing edge error\n");
  const char *e0[] = {sk_body_edge_name(j, 0)};
  CHECK(sk_fillet(j, e0, 1, 50, "F9") == 0, "oversized fillet must fail cleanly\n");
  printf("  oversized fillet error: %s\n", sk_last_error());

  printf(failures ? "\n%d FAILURE(S)\n" : "\nALL KERNEL TESTS PASSED\n", failures);
  return failures ? 1 : 0;
}
