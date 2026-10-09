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
        uint pad0, pad1, pad2;
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

    fragment FragOut faceFragment(FaceOut in [[stage_in]],
                                  constant Uniforms& u [[buffer(1)]],
                                  constant uint* sel [[buffer(2)]],
                                  constant DrawParams& p [[buffer(3)]]) {
        float3 n = normalize(in.normal);
        float3 v = normalize(u.eye.xyz - in.world);
        if (dot(n, v) < 0.0) n = -n;
        float3 key = normalize(v + float3(0.25, 0.15, 0.6));
        float diffuse = max(dot(n, key), 0.0);
        float spec = pow(max(dot(reflect(-key, n), v), 0.0), 40.0) * 0.18;
        // The body's colour (its own from the Appearance panel, or the palette's), with hover and
        // selection colours made from it (see Renderer.tint).
        float3 base = p.color.rgb;
        // Face and edge ids carry their body in bits 20-29; "(body) | 0xFFFFF" stands for the whole body.
        uint bodyBits = in.id & 0x3FF00000u;
        bool hoverBody = u.wholeBodies != 0 && u.hovered != 0 && (u.hovered & 0x40000000u) == 0
                         && (u.hovered & 0x3FF00000u) == bodyBits;
        if (in.id == u.hovered || hoverBody) base = p.hoverColor.rgb;
        if (isSelected(in.id, sel, u.selectedCount) || isSelected(bodyBits | 0xFFFFFu, sel, u.selectedCount))
            base = p.selectColor.rgb;
        FragOut o;
        o.color = (p.style & 4u) != 0 ? float4(base, 1.0) : float4(base * (0.32 + 0.68 * diffuse) + spec, 1.0);
        o.id = in.id;
        return o;
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
        // A selected body edge (top bit set) draws wider, and so does every edge of a selected body's
        // border, to make room for its black-colour-black stripes. A selected sketch curve or point is wider too.
        float thickness = p.thickness;
        if (p.pickable != 0 && p.selectedThickness > 0.0
            && (edgeSelected(s.id, sel, u.selectedCount) || isSelected(s.id, sel, u.selectedCount)))
            thickness = p.selectedThickness;
        float4 ca = u.viewProj * float4(float3(s.a), 1.0);
        float4 cb = u.viewProj * float4(float3(s.b), 1.0);
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
            // A selected body edge: the selection colour down the middle third, black on either side,
            // so it shows against a face of the same colour.
            if (p.selectedThickness > 0.0 && edgeSelected(in.id, sel, u.selectedCount) && abs(in.across) > 1.0 / 3.0)
                c = float4(0.0, 0.0, 0.0, 1.0);
        }
        FragOut o;
        o.color = float4(c.rgb, c.a * coverage);
        o.id = p.pickable != 0 ? in.id : 0;
        return o;
    }
    """
}
