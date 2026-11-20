// SimplMaker site: the wireframe in the home-page hero. It builds the SimplMaker logo, step by step, in the order the logo part
// itself was made: sketch a square and extrude it into a cube, drill the big hole in the front and the small one in the top,
// sketch a square on the right side and cut a notch with it, round the notch's inner corner, then chamfer the edges. Sketch lines
// and the feature being edited are drawn in the accent colour, then settle to ink. After a pause the steps are undone, faster,
// and it starts over. (With "reduce motion" it shows the finished part and nothing else.)
//
// The numbers are the logo's own (a 20 mm cube; holes of 12 and 8 mm; a 12 x 12 notch 2.5 mm deep with a 2 mm round; chamfers of
// 0.3 and 0.25 mm), in units of 10 mm, centred on the cube, Z up, the front (the big hole) towards -Y and the notch on the right.
//
// The part is regenerated every frame from a handful of numbers (state()): how much of each sketch is drawn, the extrude height,
// the depth of each cut, the round and the chamfer. build() turns those numbers into
//   - a triangle mesh of the solid, used only to hide the lines behind it: the faces are drawn into the depth buffer
//     with no colour, then the edges are drawn against that depth; and
//   - the edges, as short segments. Segments that fall inside a hole or the notch are dropped.
// A chamfer is drawn as the two lines it leaves on the faces either side of the edge (they lie on the faces, so they hide
// like any other line), which is also where the app draws them.
// Hidden on small screens (CSS hides the canvas, and nothing below runs until the screen is wide enough).
(function () {
  'use strict';
  var canvas = document.querySelector('canvas.hero-model');
  if (!canvas) return;
  var wide = window.matchMedia('(min-width: 861px)');

  var LINE_PX = 1.15;   // stroke width in CSS pixels

  // ---- the part (the logo's numbers, in units of 10 mm) ----
  var TAU = Math.PI * 2;
  var N = 96;                                   // samples round every circle
  var R1 = 0.6, R2 = 0.4;                       // the hole in from the front, the hole down from the top
  var NOTCH = 0.25, NLO = -0.2, ROUND = 0.2;    // the notch: depth, where it starts on y and z (to the back and the top), the round of its inner corner
  var CH1 = 0.03, CH2 = 0.025;                  // chamfers: the cube and the notch's opening, the holes' rims
  var ANG = [];
  for (var i = 0; i < N; i++) ANG.push(i * TAU / N);

  // The timeline, in seconds. Each step is [start, end]; the part holds still for a beat between steps.
  var SKETCH = [0.3, 1.4], EXTRUDE = [1.7, 2.8];
  var CIRC_F = [3.3, 3.9], CUT_F = [4.1, 5.1], CIRC_T = [5.5, 6.0], CUT_T = [6.2, 7.1];
  var RECT = [7.5, 8.4], CUT_N = [8.7, 9.5], FILLET = [9.8, 10.4], CHAMFER = [10.8, 11.8];
  var PLAY = CHAMFER[1], HOLD = 5.5, RATE = 3, UNDO = PLAY / RATE, GAP = 0.9, CYCLE = PLAY + HOLD + UNDO + GAP;

  function clamp01(x) { return x < 0 ? 0 : x > 1 ? 1 : x; }
  function ease(x) { x = clamp01(x); return x * x * (3 - 2 * x); }
  function prog(t, s) { return clamp01((t - s[0]) / (s[1] - s[0])); }
  // how much of the accent colour a line has: it has all of it from the start of its step and gives it up a beat after `s`
  function heat(t, start, fadeFrom, fade) { return t < start ? 0 : t < fadeFrom ? 1 : 1 - ease((t - fadeFrom) / fade); }

  // The numbers that describe the part at time t.
  function state(t) {
    return {
      sk: prog(t, SKETCH), zt: -1 + 2 * ease(prog(t, EXTRUDE)),                // the sketch square; the top of the cube
      cf: prog(t, CIRC_F), dF: 2 * ease(prog(t, CUT_F)),                        // the front circle; how deep the front hole is (2 is through)
      ct: prog(t, CIRC_T), dT: 2 * ease(prog(t, CUT_T)),                        // the same for the top hole
      rr: prog(t, RECT), dN: NOTCH * ease(prog(t, CUT_N)),                      // the notch's square; how deep the notch is
      fr: ROUND * ease(prog(t, FILLET)), ch: ease(prog(t, CHAMFER)),            // the round; how much of the chamfer there is
      hBot: t < EXTRUDE[0] ? 1 : 1 - ease((t - EXTRUDE[0]) / 0.7),
      hTop: t < EXTRUDE[1] ? 1 : 1 - ease((t - EXTRUDE[1]) / 0.5),
      hF: heat(t, CIRC_F[0], CUT_F[0], 0.4), hT: heat(t, CIRC_T[0], CUT_T[0], 0.4), hN: heat(t, RECT[0], CUT_N[0], 0.4),
      hR: heat(t, FILLET[0], FILLET[1], 0.4), hC: heat(t, CHAMFER[0], CHAMFER[0] + 0.5, 0.5)
    };
  }

  var INK = [0.04, 0.04, 0.045], ACCENT = [0.92, 0.34, 0.16];

  // `view` is the direction the camera looks along. A line on a flat face is only drawn while that face turns towards the camera:
  // a line on a face seen edge-on, or from behind, can show a pixel or two outside the outline where it meets the silhouette.
  function build(s, view) {
    var vd = view || [0, 0, -1];
    var tri = [], seg = [];
    var dF = s.dF, dT = s.dT, dN = s.dN, r = s.fr;
    var c1 = CH1 * s.ch, c2 = CH2 * s.ch;
    var x0 = 1 - dN, y0 = NLO + r, z0 = NLO + r;      // the notch's floor; where its round begins on the wall and on the ledge
    var solid = s.zt + 1 > 0.004, cube = s.zt >= 1 - 1e-6;

    // ---- which points are in a cut-away part ----
    function inF(x, y, z) { return dF > 0 && x * x + z * z < R1 * R1 - 1e-3 && y > -1 + 1e-4 && y < -1 + dF - 1e-4; }
    function inT(x, y, z) { return dT > 0 && x * x + y * y < R2 * R2 - 1e-3 && z > 1 - dT + 1e-4 && z < 1 - 1e-4; }
    function inN(x, y, z) {
      if (dN <= 0 || x < x0 + 1e-3 || y < NLO + 1e-3 || z < NLO + 1e-3) return false;
      if (r > 0.005 && y < y0 && z < z0) { var dy = y - y0, dz = z - z0; return dy * dy + dz * dz < r * r - 1e-3; }
      return true;
    }
    function gone(x, y, z) { return inF(x, y, z) || inT(x, y, z) || inN(x, y, z); }

    function T(a, b, c) { tri.push(a[0], a[1], a[2], b[0], b[1], b[2], c[0], c[1], c[2]); }
    function quad(a, b, c, d) { T(a, b, c); T(a, c, d); }

    // ---- the faces ----
    // a rectangle u0..u1 x v0..v1 of a plane (map turns (u, v) into a point), with a round hole at (0, 0) when `hole` is set
    function plate(map, u0, u1, v0, v1, hole) {
      if (!hole) { quad(map(u0, v0), map(u1, v0), map(u1, v1), map(u0, v1)); return; }
      var a = ANG.slice();
      [[u1, v1], [u0, v1], [u0, v0], [u1, v0]].forEach(function (p) { a.push((Math.atan2(p[1], p[0]) + TAU) % TAU); });
      a.sort(function (p, q) { return p - q; });
      function edge(th) {
        var c = Math.cos(th), s2 = Math.sin(th);
        var t = Math.min(c > 1e-9 ? u1 / c : c < -1e-9 ? u0 / c : 1e9, s2 > 1e-9 ? v1 / s2 : s2 < -1e-9 ? v0 / s2 : 1e9);
        return map(c * t, s2 * t);
      }
      for (var k = 0; k < a.length; k++) {
        var p = a[k], q = k + 1 < a.length ? a[k + 1] : TAU + a[0];
        quad(map(hole * Math.cos(p), hole * Math.sin(p)), map(hole * Math.cos(q), hole * Math.sin(q)), edge(q), edge(p));
      }
    }
    function mapF(u, v) { return [u, -1, v]; }       // the front (x, z), the back, the top (x, y), the bottom
    function mapB(u, v) { return [u, 1, v]; }
    function mapT(u, v) { return [u, v, 1]; }
    function mapD(u, v) { return [u, v, -1]; }
    // a round hole's wall (from lo to hi along its axis) and, if it stops short, its floor; cells inside the other cut are left out
    function wall(R, at, skip, lo, hi, floorToo) {
      var M = Math.max(1, Math.ceil((hi - lo) / 0.1)), RINGS = 4;
      for (var k = 0; k < N; k += 2) {
        var a = ANG[k], b = k + 2 >= N ? TAU : ANG[k + 2], m = (a + b) / 2;
        for (var j = 0; j < M; j++) {
          var u0 = lo + (hi - lo) * j / M, u1 = lo + (hi - lo) * (j + 1) / M;
          if (skip(at(R, m, (u0 + u1) / 2))) continue;
          quad(at(R, a, u0), at(R, b, u0), at(R, b, u1), at(R, a, u1));
        }
        if (floorToo) for (var q = 0; q < RINGS; q++) {
          var r0 = R * q / RINGS, r1 = R * (q + 1) / RINGS;
          if (skip(at((r0 + r1) / 2, m, hi))) continue;
          quad(at(r0, a, hi), at(r0, b, hi), at(r1, b, hi), at(r1, a, hi));
        }
      }
    }
    function atF(R, th, y) { return [R * Math.cos(th), y, R * Math.sin(th)]; }    // the front hole: along y
    function atT(R, th, z) { return [R * Math.cos(th), R * Math.sin(th), z]; }    // the top hole: along z

    if (solid && !cube) {                                          // the cube still growing: a plain box
      quad([-1, -1, -1], [1, -1, -1], [1, -1, s.zt], [-1, -1, s.zt]);
      quad([-1, 1, -1], [1, 1, -1], [1, 1, s.zt], [-1, 1, s.zt]);
      quad([-1, -1, -1], [-1, 1, -1], [-1, 1, s.zt], [-1, -1, s.zt]);
      quad([1, -1, -1], [1, 1, -1], [1, 1, s.zt], [1, -1, s.zt]);
      quad([-1, -1, -1], [1, -1, -1], [1, 1, -1], [-1, 1, -1]);
      quad([-1, -1, s.zt], [1, -1, s.zt], [1, 1, s.zt], [-1, 1, s.zt]);
    } else if (cube) {
      // the cube is chamfered: every face is inset by q, a strip joins each pair of faces and a small facet closes each corner
      var q = c1, pu = dN > 0 ? x0 : 1 - q, lo = -1 + q, hiq = 1 - q;
      plate(mapF, lo, hiq, lo, hiq, dF > 0 ? R1 : 0);                              // front, with the front hole
      plate(mapD, lo, hiq, lo, hiq, dT >= 2 ? R2 : 0);                             // bottom, with the top hole once it is through
      quad([-1, lo, lo], [-1, hiq, lo], [-1, hiq, hiq], [-1, lo, hiq]);            // left
      // back: the notch takes its right-hand strip, down to the ledge
      plate(mapB, lo, pu, lo, hiq, dF >= 2 ? R1 : 0);
      if (dN > 0) quad(mapB(x0, lo), mapB(hiq, lo), mapB(hiq, NLO), mapB(x0, NLO));
      // top: the same, and the top hole
      plate(mapT, lo, pu, lo, hiq, dT > 0 ? R2 : 0);
      if (dN > 0) quad(mapT(x0, lo), mapT(hiq, lo), mapT(hiq, NLO), mapT(x0, NLO));
      function strip(ax, e1, e2, from, to) {
        function P(v, a, b) { return ax === 0 ? [v, a, b] : ax === 1 ? [a, v, b] : [a, b, v]; }
        quad(P(from, e1, e2 * (1 - q)), P(to, e1, e2 * (1 - q)), P(to, e1 * (1 - q), e2), P(from, e1 * (1 - q), e2));
      }
      [[-1, -1], [1, -1], [-1, 1]].forEach(function (e) { strip(0, e[0], e[1], lo, hiq); });   // along x (y, z); the top back one stops at the notch
      strip(0, 1, 1, lo, dN > 0 ? x0 - q : hiq);
      [[-1, -1], [1, -1], [-1, 1]].forEach(function (e) { strip(1, e[0], e[1], lo, hiq); });   // along y (x, z)
      strip(1, 1, 1, lo, dN > 0 ? NLO - q : hiq);
      [[-1, -1], [-1, 1], [1, -1]].forEach(function (e) { strip(2, e[0], e[1], lo, hiq); });   // along z (x, y)
      strip(2, 1, 1, lo, dN > 0 ? NLO - q : hiq);
      [-1, 1].forEach(function (sx) { [-1, 1].forEach(function (sy) { [-1, 1].forEach(function (sz) {
        if (dN > 0 && sx === 1 && sy === 1 && sz === 1) return;                       // that corner is in the notch
        T([sx, sy * (1 - q), sz * (1 - q)], [sx * (1 - q), sy, sz * (1 - q)], [sx * (1 - q), sy * (1 - q), sz]);
      }); }); });
      // right: the notch's square is cut out of it, with the corner rounded
      function mapR(u, v) { return [1, u, v]; }                                    // (y, z)
      if (dN > 0) {
        quad(mapR(lo, lo), mapR(hiq, lo), mapR(hiq, NLO), mapR(lo, NLO));
        quad(mapR(lo, NLO), mapR(NLO, NLO), mapR(NLO, hiq), mapR(lo, hiq));
        if (r > 0.005) for (var k = 0; k < 12; k++) {
          var a = Math.PI + (Math.PI / 2) * k / 12, b = Math.PI + (Math.PI / 2) * (k + 1) / 12;
          T(mapR(NLO, NLO), mapR(y0 + r * Math.cos(a), z0 + r * Math.sin(a)), mapR(y0 + r * Math.cos(b), z0 + r * Math.sin(b)));
        }
        // the notch's own faces: floor, wall, ledge and the round between them
        function mapX(u, v) { return [x0, u, v]; }                                  // the floor (y, z)
        quad(mapX(y0, NLO), mapX(1, NLO), mapX(1, 1), mapX(y0, 1));
        quad(mapX(NLO, z0), mapX(y0, z0), mapX(y0, 1), mapX(NLO, 1));
        quad([x0, NLO, z0], [1, NLO, z0], [1, NLO, 1], [x0, NLO, 1]);              // the wall
        quad([x0, y0, NLO], [1, y0, NLO], [1, 1, NLO], [x0, 1, NLO]);              // the ledge
        if (r > 0.005) for (var j = 0; j < 12; j++) {
          var a2 = Math.PI + (Math.PI / 2) * j / 12, b2 = Math.PI + (Math.PI / 2) * (j + 1) / 12;
          var p1 = [y0 + r * Math.cos(a2), z0 + r * Math.sin(a2)], p2 = [y0 + r * Math.cos(b2), z0 + r * Math.sin(b2)];
          quad([x0, p1[0], p1[1]], [1, p1[0], p1[1]], [1, p2[0], p2[1]], [x0, p2[0], p2[1]]);
          T(mapX(y0, z0), mapX(p1[0], p1[1]), mapX(p2[0], p2[1]));
        }
      } else quad(mapR(lo, lo), mapR(hiq, lo), mapR(hiq, hiq), mapR(lo, hiq));
      if (dF > 0) wall(R1, atF, function (p) { return inT(p[0], p[1], p[2]); }, -1, -1 + dF, dF < 2);
      if (dT > 0) wall(R2, atT, function (p) { return inF(p[0], p[1], p[2]); }, 1 - dT, 1, false);
      if (dT > 0 && dT < 2) {                                                       // the top hole's floor
        var RINGS = 4;
        for (var kk = 0; kk < N; kk += 2) {
          var aa = ANG[kk], bb = kk + 2 >= N ? TAU : ANG[kk + 2], mm = (aa + bb) / 2;
          for (var qq = 0; qq < RINGS; qq++) {
            var q0 = R2 * qq / RINGS, q1 = R2 * (qq + 1) / RINGS, zf = 1 - dT;
            if (inF(((q0 + q1) / 2) * Math.cos(mm), ((q0 + q1) / 2) * Math.sin(mm), zf)) continue;
            quad(atT(q0, aa, zf), atT(q0, bb, zf), atT(q1, bb, zf), atT(q1, aa, zf));
          }
        }
      }
    }

    // ---- the edges ----
    function mix(h) { return [INK[0] + (ACCENT[0] - INK[0]) * h, INK[1] + (ACCENT[1] - INK[1]) * h, INK[2] + (ACCENT[2] - INK[2]) * h]; }
    var CORNER = [[0, -1], [0, 1], [1, -1], [1, -1], [0, 1], [1, 1]];
    function addSeg(a, b, col, n, bias) {
      if (n && n[0] * vd[0] + n[1] * vd[1] + n[2] * vd[2] > -0.03) return;
      var dx = b[0] - a[0], dy = b[1] - a[1], dz = b[2] - a[2];
      var n = Math.max(1, Math.ceil(Math.sqrt(dx * dx + dy * dy + dz * dz) / 0.1));
      for (var j = 0; j < n; j++) {
        var f0 = j / n, f1 = (j + 1) / n, fm = (f0 + f1) / 2;
        if (gone(a[0] + dx * fm, a[1] + dy * fm, a[2] + dz * fm)) continue;
        CORNER.forEach(function (c) {
          seg.push(a[0] + dx * f0, a[1] + dy * f0, a[2] + dz * f0, a[0] + dx * f1, a[1] + dy * f1, a[2] + dz * f1, c[0], c[1], col[0], col[1], col[2], bias || 0);
        });
      }
    }
    function poly(pts, col, closed, nrm) {
      for (var i = 0, n = closed ? pts.length : pts.length - 1; i < n; i++) addSeg(pts[i], pts[(i + 1) % pts.length], col, nrm);
    }
    function add(p, d, k) { return [p[0] + d[0] * k, p[1] + d[1] * k, p[2] + d[2] * k]; }
    // a convex edge from p to q between faces with outward normals na and nb: the chamfer leaves a line on each face
    // the ends of the chamfer lines, with the normal of the face each lies on; the corner faces between them are closed afterwards
    var ends = [];
    function convex(p, q, na, nb, c, col, facet) {
      var a1 = add(p, nb, -c), a2 = add(q, nb, -c), b1 = add(p, na, -c), b2 = add(q, na, -c);
      addSeg(a1, a2, col, na); addSeg(b1, b2, col, nb);
      if (c > 0) ends.push([a1, na, facet], [a2, na, facet], [b1, nb, facet], [b2, nb, facet]);
    }
    // Where chamfers meet at a corner the part has a small facet; its edges join the ends of the lines on the faces around it. The
    // facet lies just under the faces of the solid the lines are hidden by, so each edge is given a little depth allowance.
    function closeCorners(cmax, col) {
      var seen = {};
      for (var i = 0; i < ends.length; i++) for (var j = i + 1; j < ends.length; j++) {
        var P = ends[i][0], Q = ends[j][0], nP = ends[i][1], nQ = ends[j][1];
        if (Math.abs(nP[0] * nQ[0] + nP[1] * nQ[1] + nP[2] * nQ[2]) > 0.1) continue;
        var dx = Q[0] - P[0], dy = Q[1] - P[1], dz = Q[2] - P[2], d = Math.sqrt(dx * dx + dy * dy + dz * dz);
        if (d < 1e-4 || d > 1.8 * cmax) continue;
        // only where both faces clearly turn towards us: a corner on the outline keeps an open end rather than a spur sticking out
        if (nP[0] * vd[0] + nP[1] * vd[1] + nP[2] * vd[2] > -0.15 || nQ[0] * vd[0] + nQ[1] * vd[1] + nQ[2] * vd[2] > -0.15) continue;
        var key = [P, Q].map(function (v) { return v.map(function (x) { return Math.round(x * 2000); }).join(','); }).sort().join('|');
        if (seen[key]) continue; seen[key] = 1;
        addSeg(P, Q, col, null, 0.0007);     // straight; it lies just under the faces, so it gets a little depth allowance
      }
    }
    var X = [1, 0, 0], Y = [0, 1, 0], Z = [0, 0, 1], mX = [-1, 0, 0], mY = [0, -1, 0], mZ = [0, 0, -1];
    function ring(R, mk, col, upTo) {
      var pts = [], n = upTo === undefined ? N : Math.floor(upTo * N);
      for (var k = 0; k <= n; k++) pts.push(mk(R, ANG[k % N]));
      poly(pts, col, upTo === undefined);
    }
    function circF(R, y) { return function (rad, th) { return [rad * Math.cos(th), y, rad * Math.sin(th)]; }; }
    function circT(R, z) { return function (rad, th) { return [rad * Math.cos(th), rad * Math.sin(th), z]; }; }

    var cBot = mix(s.hBot), cTop = mix(s.hTop), cF = mix(s.hF), cT = mix(s.hT), cN = mix(s.hN), cR = mix(s.hR), cC = mix(Math.max(s.hC, 0));
    var cEdge = c1 > 0 ? cC : INK;

    if (!solid) {
      // the sketch square, drawn side by side
      var C = [[-1, -1], [1, -1], [1, 1], [-1, 1], [-1, -1]], sides = s.sk * 4, pts = [];
      for (var i = 0; i < 4 && sides > 0; i++) {
        var f = Math.min(1, sides); sides -= 1;
        if (!pts.length) pts.push([C[i][0], C[i][1], -1]);
        pts.push([C[i][0] + (C[i + 1][0] - C[i][0]) * f, C[i][1] + (C[i + 1][1] - C[i][1]) * f, -1]);
      }
      poly(pts, ACCENT, false);
    } else if (!cube) {
      var zt = s.zt, sq = function (z) { return [[-1, -1, z], [1, -1, z], [1, 1, z], [-1, 1, z]]; };
      poly(sq(-1), mix(s.hBot), true); poly(sq(zt), mix(s.hTop), true);
      sq(-1).forEach(function (p) { addSeg(p, [p[0], p[1], zt], INK); });
    } else {
      // the cube's twelve edges, each as the two lines the chamfer leaves; the notch takes the ends of three of them
      var lo = -1 + c1, hi = 1 - c1;
      function pt3(ax, v, o1, o2) { return ax === 0 ? [v, o1, o2] : ax === 1 ? [o1, v, o2] : [o1, o2, v]; }   // v along axis ax, the other two coordinates after it
      function edgeCol(base) { return c1 > 0 ? cC : base; }
      // along x, at (y, z), between the faces with these normals; the top back one stops at the notch
      [[-1, -1, mY, mZ, cBot], [1, -1, Y, mZ, cBot], [-1, 1, mY, Z, cTop], [1, 1, Y, Z, cTop]].forEach(function (e) {
        var end = dN > 0 && e[0] === 1 && e[1] === 1 ? x0 - c1 : hi;
        convex(pt3(0, lo, e[0], e[1]), pt3(0, end, e[0], e[1]), e[2], e[3], c1, edgeCol(e[4]), true);
      });
      // along y, at (x, z); the top right one stops at the notch
      [[-1, -1, mX, mZ, cBot], [1, -1, X, mZ, cBot], [-1, 1, mX, Z, cTop], [1, 1, X, Z, cTop]].forEach(function (e) {
        var end = dN > 0 && e[0] === 1 && e[1] === 1 ? NLO - c1 : hi;
        convex(pt3(1, lo, e[0], e[1]), pt3(1, end, e[0], e[1]), e[2], e[3], c1, edgeCol(e[4]), true);
      });
      // along z, at (x, y); the back right one stops at the notch
      [[-1, -1, mX, mY], [-1, 1, mX, Y], [1, -1, X, mY], [1, 1, X, Y]].forEach(function (e) {
        var end = dN > 0 && e[0] === 1 && e[1] === 1 ? NLO - c1 : hi;
        convex(pt3(2, lo, e[0], e[1]), pt3(2, end, e[0], e[1]), e[2], e[3], c1, edgeCol(INK), true);
      });
      if (dN > 0) {
        var cn = c1 > 0 ? cC : cN, k2 = r > 0.005;
        // where the notch's opening meets the right face: the wall, the round and the ledge
        convex([1, NLO, z0], [1, NLO, 1 - c1], Y, X, c1, cn);                          // wall: faces +y (the wall) and +x (the right face)
        convex([1, y0, NLO], [1, 1 - c1, NLO], Z, X, c1, cn);                          // ledge: faces +z and +x
        if (k2) {
          var arcR = function (rad, x) { var pp = []; for (var q = 0; q <= 12; q++) { var an = Math.PI + (Math.PI / 2) * q / 12; pp.push([x, y0 + rad * Math.cos(an), z0 + rad * Math.sin(an)]); } return pp; };
          poly(arcR(r + c1, 1), cn, false, X); poly(arcR(r, 1 - c1), cn, false);
          poly(arcR(r, x0), cR, false);                                                  // where the round meets the floor
          addSeg([x0, NLO, z0], [1 - c1, NLO, z0], cR); addSeg([x0, y0, NLO], [1 - c1, y0, NLO], cR);  // its seams with the wall and the ledge
        } else addSeg([x0, NLO, NLO], [1 - c1, NLO, NLO], cR);
        // the floor against the top and the back, and the wall against the top, the ledge against the back
        // The four edges along the notch's top and back. Where two of them meet at an inner corner of a face, the lines on that face
        // run on to meet at the mitre (one chamfer past the corner), and the strips' crease is closed by closeCorners below.
        var c7 = c1 > 0 ? c2 : 0;
        function ln(p, q, n, col) { addSeg(p, q, col, n); if (c1 > 0) ends.push([p, n, false], [q, n, false]); }
        ln([x0 - c1, NLO - c1, 1], [x0 - c1, 1 - c1, 1], Z, cn);                      // floor | top, on the top face
        ln([x0, NLO, 1 - c1], [x0, 1 - c1, 1 - c1], X, cn);                           // ... on the floor
        ln([x0 - c1, NLO - c1, 1], [1 - c1, NLO - c1, 1], Z, cn);                     // wall | top, on the top face
        ln([x0, NLO, 1 - c1], [1 - c1, NLO, 1 - c1], Y, cn);                          // ... on the wall
        ln([x0 - c1, 1, NLO - c7], [x0 - c1, 1, 1 - c1], Y, cn);                      // floor | back, on the back face
        ln([x0, 1 - c1, NLO], [x0, 1 - c1, 1 - c1], X, cn);                           // ... on the floor
        ln([x0 - c1, 1, NLO - c7], [1 - c1, 1, NLO - c7], Y, c1 > 0 ? cC : cN);        // ledge | back, on the back face
        ln([x0, 1 - c7, NLO], [1 - c1, 1 - c7, NLO], Z, c1 > 0 ? cC : cN);             // ... on the ledge
        // the floor's inner edges against the wall and the ledge
        addSeg([x0, NLO, z0], [x0, NLO, 1], cN); addSeg([x0, y0, NLO], [x0, 1, NLO], cN);
      }
    }

    if (solid && cube && c1 > 0) closeCorners(Math.max(c1, c2), cC);

    // ---- the holes ----
    if (solid && cube) {
      var tau8 = [0, 1, 2, 3, 4, 5, 6, 7].map(function (i) { return i * TAU / 8; });
      if (dF > 0) {
        ring(R1 + c2, circF(0, -1), c2 > 0 ? cC : cF);                              // on the front face
        ring(R1, circF(0, -1 + c2), c2 > 0 ? cC : cF);                              // on the wall, a chamfer in
        if (dF >= 2) { ring(R1 + c2, circF(0, 1), c2 > 0 ? cC : cF); ring(R1, circF(0, 1 - c2), c2 > 0 ? cC : cF); }
        else ring(R1, circF(0, -1 + dF), INK);                                      // the floor of a hole that stops short
      } else if (s.cf > 0) ring(R1, circF(0, -1), ACCENT, s.cf);
      if (dT > 0) {
        ring(R2 + c2, circT(0, 1), c2 > 0 ? cC : cT);
        ring(R2, circT(0, 1 - c2), c2 > 0 ? cC : cT);
        if (dT >= 2) { ring(R2 + c2, circT(0, -1), c2 > 0 ? cC : cT); ring(R2, circT(0, -1 + c2), c2 > 0 ? cC : cT); }
        else ring(R2, circT(0, 1 - dT), INK);
      } else if (s.ct > 0) ring(R2, circT(0, 1), ACCENT, s.ct);
      // the notch's square, sketched on the right face
      if (dN <= 0 && s.rr > 0) {
        var Rp = [[NLO, NLO], [1, NLO], [1, 1], [NLO, 1], [NLO, NLO]], len = s.rr * 4, pr = [];
        for (var q = 0; q < 4 && len > 0; q++) {
          var f2 = Math.min(1, len); len -= 1;
          if (!pr.length) pr.push([1, Rp[q][0], Rp[q][1]]);
          pr.push([1, Rp[q][0] + (Rp[q + 1][0] - Rp[q][0]) * f2, Rp[q][1] + (Rp[q + 1][1] - Rp[q][1]) * f2]);
        }
        poly(pr, ACCENT, false);
      }
      if (dF > 0 && dT > 0) {
        // where the two holes meet: one closed curve on the upper side of the front hole and one on the lower side; with a chamfer,
        // the two curves it leaves on the two walls (each is where one wall meets a slightly wider copy of the other hole)
        function meet(Rt, Rf, col) {
          // points with x^2 + y^2 = Rt^2 (a cylinder along z) and x^2 + z^2 = Rf^2 (a cylinder along y)
          [-1, 1].forEach(function (zs) {
            [-1, 1].forEach(function (ys) {
              var pts = [];
              for (var i = 0; i <= 48; i++) {
                var ph = i * Math.PI / 48, x = Rt * Math.cos(ph);
                pts.push([x, ys * Rt * Math.sin(ph), zs * Math.sqrt(Math.max(0, Rf * Rf - x * x))]);
              }
              for (var j = 0; j + 1 < pts.length; j++) {
                var a = pts[j], b = pts[j + 1];
                var okF = a[1] < -1 + dF - 1e-4 && b[1] < -1 + dF - 1e-4;
                var okT = a[2] > 1 - dT + 1e-4 && b[2] > 1 - dT + 1e-4;
                if (okF && okT) addSeg(a, b, col);
              }
            });
          });
        }
        var gcol = c2 > 0 ? cC : cT;
        meet(R2, R1, gcol);                                                           // the sharp edge; with a chamfer these are the two offset curves below
        if (c2 > 0) { meet(R2 + c2, R1, gcol); meet(R2, R1 + c2, gcol); }
      }
    }
    return { tri: new Float32Array(tri), seg: new Float32Array(seg) };
  }

  function run() {
    var gl = canvas.getContext('webgl', { antialias: true, alpha: true, premultipliedAlpha: true });
    if (!gl) { canvas.style.display = 'none'; return; }
    var reduced = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;

    // ---- colour: the site's ink and accent, read from the stylesheet ----
    function readColor(name, fallback) {
      var hex = (getComputedStyle(document.documentElement).getPropertyValue(name) || '').trim();
      return /^#([0-9a-f]{6})$/i.test(hex) ? [1, 3, 5].map(function (i) { return parseInt(hex.substr(i, 2), 16) / 255; }) : fallback;
    }
    INK = readColor('--ink', INK); ACCENT = INK.slice();     // every line is ink: the part is drawn in one colour from sketch to finish

    // ---- shaders ----
    function compile(type, src) {
      var s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s);
      if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
      return s;
    }
    function program(vs, fs) {
      var p = gl.createProgram();
      gl.attachShader(p, compile(gl.VERTEX_SHADER, vs)); gl.attachShader(p, compile(gl.FRAGMENT_SHADER, fs));
      gl.linkProgram(p);
      if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(p));
      return p;
    }
    var depthProg, lineProg;
    try {
      depthProg = program(
        'attribute vec3 p; uniform mat4 m; void main() { gl_Position = m * vec4(p, 1.0); }',
        'precision mediump float; void main() { gl_FragColor = vec4(0.0); }');
      // Each segment is a screen-space quad: both ends are projected, then pushed sideways by half the stroke width.
      lineProg = program(
        'attribute vec3 pa; attribute vec3 pb; attribute vec2 k; attribute vec3 col; attribute float bias;\n' +
        'uniform mat4 m; uniform vec2 res; uniform float half_w; varying vec3 vc;\n' +
        'void main() {\n' +
        '  vec4 A = m * vec4(pa, 1.0); vec4 B = m * vec4(pb, 1.0);\n' +
        '  vec2 a = A.xy / A.w * res * 0.5; vec2 b = B.xy / B.w * res * 0.5;\n' +
        '  vec2 d = b - a; float len = length(d); d = len > 0.0001 ? d / len : vec2(1.0, 0.0);\n' +
        '  vec2 n = vec2(-d.y, d.x);\n' +
        '  vec4 P = mix(A, B, k.x);\n' +
        '  vec2 off = n * k.y * half_w;\n' +
        '  P.xy += off / (res * 0.5) * P.w;\n' +
        '  P.z -= (0.00012 + bias) * P.w;\n' +                      // nudge toward the camera so edges win over their own faces; kept tiny, or hidden edges peek out where they end
        '  gl_Position = P; vc = col;\n' +
        '}',
        'precision mediump float; varying vec3 vc; void main() { gl_FragColor = vec4(vc, 1.0); }');
    } catch (e) { canvas.style.display = 'none'; return; }
    var uDepthM = gl.getUniformLocation(depthProg, 'm'), aDepthP = gl.getAttribLocation(depthProg, 'p');
    var uLineM = gl.getUniformLocation(lineProg, 'm'), uRes = gl.getUniformLocation(lineProg, 'res'), uHalf = gl.getUniformLocation(lineProg, 'half_w');
    var aPa = gl.getAttribLocation(lineProg, 'pa'), aPb = gl.getAttribLocation(lineProg, 'pb'), aK = gl.getAttribLocation(lineProg, 'k'), aCol = gl.getAttribLocation(lineProg, 'col'), aBias = gl.getAttribLocation(lineProg, 'bias');

    // ---- geometry: rebuilt whenever the timeline moves ----
    var meshBuf = gl.createBuffer(), lineBuf = gl.createBuffer(), triCount = 0, lineCount = 0;
    function upload(t) {
      var g = build(state(t), [Math.cos(pitch) * Math.sin(yaw), Math.cos(pitch) * Math.cos(yaw), -Math.sin(pitch)]);
      gl.bindBuffer(gl.ARRAY_BUFFER, meshBuf); gl.bufferData(gl.ARRAY_BUFFER, g.tri, gl.DYNAMIC_DRAW);
      gl.bindBuffer(gl.ARRAY_BUFFER, lineBuf); gl.bufferData(gl.ARRAY_BUFFER, g.seg, gl.DYNAMIC_DRAW);
      triCount = g.tri.length / 3; lineCount = g.seg.length / 12;
    }

    // ---- state ----
    var yaw = -0.6, pitch = 0.5;          // radians; yaw turns about Z (up), pitch tips the part toward the viewer
    var vYaw = 0, vPitch = 0;              // drag inertia
    var SPIN = reduced ? 0 : 0.28;         // idle spin, radians per second (its mean; the speed varies)
    var dragging = false, lastX = 0, lastY = 0, lastT = 0;
    var idleT = 0;                         // seconds of idle motion so far; drives the slow drift
    var clock = 0.3;                       // seconds into the build / hold / undo cycle
    var inView = true, tabShown = true, visible = true, raf = 0, prev = 0;
    var W = 1, H = 1, dpr = 1;
    var DIST = 7, FOV = DIST * 0.46, NEAR = 1, FAR = 20;   // FOV here is the focal factor: the part fills about 46% of the box

    function timelineT() {
      if (reduced) return PLAY;
      var c = clock % CYCLE;
      if (c < PLAY) return c;
      if (c < PLAY + HOLD) return PLAY;
      if (c < PLAY + HOLD + UNDO) return PLAY - (c - PLAY - HOLD) * RATE;
      return 0;
    }

    function resize() {
      var r = canvas.getBoundingClientRect();
      dpr = Math.min(window.devicePixelRatio || 1, 2);
      W = Math.max(1, Math.round(r.width * dpr)); H = Math.max(1, Math.round(r.height * dpr));
      canvas.width = W; canvas.height = H;
      gl.viewport(0, 0, W, H);
      draw();
    }

    // model -> clip space, column-major. Yaw about Z, pitch about X, camera DIST away looking along +Y.
    function matrix() {
      var cy = Math.cos(yaw), sy = Math.sin(yaw), cp = Math.cos(pitch), sp = Math.sin(pitch);
      var m = Math.min(W, H), fx = FOV * m / W, fy = FOV * m / H;
      var A = -(FAR + NEAR) / (FAR - NEAR), B = -2 * FAR * NEAR / (FAR - NEAR);
      var r0 = [fx * cy, -fx * sy, 0, 0];
      var r1 = [fy * sp * sy, fy * sp * cy, fy * cp, 0];
      var d = [cp * sy, cp * cy, -sp];
      var r2 = [-A * d[0], -A * d[1], -A * d[2], -A * DIST + B];
      var r3 = [d[0], d[1], d[2], DIST];
      var rows = [r0, r1, r2, r3], out = new Float32Array(16);
      for (var c = 0; c < 4; c++) for (var r = 0; r < 4; r++) out[c * 4 + r] = rows[r][c];
      return out;
    }

    function draw() {
      var m = matrix();
      gl.clearColor(0, 0, 0, 0); gl.clearDepth(1);
      gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
      gl.enable(gl.DEPTH_TEST); gl.depthFunc(gl.LEQUAL);

      // 1. the solid, depth only
      if (triCount) {
        gl.useProgram(depthProg);
        gl.uniformMatrix4fv(uDepthM, false, m);
        gl.bindBuffer(gl.ARRAY_BUFFER, meshBuf);
        gl.enableVertexAttribArray(aDepthP); gl.vertexAttribPointer(aDepthP, 3, gl.FLOAT, false, 0, 0);
        gl.colorMask(false, false, false, false);
        gl.enable(gl.POLYGON_OFFSET_FILL); gl.polygonOffset(1, 1);
        gl.drawArrays(gl.TRIANGLES, 0, triCount);
        gl.disable(gl.POLYGON_OFFSET_FILL);
        gl.colorMask(true, true, true, true);
        gl.disableVertexAttribArray(aDepthP);
      }

      // 2. the edges, hidden wherever the solid is in front
      if (lineCount) {
        gl.useProgram(lineProg);
        gl.uniformMatrix4fv(uLineM, false, m);
        gl.uniform2f(uRes, W, H);
        gl.uniform1f(uHalf, LINE_PX * dpr * 0.5);
        gl.bindBuffer(gl.ARRAY_BUFFER, lineBuf);
        gl.enableVertexAttribArray(aPa); gl.vertexAttribPointer(aPa, 3, gl.FLOAT, false, 48, 0);
        gl.enableVertexAttribArray(aPb); gl.vertexAttribPointer(aPb, 3, gl.FLOAT, false, 48, 12);
        gl.enableVertexAttribArray(aK); gl.vertexAttribPointer(aK, 2, gl.FLOAT, false, 48, 24);
        gl.enableVertexAttribArray(aCol); gl.vertexAttribPointer(aCol, 3, gl.FLOAT, false, 48, 32);
        gl.enableVertexAttribArray(aBias); gl.vertexAttribPointer(aBias, 1, gl.FLOAT, false, 48, 44);
        gl.drawArrays(gl.TRIANGLES, 0, lineCount);
        gl.disableVertexAttribArray(aPa); gl.disableVertexAttribArray(aPb); gl.disableVertexAttribArray(aK); gl.disableVertexAttribArray(aCol); gl.disableVertexAttribArray(aBias);
      }
    }

    function clampPitch(v) { return Math.max(-1.3, Math.min(1.3, v)); }

    function frame(t) {
      raf = 0;
      var dt = prev ? Math.min(0.05, (t - prev) / 1000) : 0.016;
      prev = t;
      if (!reduced) { clock += dt; upload(timelineT()); }
      if (!dragging) {
        // Let a flick coast, then ease back into the idle motion: a steady turn to the right whose speed breathes a
        // little, and (fading in over the first seconds) a slow, shallow nod up and down (the top face stays in view while it is being sketched on), so it never repeats exactly.
        var k = Math.pow(0.04, dt);
        idleT += dt;
        var fade = Math.min(1, idleT / 5), yawTarget = 0, pitchTarget = 0;
        if (SPIN) {
          yawTarget = SPIN * (1 + 0.35 * Math.sin(0.43 * idleT) + 0.15 * Math.sin(1.1 * idleT + 2));
          pitchTarget = fade * (0.05 * Math.cos(0.28 * idleT) + 0.02 * Math.cos(0.67 * idleT + 0.8)) + 0.1 * (0.5 - pitch);   // the last term keeps the nod around the starting view
        }
        vYaw = yawTarget + (vYaw - yawTarget) * k;
        vPitch = pitchTarget + (vPitch - pitchTarget) * k;
        yaw += vYaw * dt;
        pitch = clampPitch(pitch + vPitch * dt);
      }
      draw();
      var moving = !reduced || dragging || Math.abs(vYaw) > 0.003 || Math.abs(vPitch) > 0.003;
      if (visible && moving) raf = requestAnimationFrame(frame); else prev = 0;
    }
    function wake() { if (!raf && visible) raf = requestAnimationFrame(frame); }

    canvas.addEventListener('pointerdown', function (e) {
      dragging = true; lastX = e.clientX; lastY = e.clientY; lastT = e.timeStamp;
      vYaw = 0; vPitch = 0;
      canvas.setPointerCapture(e.pointerId);
      canvas.classList.add('grabbing');
      wake();
    });
    canvas.addEventListener('pointermove', function (e) {
      if (!dragging) return;
      var dx = e.clientX - lastX, dy = e.clientY - lastY, dt = Math.max(1, e.timeStamp - lastT) / 1000;
      yaw += dx * 0.011; pitch = clampPitch(pitch + dy * 0.011);
      vYaw = dx * 0.011 / dt; vPitch = dy * 0.011 / dt;       // the last movement becomes the fling
      lastX = e.clientX; lastY = e.clientY; lastT = e.timeStamp;
      if (reduced) upload(timelineT());     // lines on faces turned away from us are left out, so they follow the view
      draw();
    });
    function release() { dragging = false; canvas.classList.remove('grabbing'); wake(); }
    canvas.addEventListener('pointerup', release);
    canvas.addEventListener('pointercancel', release);
    canvas.addEventListener('keydown', function (e) {
      var step = { ArrowLeft: [-0.2, 0], ArrowRight: [0.2, 0], ArrowUp: [0, -0.2], ArrowDown: [0, 0.2] }[e.key];
      if (!step) return;
      e.preventDefault(); yaw += step[0]; pitch = clampPitch(pitch + step[1]); if (reduced) upload(timelineT()); draw();
    });
    canvas.addEventListener('webglcontextlost', function (e) { e.preventDefault(); canvas.style.visibility = 'hidden'; });

    if ('ResizeObserver' in window) new ResizeObserver(resize).observe(canvas); else window.addEventListener('resize', resize);
    if ('IntersectionObserver' in window) {
      new IntersectionObserver(function (entries) {
        inView = entries[0].isIntersecting; visible = inView && tabShown;
        if (visible) wake();
      }).observe(canvas);
    }
    document.addEventListener('visibilitychange', function () { tabShown = !document.hidden; visible = inView && tabShown; if (visible) wake(); });

    upload(timelineT());
    resize();
    if (SPIN) vYaw = SPIN;
    wake();
  }

  var started = false;
  function start() { if (started || !wide.matches) return; started = true; run(); }
  start();
  if (wide.addEventListener) wide.addEventListener('change', start); else wide.addListener(start);
})();
