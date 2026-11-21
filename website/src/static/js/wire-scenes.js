// SimplMaker site: the two animated wireframes on the home page, a mold that opens, a vase that comes apart.
// A third, "model", draws a sketch and extrudes it, rebuilt every frame, on the page's own paper colour (data-theme="light").
// Same technique as the hero (hero-model.js): the solid is drawn into the depth buffer with no colour, then the edges are
// drawn against that depth, so lines behind a surface disappear. No dependencies.
//
//   <canvas class="wire-scene" data-scene="mold|split">
//
// Each scene is built once (triangles for hiding, edge segments sorted into named groups) and then only moved: a part has an
// offset, and the silhouette of a round part is recomputed every frame from the viewing angle. A group is drawn bright when
// the accordion item beside the canvas is about it (the canvas hears "wirefocus"), dim otherwise. The loop is closed, open,
// hold, closed. With "reduce motion" it rests in the open pose and can only be turned by hand.
(function () {
  'use strict';
  var canvases = document.querySelectorAll('canvas.wire-scene');
  if (!canvases.length) return;

  var TAU = Math.PI * 2, HALF = Math.PI / 2;
  function clamp01(x) { return x < 0 ? 0 : x > 1 ? 1 : x; }
  function ease(x) { x = clamp01(x); return x * x * (3 - 2 * x); }

  // ---------------------------------------------------------------- geometry kit
  function Kit() { this.tri = []; this.lines = {}; }
  // a triangle: position and normal per vertex (the flat normal unless TN gives them)
  Kit.prototype.T = function (a, b, c) {
    var ux = b[0] - a[0], uy = b[1] - a[1], uz = b[2] - a[2], vx = c[0] - a[0], vy = c[1] - a[1], vz = c[2] - a[2];
    var nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx, l = Math.sqrt(nx * nx + ny * ny + nz * nz) || 1;
    nx /= l; ny /= l; nz /= l;
    this.tri.push(a[0], a[1], a[2], nx, ny, nz, b[0], b[1], b[2], nx, ny, nz, c[0], c[1], c[2], nx, ny, nz);
  };
  Kit.prototype.TN = function (a, na, b, nb, c, nc) {
    this.tri.push(a[0], a[1], a[2], na[0], na[1], na[2], b[0], b[1], b[2], nb[0], nb[1], nb[2], c[0], c[1], c[2], nc[0], nc[1], nc[2]);
  };
  Kit.prototype.Q = function (a, b, c, d) { this.T(a, b, c); this.T(a, c, d); };
  Kit.prototype.L = function (g, a, b) { (this.lines[g] || (this.lines[g] = [])).push(a[0], a[1], a[2], b[0], b[1], b[2]); };
  Kit.prototype.P = function (g, pts, closed) {
    for (var i = 0, n = closed ? pts.length : pts.length - 1; i < n; i++) this.L(g, pts[i], pts[(i + 1) % pts.length]);
  };
  Kit.prototype.part = function (name, extra) {
    var p = { name: name, tri: new Float32Array(this.tri), lines: {}, off: [0, 0, 0] };
    for (var g in this.lines) p.lines[g] = this.lines[g];
    if (extra) for (var k in extra) p[k] = extra[k];
    return p;
  };

  // a circle (or part of one) about the Z axis
  function ringZ(r, z, a0, a1, n, mapX) {
    var pts = [];
    for (var i = 0; i <= n; i++) { var a = a0 + (a1 - a0) * i / n; pts.push([(mapX || 1) * r * Math.cos(a), r * Math.sin(a), z]); }
    return pts;
  }
  // a circle in a plane square to X, at x
  function ringX(x, cy, cz, r, n) {
    var pts = [];
    for (var i = 0; i < n; i++) { var a = i * TAU / n; pts.push([x, cy + r * Math.cos(a), cz + r * Math.sin(a)]); }
    return pts;
  }
  // a cylinder along Z (r1 at the top, for a chamfered tip), with its edges in `group`
  function cylinderZ(k, group, cx, cy, z0, z1, r0, r1, n) {
    var lo = [], hi = [], i;
    for (i = 0; i < n; i++) {
      var a = i * TAU / n;
      lo.push([cx + r0 * Math.cos(a), cy + r0 * Math.sin(a), z0]);
      hi.push([cx + r1 * Math.cos(a), cy + r1 * Math.sin(a), z1]);
    }
    for (i = 0; i < n; i++) {
      var j = (i + 1) % n;
      k.Q(lo[i], lo[j], hi[j], hi[i]);
      k.T([cx, cy, z1], hi[i], hi[j]);
      k.T([cx, cy, z0], lo[j], lo[i]);
    }
    k.P(group, lo, true); k.P(group, hi, true);
    for (i = 0; i < n; i += n / 4) k.L(group, lo[i], hi[i]);
  }

  // a surface of revolution about Z from a polyline of [r, z] points; `a0..a1` is the angle range
  function revolve(k, prof, a0, a1, n, flip) {
    for (var i = 0; i + 1 < prof.length; i++) {
      var p = prof[i], q = prof[i + 1];
      if (p[0] === 0 && q[0] === 0) continue;
      for (var j = 0; j < n; j++) {
        var a = a0 + (a1 - a0) * j / n, b = a0 + (a1 - a0) * (j + 1) / n;
        var f = flip || 1;
        k.Q([f * p[0] * Math.cos(a), p[0] * Math.sin(a), p[1]], [f * p[0] * Math.cos(b), p[0] * Math.sin(b), p[1]],
            [f * q[0] * Math.cos(b), q[0] * Math.sin(b), q[1]], [f * q[0] * Math.cos(a), q[0] * Math.sin(a), q[1]]);
      }
    }
  }
  // the lean silhouette lines of a surface of revolution: the two generators square to the line of sight
  function silhouette(prof, yaw, off) {
    var out = [];
    [-yaw, Math.PI - yaw].forEach(function (phi) {
      var c = Math.cos(phi), s = Math.sin(phi);
      for (var i = 0; i + 1 < prof.length; i++) {
        var p = prof[i], q = prof[i + 1];
        if (p[1] === q[1]) continue;                       // a flat step has no silhouette
        out.push(p[0] * c, p[0] * s, p[1] + (off || 0), q[0] * c, q[0] * s, q[1] + (off || 0));
      }
    });
    return out;
  }

  // ================================================================ scene: a mold
  // A block split across X. B (x >= 0) is built, A is its mirror with the four key pegs. The cast (a small cup) sits in the middle.
  function moldScene() {
    var W = 0.9, D = 0.9, H = 1.0, RG = 0.16, NA = 28;
    var C = [[0, -0.85], [0.30, -0.85], [0.30, -0.70], [0.42, -0.70], [0.58, 0.50], [0.62, 0.50], [0.62, 0.58], [RG, 0.58], [RG, H]];
    var BODY = C.slice(0, 7).concat([[0, 0.58]]);
    var KEYS = [[0.72, 0.78], [-0.72, 0.78], [0.72, -0.78], [-0.72, -0.78]];

    // the bands of the parting face: where the profile has height, with its radius at both ends
    var bands = [];
    for (var i = 0; i + 1 < C.length; i++) if (C[i + 1][1] > C[i][1] + 1e-6) bands.push([C[i][1], C[i + 1][1], C[i][0], C[i + 1][0]]);

    function half(sgn, pegs) {
      var k = new Kit();
      function p(x, y, z) { return [sgn * x, y, z]; }
      // outer walls
      k.Q(p(W, -D, -H), p(W, D, -H), p(W, D, H), p(W, -D, H));
      k.Q(p(0, -D, -H), p(W, -D, -H), p(W, -D, H), p(0, -D, H));
      k.Q(p(0, D, -H), p(W, D, -H), p(W, D, H), p(0, D, H));
      k.Q(p(0, -D, -H), p(W, -D, -H), p(W, D, -H), p(0, D, -H));
      // top, with the gate cut out of it
      var angs = [], c0 = Math.atan2(D, W), a;
      for (i = 0; i <= NA; i++) angs.push(-HALF + i * Math.PI / NA);
      angs.push(c0, -c0); angs.sort(function (u, v) { return u - v; });
      function bound(th) {
        var c = Math.cos(th), s = Math.sin(th);
        var t = Math.min(c > 1e-9 ? W / c : 1e9, Math.abs(s) > 1e-9 ? D / Math.abs(s) : 1e9);
        return [c * t, s * t];
      }
      for (i = 0; i + 1 < angs.length; i++) {
        var u = angs[i], v = angs[i + 1], bu = bound(u), bv = bound(v);
        k.Q(p(RG * Math.cos(u), RG * Math.sin(u), H), p(RG * Math.cos(v), RG * Math.sin(v), H), p(bv[0], bv[1], H), p(bu[0], bu[1], H));
      }
      // the parting face, with the cavity's outline cut out of it
      k.Q(p(0, -D, -H), p(0, D, -H), p(0, D, C[0][1]), p(0, -D, C[0][1]));
      bands.forEach(function (b) {
        k.Q(p(0, -D, b[0]), p(0, -b[2], b[0]), p(0, -b[3], b[1]), p(0, -D, b[1]));
        k.Q(p(0, b[2], b[0]), p(0, D, b[0]), p(0, D, b[1]), p(0, b[3], b[1]));
      });
      // the cavity
      revolve(k, C, -HALF, HALF, NA, sgn);
      // pegs: on A they stand out of the parting face toward B
      if (pegs) KEYS.forEach(function (ky) {
        var n = 12, base = [], tip = [], L = 0.14;
        for (i = 0; i < n; i++) {
          var t = i * TAU / n;
          base.push([0, ky[0] + 0.075 * Math.cos(t), ky[1] + 0.075 * Math.sin(t)]);
          tip.push([-sgn * L, ky[0] + 0.05 * Math.cos(t), ky[1] + 0.05 * Math.sin(t)]);
        }
        for (i = 0; i < n; i++) { var j = (i + 1) % n; k.Q(base[i], base[j], tip[j], tip[i]); k.T([-sgn * L, ky[0], ky[1]], tip[i], tip[j]); }
        k.P('keys', base, true); k.P('keys', tip, true);
        for (i = 0; i < n; i += 3) k.L('keys', base[i], tip[i]);
      });
      else KEYS.forEach(function (ky) { k.P('keys', ringX(0, ky[0], ky[1], 0.085, 16), true); });   // the sockets
      // edges
      var X0 = 0, X1 = W;
      var box = [[X0, -D, -H], [X1, -D, -H], [X1, D, -H], [X0, D, -H], [X0, -D, H], [X1, -D, H], [X1, D, H], [X0, D, H]].map(function (q) { return p(q[0], q[1], q[2]); });
      [[0, 1], [1, 2], [2, 3], [3, 0], [4, 5], [5, 6], [6, 7], [7, 4], [0, 4], [1, 5], [2, 6], [3, 7]].forEach(function (e) { k.L('block', box[e[0]], box[e[1]]); });
      // the gate and the vent
      var vy = 0.5, vr = 0.05;
      k.P('gate', ringZ(RG, H, -HALF, HALF, 20, sgn), false);
      k.P('gate', ringZ(RG, 0.58, -HALF, HALF, 20, sgn), false);
      [-1, 1].forEach(function (s) { k.L('gate', p(0, s * RG, 0.58), p(0, s * RG, H)); });
      [-0.7, -0.35, 0, 0.35, 0.7].forEach(function (f) { k.L('gate', p(RG * Math.cos(f * HALF), RG * Math.sin(f * HALF), 0.58), p(RG * Math.cos(f * HALF), RG * Math.sin(f * HALF), H)); });
      k.L('vent', p(0, vy - vr, 0.58), p(0, vy - vr, H)); k.L('vent', p(0, vy + vr, 0.58), p(0, vy + vr, H));
      var vt = []; for (i = 0; i <= 10; i++) { a = -HALF + i * Math.PI / 10; vt.push(p(vr * Math.cos(a), vy + vr * Math.sin(a), H)); }
      k.P('vent', vt, false);
      // the cavity: rings and meridians
      for (i = 1; i < C.length - 2; i++) if (C[i][0] > 0) k.P('cavity', ringZ(C[i][0], C[i][1], -HALF, HALF, NA, sgn), false);
      [-1, 1].forEach(function (s) {
        var prof = []; for (var q = 1; q < C.length - 1; q++) prof.push(p(0, s * C[q][0], C[q][1]));
        prof.unshift(p(0, 0, C[0][1])); k.P('cavity', prof, false);
      });
      [-0.5, 0, 0.5].forEach(function (f) {
        var ph = f * HALF, ln = [];
        for (var q = 1; q < 7; q++) ln.push(p(C[q][0] * Math.cos(ph), C[q][0] * Math.sin(ph), C[q][1]));
        k.P('cavity', ln, false);
      });
      return k.part(sgn > 0 ? 'B' : 'A');
    }
    var A = half(-1, true), B = half(1, false);

    // the cast
    var kb = new Kit(), N2 = 48;
    revolve(kb, BODY, 0, TAU, N2);
    for (i = 1; i < BODY.length - 1; i++) if (BODY[i][0] > 0) kb.P('body', ringZ(BODY[i][0], BODY[i][1], 0, TAU, 48), true);
    kb.P('body', ringZ(0.62, 0.58, 0, TAU, 48), true);
    var body = kb.part('body', { dyn: function (yaw) { return { body: silhouette(BODY, yaw) }; } });

    var parts = [A, B, body];
    return {
      parts: parts,
      view: { yaw: -0.8, pitch: 0.34, dist: 8, fov: 8 * 0.44, swing: 0.5, spin: 0 },
      period: 10.5,
      pose: function (t) {
        var s = t < 1.4 ? 0 : t < 3.8 ? ease((t - 1.4) / 2.4) : t < 7.4 ? 1 : t < 9.6 ? 1 - ease((t - 7.4) / 2.2) : 0;
        A.off = [-1.25 * s, 0, 0]; B.off = [1.25 * s, 0, 0];
      },
      restPose: 0.85,
      level: function (g, focus) {
        var base = { block: 0.7, cavity: 0.7, gate: 0.7, vent: 0.7, keys: 0.7, body: 1 };
        var hot = { auto: ['block', 'cavity'], gate: ['gate', 'vent'], keys: ['keys'], check: ['body', 'cavity'] }[focus] || [];
        return hot.indexOf(g) >= 0 ? 1 : (focus ? 0.34 : base[g] === undefined ? 0.5 : base[g]);
      }
    };
  }

  // the vase: its radius at height z, from -1.5 to 1.5 (a cubic through a few points)
  var vaseR = (function () {
    var CP = [[-1.5, 0.62], [-1.0, 0.86], [-0.4, 1.0], [0.2, 0.82], [0.8, 0.52], [1.2, 0.54], [1.5, 0.74]];
    var slope = CP.map(function (c, i) {
      var a = CP[Math.max(0, i - 1)], b = CP[Math.min(CP.length - 1, i + 1)];
      return (b[1] - a[1]) / (b[0] - a[0]);
    });
    return function (z) {
      for (var i = 0; i + 1 < CP.length; i++) if (z <= CP[i + 1][0] + 1e-9) {
        var z0 = CP[i][0], z1 = CP[i + 1][0], h = z1 - z0, t = (z - z0) / h, t2 = t * t, t3 = t2 * t;
        return (2 * t3 - 3 * t2 + 1) * CP[i][1] + (t3 - 2 * t2 + t) * h * slope[i] + (-2 * t3 + 3 * t2) * CP[i + 1][1] + (t3 - t2) * h * slope[i + 1];
      }
      return CP[CP.length - 1][1];
    };
  })();

  // ================================================================ scene: a vase cut in three, with connectors
  function splitScene() {
    var Z0 = -1.5, Z1 = 1.5, CUTS = [-0.5, 0.5], R = vaseR;
    function profile(za, zb) {
      var pts = [[0, za]], steps = Math.max(2, Math.round((zb - za) / 0.1));
      for (var i = 0; i <= steps; i++) { var z = za + (zb - za) * i / steps; pts.push([R(z), z]); }
      pts.push([0, zb]);
      return pts;
    }
    var PIN_R = 0.10, SOCK = 0.125, ANG1 = [0.5, 0.5 + TAU / 3, 0.5 + 2 * TAU / 3], ANG2 = ANG1.map(function (a) { return a + TAU / 6; });

    var zs = [Z0].concat(CUTS, [Z1]), pieces = [];
    for (var pi = 0; pi < 3; pi++) {
      var za = zs[pi], zb = zs[pi + 1], k = new Kit(), prof = profile(za, zb), j;
      revolve(k, prof, 0, TAU, 40);
      // the rings: at both ends, and one every quarter
      var level = [za];
      for (var z = Math.ceil((za + 0.01) / 0.25) * 0.25; z < zb - 0.01; z += 0.25) level.push(z);
      level.push(zb);
      level.forEach(function (zz, q) { k.P(q === 0 || q === level.length - 1 ? 'cut' : 'piece', ringZ(R(zz), zz, 0, TAU, 56), true); });
      // sockets and pins
      if (pi === 0) ANG1.forEach(function (a) { cylinderZ(k, 'pins', 0.42 * Math.cos(a), 0.42 * Math.sin(a), zb, zb + 0.24, PIN_R, PIN_R * 0.8, 16); });
      if (pi === 1) {
        ANG1.forEach(function (a) { k.P('pins', ringZ(SOCK, za, 0, TAU, 16).map(function (q) { return [q[0] + 0.42 * Math.cos(a), q[1] + 0.42 * Math.sin(a), q[2]]; }), true); });
        ANG2.forEach(function (a) { k.P('pins', ringZ(SOCK, zb, 0, TAU, 16).map(function (q) { return [q[0] + 0.42 * Math.cos(a), q[1] + 0.42 * Math.sin(a), q[2]]; }), true); });
      }
      if (pi === 2) ANG2.forEach(function (a) { k.P('pins', ringZ(SOCK, za, 0, TAU, 16).map(function (q) { return [q[0] + 0.42 * Math.cos(a), q[1] + 0.42 * Math.sin(a), q[2]]; }), true); });
      pieces.push(k.part('piece' + pi, { prof: prof, dyn: (function (pr) { return function (yaw) { return { piece: silhouette(pr, yaw) }; }; })(prof) }));
    }

    // the loose dowels between the middle and the top piece
    var kd = new Kit();
    ANG2.forEach(function (a) { cylinderZ(kd, 'pins', 0.42 * Math.cos(a), 0.42 * Math.sin(a), CUTS[1] - 0.22, CUTS[1] + 0.22, PIN_R, PIN_R, 16); });
    var dowels = kd.part('dowels');

    // the printer's build volume round the lowest piece
    var kv = new Kit(), bx = 1.22, vz0 = Z0 - 0.04, vz1 = CUTS[0] + 0.45;
    var c8 = [[-bx, -bx, vz0], [bx, -bx, vz0], [bx, bx, vz0], [-bx, bx, vz0], [-bx, -bx, vz1], [bx, -bx, vz1], [bx, bx, vz1], [-bx, bx, vz1]];
    [[0, 1], [1, 2], [2, 3], [3, 0], [4, 5], [5, 6], [6, 7], [7, 4], [0, 4], [1, 5], [2, 6], [3, 7]].forEach(function (e) { kv.L('volume', c8[e[0]], c8[e[1]]); });
    var volume = kv.part('volume');

    var parts = [pieces[0], pieces[1], pieces[2], dowels, volume];
    return {
      parts: parts,
      view: { yaw: -0.7, pitch: 0.3, dist: 12, fov: 12 * 0.255, swing: 0, spin: 0.26 },
      period: 10.5,
      pose: function (t) {
        var s = t < 1.4 ? 0 : t < 3.8 ? ease((t - 1.4) / 2.4) : t < 7.4 ? 1 : t < 9.6 ? 1 - ease((t - 7.4) / 2.2) : 0;
        pieces[0].off = [0, 0, -1.05 * s]; pieces[1].off = [0, 0, 0]; pieces[2].off = [0, 0, 1.05 * s];
        dowels.off = [0, 0, 0.5 * 1.05 * s]; volume.off = [0, 0, -1.05 * s];
      },
      restPose: 0.85,
      level: function (g, focus) {
        var base = { piece: 0.7, cut: 0.7, pins: 1, volume: 0.42 };
        var hot = { printer: ['volume'], cuts: ['piece', 'cut'], connectors: ['pins'], fit: ['pins'] }[focus] || [];
        return hot.indexOf(g) >= 0 ? 1 : (focus ? 0.34 : base[g] === undefined ? 0.5 : base[g]);
      }
    };
  }

  // ================================================================ scene: a hex nut, drawn and then extruded
  // Rebuilt every frame from a few numbers (see state()): how much of the sketch is drawn, the dimensions, the extrude height.
  function modelScene() {
    var ZB = -0.45, HT = 0.9, HR = 0.4, A30 = Math.cos(Math.PI / 6), SIXTH = Math.PI / 3;
    var SKETCH = [0.4, 2.2], CIRCLE = [2.5, 3.3], DIM = [3.5, 4.1], EXTRUDE = [4.5, 6.0];
    var PLAY = EXTRUDE[1], HOLD = 5, RATE = 3, UNDO = PLAY / RATE, GAP = 0.9, CYCLE = PLAY + HOLD + UNDO + GAP;
    function prog(t, r) { return clamp01((t - r[0]) / (r[1] - r[0])); }
    function state(t) {
      return {
        sk: prog(t, SKETCH), ci: prog(t, CIRCLE), dm: ease(prog(t, DIM)), h: HT * ease(prog(t, EXTRUDE)),
        hBot: t < EXTRUDE[0] ? 1 : 1 - ease((t - EXTRUDE[0]) / 0.7),
        hTop: t < EXTRUDE[1] ? 1 : 1 - ease((t - EXTRUDE[1]) / 0.5)
      };
    }
    function hexR(th) {                                   // distance from the centre to the hexagon, along angle th
      th = ((th % TAU) + TAU) % TAU;
      var k = Math.floor(th / SIXTH + 1e-9);
      return A30 / Math.cos(th - (SIXTH / 2 + k * SIXTH));
    }
    function corner(k) { return [Math.cos(k * SIXTH), Math.sin(k * SIXTH)]; }
    var ANGS = [], i;
    for (i = 0; i < 72; i++) ANGS.push(i * TAU / 72);
    for (i = 0; i < 6; i++) ANGS.push(i * SIXTH + 1e-6);
    ANGS.sort(function (a, b) { return a - b; });
    // the floor: a grid in the sketch's plane that fades out toward the edge, in bands so each can have its own strength
    var kf = new Kit(), GR = 2.4, GS = 0.4, BANDS = 6, GAP = 0.12;   // the floor lies a little below the sketch plane, so nothing touches the part
    for (i = -5; i <= 5; i++) {
      for (var q = -GR; q < GR - 1e-6; q += GS) {
        var c = i * GS, mid = q + GS / 2;
        [[c, q, c, q + GS, c, mid], [q, c, q + GS, c, mid, c]].forEach(function (sg) {
          var dist = Math.sqrt(sg[4] * sg[4] + sg[5] * sg[5]);
          if (dist >= GR) return;
          kf.L('grid' + Math.min(BANDS - 1, Math.floor(dist / GR * BANDS)), [sg[0], sg[1], ZB - GAP], [sg[2], sg[3], ZB - GAP]);
        });
      }
    }
    var scene = {
      view: { yaw: -0.75, pitch: 0.5, dist: 8, fov: 8 * 0.47, swing: 0, spin: 0.2 },
      period: CYCLE,
      parts: [kf.part('floor', { width: 0.5 }), {
        name: 'nut', tri: new Float32Array(0), lines: {}, off: [0, 0, 0], dynamicPart: true,
        // the vertical edges, chosen for the viewing angle: an outer corner shows when one of its two sides faces us, a line on the
        // hole's wall only on the far side of the hole (the side we see), and none that are edge-on, so no stubs poke out at the rims
        dyn: function (yaw) {
          var st = this.state, sy = Math.sin(yaw), cy = Math.cos(yaw);
          if (!st || st.h < 0.004) return {};
          var zt = ZB + st.h, out = [], j;
          function facing(ang) { return Math.cos(ang) * sy + Math.sin(ang) * cy; }      // > 0 faces away from the viewer
          for (j = 0; j < 6; j++) {
            var side0 = facing((j - 0.5) * SIXTH), side1 = facing((j + 0.5) * SIXTH), c = corner(j);
            if (Math.min(side0, side1) < -0.02) out.push(c[0], c[1], ZB, c[0], c[1], zt);
          }
          for (j = 0; j < 8; j++) {
            var an = j * TAU / 8 + 0.3;
            if (facing(an) > 0.3) out.push(HR * Math.cos(an), HR * Math.sin(an), ZB, HR * Math.cos(an), HR * Math.sin(an), zt);
          }
          return { ink: out };
        }
      }],
      rest: PLAY + 1,
      update: function (tt) {
        var t = tt < PLAY ? tt : tt < PLAY + HOLD ? PLAY : tt < PLAY + HOLD + UNDO ? PLAY - (tt - PLAY - HOLD) * RATE : 0;
        var s = state(t), k = new Kit(), zt = ZB + s.h, solid = s.h > 0.004, j;
        k.lines.ink = [];      // drawn first: a hidden edge can show a pixel or two at its ends, and the coloured outline then covers it
        function pt(x, y, z) { return [x, y, z]; }
        if (solid) {
          for (j = 0; j < 6; j++) {                       // the six flat sides
            var a = corner(j), b = corner(j + 1);
            k.Q(pt(a[0], a[1], ZB), pt(b[0], b[1], ZB), pt(b[0], b[1], zt), pt(a[0], a[1], zt));
          }
          for (j = 0; j < 48; j++) {                      // the hole's wall
            var u = j * TAU / 48, v = (j + 1) * TAU / 48;
            k.Q(pt(HR * Math.cos(u), HR * Math.sin(u), ZB), pt(HR * Math.cos(v), HR * Math.sin(v), ZB),
                pt(HR * Math.cos(v), HR * Math.sin(v), zt), pt(HR * Math.cos(u), HR * Math.sin(u), zt));
          }
          [ZB, zt].forEach(function (z) {                 // the faces: a ring between the hole and the hexagon
            for (var q = 0; q < ANGS.length; q++) {
              var th0 = ANGS[q], th1 = q + 1 < ANGS.length ? ANGS[q + 1] : TAU + ANGS[0], r0 = hexR(th0 + 1e-7), r1 = hexR(th1 - 1e-7);
              k.Q(pt(HR * Math.cos(th0), HR * Math.sin(th0), z), pt(HR * Math.cos(th1), HR * Math.sin(th1), z),
                  pt(r1 * Math.cos(th1), r1 * Math.sin(th1), z), pt(r0 * Math.cos(th0), r0 * Math.sin(th0), z));
            }
          });
        }
        // the outline, drawn side by side while it is a sketch, and the hole's circle
        function hexPath(z, f) {
          var pts = [], len = f * 6;
          for (var q = 0; q < 6 && len > 0; q++) {
            var m = Math.min(1, len); len -= 1;
            var a = corner(q), b = corner(q + 1);
            if (!pts.length) pts.push(pt(a[0], a[1], z));
            pts.push(pt(a[0] + (b[0] - a[0]) * m, a[1] + (b[1] - a[1]) * m, z));
          }
          return pts;
        }
        function circlePath(z, f) {
          var pts = [], n = Math.max(0, Math.floor(f * 64));
          for (var q = 0; q <= n; q++) pts.push(pt(HR * Math.cos(q * TAU / 64 + 0.3), HR * Math.sin(q * TAU / 64 + 0.3), z));
          return pts;
        }
        if (!solid) { k.P('bot', hexPath(ZB, s.sk), false); k.P('bot', circlePath(ZB, s.ci), false); }
        else {
          k.P('bot', hexPath(ZB, 1), true); k.P('bot', circlePath(ZB, 1), true);
          k.P('top', hexPath(zt, 1), true); k.P('top', circlePath(zt, 1), true);
        }
        // the dimensions: the width across the corners, then the height
        if (s.dm > 0.001) {
          var y0 = -1.35, d = s.dm, e = d * 1.0;
          k.L('dim', pt(-e, y0, ZB), pt(e, y0, ZB));
          k.L('dim', pt(-1, 0, ZB), pt(-1, y0 - 0.08, ZB)); k.L('dim', pt(1, 0, ZB), pt(1, y0 - 0.08, ZB));
          k.L('dim', pt(-e, y0 - 0.07, ZB), pt(-e, y0 + 0.07, ZB)); k.L('dim', pt(e, y0 - 0.07, ZB), pt(e, y0 + 0.07, ZB));
        }
        if (solid) {
          var x0 = 1.5;
          k.L('dim', pt(x0, 0, ZB), pt(x0, 0, zt));
          k.L('dim', pt(1.02, 0, ZB), pt(x0 + 0.08, 0, ZB)); k.L('dim', pt(1.02, 0, zt), pt(x0 + 0.08, 0, zt));
          k.L('dim', pt(x0, -0.07, ZB), pt(x0, 0.07, ZB)); k.L('dim', pt(x0, -0.07, zt), pt(x0, 0.07, zt));
        }
        var np = k.part('nut');
        var part = scene.parts[1];
        part.tri = np.tri; part.lines = np.lines; part.state = s; part.dirty = true;
      },
      cap: function (g) { return g === 'ink' ? 0 : 1; },    // the vertical edges end at a corner of the outline
      colour: function (g, focus, P, part) {
        if (g.indexOf('grid') === 0) return P.mix(P.BG, P.INK, 0.22 * Math.pow(1 - +g.slice(4) / BANDS, 1.4));
        var s = (part && part.state) || { hBot: 1, hTop: 1 };
        var natural = g === 'bot' ? P.mix(P.INK, P.ACC, s.hBot) : g === 'top' ? P.mix(P.INK, P.ACC, s.hTop) : g === 'dim' ? P.ACC : P.INK;
        var hot = { sketch: ['bot'], dims: ['dim'], extrude: ['top', 'ink', 'bot'] }[focus];
        if (!focus || !hot || hot.indexOf(g) >= 0) return natural;
        return P.mix(P.BG, natural, 0.3);
      }
    };
    return scene;
  }

  var SCENES = { mold: moldScene, split: splitScene, model: modelScene };

  // ================================================================ the renderer
  function run(canvas) {
    var make = SCENES[canvas.getAttribute('data-scene')];
    var gl = make && canvas.getContext('webgl', { antialias: true, alpha: true, premultipliedAlpha: true });
    if (!gl) { canvas.style.display = 'none'; return; }
    var scene = make(), parts = scene.parts, view = scene.view;
    var reduced = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    var LINE_PX = 1.5;

    function readColor(name, fallback) {
      var hex = (getComputedStyle(document.documentElement).getPropertyValue(name) || '').trim();
      return /^#([0-9a-f]{6})$/i.test(hex) ? [1, 3, 5].map(function (i) { return parseInt(hex.substr(i, 2), 16) / 255; }) : fallback;
    }
    var light = canvas.getAttribute('data-theme') === 'light';
    var BG = readColor(light ? '--paper' : '--dark', light ? [0.95, 0.94, 0.92] : [0.04, 0.05, 0.06]);
    var ACC = readColor('--accent', [0.92, 0.34, 0.16]), INK = readColor('--ink', [0.04, 0.04, 0.045]);
    function mix(a, b, f) { return [a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f]; }
    var PAL = { BG: BG, ACC: ACC, INK: INK, mix: mix };
    function colour(level) { return mix(BG, ACC, level); }
    function colourOf(part, g) { return scene.colour ? scene.colour(g, focus, PAL, part) : colour(scene.level(g, focus)); }

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
    var depthProg, lineProg, shadeProg, floorProg;
    try {
      depthProg = program(
        'attribute vec3 p; uniform mat4 m; uniform vec3 off; void main() { gl_Position = m * vec4(p + off, 1.0); }',
        'precision mediump float; void main() { gl_FragColor = vec4(0.0); }');
      lineProg = program(
        'attribute vec3 pa; attribute vec3 pb; attribute vec3 k; attribute vec3 col;\n' +
        'uniform mat4 m; uniform vec3 off; uniform vec2 res; uniform float half_w; varying vec3 vc;\n' +
        'void main() {\n' +
        '  vec4 A = m * vec4(pa + off, 1.0); vec4 B = m * vec4(pb + off, 1.0);\n' +
        '  vec2 a = A.xy / A.w * res * 0.5; vec2 b = B.xy / B.w * res * 0.5;\n' +
        '  vec2 d = b - a; float len = length(d); d = len > 0.0001 ? d / len : vec2(1.0, 0.0);\n' +
        '  vec2 n = vec2(-d.y, d.x);\n' +
        '  vec4 P = mix(A, B, k.x);\n' +
        '  vec2 o = n * k.y * half_w + d * (k.x * 2.0 - 1.0) * half_w * k.z;\n' +
        '  P.xy += o / (res * 0.5) * P.w;\n' +
        '  P.z -= 0.00012 * P.w;\n' +
        '  gl_Position = P; vc = col;\n' +
        '}',
        'precision mediump float; varying vec3 vc; uniform float la; void main() { gl_FragColor = vec4(vc * la, la); }');
      // the lit surface: a soft key light, a sky-and-ground term, a highlight and a touch of rim; normals are turned into view space here
      shadeProg = program(
        'attribute vec3 p; attribute vec3 n; uniform mat4 m; uniform vec3 off; uniform vec3 r0; uniform vec3 r1; uniform vec3 r2; varying vec3 vn;\n' +
        'void main() { gl_Position = m * vec4(p + off, 1.0); vn = vec3(dot(r0, n), dot(r1, n), dot(r2, n)); }',
        'precision mediump float; varying vec3 vn; uniform vec3 base; uniform vec3 light; uniform vec3 up; uniform float spec; uniform float shin; uniform float fill;\n' +
        'void main() {\n' +
        '  vec3 N = normalize(vn); vec3 L = normalize(light); vec3 V = vec3(0.0, 0.0, -1.0);\n' +
        '  float d = max(dot(N, L), 0.0); float hemi = 0.5 + 0.5 * dot(N, up);\n' +
        '  float s = pow(max(dot(N, normalize(L + V)), 0.0), shin) * spec;\n' +
        '  float fres = pow(1.0 - max(dot(N, V), 0.0), 3.0);\n' +
        '  vec3 c = base * (0.28 + 0.24 * hemi + 0.62 * d) + vec3(s) + vec3(fres * 0.09);\n' +
        '  gl_FragColor = vec4(min(c, vec3(1.0)) * fill, fill);\n' +
        '}');
      // flat coloured triangles with their own premultiplied colour, for the floor and its shadows
      floorProg = program(
        'attribute vec3 p; attribute vec4 c; uniform mat4 m; varying vec4 vc; void main() { gl_Position = m * vec4(p, 1.0); vc = c; }',
        'precision mediump float; varying vec4 vc; void main() { gl_FragColor = vc; }');
    } catch (e) { canvas.style.display = 'none'; return; }
    var uDm = gl.getUniformLocation(depthProg, 'm'), uDoff = gl.getUniformLocation(depthProg, 'off'), aDp = gl.getAttribLocation(depthProg, 'p');
    var uLa = gl.getUniformLocation(lineProg, 'la');
    var uSm = gl.getUniformLocation(shadeProg, 'm'), uSoff = gl.getUniformLocation(shadeProg, 'off'), uSr0 = gl.getUniformLocation(shadeProg, 'r0'), uSr1 = gl.getUniformLocation(shadeProg, 'r1'), uSr2 = gl.getUniformLocation(shadeProg, 'r2');
    var uSbase = gl.getUniformLocation(shadeProg, 'base'), uSlight = gl.getUniformLocation(shadeProg, 'light'), uSup = gl.getUniformLocation(shadeProg, 'up'), uSspec = gl.getUniformLocation(shadeProg, 'spec'), uSshin = gl.getUniformLocation(shadeProg, 'shin'), uSfill = gl.getUniformLocation(shadeProg, 'fill');
    var aSp = gl.getAttribLocation(shadeProg, 'p'), aSn = gl.getAttribLocation(shadeProg, 'n');
    var uFm = gl.getUniformLocation(floorProg, 'm'), aFp = gl.getAttribLocation(floorProg, 'p'), aFc = gl.getAttribLocation(floorProg, 'c'), floorBuf = gl.createBuffer(), floorCount = 0;
    var uLm = gl.getUniformLocation(lineProg, 'm'), uLoff = gl.getUniformLocation(lineProg, 'off'), uRes = gl.getUniformLocation(lineProg, 'res'), uHalf = gl.getUniformLocation(lineProg, 'half_w');
    var aPa = gl.getAttribLocation(lineProg, 'pa'), aPb = gl.getAttribLocation(lineProg, 'pb'), aK = gl.getAttribLocation(lineProg, 'k'), aCol = gl.getAttribLocation(lineProg, 'col');

    // ---- buffers ----
    var CORNER = [[0, -1], [0, 1], [1, -1], [1, -1], [0, 1], [1, 1]];
    // [x0 y0 z0 x1 y1 z1 ...] -> six vertices of 12 floats per segment. `cap` is how far the stroke reaches past each end, in half widths:
    // 1 closes the joints of a curve; 0 is for a straight edge that ends at a corner, where a longer stroke would poke out beside it.
    function segments(list, col, cap) {
      var out = new Float32Array(list.length / 6 * 72), o = 0;
      for (var i = 0; i < list.length; i += 6) for (var c = 0; c < 6; c++) {
        out[o++] = list[i]; out[o++] = list[i + 1]; out[o++] = list[i + 2]; out[o++] = list[i + 3]; out[o++] = list[i + 4]; out[o++] = list[i + 5];
        out[o++] = CORNER[c][0]; out[o++] = CORNER[c][1]; out[o++] = cap; out[o++] = col[0]; out[o++] = col[1]; out[o++] = col[2];
      }
      return out;
    }
    function capOf(g) { return scene.cap ? scene.cap(g) : 1; }
    var focus = '';
    parts.forEach(function (p) { p.triBuf = gl.createBuffer(); p.lineBuf = gl.createBuffer(); p.dynBuf = gl.createBuffer(); p.dynCount = 0; p.lineCount = 0; });
    function uploadTris(p) { gl.bindBuffer(gl.ARRAY_BUFFER, p.triBuf); gl.bufferData(gl.ARRAY_BUFFER, p.tri, p.dynamicPart ? gl.DYNAMIC_DRAW : gl.STATIC_DRAW); }
    function refresh() { parts.forEach(function (p) { if (p.dirty) { uploadTris(p); p.dirty = false; } }); colourise(true); }
    function colourise(dynamicOnly) {
      parts.forEach(function (p) {
        if (dynamicOnly && !p.dynamicPart) return;
        var chunks = [], n = 0;
        for (var g in p.lines) { var s = segments(p.lines[g], colourOf(p, g), capOf(g)); chunks.push(s); n += s.length; }
        var all = new Float32Array(n), o = 0;
        chunks.forEach(function (c) { all.set(c, o); o += c.length; });
        p.lineCount = n / 12;
        gl.bindBuffer(gl.ARRAY_BUFFER, p.lineBuf); gl.bufferData(gl.ARRAY_BUFFER, all, gl.STATIC_DRAW);
      });
    }
    function silhouettes(yaw) {
      parts.forEach(function (p) {
        if (!p.dyn) return;
        var d = p.dyn(yaw), chunks = [], n = 0;
        for (var g in d) { var s = segments(d[g], colourOf(p, g), capOf(g)); chunks.push(s); n += s.length; }
        var all = new Float32Array(n), o = 0;
        chunks.forEach(function (c) { all.set(c, o); o += c.length; });
        p.dynCount = n / 12;
        gl.bindBuffer(gl.ARRAY_BUFFER, p.dynBuf); gl.bufferData(gl.ARRAY_BUFFER, all, gl.DYNAMIC_DRAW);
      });
    }

    // ---- state ----
    var yaw = view.yaw, pitch = view.pitch, vYaw = 0, vPitch = 0, dragging = false, lastX = 0, lastY = 0, lastT = 0;
    var clock = 0, idleT = 0, inView = false, tabShown = true, visible = false, raf = 0, prev = 0, W = 1, H = 1, dpr = 1;
    var NEAR = 1, FAR = 40;

    function resize() {
      var r = canvas.getBoundingClientRect();
      dpr = Math.min(window.devicePixelRatio || 1, 2);
      W = Math.max(1, Math.round(r.width * dpr)); H = Math.max(1, Math.round(r.height * dpr));
      canvas.width = W; canvas.height = H;
      gl.viewport(0, 0, W, H);
      draw();
    }
    function matrix() {
      var cy = Math.cos(yaw), sy = Math.sin(yaw), cp = Math.cos(pitch), sp = Math.sin(pitch), DIST = view.dist, FOV = view.fov;
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
    // ---- the floor and its shadows, rebuilt every frame (the light moves): radial blobs lying on the floor plane ----
    var S = null;                              // what the scene wants this frame: fill, light, material, floor strength
    function blob(out, cx, cy, z, r, rgb, a0, power) {
      var RINGS = 7, SEGS = 40, i, j;
      function v(rad, ang, k) {
        var a = a0 * Math.pow(1 - rad / r, power);
        out.push(cx + rad * Math.cos(ang), cy + rad * Math.sin(ang), z, rgb[0] * a, rgb[1] * a, rgb[2] * a, a);
      }
      for (j = 0; j < SEGS; j++) {
        var u = j * TAU / SEGS, w = (j + 1) * TAU / SEGS;
        for (i = 0; i < RINGS; i++) {
          var r0 = r * i / RINGS, r1 = r * (i + 1) / RINGS;
          v(r0, u); v(r0, w); v(r1, w);
          v(r0, u); v(r1, w); v(r1, u);
        }
      }
    }
    function drawFloor(m, lw) {
      var f = scene.floor, out = [], a = S.floorAmt;
      if (a <= 0.003) return;
      var s = S.shadowAmt, ox = -lw[0] / Math.max(lw[2], 0.35) * 0.8, oy = -lw[1] / Math.max(lw[2], 0.35) * 0.8;
      blob(out, 0, 0, f.z, f.radius, mix(BG, INK, 0.5), 0.2 * a, 1.3);                       // the pool of floor
      blob(out, ox, oy, f.z, 1.7, INK, Math.min(0.9, 0.2 * s), 1.4);                          // the cast shadow, away from the light
      blob(out, 0, 0, f.z, 0.95, INK, Math.min(0.9, 0.34 * s), 1.2);                          // the dark under the base
      gl.useProgram(floorProg);
      gl.uniformMatrix4fv(uFm, false, m);
      gl.bindBuffer(gl.ARRAY_BUFFER, floorBuf);
      gl.bufferData(gl.ARRAY_BUFFER, new Float32Array(out), gl.DYNAMIC_DRAW);
      gl.enableVertexAttribArray(aFp); gl.enableVertexAttribArray(aFc);
      gl.vertexAttribPointer(aFp, 3, gl.FLOAT, false, 28, 0); gl.vertexAttribPointer(aFc, 4, gl.FLOAT, false, 28, 12);
      gl.disable(gl.DEPTH_TEST); gl.depthMask(false);
      gl.drawArrays(gl.TRIANGLES, 0, out.length / 7);
      gl.depthMask(true); gl.enable(gl.DEPTH_TEST);
      gl.disableVertexAttribArray(aFp); gl.disableVertexAttribArray(aFc);
    }
    function draw() {
      var m = matrix();
      gl.clearColor(0, 0, 0, 0); gl.clearDepth(1);
      gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
      gl.enable(gl.DEPTH_TEST); gl.depthFunc(gl.LEQUAL);

      gl.enable(gl.BLEND); gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
      var cy = Math.cos(yaw), sy = Math.sin(yaw), cp = Math.cos(pitch), sp = Math.sin(pitch);
      if (S) {
        var L = S.light, lw = [L[0] * cy + L[1] * sp * sy + L[2] * cp * sy, -L[0] * sy + L[1] * sp * cy + L[2] * cp * cy, L[1] * cp - L[2] * sp];
        drawFloor(m, lw);
        // the surfaces, lit; they write the depth the edges are tested against, as the depth-only pass does for the wireframes
        gl.useProgram(shadeProg);
        gl.uniformMatrix4fv(uSm, false, m);
        gl.uniform3f(uSr0, cy, -sy, 0); gl.uniform3f(uSr1, sp * sy, sp * cy, cp); gl.uniform3f(uSr2, cp * sy, cp * cy, -sp);
        gl.uniform3f(uSbase, S.base[0], S.base[1], S.base[2]); gl.uniform3f(uSlight, L[0], L[1], L[2]); gl.uniform3f(uSup, 0, cp, -sp);
        gl.uniform1f(uSspec, S.spec); gl.uniform1f(uSshin, S.shin); gl.uniform1f(uSfill, S.fill);
        gl.enable(gl.POLYGON_OFFSET_FILL); gl.polygonOffset(1, 1);
        gl.enableVertexAttribArray(aSp); gl.enableVertexAttribArray(aSn);
        parts.forEach(function (p) {
          if (!p.tri.length) return;
          gl.uniform3f(uSoff, p.off[0], p.off[1], p.off[2]);
          gl.bindBuffer(gl.ARRAY_BUFFER, p.triBuf);
          gl.vertexAttribPointer(aSp, 3, gl.FLOAT, false, 24, 0); gl.vertexAttribPointer(aSn, 3, gl.FLOAT, false, 24, 12);
          gl.drawArrays(gl.TRIANGLES, 0, p.tri.length / 6);
        });
        gl.disableVertexAttribArray(aSp); gl.disableVertexAttribArray(aSn);
        gl.disable(gl.POLYGON_OFFSET_FILL);
      } else {
        gl.useProgram(depthProg);
        gl.uniformMatrix4fv(uDm, false, m);
        gl.colorMask(false, false, false, false);
        gl.enable(gl.POLYGON_OFFSET_FILL); gl.polygonOffset(1, 1);
        gl.enableVertexAttribArray(aDp);
        parts.forEach(function (p) {
          if (!p.tri.length) return;
          gl.uniform3f(uDoff, p.off[0], p.off[1], p.off[2]);
          gl.bindBuffer(gl.ARRAY_BUFFER, p.triBuf);
          gl.vertexAttribPointer(aDp, 3, gl.FLOAT, false, 24, 0);
          gl.drawArrays(gl.TRIANGLES, 0, p.tri.length / 6);
        });
        gl.disableVertexAttribArray(aDp);
        gl.disable(gl.POLYGON_OFFSET_FILL);
        gl.colorMask(true, true, true, true);
      }

      gl.useProgram(lineProg);
      gl.uniformMatrix4fv(uLm, false, m);
      gl.uniform2f(uRes, W, H);
      gl.uniform1f(uLa, S ? S.lineAlpha : 1);
      [aPa, aPb, aK, aCol].forEach(function (a) { gl.enableVertexAttribArray(a); });
      parts.forEach(function (p) {
        gl.uniform3f(uLoff, p.off[0], p.off[1], p.off[2]);
        gl.uniform1f(uHalf, LINE_PX * dpr * 0.5 * (p.width || 1));
        [[p.dynBuf, p.dynCount], [p.lineBuf, p.lineCount]].forEach(function (b) {
          if (!b[1]) return;
          gl.bindBuffer(gl.ARRAY_BUFFER, b[0]);
          gl.vertexAttribPointer(aPa, 3, gl.FLOAT, false, 48, 0);
          gl.vertexAttribPointer(aPb, 3, gl.FLOAT, false, 48, 12);
          gl.vertexAttribPointer(aK, 3, gl.FLOAT, false, 48, 24);
          gl.vertexAttribPointer(aCol, 3, gl.FLOAT, false, 48, 36);
          gl.drawArrays(gl.TRIANGLES, 0, b[1]);
        });
      });
      [aPa, aPb, aK, aCol].forEach(function (a) { gl.disableVertexAttribArray(a); });
    }

    function clampPitch(v) { return Math.max(-1.2, Math.min(1.2, v)); }
    function frame(t) {
      raf = 0;
      var dt = prev ? Math.min(0.05, (t - prev) / 1000) : 0.016;
      prev = t;
      if (!reduced) { clock += dt; var tt = clock % scene.period; if (scene.pose) scene.pose(tt); if (scene.update) { scene.update(tt); refresh(); } if (scene.tick) S = scene.tick(tt, focus, dt, PAL); }
      if (!dragging) {
        var k = Math.pow(0.04, dt);
        idleT += dt;
        var yawTarget = 0, pitchTarget = 0;
        if (!reduced) {
          if (view.swing) {      // a slow sway, so the open faces stay in view
            yawTarget = view.swing * 0.42 * Math.cos(0.42 * idleT);
          } else yawTarget = view.spin * (1 + 0.3 * Math.sin(0.43 * idleT));
          pitchTarget = 0.035 * Math.cos(0.31 * idleT) + 0.1 * (view.pitch - pitch);
        }
        vYaw = yawTarget + (vYaw - yawTarget) * k;
        vPitch = pitchTarget + (vPitch - pitchTarget) * k;
        yaw += vYaw * dt;
        pitch = clampPitch(pitch + vPitch * dt);
      }
      silhouettes(yaw);
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
      vYaw = dx * 0.011 / dt; vPitch = dy * 0.011 / dt;
      lastX = e.clientX; lastY = e.clientY; lastT = e.timeStamp;
      silhouettes(yaw); draw();
    });
    function release() { dragging = false; canvas.classList.remove('grabbing'); wake(); }
    canvas.addEventListener('pointerup', release);
    canvas.addEventListener('pointercancel', release);
    canvas.addEventListener('keydown', function (e) {
      var step = { ArrowLeft: [-0.2, 0], ArrowRight: [0.2, 0], ArrowUp: [0, -0.2], ArrowDown: [0, 0.2] }[e.key];
      if (!step) return;
      e.preventDefault(); yaw += step[0]; pitch = clampPitch(pitch + step[1]); silhouettes(yaw); draw();
    });
    canvas.addEventListener('wirefocus', function (e) { focus = e.detail || ''; colourise(); silhouettes(yaw); draw(); wake(); });
    canvas.addEventListener('webglcontextlost', function (e) { e.preventDefault(); canvas.style.visibility = 'hidden'; });

    if ('ResizeObserver' in window) new ResizeObserver(resize).observe(canvas); else window.addEventListener('resize', resize);
    if ('IntersectionObserver' in window) {
      new IntersectionObserver(function (entries) {
        inView = entries[0].isIntersecting; visible = inView && tabShown;
        if (visible) wake();
      }).observe(canvas);
    } else { inView = true; visible = true; }
    document.addEventListener('visibilitychange', function () { tabShown = !document.hidden; visible = inView && tabShown; if (visible) wake(); });

    if (scene.pose) scene.pose(reduced ? scene.period * 0.5 : 0);
    if (scene.update) scene.update(reduced ? scene.rest : 0);
    if (scene.tick) S = scene.tick(reduced ? scene.rest : 0, focus, 0, PAL);
    parts.forEach(uploadTris); parts.forEach(function (p) { p.dirty = false; }); colourise(); silhouettes(yaw);
    resize();
    if (!reduced && !('IntersectionObserver' in window)) wake();
  }

  Array.prototype.forEach.call(canvases, run);

  // ---------------------------------------------------------------- the accordions beside the canvases
  // <div class="wire-list" data-for="id of the canvas"> <details data-focus="gate" open>…</details> … </div>
  // One item open at a time; opening one tells the canvas what to light up. Two things keep the page still while you click:
  // the swap (close the old item, open the new one) happens in one go, so no frame ever has two items open, and the list
  // keeps the height of its tallest state, so the heading, the model and everything below stay where they are.
  Array.prototype.forEach.call(document.querySelectorAll('.wire-list'), function (list) {
    var canvas = document.getElementById(list.getAttribute('data-for'));
    var items = Array.prototype.slice.call(list.querySelectorAll('details'));
    function tell(d) { if (canvas) canvas.dispatchEvent(new CustomEvent('wirefocus', { detail: d ? d.getAttribute('data-focus') : '' })); }
    items.forEach(function (d) {
      var summary = d.querySelector('summary');
      summary.addEventListener('click', function (e) {
        e.preventDefault();
        if (d.open) { d.open = false; tell(null); return; }
        items.forEach(function (o) { o.open = (o === d); });
        tell(d);
      });
    });

    // The height of the list with each item open in turn, measured on an invisible copy; the tallest is kept as the minimum.
    function reserve() {
      var copy = list.cloneNode(true), tallest = 0;
      copy.removeAttribute('id'); copy.style.cssText = 'position:absolute;left:0;right:0;visibility:hidden;pointer-events:none;min-height:0';
      list.parentNode.style.position = list.parentNode.style.position || 'relative';
      list.parentNode.appendChild(copy);
      var rows = copy.querySelectorAll('details');
      Array.prototype.forEach.call(rows, function (open) {
        Array.prototype.forEach.call(rows, function (o) { o.open = (o === open); });
        tallest = Math.max(tallest, Math.ceil(copy.getBoundingClientRect().height));
      });
      list.parentNode.removeChild(copy);
      if (tallest) list.style.minHeight = tallest + 'px';
    }
    reserve();
    if (document.fonts && document.fonts.ready) document.fonts.ready.then(reserve);
    var pending = 0, width = list.offsetWidth;
    window.addEventListener('resize', function () {
      if (list.offsetWidth === width) return;
      width = list.offsetWidth; clearTimeout(pending);
      list.style.minHeight = ''; pending = setTimeout(reserve, 120);
    });
  });
})();
