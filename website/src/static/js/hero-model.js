// SimplMaker site: the wireframe in the home-page hero, built step by step as you watch. No dependencies.
//
// It replays the way a part is made in the app: sketch a square, extrude it into a cube, fillet the four vertical
// edges, then cut a hole down through the top and a second one through the front. Sketch lines and the feature being
// edited are drawn in the accent colour, then settle to ink. After a pause the steps are undone, faster, and it starts
// over. (With "reduce motion" it shows the finished part and nothing else.)
//
// The part is regenerated every frame from a handful of numbers (state()): the extrude height, the fillet radius and
// the two hole depths. Units are 10 mm, centred on the part, Z up. build() turns those numbers into
//   - a triangle mesh of the solid, used only to hide the lines behind it: the faces are drawn into the depth buffer
//     with no colour, then the edges are drawn against that depth; and
//   - the edge curves, as short segments. Segments that fall inside a hole are dropped, so the lines of one hole
//     disappear where the other one cuts through it.
// Hidden on small screens (CSS hides the canvas, and nothing below runs until the screen is wide enough).
(function () {
  'use strict';
  var canvas = document.querySelector('canvas.hero-model');
  if (!canvas) return;
  var wide = window.matchMedia('(min-width: 861px)');

  var LINE_PX = 1.15;   // stroke width in CSS pixels

  // ---- the part ----
  var TAU = Math.PI * 2;
  var N = 192;                    // samples round every outline; the same angles are used for the cube, the holes and the faces between
  var R_FILLET = 0.28, R_TOP = 0.55, R_FRONT = 0.42;     // fillet radius; radius of the hole down from the top; of the hole in from the front
  var ANG = [];
  for (var i = 0; i < N; i++) ANG.push(i * TAU / N);

  // The timeline, in seconds. Each step is [start, end]; the part holds still for a beat between steps.
  var SKETCH = [0.3, 1.5], EXTRUDE = [1.9, 3.2], PICK = [3.9, 4.3], FILLET = [4.3, 5.6], UNPICK = [5.6, 6.1];
  var CIRC_TOP = [6.2, 6.9], CUT_TOP = [7.2, 8.4], CIRC_FRONT = [8.8, 9.5], CUT_FRONT = [9.8, 11.0];
  var PLAY = CUT_FRONT[1], HOLD = 5.5, RATE = 3, UNDO = PLAY / RATE, GAP = 0.9, CYCLE = PLAY + HOLD + UNDO + GAP;

  function clamp01(x) { return x < 0 ? 0 : x > 1 ? 1 : x; }
  function ease(x) { x = clamp01(x); return x * x * (3 - 2 * x); }
  function prog(t, s) { return clamp01((t - s[0]) / (s[1] - s[0])); }

  // The numbers that describe the part at time t. h* are how much of the accent colour a line still has.
  function state(t) {
    var cut = prog(t, CUT_TOP);
    return {
      sk: prog(t, SKETCH),                                  // how much of the sketch square is drawn
      zt: -1 + 2 * ease(prog(t, EXTRUDE)),                  // top of the cube
      r: R_FILLET * ease(prog(t, FILLET)),                  // fillet radius
      cpA: prog(t, CIRC_TOP), cpB: prog(t, CIRC_FRONT),     // how much of each hole's sketch circle is drawn
      dA: 2 * ease(cut), dB: 2 * ease(prog(t, CUT_FRONT)),  // hole depths; 2 is all the way through
      hBot: t < EXTRUDE[0] ? 1 : 1 - ease((t - EXTRUDE[0]) / 0.7),
      hTop: t < EXTRUDE[1] ? 1 : 1 - ease((t - EXTRUDE[1]) / 0.5),
      hSeam: ease(prog(t, PICK)) * (1 - ease(prog(t, UNPICK))),
      hA: t < CUT_TOP[0] ? 1 : 1 - ease((t - CUT_TOP[0]) / 0.4),
      hB: t < CUT_FRONT[0] ? 1 : 1 - ease((t - CUT_FRONT[0]) / 0.4)
    };
  }

  // A point on the outline of the square, rounded at the corners by r, where the ray from the centre at angle th meets it.
  function outline(th, r) {
    var c = Math.cos(th), s = Math.sin(th);
    var t = 1 / Math.max(Math.abs(c), Math.abs(s));
    var x = c * t, y = s * t;
    if (r > 0.005 && Math.abs(x) > 1 - r && Math.abs(y) > 1 - r) {
      var cx = (x > 0 ? 1 : -1) * (1 - r), cy = (y > 0 ? 1 : -1) * (1 - r);
      var b = c * cx + s * cy, d = b * b - (cx * cx + cy * cy - r * r);
      if (d >= 0) { t = b + Math.sqrt(d); x = c * t; y = s * t; }
    }
    return [x, y];
  }

  // The front and back faces once the fillet is done: a rectangle, half as wide as the cube is left flat, with a hole in it.
  // The angles include the rectangle's four corners so they are not cut off.
  var FLAT = 1 - R_FILLET, RECT = [], RECT_ANG;
  (function () {
    var a = ANG.slice(), k = Math.atan2(1, FLAT);
    a.push(k, Math.PI - k, Math.PI + k, TAU - k);
    a.sort(function (p, q) { return p - q; });
    RECT_ANG = a;
    a.forEach(function (th) {
      var c = Math.cos(th), s = Math.sin(th);
      var t = Math.min(Math.abs(c) < 1e-9 ? 1e9 : FLAT / Math.abs(c), Math.abs(s) < 1e-9 ? 1e9 : 1 / Math.abs(s));
      RECT.push([c * t, s * t]);
    });
  })();

  var INK = [0.04, 0.04, 0.045], ACCENT = [0.92, 0.34, 0.16];

  function build(s) {
    var tri = [], seg = [];
    var r = s.r, zb = -1, zt = s.zt, zA = 1 - s.dA, yB = -1 + s.dB;
    var solid = zt - zb > 0.004;

    // Is a point inside the empty part of a hole?
    function inA(x, y, z) { return s.dA > 0 && x * x + y * y < R_TOP * R_TOP - 1e-3 && z > zA + 1e-4 && z < 1 - 1e-4; }
    function inB(x, y, z) { return s.dB > 0 && x * x + z * z < R_FRONT * R_FRONT - 1e-3 && y > -1 + 1e-4 && y < yB - 1e-4; }

    function T(a, b, c) { tri.push(a[0], a[1], a[2], b[0], b[1], b[2], c[0], c[1], c[2]); }
    function quad(a, b, c, d) { T(a, b, c); T(a, c, d); }

    // ---- the solid ----
    var O = ANG.map(function (th) { return outline(th, r); });
    function pt(k, z) { var p = O[k % N]; return [p[0], p[1], z]; }
    if (solid) {
      for (var k = 0; k < N; k++) {                      // the side walls; the front and back ones are replaced below once a hole goes through them
        var my = (O[k][1] + O[(k + 1) % N][1]) / 2;
        if (Math.abs(my) > 0.9999 && ((my < 0 && s.dB > 0) || (my > 0 && s.dB >= 2))) continue;
        quad(pt(k, zb), pt(k + 1, zb), pt(k + 1, zt), pt(k, zt));
      }
      [[zt, s.dA > 0], [zb, s.dA >= 2]].forEach(function (f) {      // top and bottom, with the hole when there is one
        var z = f[0];
        for (var k = 0; k < N; k++) {
          if (f[1]) {
            var a = ANG[k], b = ANG[(k + 1) % N];
            quad(pt(k, z), pt(k + 1, z), [R_TOP * Math.cos(b), R_TOP * Math.sin(b), z], [R_TOP * Math.cos(a), R_TOP * Math.sin(a), z]);
          } else T([0, 0, z], pt(k, z), pt(k + 1, z));
        }
      });
    }
    // a round hole: its wall (from p0 to p1 along the axis) and, if it stops short, its floor
    function hole(R, at, skip, len, through) {
      var M = 20, step = 2;
      for (var k = 0; k < N; k += step) {
        var a = ANG[k], b = k + step >= N ? TAU : ANG[k + step], m = (a + b) / 2;
        for (var j = 0; j < M; j++) {
          var u0 = len * j / M, u1 = len * (j + 1) / M;
          if (skip(at(R, m, (u0 + u1) / 2))) continue;
          quad(at(R, a, u0), at(R, b, u0), at(R, b, u1), at(R, a, u1));
        }
      }
      if (through) return;
      var RINGS = 4;
      for (var k = 0; k < N; k += step) {
        var a = ANG[k], b = k + step >= N ? TAU : ANG[k + step], m = (a + b) / 2;
        for (var j = 0; j < RINGS; j++) {
          var r0 = R * j / RINGS, r1 = R * (j + 1) / RINGS;
          if (skip(at((r0 + r1) / 2, m, len))) continue;
          quad(at(r0, a, len), at(r0, b, len), at(r1, b, len), at(r1, a, len));
        }
      }
    }
    // the hole down from the top: u runs from the top face (z = 1) downward
    function atA(R, th, u) { return [R * Math.cos(th), R * Math.sin(th), 1 - u]; }
    function skipA(p) { return inB(p[0], p[1], p[2]); }
    // the hole in from the front: u runs from the front face (y = -1) toward the back
    function atB(R, th, u) { return [R * Math.cos(th), -1 + u, R * Math.sin(th)]; }
    function skipB(p) { return inA(p[0], p[1], p[2]); }
    if (solid && s.dA > 0) hole(R_TOP, atA, skipA, s.dA, s.dA >= 2);
    if (solid && s.dB > 0) {
      hole(R_FRONT, atB, skipB, s.dB, s.dB >= 2);
      [-1, 1].forEach(function (y) {
        if (y > 0 && s.dB < 2) return;
        for (var k = 0; k < RECT_ANG.length; k++) {
          var l = (k + 1) % RECT_ANG.length, a = RECT_ANG[k], b = RECT_ANG[l];
          quad([RECT[k][0], y, RECT[k][1]], [RECT[l][0], y, RECT[l][1]],
               [R_FRONT * Math.cos(b), y, R_FRONT * Math.sin(b)], [R_FRONT * Math.cos(a), y, R_FRONT * Math.sin(a)]);
        }
      });
    }

    // ---- the edges ----
    function mix(h) { return [INK[0] + (ACCENT[0] - INK[0]) * h, INK[1] + (ACCENT[1] - INK[1]) * h, INK[2] + (ACCENT[2] - INK[2]) * h]; }
    var CORNER = [[0, -1], [0, 1], [1, -1], [1, -1], [0, 1], [1, 1]];
    function addSeg(a, b, col) {
      var dx = b[0] - a[0], dy = b[1] - a[1], dz = b[2] - a[2];
      var n = Math.max(1, Math.ceil(Math.sqrt(dx * dx + dy * dy + dz * dz) / 0.1));
      for (var j = 0; j < n; j++) {
        var f0 = j / n, f1 = (j + 1) / n, fm = (f0 + f1) / 2;
        if (inA(a[0] + dx * fm, a[1] + dy * fm, a[2] + dz * fm) || inB(a[0] + dx * fm, a[1] + dy * fm, a[2] + dz * fm)) continue;
        CORNER.forEach(function (c) {
          seg.push(a[0] + dx * f0, a[1] + dy * f0, a[2] + dz * f0, a[0] + dx * f1, a[1] + dy * f1, a[2] + dz * f1, c[0], c[1], col[0], col[1], col[2]);
        });
      }
    }
    function poly(pts, col, closed) {
      for (var i = 0, n = closed ? pts.length : pts.length - 1; i < n; i++) addSeg(pts[i], pts[(i + 1) % pts.length], col);
    }
    function ring(R, at, u, col, upTo) {
      var pts = [], n = upTo === undefined ? N : Math.floor(upTo * N);
      for (var k = 0; k <= n; k++) pts.push(at(R, ANG[k % N], u));
      poly(pts, col, upTo === undefined);
    }

    if (!solid) {
      // the sketch: a square drawn side by side
      var C = [[-1, -1], [1, -1], [1, 1], [-1, 1], [-1, -1]], sides = s.sk * 4, pts = [];
      for (var i = 0; i < 4 && sides > 0; i++) {
        var f = Math.min(1, sides); sides -= 1;
        if (!pts.length) pts.push([C[i][0], C[i][1], zb]);
        pts.push([C[i][0] + (C[i + 1][0] - C[i][0]) * f, C[i][1] + (C[i + 1][1] - C[i][1]) * f, zb]);
      }
      poly(pts, ACCENT, false);
    } else {
      poly(O.map(function (p) { return [p[0], p[1], zb]; }), mix(s.hBot), true);
      poly(O.map(function (p) { return [p[0], p[1], zt]; }), mix(s.hTop), true);
      var seams = r < 0.01 ? [[-1, -1], [1, -1], [1, 1], [-1, 1]]
        : [[-1 + r, -1], [1 - r, -1], [1, -1 + r], [1, 1 - r], [1 - r, 1], [-1 + r, 1], [-1, 1 - r], [-1, -1 + r]];
      seams.forEach(function (p) { addSeg([p[0], p[1], zb], [p[0], p[1], zt], mix(s.hSeam)); });
    }

    var tau8 = [0, 1, 2, 3, 4, 5, 6, 7].map(function (i) { return i * TAU / 8; });
    if (s.dA > 0) {
      ring(R_TOP, atA, 0, mix(s.hA));
      tau8.forEach(function (th) { addSeg(atA(R_TOP, th, 0), atA(R_TOP, th, s.dA), INK); });
      ring(R_TOP, atA, s.dA, INK);
    } else if (s.cpA > 0 && solid) ring(R_TOP, atA, 0, ACCENT, s.cpA);
    if (s.dB > 0) {
      ring(R_FRONT, atB, 0, mix(s.hB));
      tau8.forEach(function (th) { addSeg(atB(R_FRONT, th, 0), atB(R_FRONT, th, s.dB), INK); });
      ring(R_FRONT, atB, s.dB, INK);
    } else if (s.cpB > 0 && solid) ring(R_FRONT, atB, 0, ACCENT, s.cpB);
    if (s.dA > 0 && s.dB > 0) {
      // where the two holes meet: one closed curve on the front side of the vertical hole, one on the back
      [-1, 1].forEach(function (sg) {
        var pts = [];
        for (var i = 0; i <= 96; i++) {
          var psi = i * TAU / 96, x = R_FRONT * Math.cos(psi);
          pts.push([x, sg * Math.sqrt(R_TOP * R_TOP - x * x), R_FRONT * Math.sin(psi)]);
        }
        for (var i = 0; i < 96; i++) {
          var a = pts[i], b = pts[i + 1];
          if (a[1] < yB - 1e-4 && b[1] < yB - 1e-4 && a[2] > zA - 1e-4 && b[2] > zA - 1e-4) addSeg(a, b, INK);
        }
      });
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
    INK = readColor('--ink', INK); ACCENT = readColor('--accent', ACCENT);

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
        'attribute vec3 pa; attribute vec3 pb; attribute vec2 k; attribute vec3 col;\n' +
        'uniform mat4 m; uniform vec2 res; uniform float half_w; varying vec3 vc;\n' +
        'void main() {\n' +
        '  vec4 A = m * vec4(pa, 1.0); vec4 B = m * vec4(pb, 1.0);\n' +
        '  vec2 a = A.xy / A.w * res * 0.5; vec2 b = B.xy / B.w * res * 0.5;\n' +
        '  vec2 d = b - a; float len = length(d); d = len > 0.0001 ? d / len : vec2(1.0, 0.0);\n' +
        '  vec2 n = vec2(-d.y, d.x);\n' +
        '  vec4 P = mix(A, B, k.x);\n' +
        '  vec2 off = n * k.y * half_w + d * (k.x * 2.0 - 1.0) * half_w;\n' +
        '  P.xy += off / (res * 0.5) * P.w;\n' +
        '  P.z -= 0.0004 * P.w;\n' +                      // nudge toward the camera so edges win over their own faces; kept tiny, or hidden edges peek out where they end
        '  gl_Position = P; vc = col;\n' +
        '}',
        'precision mediump float; varying vec3 vc; void main() { gl_FragColor = vec4(vc, 1.0); }');
    } catch (e) { canvas.style.display = 'none'; return; }
    var uDepthM = gl.getUniformLocation(depthProg, 'm'), aDepthP = gl.getAttribLocation(depthProg, 'p');
    var uLineM = gl.getUniformLocation(lineProg, 'm'), uRes = gl.getUniformLocation(lineProg, 'res'), uHalf = gl.getUniformLocation(lineProg, 'half_w');
    var aPa = gl.getAttribLocation(lineProg, 'pa'), aPb = gl.getAttribLocation(lineProg, 'pb'), aK = gl.getAttribLocation(lineProg, 'k'), aCol = gl.getAttribLocation(lineProg, 'col');

    // ---- geometry: rebuilt whenever the timeline moves ----
    var meshBuf = gl.createBuffer(), lineBuf = gl.createBuffer(), triCount = 0, lineCount = 0;
    function upload(t) {
      var g = build(state(t));
      gl.bindBuffer(gl.ARRAY_BUFFER, meshBuf); gl.bufferData(gl.ARRAY_BUFFER, g.tri, gl.DYNAMIC_DRAW);
      gl.bindBuffer(gl.ARRAY_BUFFER, lineBuf); gl.bufferData(gl.ARRAY_BUFFER, g.seg, gl.DYNAMIC_DRAW);
      triCount = g.tri.length / 3; lineCount = g.seg.length / 11;
    }

    // ---- state ----
    var yaw = -0.85, pitch = 0.46;          // radians; yaw turns about Z (up), pitch tips the part toward the viewer
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
        gl.enable(gl.POLYGON_OFFSET_FILL); gl.polygonOffset(2, 2);
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
        gl.enableVertexAttribArray(aPa); gl.vertexAttribPointer(aPa, 3, gl.FLOAT, false, 44, 0);
        gl.enableVertexAttribArray(aPb); gl.vertexAttribPointer(aPb, 3, gl.FLOAT, false, 44, 12);
        gl.enableVertexAttribArray(aK); gl.vertexAttribPointer(aK, 2, gl.FLOAT, false, 44, 24);
        gl.enableVertexAttribArray(aCol); gl.vertexAttribPointer(aCol, 3, gl.FLOAT, false, 44, 32);
        gl.drawArrays(gl.TRIANGLES, 0, lineCount);
        gl.disableVertexAttribArray(aPa); gl.disableVertexAttribArray(aPb); gl.disableVertexAttribArray(aK); gl.disableVertexAttribArray(aCol);
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
          pitchTarget = fade * (0.05 * Math.cos(0.28 * idleT) + 0.02 * Math.cos(0.67 * idleT + 0.8)) + 0.1 * (0.45 - pitch);   // the last term keeps the nod around the starting view
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
      draw();
    });
    function release() { dragging = false; canvas.classList.remove('grabbing'); wake(); }
    canvas.addEventListener('pointerup', release);
    canvas.addEventListener('pointercancel', release);
    canvas.addEventListener('keydown', function (e) {
      var step = { ArrowLeft: [-0.2, 0], ArrowRight: [0.2, 0], ArrowUp: [0, -0.2], ArrowDown: [0, 0.2] }[e.key];
      if (!step) return;
      e.preventDefault(); yaw += step[0]; pitch = clampPitch(pitch + step[1]); draw();
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
