// Metal shaders, compiled at runtime (SwiftPM builds don't run the Metal compiler).
// SPDX-License-Identifier: GPL-3.0-or-later

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
        uint pad;
    };

    struct FaceOut {
        float4 position [[position]];
        float3 normal;
        float3 world;
        uint id [[flat]];
    };
    struct LineOut {
        float4 position [[position]];
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
                                  constant uint* sel [[buffer(2)]]) {
        float3 n = normalize(in.normal);
        float3 v = normalize(u.eye.xyz - in.world);
        if (dot(n, v) < 0.0) n = -n;
        float3 key = normalize(v + float3(0.25, 0.15, 0.6));
        float diffuse = max(dot(n, key), 0.0);
        float spec = pow(max(dot(reflect(-key, n), v), 0.0), 40.0) * 0.18;
        float3 base = float3(0.64, 0.67, 0.72);
        if (in.id == u.hovered) base = float3(0.55, 0.72, 0.95);
        if (isSelected(in.id, sel, u.selectedCount)) base = float3(0.30, 0.56, 1.0);
        FragOut o;
        o.color = float4(base * (0.32 + 0.68 * diffuse) + spec, 1.0);
        o.id = in.id;
        return o;
    }

    // Sketch profiles: translucent fills on the sketch plane, pulled slightly toward the camera.
    vertex FaceOut regionVertex(uint vid [[vertex_id]],
                                device const FaceVertex* verts [[buffer(0)]],
                                constant Uniforms& u [[buffer(1)]]) {
        FaceOut o = transformFace(verts[vid], u);
        o.position.z -= 0.0002 * o.position.w;
        return o;
    }

    fragment FragOut regionFragment(FaceOut in [[stage_in]],
                                    constant Uniforms& u [[buffer(1)]],
                                    constant uint* sel [[buffer(2)]]) {
        float alpha = 0.16;
        if (in.id == u.hovered) alpha = 0.32;
        if (isSelected(in.id, sel, u.selectedCount)) alpha = 0.5;
        FragOut o;
        o.color = float4(0.25, 0.5, 0.95, alpha);
        o.id = in.id;
        return o;
    }

    // Each segment instance is a screen-space quad (triangle strip of 4 vertices).
    vertex LineOut segmentVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                 device const Segment* segs [[buffer(0)]],
                                 constant Uniforms& u [[buffer(1)]],
                                 constant DrawParams& p [[buffer(3)]]) {
        Segment s = segs[iid];
        float4 ca = u.viewProj * float4(float3(s.a), 1.0);
        float4 cb = u.viewProj * float4(float3(s.b), 1.0);
        float2 halfSize = u.viewport * 0.5;
        float2 sa = ca.xy / max(ca.w, 1e-6) * halfSize;
        float2 sb = cb.xy / max(cb.w, 1e-6) * halfSize;
        float2 d = sb - sa;
        d = length(d) > 1e-6 ? normalize(d) : float2(1.0, 0.0);
        float2 nrm = float2(-d.y, d.x);
        bool atB = vid >= 2;
        float side = (vid % 2 == 0) ? -1.0 : 1.0;
        float4 c = atB ? cb : ca;
        float2 offset = (nrm * side + d * (atB ? 1.0 : -1.0)) * p.thickness * 0.5;
        c.xy += offset / halfSize * c.w;
        c.z -= p.depthBias * c.w;
        LineOut o;
        o.position = c;
        o.id = s.id;
        return o;
    }

    fragment FragOut segmentFragment(LineOut in [[stage_in]],
                                     constant Uniforms& u [[buffer(1)]],
                                     constant uint* sel [[buffer(2)]],
                                     constant DrawParams& p [[buffer(3)]]) {
        float4 c = p.color;
        if (p.pickable != 0) {
            if (in.id == u.hovered) c = p.hoverColor;
            if (isSelected(in.id, sel, u.selectedCount)) c = p.selectColor;
        }
        FragOut o;
        o.color = c;
        o.id = p.pickable != 0 ? in.id : 0;
        return o;
    }
    """
}
