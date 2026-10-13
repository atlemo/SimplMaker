// Metal shaders, compiled at runtime (SwiftPM builds don't run the Metal compiler).
// Copyright © 2026 Atle Mo. All rights reserved.

enum Shaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float4x4 viewProj;
        float4 eye;
        float2 viewport;       // drawable size in pixels
        uint hovered;
        uint selectedCount;
        float4 faceColor;
        float4 faceHoverColor;
        float4 faceSelectedColor;
        float4 regionColor;     // rgb + base alpha
        uint wholeBodies;       // a tool is picking bodies: hover and selection cover the whole body
        uint evenLight;         // sketching: lit evenly from the camera's side, with no glare moving over the faces
        float printLayer;       // print preview: layer height in mm
        float printNozzle;      // print preview: nozzle width in mm
        float4 clipPlane;       // section analysis: xyz = unit normal, w = distance; the side where dot(p, n) > w is cut away
        float4 viewDir;         // xyz = the way the camera looks; w = 1 when rays run parallel (orthographic)
        uint clipOn;
        float padClip2;
        uint padClip0;
        uint padClip1;
    };

    struct FaceVertex { packed_float3 position; packed_float3 normal; uint id; };
    struct Segment { packed_float3 a; packed_float3 b; uint id; };
    struct DrawParams {
        float4 color;
        float4 hoverColor;
        float4 selectColor;
        float thickness;       // pixels
        float depthBias;
        uint pickable;
        float selectedThickness; // pixels; a selected body edge's or sketch curve's width when set (see segmentFragment)
        uint style;            // DrawStyle bits: 1 only when hovered or selected, 2 dashed, 4 flat (unlit), 8 arrowhead
        float grow;            // pixels; an arrowhead's outline layer reaches this far past its edge
        float radius;          // pixels; the rounding of an arrowhead's corners
        float minLength;       // pixels; a segment shorter than this on screen is drawn this long (0 = as it is)
        float growSide;        // pixels; like grow, along an arrowhead's slanted sides (it fades to grow at the back)
        float dashPitch;       // pixels; a dashed line's dashes start this far apart
        float dashLength;      // pixels; (radius is half a dash's width, grow its outline)
    };

    struct FaceOut {
        float4 position [[position]];
        float3 normal;
        float3 world;
        uint id [[flat]];
    };
    struct LineOut {
        float4 position [[position]];
        float across;          // -1 to 1 from one side of the line to the other
        float2 dir [[flat]];   // the line's direction on screen, in framebuffer pixels (y down), for dashes
        float2 tip [[flat]];   // an arrowhead's tip, or a dashed line's start, in framebuffer pixels
        uint id [[flat]];
    };
    struct FragOut {
        float4 color [[color(0)]];
        uint id [[color(1)]];
    };

    static bool isSelected(uint id, constant uint* sel, uint n) {
        for (uint i = 0; i < n; i++) { if (sel[i] == id) return true; }
        return false;
    }

    // A body edge (top bit set) is lit when it is selected, or its whole body is (a border).
    static bool edgeSelected(uint id, constant uint* sel, uint n) {
        return (id & 0x80000000u) != 0
            && (isSelected(id, sel, n) || isSelected((id & 0x3FF00000u) | 0xFFFFFu, sel, n));
    }

    static FaceOut transformFace(FaceVertex v, constant Uniforms& u) {
        FaceOut o;
        o.world = float3(v.position);
        o.position = u.viewProj * float4(o.world, 1.0);
        o.normal = float3(v.normal);
        o.id = v.id;
        return o;
    }

    vertex FaceOut faceVertex(uint vid [[vertex_id]],
                              device const FaceVertex* verts [[buffer(0)]],
                              constant Uniforms& u [[buffer(1)]]) {
        return transformFace(verts[vid], u);
    }

    // A rounded bead's tilt across one printed line: t runs -1 to 1 over its width; the tilt is steep
    // at the edges and flat in the middle. The sudden change where one line meets the next is the groove.
    static float beadTilt(float t) { return 0.3 * t * rsqrt(1.02 - 0.9 * t * t); }

    // One set of printed lines along `coord` (one unit = one line), as the tilt of the surface and how dark
    // the groove between lines is. Zoomed out, lines closer than `minPx` pixels would shimmer, so they are
    // drawn at the next wider spacing (every second line, ...) with the two nearest spacings cross-faded.
    // That is a lie about the layer height, so it only goes so far (about 2.8 times) before the lines fade
    // out instead of growing. Their grooves are lines of the finer spacing too, so nothing slides while
    // zooming. A little stronger the further out, softer the further in.
    static float2 printLines(float coord, float minPx) {
        float w = fwidth(coord);                       // lines per pixel
        float level = log2(max(minPx * w, 1.0));       // 0 = every line fits; 1 = every second line, ...
        float tooFar = 1.0 - smoothstep(1.5, 2.5, level);
        level = min(level, 2.5);
        float k = floor(level);
        float blend = smoothstep(0.0, 1.0, level - k);
        float pitch = exp2(k);
        float tA = 2.0 * fract(coord / pitch) - 1.0;
        float tB = 2.0 * fract(coord / (2.0 * pitch)) - 1.0;
        float tilt = mix(beadTilt(tA), beadTilt(tB), blend);
        float groove = mix(smoothstep(0.7, 1.0, abs(tA)), smoothstep(0.7, 1.0, abs(tB)), blend);
        float closeUp = 1.0 - smoothstep(minPx, 4.0 * minPx, 1.0 / max(w, 1e-4));  // 0 once a line is wide
        float gain = mix(0.6, 1.0, closeUp) * (1.0 + 0.2 * min(level, 1.5)) * tooFar;
        return float2(tilt, groove) * gain;
    }

    // What an FDM print looks like at this point: horizontal layer lines on walls and slopes, and on flat
    // faces two perimeter lines along the edges with the diagonal lines of the top skin inside them.
    // Changes the normal and returns how much light the grooves between lines let in. `ring` is how far
    // the point is from the face's edge (mm). Approximate: nothing is sliced.
    static float printLook(thread float3& n, float3 world, float layer, float nozzle, float ring) {
        float zl = world.z / layer;
        float flatness = smoothstep(0.9, 0.98, abs(n.z));  // 0 on walls and slopes, 1 on tops and bottoms
        float2 wall = printLines(zl, 4.0);

        // Perimeters: lines one nozzle wide, counted from the edge in. Zoomed out they widen to stay about
        // four pixels each.
        float perimeters = 2.0;
        float scale = max(1.0, 4.0 * fwidth(ring) / nozzle);
        float rd = ring / (nozzle * scale);
        float aa = fwidth(rd);
        float inRing = 1.0 - smoothstep(perimeters - aa, perimeters + aa, rd);
        float ringLine = smoothstep(0.7, 1.0, abs(2.0 * fract(rd) - 1.0)) * inRing;
        float divider = 1.0 - smoothstep(0.0, 0.12 + aa, abs(rd - perimeters));

        // Top skin: lines a nozzle wide, crossing at 45 degrees on every other layer, inside the perimeters.
        float side = (int(floor(zl - 0.002)) & 1) != 0 ? 1.0 : -1.0;
        float2 across = float2(-side, 1.0) * 0.70710678;
        float2 skin = printLines(dot(world.xy, across) / nozzle, 4.0);
        skin *= 1.0 - inRing;

        float2 skinTilt = across * (0.3 * skin.x * flatness);
        n = normalize(n + float3(skinTilt, wall.x * (1.0 - flatness)));
        return 1.0 - 0.1 * wall.y * (1.0 - flatness)
                   - 0.04 * skin.y * flatness
                   - 0.07 * ringLine * flatness
                   - 0.1 * divider * flatness;
    }

    // Lighting, hover and selection colours; `print` gives the surface the look of an FDM print.
    static FragOut shadeFace(float3 normal, float3 world, uint id, bool print, float ring,
                             constant Uniforms& u, constant uint* sel, constant DrawParams& p) {
        float3 n = normalize(normal);
        float3 v = normalize(u.eye.xyz - world);
        if (u.evenLight != 0) v = -normalize(u.viewDir.xyz);  // the same for every pixel: a flat face is one shade
        if (dot(n, v) < 0.0) n = -n;
        float groove = 1.0;
        if (print) groove = printLook(n, world, max(u.printLayer, 0.01), max(u.printNozzle, 0.05), ring);
        float3 key = normalize(v + float3(0.25, 0.15, 0.6));
        float diffuse = max(dot(n, key), 0.0);
        float spec = print ? pow(max(dot(reflect(-key, n), v), 0.0), 14.0) * 0.07
                           : pow(max(dot(reflect(-key, n), v), 0.0), 40.0) * 0.18;
        if (u.evenLight != 0) spec = 0.0;
        // The body's colour (its own from the Appearance panel, or the palette's), with hover and
        // selection colours made from it (see Renderer.tint).
        float3 base = p.color.rgb;
        // Face and edge ids carry their body in bits 20-29; "(body) | 0xFFFFF" stands for the whole body.
        uint bodyBits = id & 0x3FF00000u;
        bool hoverBody = u.wholeBodies != 0 && u.hovered != 0 && (u.hovered & 0x40000000u) == 0
                         && (u.hovered & 0x3FF00000u) == bodyBits;
        if (id == u.hovered || hoverBody) base = p.hoverColor.rgb;
        if (isSelected(id, sel, u.selectedCount) || isSelected(bodyBits | 0xFFFFFu, sel, u.selectedCount))
            base = p.selectColor.rgb;
        FragOut o;
        o.color = (p.style & 4u) != 0 ? float4(base, 1.0) : float4(base * (0.32 + 0.68 * diffuse) * groove + spec, 1.0);
        o.id = id;
        return o;
    }

    fragment FragOut faceFragment(FaceOut in [[stage_in]],
                                  constant Uniforms& u [[buffer(1)]],
                                  constant uint* sel [[buffer(2)]],
                                  constant DrawParams& p [[buffer(3)]]) {
        if (u.clipOn != 0 && dot(in.world, u.clipPlane.xyz) - u.clipPlane.w > 1e-4) discard_fragment();
        return shadeFace(in.normal, in.world, in.id, false, 1e9, u, sel, p);
    }

    // The print preview draws each triangle on its own, with what it takes to tell how far a point is from the
    // edge of its face: which of its corners lie on the face's boundary, and the mesh vertex of each corner, to
    // look up the boundary segments that run from it (see Renderer.makePrintFaces).
    struct PrintVertex {
        packed_float3 position; packed_float3 normal; uint id;
        uint c0, c1, c2;        // the mesh vertices of the triangle's corners
        uint mask;              // bit j: corner j is on the boundary of the face
    };
    struct PrintCorner {
        float4 p;               // the vertex
        float4 a, b;            // the vertices next to it along the boundary (w = 0: none)
    };
    struct PrintOut {
        float4 position [[position]];
        float3 normal;
        float3 world;
        uint id [[flat]];
        uint3 corner [[flat]];
        uint mask [[flat]];
    };

    vertex PrintOut printFaceVertex(uint vid [[vertex_id]],
                                    device const PrintVertex* verts [[buffer(0)]],
                                    constant Uniforms& u [[buffer(1)]]) {
        PrintVertex v = verts[vid];
        PrintOut o;
        o.world = float3(v.position);
        o.position = u.viewProj * float4(o.world, 1.0);
        o.normal = float3(v.normal);
        o.id = v.id;
        o.corner = uint3(v.c0, v.c1, v.c2);
        o.mask = v.mask;
        return o;
    }

    static float segmentDistance(float3 p, float3 a, float3 b) {
        float3 ab = b - a;
        float t = clamp(dot(p - a, ab) / max(dot(ab, ab), 1e-12), 0.0, 1.0);
        return length(p - (a + ab * t));
    }

    // How far this point is from the face's boundary: the distance to the boundary segments that start at
    // the triangle's corners on it. (Only flat faces get a ring, so the others skip the lookups.)
    static float printRing(PrintOut in, device const PrintCorner* corners) {
        float ring = 1e9;
        if (abs(in.normal.z) > 0.8) {
            for (uint j = 0; j < 3; j++) {
                if (((in.mask >> j) & 1u) == 0) continue;
                PrintCorner c = corners[in.corner[j]];
                ring = min(ring, length(in.world - c.p.xyz));
                if (c.a.w > 0.0) ring = min(ring, segmentDistance(in.world, c.p.xyz, c.a.xyz));
                if (c.b.w > 0.0) ring = min(ring, segmentDistance(in.world, c.p.xyz, c.b.xyz));
            }
        }
        return ring;
    }

    fragment FragOut printFaceFragment(PrintOut in [[stage_in]],
                                       constant Uniforms& u [[buffer(1)]],
                                       constant uint* sel [[buffer(2)]],
                                       constant DrawParams& p [[buffer(3)]],
                                       device const PrintCorner* corners [[buffer(4)]]) {
        if (u.clipOn != 0 && dot(in.world, u.clipPlane.xyz) - u.clipPlane.w > 1e-4) discard_fragment();
        return shadeFace(in.normal, in.world, in.id, true, printRing(in, corners), u, sel, p);
    }

    // Section analysis: the bodies are cut by a plane. Faces on the cut-away side are discarded. Where the camera
    // then looks into a closed body (it sees the inside of a face, one that turns away from it), the body is solid
    // there, and the plane's cut face is drawn in its place: filled and hatched. That is a second draw of the faces
    // (p.style & 256: only these cut faces); the first leaves them out. The cut face lies at the depth of the
    // face it is seen on, so what is nearer along the same line of sight (a face the line meets on the way
    // to it) still hides it. Surfaces right at the plane get a dark outline, which gives the cut its edge.
    static FragOut sectionFace(float3 normal, float3 world, uint id, bool print, float ring,
                               constant Uniforms& u, constant uint* sel, constant DrawParams& p) {
        float3 n = u.clipPlane.xyz;
        float3 dir = u.viewDir.w > 0.5 ? u.viewDir.xyz : normalize(world - u.eye.xyz);
        float nd = dot(n, dir);
        float height = dot(world, n) - u.clipPlane.w;        // above 0: on the side that is cut away
        // Where this pixel's ray crosses the plane. Every point along the ray gives the same one, so it varies
        // smoothly across the screen however the surfaces behind it jump about (its derivatives are used below).
        float3 hit = world - dir * (height / (abs(nd) > 1e-5 ? nd : -1e-5));
        float pixel = max(length(dfdx(hit)), length(dfdy(hit)));
        float heightStep = fwidth(height);
        // Hatching: lines at 45 degrees in the plane, about 7 pixels apart.
        float3 up = abs(n.z) < 0.9 ? float3(0.0, 0.0, 1.0) : float3(1.0, 0.0, 0.0);
        float3 ux = normalize(cross(up, n));
        float3 vx = cross(n, ux);
        float k = (dot(hit, ux) + dot(hit, vx)) / (max(pixel, 1e-6) * 7.0 * 1.41421356);
        float hatch = 1.0 - smoothstep(0.35, 1.2, abs(k - round(k)) / max(fwidth(k), 1e-5));

        bool cut = dot(normal, dir) > 0.0 && nd < -1e-4;
        bool capsOnly = (p.style & 256u) != 0;
        FragOut o;
        o.color = float4(0.0);
        o.id = 0;
        if (height > 1e-4 || cut != capsOnly) {
            discard_fragment();
            return o;
        }
        if (cut) {
            float3 fill = mix(p.color.rgb, float3(1.0, 0.78, 0.92), 0.7);
            o.color = float4(mix(fill, float3(0.2, 0.06, 0.18), hatch * 0.75), 1.0);
            return o;
        }
        FragOut f = shadeFace(normal, world, id, print, ring, u, sel, p);
        float3 color = f.color.rgb;
        if ((p.style & 4u) == 0 && heightStep > 1e-7) {
            float band = 1.0 - smoothstep(0.5, 1.6, -height / heightStep);
            color = mix(color, float3(0.06, 0.06, 0.08), band * 0.9);
        }
        o.color = float4(color, 1.0);
        o.id = f.id;
        return o;
    }

    fragment FragOut sectionFaceFragment(FaceOut in [[stage_in]],
                                            constant Uniforms& u [[buffer(1)]],
                                            constant uint* sel [[buffer(2)]],
                                            constant DrawParams& p [[buffer(3)]]) {
        return sectionFace(in.normal, in.world, in.id, false, 1e9, u, sel, p);
    }

    fragment FragOut sectionPrintFragment(PrintOut in [[stage_in]],
                                             constant Uniforms& u [[buffer(1)]],
                                             constant uint* sel [[buffer(2)]],
                                             constant DrawParams& p [[buffer(3)]],
                                             device const PrintCorner* corners [[buffer(4)]]) {
        return sectionFace(in.normal, in.world, in.id, true, printRing(in, corners), u, sel, p);
    }

    // Sketch profiles: translucent fills on the sketch plane, pulled slightly toward the camera
    // (less than the sketch lines, so a line with fill on both sides, like a hole's, still shows).
    vertex FaceOut regionVertex(uint vid [[vertex_id]],
                                device const FaceVertex* verts [[buffer(0)]],
                                constant Uniforms& u [[buffer(1)]],
                                constant DrawParams& p [[buffer(3)]]) {
        FaceOut o = transformFace(verts[vid], u);
        o.position.z -= p.depthBias;
        return o;
    }

    fragment FragOut regionFragment(FaceOut in [[stage_in]],
                                    constant Uniforms& u [[buffer(1)]],
                                    constant uint* sel [[buffer(2)]]) {
        float alpha = u.regionColor.a;
        if (in.id == u.hovered) alpha *= 2.0;
        if (isSelected(in.id, sel, u.selectedCount)) alpha *= 3.0;
        FragOut o;
        o.color = float4(u.regionColor.rgb, min(alpha, 0.7));
        o.id = in.id;
        return o;
    }

    // Origin planes offered when choosing where to sketch: a translucent fill that brightens under the cursor.
    fragment FragOut planeFragment(FaceOut in [[stage_in]],
                                   constant Uniforms& u [[buffer(1)]],
                                   constant DrawParams& p [[buffer(3)]]) {
        FragOut o;
        o.color = in.id == u.hovered ? p.hoverColor : p.color;
        o.id = in.id;
        return o;
    }

    // Reference images: a textured quad on a plane, blended (premultiplied) at the image's opacity.
    // It writes colour only, so clicks pass through to whatever lies beneath.
    struct ImageParams {
        float4 corners[4];     // top left, top right, bottom right, bottom left
        float opacity;
        float depthBias;
        float2 pad;
    };
    struct ImageOut {
        float4 position [[position]];
        float2 uv;
    };

    // Reads one sample of a multisampled ID buffer (a copy can't, and the integers can't be resolved).
    kernel void pickSample(texture2d_ms<uint, access::read> ids [[texture(0)]],
                           constant uint2& pixel [[buffer(0)]],
                           device uint* result [[buffer(1)]]) {
        result[0] = ids.read(pixel, 0).x;
    }

    vertex ImageOut imageVertex(uint vid [[vertex_id]],
                                constant Uniforms& u [[buffer(1)]],
                                constant ImageParams& p [[buffer(3)]]) {
        // A triangle strip: top left, top right, bottom left, bottom right.
        const float2 uvs[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };
        const int corner[4] = { 0, 1, 3, 2 };
        ImageOut o;
        o.position = u.viewProj * float4(p.corners[corner[vid]].xyz, 1.0);
        o.position.z -= p.depthBias;
        o.uv = uvs[vid];
        return o;
    }

    fragment FragOut imageFragment(ImageOut in [[stage_in]],
                                   texture2d<float> image [[texture(0)]],
                                   constant ImageParams& p [[buffer(3)]]) {
        constexpr sampler smooth(filter::linear, mip_filter::linear, address::clamp_to_edge);
        FragOut o;
        o.color = image.sample(smooth, in.uv) * p.opacity;  // the texture holds premultiplied colour
        o.id = 0;
        return o;
    }

    // Each segment instance is a screen-space quad (triangle strip of 4 vertices).
    vertex LineOut segmentVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                 device const Segment* segs [[buffer(0)]],
                                 constant Uniforms& u [[buffer(1)]],
                                 constant uint* sel [[buffer(2)]],
                                 constant DrawParams& p [[buffer(3)]]) {
        Segment s = segs[iid];
        float3 segA = float3(s.a), segB = float3(s.b);
        // Section analysis: body edges (style 128) stop at the cutting plane, and vanish on the cut-away side.
        if ((p.style & 128u) != 0 && u.clipOn != 0) {
            float da = dot(segA, u.clipPlane.xyz) - u.clipPlane.w, db = dot(segB, u.clipPlane.xyz) - u.clipPlane.w;
            if (da > 1e-4 && db > 1e-4) {
                LineOut gone;
                gone.position = float4(2.0, 2.0, 2.0, 1.0);
                gone.across = 0.0;
                gone.dir = float2(0.0);
                gone.tip = float2(0.0);
                gone.id = 0;
                return gone;
            }
            float t = da / (da - db);
            float3 cut = segA + (segB - segA) * t;
            if (da > 1e-4) segA = cut; else if (db > 1e-4) segB = cut;
        }
        // A selected body edge (top bit set) draws wider, and so does every edge of a selected body's
        // border. A selected sketch curve or point is wider too.
        float thickness = p.thickness;
        if (p.pickable != 0 && p.selectedThickness > 0.0
            && (edgeSelected(s.id, sel, u.selectedCount) || isSelected(s.id, sel, u.selectedCount)))
            thickness = p.selectedThickness;
        float4 ca = u.viewProj * float4(segA, 1.0);
        float4 cb = u.viewProj * float4(segB, 1.0);
        // Trim the line to the depth range (0 <= z <= w) before anything is worked out from its ends. A long line
        // (the ground grid) often runs past the near or far plane, or behind the camera; its end's screen position
        // and depth then mean nothing, and the quad built from them is wrong: huge, and at the wrong depth, so it
        // shows through bodies. Arrowheads sit at their end point, so they are left alone.
        if ((p.style & 8u) == 0) {
            float fa[2] = { ca.z, ca.w - ca.z }, fb[2] = { cb.z, cb.w - cb.z };
            float t0 = 0.0, t1 = 1.0;
            for (int k = 0; k < 2; k++) {
                if (fa[k] < 0.0 && fb[k] < 0.0) { t0 = 2.0; break; }
                if (fa[k] < 0.0) t0 = max(t0, fa[k] / (fa[k] - fb[k]));
                else if (fb[k] < 0.0) t1 = min(t1, fa[k] / (fa[k] - fb[k]));
            }
            if (t0 >= t1) {
                LineOut gone;
                gone.position = float4(2.0, 2.0, 2.0, 1.0);
                gone.across = 0.0;
                gone.dir = float2(0.0);
                gone.tip = float2(0.0);
                gone.id = 0;
                return gone;
            }
            float4 ta = mix(ca, cb, t0), tb = mix(ca, cb, t1);
            ca = ta; cb = tb;
        }
        float2 halfSize = u.viewport * 0.5;
        float2 sa = ca.xy / max(ca.w, 1e-6) * halfSize;
        float2 sb = cb.xy / max(cb.w, 1e-6) * halfSize;
        float2 d = sb - sa;
        float screenLength = length(d);
        d = screenLength > 1e-6 ? d / screenLength : float2(1.0, 0.0);
        if (p.minLength > 0.0 && screenLength < p.minLength) {
            screenLength = p.minLength;
            sb = sa + d * screenLength;
            cb.xy = sb / halfSize * cb.w;
        }
        float2 nrm = float2(-d.y, d.x);
        bool atB = vid >= 2;
        float side = (vid % 2 == 0) ? -1.0 : 1.0;
        float4 c = atB ? cb : ca;
        float2 offset = (nrm * side + d * (atB ? 1.0 : -1.0)) * thickness * 0.5;
        if ((p.style & 8u) != 0) {
            // An arrowhead: a triangle pointing along a to b. `thickness` is its width on screen, and it is a
            // little longer than wide. It stands mostly past b, so the tip is well beyond where the shaft
            // ends (and the shaft's square end stays hidden inside the head). The two back corners come
            // from vertices 0 and 1.
            c = cb;
            float g = max(p.grow, p.growSide) + 2.0;  // room for the outline layer and the soft edge
            offset = (atB ? d * (0.45 * p.thickness + g)
                          : nrm * side * (0.5 * p.thickness + g) - d * (0.416 * p.thickness + g));
        }
        c.xy += offset / halfSize * c.w;
        // The quad reaches half a width past each end of the line, but its corners there would keep the
        // end's own depth, which flattens the depth along the line: the line then reads too far away at one
        // end, and the faces beside it hide a wide line (a selected edge, the pick band) there. Carry the
        // depth on past the ends at the line's own slope, so it matches the faces all along.
        if ((p.style & 8u) == 0 && ca.w > 1e-4 && cb.w > 1e-4 && screenLength > 1.0) {
            float za = ca.z / ca.w, zb = cb.z / cb.w;
            float reach = thickness * 0.5 / screenLength;
            float ze = atB ? zb + (zb - za) * reach : za + (za - zb) * reach;
            c.z = clamp(ze, 0.0, 1.0) * c.w;
        }
        // Constant in clip space: a fixed fraction of the view depth (see Camera.depthBiasScale). A wider line (a selected
        // edge) reaches farther across the face it lies on, which slopes away in depth, so its bias grows with it.
        c.z -= p.depthBias * max(thickness / max(p.thickness, 1e-3), 1.0);
        LineOut o;
        o.position = c;
        o.across = side;
        o.dir = float2(d.x, -d.y);
        float2 tipClip = sb + d * (0.45 * p.thickness);
        float2 anchor = (p.style & 8u) != 0 ? tipClip : sa;
        o.tip = float2(anchor.x + halfSize.x, halfSize.y - anchor.y);
        o.id = s.id;
        return o;
    }

    fragment FragOut segmentFragment(LineOut in [[stage_in]],
                                     constant Uniforms& u [[buffer(1)]],
                                     constant uint* sel [[buffer(2)]],
                                     constant DrawParams& p [[buffer(3)]]) {
        float coverage = 1.0;
        if ((p.style & 8u) != 0) {
            // An arrowhead: a triangle with rounded corners, laid out from its tip. The sharp triangle is
            // pulled in by the radius, and the radius added back to the distance, which rounds it.
            float L = 1 * p.thickness, H = 0.5 * p.thickness;
            float2 rel = in.position.xy - in.tip;
            float2 q = float2(-dot(rel, in.dir), dot(rel, float2(-in.dir.y, in.dir.x)));  // behind the tip, across
            float s = sqrt(L * L + H * H);
            float rho = L * H / (H + s);
            float k = (rho - p.radius) / rho;
            float cu = L - rho;
            float2 v0 = float2(cu - cu * k, 0.0);
            float2 v1 = float2(cu + (L - cu) * k, H * k);
            float2 v2 = float2(v1.x, -v1.y);
            // The distance to the triangle v0 v1 v2 (negative inside).
            float2 e0 = v1 - v0, e1 = v2 - v1, e2 = v0 - v2;
            float2 w0 = q - v0, w1 = q - v1, w2 = q - v2;
            float2 a0 = w0 - e0 * clamp(dot(w0, e0) / dot(e0, e0), 0.0, 1.0);
            float2 a1 = w1 - e1 * clamp(dot(w1, e1) / dot(e1, e1), 0.0, 1.0);
            float2 a2 = w2 - e2 * clamp(dot(w2, e2) / dot(e2, e2), 0.0, 1.0);
            float sgn = sign(e0.x * e2.y - e0.y * e2.x);
            float2 dd = min(min(float2(dot(a0, a0), sgn * (w0.x * e0.y - w0.y * e0.x)),
                                float2(dot(a1, a1), sgn * (w1.x * e1.y - w1.y * e1.x))),
                            float2(dot(a2, a2), sgn * (w2.x * e2.y - w2.y * e2.x)));
            float dist = -sqrt(dd.x) * sign(dd.y) - p.radius;
            // The slanted sides take growSide; it eases to grow toward the back edge, where the shaft joins.
            float sides = 1.0 - smoothstep(L - 0.35 * p.thickness, L, q.x);
            coverage = 1.0 - smoothstep(-0.5, 0.5, dist - mix(p.grow, p.growSide, sides));
            if (coverage <= 0.01) discard_fragment();
        }
        if ((p.style & 64u) != 0) {
            // A round dot at the segment's start (a zero-length segment), as wide as `thickness`.
            float dist = length(in.position.xy - in.tip) - p.thickness * 0.5;
            coverage = 1.0 - smoothstep(-0.5, 0.5, dist);
            if (coverage <= 0.01) discard_fragment();
        }
        if ((p.style & 32u) != 0) {
            // A dashed line: rounded dashes along it from its start, each with its outline (grow) around it.
            float2 rel = in.position.xy - in.tip;
            float s = dot(rel, in.dir) - p.dashLength * 0.5, across = dot(rel, float2(-in.dir.y, in.dir.x));
            float cell = round(s / p.dashPitch);
            if (cell < 0.0) discard_fragment();
            float corner = p.radius * 0.5;
            float2 q = abs(float2(s - cell * p.dashPitch, across)) - float2(p.dashLength * 0.5 - corner, p.radius - corner);
            float dist = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - corner;
            coverage = 1.0 - smoothstep(-0.5, 0.5, dist - p.grow);
            if (coverage <= 0.01) discard_fragment();
        }
        // Dashes, measured along the line on screen (so a curve made of short pieces still dashes evenly).
        if ((p.style & 2u) != 0) {
            float period = max(p.thickness, 1.0) * 5.0;
            float t = dot(in.position.xy, in.dir);
            if (t - period * floor(t / period) > period * 0.55) discard_fragment();
        }
        // Edges that show only while hovered or selected (the Shaded style), still there to pick.
        if ((p.style & 1u) != 0 && in.id != u.hovered && !isSelected(in.id, sel, u.selectedCount)
            && !edgeSelected(in.id, sel, u.selectedCount)) discard_fragment();
        float4 c = p.color;
        if (p.pickable != 0) {
            if (in.id == u.hovered) c = p.hoverColor;
            if (isSelected(in.id, sel, u.selectedCount) || edgeSelected(in.id, sel, u.selectedCount)) c = p.selectColor;
        }
        FragOut o;
        o.color = float4(c.rgb, c.a * coverage);
        o.id = p.pickable != 0 ? in.id : 0;
        return o;
    }
    """
}
