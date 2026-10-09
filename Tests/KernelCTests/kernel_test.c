// Kernel regression test in plain C (also proves SimplKernel.h is valid C).
// Build + run: scripts/test-kernel.sh
// Copyright © 2026 Atle Mo. All rights reserved.
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
#define NEAR(a, b, tol) (fabs((double)(a) - (double)(b)) <= (tol) * fmax(1.0, fabs((double)(b))))

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
  SKMesh *rm = sk_sketch_region_tessellate(s1, ri, 0.1);
  CHECK(rm && rm->triangleCount > 10 && rm->segmentCount == 0, "region tessellation\n");
  double area = 0;  // triangulated area should match the region area closely
  for (uint32_t t = 0; rm && t < rm->triangleCount; t++) {
    const float *a = rm->positions + 3 * rm->indices[3 * t], *b = rm->positions + 3 * rm->indices[3 * t + 1],
                *c = rm->positions + 3 * rm->indices[3 * t + 2];
    area += 0.5 * fabs((b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]));
  }
  CHECK(fabs(area - sk_sketch_region_area(s1, ri)) < 0.01 * area, "region mesh area %f\n", area);
  sk_mesh_free(rm);

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

/// A whole file in memory (NULL if it can't be read); free() it.
static char *read_file(const char *path, size_t *size) {
  FILE *f = fopen(path, "rb");
  if (!f) return NULL;
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  char *buf = n > 0 ? malloc((size_t)n) : NULL;
  *size = buf ? fread(buf, 1, (size_t)n, f) : 0;
  fclose(f);
  return buf;
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
  CHECK(sk_export_step(&b.finalBody, 1, "/tmp/simplmaker_test.step"), "step\n");
  CHECK(sk_export_stl(&b.finalBody, 1, "/tmp/simplmaker_test.stl", 0.05), "stl\n");

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

  printf("== fillet/chamfer drag handle\n");
  {  // Outside corner of the joined 40x10x5 box: top front edge at y=0, z=5 -> handle points into the material.
    double h[6];
    const char *top_front = "J1.end|J1.side.A0";
    CHECK(sk_body_edge_handle(j, top_front, h), "edge handle\n");
    CHECK(NEAR(h[1], 0, 1e-9) && NEAR(h[2], 5, 1e-9), "handle at edge midpoint (%g %g %g)\n", h[0], h[1], h[2]);
    CHECK(NEAR(h[4], sqrt(0.5), 1e-9) && NEAR(h[5], -sqrt(0.5), 1e-9), "convex: into material (%g %g %g)\n", h[3], h[4], h[5]);
  }
  {  // Inside corner: an L-shaped extrusion; the inner vertical edge's handle points into the air.
    SKHandle ls = sk_sketch_new(XY);
    sk_sketch_add_line(ls, "a", 0, 0, 20, 0);
    sk_sketch_add_line(ls, "b", 20, 0, 20, 10);
    sk_sketch_add_line(ls, "c", 20, 10, 10, 10);
    sk_sketch_add_line(ls, "d", 10, 10, 10, 20);
    sk_sketch_add_line(ls, "e", 10, 20, 0, 20);
    sk_sketch_add_line(ls, "f", 0, 20, 0, 0);
    CHECK(sk_sketch_build_regions(ls) == 1, "L region\n");
    SKHandle lp = sk_sketch_region_profile(ls, 0);
    SKHandle lb = sk_extrude(&lp, 1, 0, 0, 1, 5, 0, "L");
    double h[6];
    CHECK(sk_body_edge_handle(lb, "L.side.c|L.side.d", h), "inner edge handle\n");
    CHECK(NEAR(h[0], 10, 1e-9) && NEAR(h[1], 10, 1e-9), "inner edge position\n");
    CHECK(h[3] > 0.5 && h[4] > 0.5, "concave: into the air (%g %g %g)\n", h[3], h[4], h[5]);
    const char *inner[] = {"L.side.c|L.side.d"};
    SKHandle rounded = sk_fillet(lb, inner, 1, 3, "F");
    CHECK(rounded && sk_body_volume(rounded) > sk_body_volume(lb), "inner fillet adds material\n");
    SKHandle tmp[] = {ls, lp, lb, rounded};
    for (int i = 0; i < 4; i++) sk_release(tmp[i]);
  }

  printf("== tapered extrude\n");
  {
    SKHandle ts = sk_sketch_new(XY);
    sk_sketch_add_line(ts, "T0", 0, 0, 20, 0);
    sk_sketch_add_line(ts, "T1", 20, 0, 20, 10);
    sk_sketch_add_line(ts, "T2", 20, 10, 0, 10);
    sk_sketch_add_line(ts, "T3", 0, 10, 0, 0);
    CHECK(sk_sketch_build_regions(ts) == 1, "taper region\n");
    SKHandle tp = sk_sketch_region_profile(ts, 0);
    double a = 10 * M_PI / 180, t = tan(a);
    // In by 10 degrees: a frustum 5 high whose top is 20 - 2*5*t by 10 - 2*5*t.
    SKHandle in = sk_extrude_tapered(&tp, 1, 0, 0, 1, 5, 0, -a, "TI");
    double top_w = 20 - 10 * t, top_d = 10 - 10 * t;
    double v = 5 * (20 * 10 + top_w * top_d + sqrt(20 * 10 * top_w * top_d)) / 3;  // not exact for a rectangle; use the integral
    v = 0;
    for (int i = 0; i < 1000; i++) {
      double z = (i + 0.5) * 5 / 1000;
      v += (20 - 2 * z * t) * (10 - 2 * z * t) * 5 / 1000;
    }
    CHECK(in && NEAR(sk_body_volume(in), v, 1e-4), "tapered-in volume %g, want %g\n", in ? sk_body_volume(in) : 0, v);
    CHECK(in && sk_body_face_count(in) == 6, "tapered box faces %d\n", in ? sk_body_face_count(in) : 0);
    double ib[6];
    CHECK(in && sk_body_bounds(in, ib) && NEAR(ib[3], 20, 1e-6) && NEAR(ib[5], 5, 1e-6), "tapered-in stays inside the profile\n");
    SKHandle out = sk_extrude_tapered(&tp, 1, 0, 0, 1, 5, 0, a, "TO");
    CHECK(out && sk_body_volume(out) > 1000, "tapered-out grows: %g\n", out ? sk_body_volume(out) : 0);
    CHECK(out && sk_body_bounds(out, ib) && NEAR(ib[3], 20 + 5 * t, 1e-6), "tapered-out bounds %g\n", ib[3]);
    // Against the other way (negative distance): leans the same way as it goes.
    SKHandle down = sk_extrude_tapered(&tp, 1, 0, 0, 1, -5, 0, -a, "TD");
    CHECK(down && NEAR(sk_body_volume(down), v, 1e-4), "tapered the other way, volume %g\n", down ? sk_body_volume(down) : 0);
    // Two sides: a ridge on the plane.
    SKHandle two = sk_extrude_tapered(&tp, 1, 0, 0, 1, 5, 5, a, "T2");
    CHECK(two && sk_body_bounds(two, ib) && NEAR(ib[0], -5 * t, 1e-6) && NEAR(ib[2], -5, 1e-6) && NEAR(ib[5], 5, 1e-6),
          "two-sided taper bounds\n");
    // Too steep: it would close up.
    CHECK(sk_extrude_tapered(&tp, 1, 0, 0, 1, 40, 0, -a, "TX") == 0, "a taper that closes the shape fails\n");
    // A round profile gets a cone.
    SKHandle cs = sk_sketch_new(XY);
    sk_sketch_add_circle(cs, "C", 0, 0, 5);
    CHECK(sk_sketch_build_regions(cs) == 1, "circle region\n");
    SKHandle cp = sk_sketch_region_profile(cs, 0);
    SKHandle cone = sk_extrude_tapered(&cp, 1, 0, 0, 1, 4, 0, -a, "TC");
    double r2 = 5 - 4 * t;
    CHECK(cone && NEAR(sk_body_volume(cone), M_PI * 4 * (25 + 5 * r2 + r2 * r2) / 3, 1e-4), "cone volume %g\n", cone ? sk_body_volume(cone) : 0);
    // A plate with a hole: the hole tapers too.
    SKHandle hs = sk_sketch_new(XY);
    sk_sketch_add_line(hs, "H0", 0, 0, 20, 0);
    sk_sketch_add_line(hs, "H1", 20, 0, 20, 20);
    sk_sketch_add_line(hs, "H2", 20, 20, 0, 20);
    sk_sketch_add_line(hs, "H3", 0, 20, 0, 0);
    sk_sketch_add_circle(hs, "HC", 10, 10, 3);
    int hn = sk_sketch_build_regions(hs);
    int hr = find_region(hs, hn, "H0,H1,H2,H3,HC");
    CHECK(hr >= 0, "plate-with-hole region\n");
    SKHandle hp = sk_sketch_region_profile(hs, hr);
    SKHandle plate = sk_extrude_tapered(&hp, 1, 0, 0, 1, 4, 0, -a, "TH");
    CHECK(plate != 0, "plate with a hole tapers\n");
    print_names(in);
  }

  printf("== symmetric extrude + errors\n");
  SKHandle sym = sk_extrude(profs, 1, 0, 0, 1, 3, 3, "S1");
  double bb[6];
  CHECK(sym && sk_body_bounds(sym, bb) && NEAR(bb[2], -3, 1e-6) && NEAR(bb[5], 3, 1e-6), "symmetric bounds\n");
  const char *bad[] = {"J1.nonexistent|edge"};
  CHECK(sk_fillet(j, bad, 1, 1, "F9") == 0 && strstr(sk_last_error(), "edge not found"), "missing edge error\n");
  const char *e0[] = {sk_body_edge_name(j, 0)};
  CHECK(sk_fillet(j, e0, 1, 50, "F9") == 0, "oversized fillet must fail cleanly\n");
  printf("  oversized fillet error: %s\n", sk_last_error());

  printf("== chamfer/fillet size limited by a rounded corner\n");
  {  // A 60x40x10 plate with 5 mm rounded corners: the top edge's chain runs round them.
    SKHandle box = sk_primitive(SK_BOX, XY, 60, 40, 10, 0, "P");
    const char *vertical[4];
    int nv = 0, ne = sk_body_edge_count(box);
    for (int i = 0; i < ne; i++) {
      SKMeasure m;
      sk_measure_element(box, false, sk_body_edge_name(box, i), &m);
      if (m.geom == SK_GEOM_LINE && fabs(m.direction[2]) > 0.9 && nv < 4) vertical[nv++] = sk_body_edge_name(box, i);
    }
    CHECK(nv == 4, "four vertical edges\n");
    SKHandle plate = sk_fillet(box, vertical, 4, 5, "R");
    CHECK(plate, "round the corners\n");
    const char *top[1] = {0};
    for (int i = 0; plate && i < sk_body_edge_count(plate) && !top[0]; i++) {
      SKMeasure m;
      sk_measure_element(plate, false, sk_body_edge_name(plate, i), &m);
      if (m.geom == SK_GEOM_LINE && fabs(m.bounds[2] - 10) < 1e-6 && fabs(m.bounds[5] - 10) < 1e-6) top[0] = sk_body_edge_name(plate, i);
    }
    CHECK(top[0], "a top edge\n");
    double limit = 0;
    CHECK(top[0] && sk_edge_round_limit(plate, top, 1, &limit) && NEAR(limit, 5, 1e-9), "corner limit is the 5 mm radius (%g)\n", limit);
    SKHandle big = top[0] ? sk_chamfer(plate, top, 1, 6, "C") : 0;
    CHECK(big == 0 && strstr(sk_last_error(), "radius of 5 mm"), "a 6 mm chamfer says why\n");
    printf("  too-big chamfer error: %s\n", sk_last_error());
    SKHandle bigFillet = top[0] ? sk_fillet(plate, top, 1, 6, "F") : 0;
    CHECK(bigFillet && sk_body_is_valid(bigFillet), "a fillet isn't held to the corner radius\n");
    if (bigFillet) sk_release(bigFillet);
    SKHandle ok = top[0] ? sk_chamfer(plate, top, 1, 4.99, "C") : 0;
    CHECK(ok && sk_body_is_valid(ok), "a chamfer just under the corner radius builds\n");
    // Holes widen when rounded, so they never limit it.
    SKHandle pin = sk_primitive(SK_CYLINDER, XY, 8, 0, 20, 0, "Q");
    SKHandle drilled = plate && pin ? sk_boolean(plate, pin, SK_CUT) : 0;
    const char *rim[1] = {0};
    for (int i = 0; drilled && i < sk_body_edge_count(drilled) && !rim[0]; i++) {
      SKMeasure m;
      sk_measure_element(drilled, false, sk_body_edge_name(drilled, i), &m);
      if (m.geom == SK_GEOM_CIRCLE && fabs(m.bounds[2] - 10) < 1e-6) rim[0] = sk_body_edge_name(drilled, i);
    }
    CHECK(rim[0], "a hole's rim\n");
    CHECK(rim[0] && !sk_edge_round_limit(drilled, rim, 1, &limit), "a hole's rim has no corner limit\n");
    SKHandle wide = rim[0] ? sk_chamfer(drilled, rim, 1, 6, "C") : 0;
    CHECK(wide && sk_body_is_valid(wide), "a big chamfer on a hole is fine\n");
    if (wide) sk_release(wide);
    if (drilled) sk_release(drilled);
    if (pin) sk_release(pin);
    SKHandle tmp[] = {box, plate, ok};
    for (int i = 0; i < 3; i++) if (tmp[i]) sk_release(tmp[i]);
  }

  printf("== STEP import\n");
  {
    size_t size = 0;
    char *step = read_file("/tmp/simplmaker_test.step", &size);
    CHECK(step && size > 100, "read back the exported STEP file\n");
    SKHandle imp = sk_import_step(step, size, "imp");
    CHECK(imp && sk_body_is_valid(imp), "import\n");
    CHECK(NEAR(sk_body_volume(imp), sk_body_volume(b.finalBody), 1e-6), "same volume (%f vs %f)\n", sk_body_volume(imp),
          sk_body_volume(b.finalBody));
    CHECK(sk_body_face_count(imp) == sk_body_face_count(b.finalBody), "same faces (%d vs %d)\n", sk_body_face_count(imp),
          sk_body_face_count(b.finalBody));
    CHECK(strcmp(sk_body_face_name(imp, 0), "imp.face1") == 0, "faces named by their place: %s\n", sk_body_face_name(imp, 0));
    // Reading it again names every face and edge the same, so features after an import hold on.
    SKHandle again = sk_import_step(step, size, "imp");
    CHECK(again && sk_body_edge_count(again) == sk_body_edge_count(imp), "same edges\n");
    for (int i = 0; again && i < sk_body_edge_count(imp); i++)
      CHECK(strcmp(sk_body_edge_name(imp, i), sk_body_edge_name(again, i)) == 0, "edge %d renamed\n", i);
    // An imported body can be filleted like any other. (A box: the plate's edges along its
    // rounded corners join tangent faces, which can't take a fillet whether imported or not.)
    SKHandle box = sk_primitive(SK_BOX, XY, 20, 10, 5, 0, "B");
    CHECK(sk_export_step(&box, 1, "/tmp/simplmaker_box.step"), "export a box\n");
    size_t boxSize = 0;
    char *boxStep = read_file("/tmp/simplmaker_box.step", &boxSize);
    SKHandle importedBox = boxStep ? sk_import_step(boxStep, boxSize, "imp3") : 0;
    const char *e0[] = {importedBox ? sk_body_edge_name(importedBox, 0) : ""};
    SKHandle rounded = importedBox ? sk_fillet(importedBox, e0, 1, 0.5, "F") : 0;
    CHECK(rounded && sk_body_volume(rounded) < 1000 && sk_body_volume(rounded) > 990, "fillet an imported edge\n");
    free(boxStep);
    CHECK(sk_import_step("not a step file", 15, "bad") == 0, "garbage is rejected\n");
    CHECK(sk_import_step(NULL, 0, "bad") == 0 && strstr(sk_last_error(), "empty"), "empty is rejected\n");
    free(step);
    SKHandle tmp[] = {imp, again, box, importedBox, rounded};
    for (int i = 0; i < 5; i++) sk_release(tmp[i]);

    // Several bodies in one file come back as one body with all of them.
    SKHandle two[] = {b.finalBody, sym};
    CHECK(sk_export_step(two, 2, "/tmp/simplmaker_test2.step"), "export two bodies\n");
    step = read_file("/tmp/simplmaker_test2.step", &size);
    SKHandle both = step ? sk_import_step(step, size, "imp2") : 0;
    CHECK(both && NEAR(sk_body_volume(both), sk_body_volume(b.finalBody) + sk_body_volume(sym), 1e-6), "two solids\n");
    free(step);
    sk_release(both);
  }

  printf(failures ? "\n%d FAILURE(S)\n" : "\nALL KERNEL TESTS PASSED\n", failures);
  return failures ? 1 : 0;
}
