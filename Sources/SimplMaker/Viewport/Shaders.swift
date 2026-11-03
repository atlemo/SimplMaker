// Metal shaders, compiled at runtime (SwiftPM builds don't run the Metal compiler).
// Copyright © 2026 Atle Mo
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
        uint hoverGroupCount;   // ids after the selected ones in the selection buffer that light up like the hovered one
        uint padClip1;
        float4 lightDir;        // render view: xyz = the way to the main light, w = its strength
        float4 renderParams;    // render view: x = 1 when on, y = the ambient light, z = 1 while drawing the reflection, w = its strength
        float4x4 lightViewProj; // render view: the main light's view, for the shadow map
        float4 shadowParams;    // render view: x = 1 when shadows are on, y = how wide the light is (tan of its angle), w = depth range of the map in mm
        float4 shadowExtent;    // render view: xy = what the map covers in mm, z = a texel in mm, w = height a reflection fades out at
        float4 cameraRight;     // xyz = the camera's right
        float4 cameraUp;        // xyz = the camera's up
        float4 sceneCenter;     // render view: xyz = the middle of the part, w = how far a shiny face's reflection reaches (the room's size)
        float4x4 invViewProj;   // render view: from the screen back to the world, for the depth the occlusion and refraction read
        float4 look1;           // render view: x = 1 for physical light, y = exposure (a multiplier), z = softbox, w = finish (gloss of plain bodies)
        float4 look2;           // render view: x = occlusion strength, y = its reach in mm, z = its samples, w = contact shadow strength
        float4 look3;           // render view: x = contact shadow reach in mm, y = this frame's number (turns the sample patterns), z = glass refraction (0 off)
        float4 envZenith;       // the room: rgb = overhead, w = brightness of the soft boxes round it
        float4 envSky;          // rgb = the sky at the horizon, w = the main light's reflection
        float4 envGroundA;      // rgb = the ground at the horizon
        float4 envGroundB;      // rgb = the ground straight down
        float4 envTint;         // rgb = the main light's colour
        float4 floorLit;        // the floor as the shader draws it (see FloorParams), for what glass shows of it: rgb lit, w = where it starts to fade
        float4 floorShadow;     // rgb = in shadow, w = where the fade ends
        float4 floorBack;       // rgb = the backdrop
        float4 floorCenter;     // xy = the middle of the floor
    };

    struct FloorParams {
        float4 centerHalf;     // xy = the middle of the part, z = the floor's height, w = half the floor's side
        float4 lit;            // rgb = the floor as lit, w = where it starts to fade into the backdrop
        float4 backdrop;       // rgb = the backdrop, w = where the fade ends
        float4 shadowed;       // rgb = the floor where the main light does not reach
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
        uint material;         // render view: 0 plain, 1 metal, 2 glass, 3 wood, 4 plastic
        float roughness;       // render view: plastic and metal, 0 to 1; -1 = the material's own
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
        float fade;            // opacity of a fading line (style 512), 1 otherwise; 0 to 1 along a line fading in (style 1024)
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

    // The render view's shadow map: depth seen from the main light. A pixel is lit when nothing nearer the light is
    // in its way. The edge of a shadow is as soft as the light is wide: sharp where the shadow starts at the thing
    // casting it, softer the farther away it falls (a search for what blocks the light, then a filter as wide as
    // its distance asks for). The samples are turned by a different amount at every spot, so no pattern shows.
    static float2 vogelDisc(int i, int count, float turn) {
        float r = sqrt((float(i) + 0.5) / float(count));
        float a = float(i) * 2.39996323 + turn;
        return r * float2(cos(a), sin(a));
    }

    static float shadowVisibility(float3 world, float3 n, constant Uniforms& u, depth2d<float> map) {
        if (u.shadowParams.x < 0.5) return 1.0;
        float3 L = normalize(u.lightDir.xyz);
        float nl = dot(n, L);
        if (nl <= 0.0) return 1.0;  // turned away from the light: unlit already
        float texel = u.shadowExtent.z;
        float slope = clamp(sqrt(max(1.0 - nl * nl, 0.0)) / max(nl, 0.05), 0.0, 6.0);
        float4 c = u.lightViewProj * float4(world + n * texel * (1.5 + slope), 1.0);
        float2 uv = c.xy * float2(0.5, -0.5) + 0.5;
        if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) return 1.0;
        float range = u.shadowParams.w;
        float bias = texel * 2.0 / range;
        float zr = min(c.z, 0.9999);  // beyond the map's far plane: still behind everything in it, and in front of nothing
        constexpr sampler nearest(coord::normalized, filter::nearest, address::clamp_to_edge);
        constexpr sampler compare(coord::normalized, filter::linear, address::clamp_to_edge, compare_func::less_equal);
        float width = u.shadowParams.y;
        float2 extent = u.shadowExtent.xy;
        float turn = 6.2831853 * fract(sin(dot(world, float3(12.9898, 78.233, 37.719))) * 43758.5453 + u.look3.y * 0.61803);
        float2 search = min(width * range, 0.25 * min(extent.x, extent.y)) / extent;
        float blocked = 0.0, count = 0.0;
        for (int i = 0; i < 16; i++) {
            float z = map.sample(nearest, uv + vogelDisc(i, 16, turn) * search);
            if (z < zr - bias) { blocked += z; count += 1.0; }
        }
        if (count < 0.5) return 1.0;
        float penumbra = max((zr - blocked / count) * range * width, texel * 1.5);
        float2 radius = penumbra / extent;
        float lit = 0.0;
        for (int i = 0; i < 28; i++) lit += map.sample_compare(compare, uv + vogelDisc(i, 28, turn + 1.0) * radius, zr - bias);
        return lit / 28.0;
    }

    // The way from a point to the viewer. In an orthographic view every ray runs the same way: `eye` is a point near the
    // model there, not where the rays start, and a face seen at a shallow angle (a cylinder's top) can lie in front of it.
    static float3 toViewer(float3 world, constant Uniforms& u) {
        return u.viewDir.w > 0.5 ? -normalize(u.viewDir.xyz) : normalize(u.eye.xyz - world);
    }

    // The room shiny things reflect (see RenderSettings.Environment): a sky overhead, a band at the horizon, the floor
    // below, tall soft boxes round it, a big panel overhead (the softbox) and the main light as a soft box (as far as it
    // reaches the point, `lit`). `rough` blurs it: a rough surface sees the room as a smooth gradient.
    struct Env {
        float3 zenith; float3 skyHorizon; float3 groundHorizon; float3 groundDown;
        float strips; float key; float3 tint; float soft; float stripFrom; float stripTo;
    };

    static Env envOf(constant Uniforms& u) {
        Env e;
        e.zenith = u.envZenith.xyz; e.skyHorizon = u.envSky.xyz; e.groundHorizon = u.envGroundA.xyz; e.groundDown = u.envGroundB.xyz;
        e.strips = u.envZenith.w; e.key = u.envSky.w; e.tint = u.envTint.xyz; e.soft = u.look1.z;
        // Physical light shows the soft boxes lower, down to the horizon, which is where a standing body's sides look.
        e.stripFrom = u.look1.x > 0.5 ? -0.3 : -0.05;
        e.stripTo = u.look1.x > 0.5 ? 0.1 : 0.2;
        return e;
    }

    static float3 studioEnv(float3 r, float3 L, float key, float lit, float sharp, float rough, Env e) {
        float up = r.z;
        float az = atan2(r.y, r.x);
        // A dim room with bright things in it, which is what makes a metal read as one: sky overhead, a darker band at
        // the horizon, the floor below (mostly light in the render view, darker straight down).
        float3 sky = mix(e.skyHorizon, e.zenith, smoothstep(0.15, 0.95, up));
        float3 ground = mix(e.groundHorizon, e.groundDown, smoothstep(-0.1, -0.85, up));
        float edge = 0.12 + 0.55 * rough;
        float3 c = mix(ground, sky, smoothstep(-edge, edge, up));
        // Tall soft boxes round the room, so faces turned different ways pick up different light.
        float contrast = (1.0 - rough) * (1.0 - rough);
        float strips = mix(0.3, smoothstep(0.86, 0.96, cos(az * 2.5 + 0.7)), contrast);
        c += e.strips * strips * smoothstep(e.stripFrom, e.stripTo, up) * smoothstep(0.85, 0.5, up);
        c += e.soft * 1.6 * smoothstep(mix(0.78, 0.4, rough), mix(0.93, 0.9, rough), up);
        float lobe = mix(sharp, min(sharp, 4.0), rough);
        c += key * lit * e.key * e.tint * pow(max(dot(r, L), 0.0), lobe) * mix(1.0, 0.35, rough);
        return c;
    }

    static float hash31(float3 p) {
        p = fract(p * 0.1031);
        p += dot(p, p.zyx + 31.32);
        return fract((p.x + p.y) * p.z);
    }

    static float valueNoise(float3 p) {
        float3 i = floor(p), f = fract(p);
        f = f * f * (3.0 - 2.0 * f);
        float a = mix(hash31(i), hash31(i + float3(1, 0, 0)), f.x);
        float b = mix(hash31(i + float3(0, 1, 0)), hash31(i + float3(1, 1, 0)), f.x);
        float c = mix(hash31(i + float3(0, 0, 1)), hash31(i + float3(1, 0, 1)), f.x);
        float d = mix(hash31(i + float3(0, 1, 1)), hash31(i + float3(1, 1, 1)), f.x);
        return mix(mix(a, b, f.y), mix(c, d, f.y), f.z);
    }

    // Wood grain, 0 (dark) to 1 (light): growth rings round an axis along x that lies off to one side of the part, so a
    // cut through it shows arcs, bent by slow waves, with fine fibres along the grain. It is fixed in the world.
    static float woodGrain(float3 w) {
        float wave = valueNoise(float3(w.x * 0.012, w.y * 0.05, w.z * 0.05));
        float r = length(w.yz - float2(-40.0, -70.0)) + wave * 7.0;
        float ring = fract(r / 3.2);
        float rings = ring * ring * (1.0 - 0.6 * smoothstep(0.85, 1.0, ring));
        float fibre = valueNoise(float3(w.x * 0.04, w.y * 3.2, w.z * 3.2));
        float blotch = valueNoise(w * 0.12);
        return clamp(0.5 * rings + 0.32 * fibre + 0.18 * blotch, 0.0, 1.0);
    }

    // The side of a face that faces the viewer (the same turning shadeFace does).
    static float3 facing(float3 normal, float3 world, constant Uniforms& u) {
        float3 n = normalize(normal);
        return dot(n, toViewer(world, u)) < 0.0 ? -n : n;
    }

    // MARK: render view, physical light

    // Colours as light: the shader works in linear light and shows it through a filmic curve (the same as
    // RenderSettings.display), so highlights roll off instead of clipping.
    static float3 toLinear(float3 c) { return pow(max(c, float3(0.0)), float3(2.2)); }
    static float3 display(float3 lin, float exposure) {
        float3 x = max(lin * exposure, float3(0.0));
        float3 t = clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
        return pow(t, float3(1.0 / 2.2));
    }

    // A different number for every pixel, evenly spread (so the sample patterns don't clump).
    static float ign(float2 p) { return fract(52.9829189 * fract(dot(p, float2(0.06711056, 0.00583715)))); }

    // The world point at a screen position (uv, 0 to 1 from the top left) and a depth.
    static float3 unproject(float2 uv, float depth, constant Uniforms& u) {
        float4 p = u.invViewProj * float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, depth, 1.0);
        return p.xyz / p.w;
    }

    // Ambient occlusion: how much of the sky a point sees. Points in a hemisphere over the surface are looked up in the
    // depth of the bodies as the camera sees them; one that lies behind what is seen there is in something, and the
    // more of them are, the darker the corner. Returns 1 (open) to 0.
    static float ambientOcclusion(float3 world, float3 n, float2 pixel, constant Uniforms& u, depth2d<float> depthMap) {
        float strength = u.look2.x;
        if (strength <= 0.0) return 1.0;
        float radius = u.look2.y;
        int count = int(u.look2.z);
        constexpr sampler nearest(coord::normalized, filter::nearest, address::clamp_to_edge);
        float3 helper = abs(n.z) < 0.99 ? float3(0.0, 0.0, 1.0) : float3(1.0, 0.0, 0.0);
        float3 t = normalize(cross(helper, n));
        float3 b = cross(n, t);
        float turn = 6.2831853 * ign(pixel + u.look3.y * 5.588238);
        float3 origin = world + n * radius * 0.02;
        float occluded = 0.0;
        for (int i = 0; i < count; i++) {
            float2 d = vogelDisc(i, count, turn);
            float3 dir = t * d.x + b * d.y + n * sqrt(max(1.0 - dot(d, d), 0.0));
            float k = (float(i) + 0.5) / float(count);
            float3 s = origin + dir * radius * (0.12 + 0.88 * k);
            float4 clip = u.viewProj * float4(s, 1.0);
            float3 ndc = clip.xyz / clip.w;
            float2 uv = ndc.xy * float2(0.5, -0.5) + 0.5;
            if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) continue;
            float seen = depthMap.sample(nearest, uv);
            if (seen >= 1.0) continue;
            float3 p = unproject(uv, seen, u);
            if (dot(p - s, toViewer(s, u)) > radius * 0.03) {  // what is seen there is nearer the camera than the point: the point is inside it
                occluded += 1.0 - smoothstep(radius * 0.5, radius * 1.4, length(p - world));
            }
        }
        float open = 1.0 - clamp(occluded / float(count) * 1.7, 0.0, 1.0);
        return mix(1.0, open * open, strength);
    }

    // Contact shadows: a short march from the point toward the main light through the same depth. Sharp where the
    // shadow map's soft shadow is not, right where bodies touch the floor and each other.
    static float contactShadow(float3 world, float3 n, float2 pixel, constant Uniforms& u, depth2d<float> depthMap) {
        float strength = u.look2.w;
        if (strength <= 0.0) return 1.0;
        float3 L = normalize(u.lightDir.xyz);
        if (dot(n, L) <= 0.0) return 1.0;
        float reach = u.look3.x;
        constexpr sampler nearest(coord::normalized, filter::nearest, address::clamp_to_edge);
        float jitter = ign(pixel + u.look3.y * 3.17);
        float3 origin = world + n * reach * 0.012;
        float hit = 0.0;
        for (int i = 0; i < 12; i++) {
            float3 s = origin + L * reach * (0.04 + 0.96 * ((float(i) + jitter) / 12.0));
            float4 clip = u.viewProj * float4(s, 1.0);
            float3 ndc = clip.xyz / clip.w;
            float2 uv = ndc.xy * float2(0.5, -0.5) + 0.5;
            if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) continue;
            float seen = depthMap.sample(nearest, uv);
            if (seen >= 1.0) continue;
            float3 p = unproject(uv, seen, u);
            float inFront = dot(p - s, toViewer(s, u));
            if (inFront > reach * 0.015 && inFront < reach * 0.3) hit = 1.0;
        }
        return 1.0 - strength * hit;
    }

    static float distributionGGX(float nh, float a) {
        float a2 = a * a;
        float d = nh * nh * (a2 - 1.0) + 1.0;
        return a2 / (3.14159265 * d * d + 1e-5);
    }

    // Light on a body, in linear light: the main light (with a GGX highlight), a fill, ambient light from the room and
    // the softbox (dimmed by occlusion), and the room reflected in it, more at grazing angles and blurrier the rougher
    // the finish. Returns what the screen shows.
    static float3 physicalShade(float3 n, float3 v, float3 world, float3 base, uint material, float lit, float ao,
                                float roughness, constant Uniforms& u) {
        Env e = envOf(u);
        float3 L = normalize(u.lightDir.xyz);
        float3 albedo = toLinear(base);
        bool metal = material == 1u;
        float rough = metal ? 0.2 : (material == 3u ? 0.5 : mix(0.85, 0.12, u.look1.w));
        if (roughness >= 0.0) rough = mix(0.05, 0.95, roughness);  // plastic and metal: 0 polished, 1 matte
        float nl = max(dot(n, L), 0.0), nv = max(dot(n, v), 1e-3);
        float brightness = u.lightDir.w;
        float3 key = e.tint * (brightness * 1.5);
        float2 h = float2(L.x * -0.1736 - L.y * 0.9848, L.x * 0.9848 - L.y * 0.1736);
        float3 fillDir = normalize(float3(h / max(length(h), 1e-4), 0.35));
        float fill = max(dot(n, fillDir), 0.0) * 0.25 * brightness;
        float3 sky = e.zenith * 0.8 + e.skyHorizon * 0.2;
        float3 ambient = mix(e.groundHorizon * 0.5, sky, 0.5 + 0.5 * n.z) * (u.renderParams.y * 0.28);
        float soft = u.look1.z * 0.3 * max(n.z, 0.0);
        float3 irradiance = key * (nl * lit) + float3(fill) + (ambient + float3(soft)) * ao;
        float3 f0 = metal ? albedo : float3(0.04);
        float3 diffuse = metal ? float3(0.0) : albedo * 0.96;
        float3 hv = normalize(L + v);
        float nh = max(dot(n, hv), 0.0), vh = max(dot(v, hv), 0.0);
        float a = max(rough * rough, 0.02);
        float k = (rough + 1.0) * (rough + 1.0) / 8.0;
        float visibility = 0.25 / ((nl * (1.0 - k) + k) * (nv * (1.0 - k) + k));
        float3 fresnel = f0 + (1.0 - f0) * pow(1.0 - vh, 5.0);
        float3 highlight = min(fresnel * (distributionGGX(nh, a) * visibility * nl) * key * lit, float3(6.0));
        // The room reflected, looked up from the middle of the room so a big flat face shows a gradient.
        float3 r = reflect(-v, n);
        float3 look = normalize((world - u.sceneCenter.xyz) + normalize(mix(r, n, 0.2)) * u.sceneCenter.w);
        float3 room = studioEnv(look, L, brightness, lit, mix(400.0, 6.0, rough), rough, e);
        if (metal) room = pow(max(room, float3(0.0)), float3(1.7)) * 1.25;
        else {
            // The lights in a room are far brighter than the walls: a glossy plastic shows them as clear streaks and dots, a rough
            // one only as a faint sheen (the room is blurred and flattened by the roughness, above, and the boost fades with it).
            float gloss = 1.0 - rough;
            room = mix(room, pow(max(room, float3(0.0)), float3(2.2)) * 3.5, gloss * gloss);
        }  // a polished metal is all contrast: dark where the room is dim, bright where it is lit
        float3 fEnv = f0 + (max(float3(1.0 - rough), f0) - f0) * pow(1.0 - nv, 5.0);
        float3 reflected = room * fEnv * mix(1.0, ao, 0.85);
        return display(diffuse * irradiance + highlight + reflected, u.look1.y);
    }

    // What a glass body shows of what lies behind it when the glass bends the light: the view ray is turned as it enters
    // (index 1.5), travels as far as the glass is thick (the farthest glass surface behind this one) and comes out
    // turned back about half way, to land on the floor (as lit and shadowed there) or on the room. Thicker glass is
    // darker. rgb = what is seen (as it shows on the screen), a = how much of the picture it replaces: 0 where a body
    // stands behind (that one is not bent, it is only seen through the glass).
    static float4 glassRefraction(float3 world, float3 n, float3 v, float2 uv, float3 tint, constant Uniforms& u,
                                  depth2d<float> shadowMap, depth2d<float> sceneDepth, depth2d<float> backDepth) {
        constexpr sampler nearest(coord::normalized, filter::nearest, address::clamp_to_edge);
        if (sceneDepth.sample(nearest, uv) < 1.0) return float4(0.0);
        float room = u.sceneCenter.w;
        float thickness = room * 0.08;
        float back = backDepth.sample(nearest, uv);
        if (back > 0.0) thickness = max(length(unproject(uv, back, u) - world), room * 0.005);
        float3 d = refract(-v, n, 1.0 / 1.5);
        float3 leaving = normalize(mix(d, -v, 0.5));
        float3 exitPoint = world + d * thickness;
        float3 color;
        if (leaving.z < -0.01 && exitPoint.z > 0.0) {
            float3 hit = exitPoint + leaving * (exitPoint.z / -leaving.z);
            float lit = shadowVisibility(hit, float3(0.0, 0.0, 1.0), u, shadowMap);
            float fade = smoothstep(u.floorLit.w, u.floorShadow.w, length(hit.xy - u.floorCenter.xy));
            color = mix(mix(u.floorShadow.rgb, u.floorLit.rgb, lit), u.floorBack.rgb, fade);
        } else {
            color = display(studioEnv(leaving, normalize(u.lightDir.xyz), u.lightDir.w, 1.0, 40.0, 0.2, envOf(u)) * 0.9, u.look1.y);
        }
        float3 absorb = pow(clamp(tint, float3(0.05), float3(1.0)), float3(thickness / (room * 0.45)));
        return float4(color * absorb, u.look3.z);
    }

    // Lighting, hover and selection colours; `print` gives the surface the look of an FDM print. `lit` is how much of
    // the main light of the render view reaches the point (1 without shadows).
    static FragOut shadeFace(float3 normal, float3 world, uint id, bool print, float ring,
                             constant Uniforms& u, constant uint* sel, constant DrawParams& p, float lit = 1.0, float occlusion = 1.0,
                             float4 refraction = float4(0.0)) {
        float3 n = normalize(normal);
        float3 v = toViewer(world, u);
        if (u.evenLight != 0) v = -normalize(u.viewDir.xyz);  // the same for every pixel: a flat face is one shade
        // Glass is drawn in two passes: the faces turned away from the viewer first, then those turned toward it.
        bool turnedAway = dot(n, v) < 0.0;
        if ((p.style & 2048u) != 0u && !turnedAway) discard_fragment();
        if ((p.style & 4096u) != 0u && turnedAway) discard_fragment();
        if (turnedAway) n = -n;
        float groove = 1.0;
        if (print) groove = printLook(n, world, max(u.printLayer, 0.01), max(u.printNozzle, 0.05), ring);
        // The key light sits up and to the right of the camera. The offset is in the camera's own axes: a world-space
        // offset added to the view vector swings the light round the model as the camera orbits, so a face seen from
        // behind the offset lit and darkened from one angle to the next.
        float3 key = normalize(v + 0.25 * u.cameraRight.xyz + 0.6 * u.cameraUp.xyz);
        float diffuse = max(dot(n, key), 0.0);
        float spec = print ? pow(max(dot(reflect(-key, n), v), 0.0), 14.0) * 0.07
                           : pow(max(dot(reflect(-key, n), v), 0.0), 40.0) * 0.18;
        float lighting = 0.32 + 0.68 * diffuse;
        if (u.renderParams.x > 0.5 && u.evenLight == 0) {
            // The render view: a main light that stays where it is set in the world, a weaker fill from the side, and ambient light that is stronger on faces turned up. (RenderSettings.shade is this sum
            // for a face turned straight up.)
            float3 L = normalize(u.lightDir.xyz);
            // The fill stands 100° round from the main light and low, so it reaches the side the main light misses.
            float2 h = float2(L.x * -0.1736 - L.y * 0.9848, L.x * 0.9848 - L.y * 0.1736);
            float3 fillDir = normalize(float3(h / max(length(h), 1e-4), 0.35));
            float mainLight = max(dot(n, L), 0.0);
            float fill = max(dot(n, fillDir), 0.0);
            lighting = u.renderParams.y * (0.7 + 0.3 * n.z) * occlusion + u.lightDir.w * (0.7 * mainLight * lit + 0.3 * fill);
            spec = pow(max(dot(reflect(-L, n), v), 0.0), 40.0) * 0.2 * u.lightDir.w * step(0.001, mainLight) * lit;
        }
        if (u.evenLight != 0) spec = 0.0;
        if (p.material == 4u && u.renderParams.x > 0.5 && u.evenLight == 0 && !print) {
            // Plastic without physical light: the main light's highlight, tight and bright when it is glossy and broad and dull when it
            // is rough, and a little sheen at grazing angles.
            float r = p.roughness >= 0.0 ? p.roughness : 0.35;
            float3 Lp = normalize(u.lightDir.xyz);
            spec = pow(max(dot(reflect(-Lp, n), v), 0.0), mix(180.0, 7.0, r)) * mix(0.55, 0.08, r)
                 * u.lightDir.w * step(0.001, max(dot(n, Lp), 0.0)) * lit
                 + pow(1.0 - max(dot(n, v), 0.0), 4.0) * 0.12 * (1.0 - r);
        }
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
        o.color = (p.style & 4u) != 0 ? float4(base, 1.0) : float4(base * lighting * groove + spec, 1.0);
        float opacity = 1.0;
        bool physical = u.look1.x > 0.5 && (p.style & 4u) == 0 && !print && u.renderParams.x > 0.5 && u.evenLight == 0;
        if (physical && p.material != 2u) {
            // Physical light: plain, metal and wood bodies are all lit the same way, only the finish differs.
            float3 surface = p.material == 3u ? base * mix(0.6, 1.12, woodGrain(world)) : base;
            o.color = float4(physicalShade(n, v, world, surface, p.material, lit, occlusion, p.roughness, u), 1.0);
        } else if (p.material != 0u && p.material != 4u && (p.style & 4u) == 0 && !print && u.renderParams.x > 0.5 && u.evenLight == 0) {
            // Materials (render view). The colour is the metal's colour, the glass's tint, the wood's base shade.
            float3 L = normalize(u.lightDir.xyz);
            float ndv = clamp(dot(n, v), 0.0, 1.0);
            float fresnel = pow(1.0 - ndv, 5.0);
            float3 r = reflect(-v, n);
            if (p.material == 1u) {
                // The studio is a room round the part, not at infinity, so a big flat face reflects a gradient (the lookup runs from the room's middle).
                float3 env = studioEnv(normalize((world - u.sceneCenter.xyz) + normalize(mix(r, n, 0.2)) * u.sceneCenter.w), L, u.lightDir.w, lit, 28.0, 0.0, envOf(u)) * mix(0.6, 1.0, lit);
                float3 F = base + (1.0 - base) * fresnel;
                o.color.rgb = F * env * 0.9 + base * lighting * 0.1;
            } else if (p.material == 3u) {
                float3 wood = base * mix(0.6, 1.12, woodGrain(world));
                o.color.rgb = wood * lighting + spec * 0.8;
            } else {
                // Glass: see-through and tinted, with the studio mirrored in it (a little head-on, a lot at grazing angles), a hard
                // highlight from the main light, and the inside of the far wall seen through the near one (drawn first, `glassBack`).
                float3 rr = normalize((world - u.sceneCenter.xyz) + r * u.sceneCenter.w);
                float3 room = studioEnv(rr, L, 0.0, 1.0, 1.0, 0.0, envOf(u)) * 1.35;
                if (physical) room = display(room, u.look1.y);
                float F = 0.11 + 0.89 * pow(1.0 - ndv, 3.5);
                float highlight = clamp(u.lightDir.w * lit * 2.5 * pow(max(dot(rr, L), 0.0), 220.0), 0.0, 0.9);
                float3 tint = base * (0.55 + 0.45 * lighting);
                if ((p.style & 2048u) != 0u) {
                    // The far wall: tinted light that has come through the glass, with a dimmer reflection of the room.
                    float a = clamp(0.2 + 0.45 * F, 0.0, 0.9);
                    o.color = float4((tint * 0.7 * 0.2 + room * F * 0.55 + highlight * 0.5) / max(a, 0.001), a);
                } else if (physical && refraction.a > 0.0) {
                    // Bent: the picture behind is replaced by what the glass shows (the transmitted part), plus the room reflected.
                    float Fr = 0.05 + 0.95 * pow(1.0 - ndv, 4.0);
                    float w = refraction.a;
                    float a = clamp(1.0 - (1.0 - Fr) * (1.0 - w) + highlight, 0.0, 0.995);
                    o.color = float4(((1.0 - Fr) * w * refraction.rgb + room * Fr + highlight) / max(a, 0.001), a);
                } else {
                    float absorbed = 0.14;
                    float a = clamp(absorbed + F + highlight, 0.0, 0.97);
                    o.color = float4((tint * absorbed + room * F + highlight) / a, a);
                }
                opacity = 0.35;
            }
        }
        // The reflection in the floor: opaque only where the body meets the floor, and fading out with the height.
        if (u.renderParams.z > 0.5) o.color.a = opacity * u.renderParams.w * (1.0 - smoothstep(0.0, max(u.shadowExtent.w, 1.0), world.z));
        o.id = id;
        return o;
    }

    struct FloorOut {
        float4 position [[position]];
        float2 xy;
    };

    vertex FloorOut floorVertex(uint vid [[vertex_id]],
                                constant Uniforms& u [[buffer(1)]],
                                constant FloorParams& f [[buffer(3)]]) {
        float2 corner = float2((vid & 1) != 0 ? 1.0 : -1.0, (vid & 2) != 0 ? 1.0 : -1.0);
        float2 xy = f.centerHalf.xy + corner * f.centerHalf.w;
        FloorOut o;
        o.position = u.viewProj * float4(xy, f.centerHalf.z, 1.0);
        o.xy = xy;
        return o;
    }

    fragment FragOut floorFragment(FloorOut in [[stage_in]],
                                   constant Uniforms& u [[buffer(1)]],
                                   constant FloorParams& f [[buffer(3)]],
                                   depth2d<float> shadowMap [[texture(1)]],
                                   depth2d<float> viewDepth [[texture(3)]],
                                   texture2d<float> occlusionMap [[texture(5)]]) {
        float3 spot = float3(in.xy, f.centerHalf.z);
        float3 up = float3(0.0, 0.0, 1.0);
        float lit = shadowVisibility(spot, up, u, shadowMap);
        // Right at the foot of a body the floor is darker than its soft shadow says: contact shadow and occlusion.
        lit = min(lit, contactShadow(spot, up, in.position.xy, u, viewDepth));
        constexpr sampler nearestSampler(coord::normalized, filter::nearest, address::clamp_to_edge);
        float occlusion = u.look2.x > 0.0 ? occlusionMap.sample(nearestSampler, in.position.xy / u.viewport).r : 1.0;
        float t = smoothstep(f.lit.w, f.backdrop.w, length(in.xy - f.centerHalf.xy));
        FragOut o;
        o.color = float4(mix(mix(f.shadowed.rgb, f.lit.rgb, lit) * occlusion, f.backdrop.rgb, t), 1.0);
        o.id = 0;
        return o;
    }

    // A blurred reflection is made apart, from many mirror views tilted a little differently (each moves what is
    // reflected sideways by its height, so the foot of a body stays sharp and the top blurs the most), added up in a
    // texture: premultiplied colour and, in alpha, how much of the floor the reflection takes. This is one view.
    fragment float4 reflectionFragment(FaceOut in [[stage_in]],
                                       constant Uniforms& u [[buffer(1)]],
                                       constant uint* sel [[buffer(2)]],
                                       constant DrawParams& p [[buffer(3)]],
                                       depth2d<float> shadowMap [[texture(1)]]) {
        if (u.clipOn != 0 && dot(in.world, u.clipPlane.xyz) - u.clipPlane.w > 1e-4) discard_fragment();
        float lit = shadowVisibility(in.world, facing(in.normal, in.world, u), u, shadowMap);
        float3 color = shadeFace(in.normal, in.world, in.id, false, 1e9, u, sel, p, lit).color.rgb;
        float a = (p.material == 2u ? 0.35 : 1.0) * u.renderParams.w * (1.0 - smoothstep(0.0, max(u.shadowExtent.w, 1.0), in.world.z));
        return float4(color * a, a);
    }

    // The floor again, over the floor, with the summed reflection (read a little blurred, to blend the steps between views).
    fragment FragOut reflectionCompositeFragment(FloorOut in [[stage_in]],
                                                 constant Uniforms& u [[buffer(1)]],
                                                 constant FloorParams& f [[buffer(3)]],
                                                 texture2d<float> reflection [[texture(2)]]) {
        constexpr sampler linearSampler(coord::normalized, filter::linear, address::clamp_to_edge);
        float2 uv = in.position.xy / u.viewport;
        float2 texel = 1.0 / float2(reflection.get_width(), reflection.get_height());
        float radius = 1.0 + 3.0 * f.shadowed.w;
        float4 sum = reflection.sample(linearSampler, uv);
        for (int i = 0; i < 8; i++) {
            float a = float(i) * 0.785398;
            sum += reflection.sample(linearSampler, uv + float2(cos(a), sin(a)) * radius * texel);
        }
        sum /= 9.0;
        FragOut o;
        o.color = float4(sum.rgb / max(sum.a, 1e-4), sum.a);
        o.id = 0;
        return o;
    }

    // Grain over the whole view, drawn twice, once adding the light grains and once taking away the dark ones, so it
    // is as strong on a white floor as on a dark one. It is fixed to the screen, one grain to a point.
    struct NoiseParams {
        float amount;
        float grain;       // pixels to a grain
        float sign;        // 1 adds, -1 takes away
        float pad;
    };

    struct NoiseOut {
        float4 position [[position]];
    };

    vertex NoiseOut noiseVertex(uint vid [[vertex_id]]) {
        NoiseOut o;
        o.position = float4(vid == 1 ? 3.0 : -1.0, vid == 2 ? 3.0 : -1.0, 0.0, 1.0);
        return o;
    }

    fragment FragOut noiseFragment(NoiseOut in [[stage_in]], constant NoiseParams& n [[buffer(3)]]) {
        uint2 cell = uint2(floor(in.position.xy / max(n.grain, 1.0)));
        uint h = cell.x * 1664525u + cell.y * 1013904223u + 12345u;
        h ^= h >> 16; h *= 2246822519u;
        h ^= h >> 13; h *= 3266489917u;
        h ^= h >> 16;
        float v = (float(h) / 4294967295.0 - 0.5) * 2.0 * n.sign;   // -1 to 1, mirrored for the taking-away pass
        FragOut o;
        o.color = float4(float3(max(v, 0.0) * n.amount), 1.0);
        o.id = 0;
        return o;
    }

    // The bodies seen from the main light, for the shadow map: depth only.
    struct ShadowOut {
        float4 position [[position]];
    };

    // The bodies as the camera sees them, depth only: what the occlusion and contact shadows read.
    vertex ShadowOut viewDepthVertex(uint vid [[vertex_id]],
                                     device const FaceVertex* verts [[buffer(0)]],
                                     constant Uniforms& u [[buffer(1)]]) {
        ShadowOut o;
        o.position = u.viewProj * float4(float3(verts[vid].position), 1.0);
        return o;
    }

    // A body's depth and ID with no colour: what the view draws of the bodies after the picture was made apart.
    fragment FragOut idFragment(FaceOut in [[stage_in]]) {
        FragOut o;
        o.color = float4(0.0);
        o.id = in.id;
        return o;
    }


    struct PostParams {
        float4 effects;   // x = glow, y = darker corners, z = blur in depth, w = the distance (mm along the view) that is sharp
        float4 scene;     // x = the size of the part in mm, y = pixels to a point, z = where the glow starts, w = 0
        float4 step;      // xy = one step of a blur in texels of what is read, zw = 1 / the size drawn into
    };

    // Ambient occlusion is made apart for the whole picture: the bodies' (and the floor's) depth and normals, the occlusion of
    // each pixel from them, and a blur that keeps edges (the samples are few and turned differently at every pixel, so
    // the raw result is grainy). The shaders then read it.
    fragment float4 aoNormalFragment(FaceOut in [[stage_in]], constant Uniforms& u [[buffer(1)]]) {
        return float4(facing(in.normal, in.world, u) * 0.5 + 0.5, 1.0);
    }

    fragment float4 aoFloorFragment(FloorOut in [[stage_in]]) {
        return float4(0.5, 0.5, 1.0, 1.0);
    }

    fragment float4 aoFragment(NoiseOut in [[stage_in]], constant Uniforms& u [[buffer(1)]],
                               depth2d<float> depthMap [[texture(0)]], texture2d<float> normals [[texture(1)]]) {
        constexpr sampler nearest(coord::normalized, filter::nearest, address::clamp_to_edge);
        float2 uv = in.position.xy / u.viewport;
        float d = depthMap.sample(nearest, uv);
        if (d >= 1.0) return float4(1.0);
        float3 n = normalize(normals.sample(nearest, uv).xyz * 2.0 - 1.0);
        return float4(ambientOcclusion(unproject(uv, d, u), n, in.position.xy, u, depthMap));
    }

    fragment float4 aoBlurFragment(NoiseOut in [[stage_in]], constant Uniforms& u [[buffer(1)]], constant PostParams& pp [[buffer(3)]],
                                   texture2d<float> occlusion [[texture(0)]], depth2d<float> depthMap [[texture(1)]]) {
        constexpr sampler nearest(coord::normalized, filter::nearest, address::clamp_to_edge);
        float2 uv = in.position.xy / u.viewport;
        float d0 = depthMap.sample(nearest, uv);
        if (d0 >= 1.0) return float4(1.0);
        float3 p0 = unproject(uv, d0, u);
        float2 texel = pp.step.xy / u.viewport;
        float sum = occlusion.sample(nearest, uv).r, weights = 1.0;
        for (int i = -5; i <= 5; i++) {
            if (i == 0) continue;
            float2 tapUV = uv + texel * float(i);
            float d = depthMap.sample(nearest, tapUV);
            if (d >= 1.0) continue;
            float w = exp(-float(i * i) / 12.0) * (1.0 - smoothstep(0.0, pp.scene.x * 0.25, length(unproject(tapUV, d, u) - p0)));
            sum += occlusion.sample(nearest, tapUV).r * w;
            weights += w;
        }
        return float4(sum / weights);
    }

    // MARK: the render view's finishing touches

    // The glow starts with what is bright: a quarter of the size, four taps that each average 2 x 2 texels.
    fragment float4 brightFragment(NoiseOut in [[stage_in]], constant PostParams& pp [[buffer(3)]], texture2d<float> source [[texture(0)]]) {
        constexpr sampler lin(coord::normalized, filter::linear, address::clamp_to_edge);
        float2 uv = in.position.xy * pp.step.zw;
        float2 texel = 1.0 / float2(source.get_width(), source.get_height());
        float3 sum = float3(0.0);
        for (int i = 0; i < 4; i++) {
            float2 o = float2(i & 1 ? 1.0 : -1.0, i & 2 ? 1.0 : -1.0) * texel * 1.0;
            float3 c = source.sample(lin, uv + o).rgb;
            sum += max(c - pp.scene.z, float3(0.0)) / max(1.0 - pp.scene.z, 0.05);
        }
        return float4(sum * 0.25, 1.0);
    }

    fragment float4 downFragment(NoiseOut in [[stage_in]], constant PostParams& pp [[buffer(3)]], texture2d<float> source [[texture(0)]]) {
        constexpr sampler lin(coord::normalized, filter::linear, address::clamp_to_edge);
        float2 uv = in.position.xy * pp.step.zw;
        float2 texel = 1.0 / float2(source.get_width(), source.get_height());
        float3 sum = float3(0.0);
        for (int i = 0; i < 4; i++) sum += source.sample(lin, uv + float2(i & 1 ? 1.0 : -1.0, i & 2 ? 1.0 : -1.0) * texel).rgb;
        return float4(sum * 0.25, 1.0);
    }

    // A Gaussian blur along `step.xy`, nine taps.
    fragment float4 blurFragment(NoiseOut in [[stage_in]], constant PostParams& pp [[buffer(3)]], texture2d<float> source [[texture(0)]]) {
        constexpr sampler lin(coord::normalized, filter::linear, address::clamp_to_edge);
        float2 uv = in.position.xy * pp.step.zw;
        float2 texel = pp.step.xy / float2(source.get_width(), source.get_height());
        float w[5] = {0.227027, 0.1945946, 0.1216216, 0.054054, 0.016216};
        float3 sum = source.sample(lin, uv).rgb * w[0];
        for (int i = 1; i < 5; i++) {
            sum += source.sample(lin, uv + texel * float(i)).rgb * w[i];
            sum += source.sample(lin, uv - texel * float(i)).rgb * w[i];
        }
        return float4(sum, 1.0);
    }

    // How far along the view a screen position is: the nearest body there, else the floor, else nothing (very far).
    static float viewDistance(float2 uv, constant Uniforms& u, depth2d<float> depthMap) {
        constexpr sampler nearest(coord::normalized, filter::nearest, address::clamp_to_edge);
        float d = depthMap.sample(nearest, uv);
        float3 p;
        if (d < 1.0) {
            p = unproject(uv, d, u);
        } else {
            float3 a = unproject(uv, 0.0, u), b = unproject(uv, 1.0, u);
            float3 dir = b - a;
            if (abs(dir.z) < 1e-6) return 1e6;
            float t = -a.z / dir.z;
            if (t < 0.0) return 1e6;
            p = a + dir * t;
        }
        return dot(p - u.eye.xyz, normalize(u.viewDir.xyz));
    }

    // The picture made apart, with the finishing touches: blur for what is nearer or farther than the part, the glow
    // laid over it (screen blend, so it never goes past white) and darker corners.
    fragment FragOut compositeFragment(NoiseOut in [[stage_in]],
                                       constant Uniforms& u [[buffer(1)]],
                                       constant PostParams& pp [[buffer(3)]],
                                       texture2d<float> picture [[texture(0)]],
                                       texture2d<float> glowNear [[texture(1)]],
                                       texture2d<float> glowFar [[texture(2)]],
                                       depth2d<float> viewDepth [[texture(3)]]) {
        constexpr sampler lin(coord::normalized, filter::linear, address::clamp_to_edge);
        float2 uv = in.position.xy / u.viewport;
        float3 color = picture.sample(lin, uv).rgb;
        if (pp.effects.z > 0.005) {
            float maxRadius = pp.effects.z * 7.0 * pp.scene.y;
            float focus = pp.effects.w, span = max(pp.scene.x * 0.8, 1.0);
            float centerDistance = viewDistance(uv, u, viewDepth);
            float centerRadius = clamp(abs(centerDistance - focus) / span, 0.0, 1.0) * maxRadius;
            if (centerRadius > 0.4) {
                float turn = 6.2831853 * ign(in.position.xy);
                float3 sum = color;
                float weights = 1.0;
                for (int i = 0; i < 24; i++) {
                    float2 offset = vogelDisc(i, 24, turn) * centerRadius;
                    float2 tapUV = uv + offset / u.viewport;
                    float tapDistance = viewDistance(tapUV, u, viewDepth);
                    float tapRadius = clamp(abs(tapDistance - focus) / span, 0.0, 1.0) * maxRadius;
                    // A sharp thing in front of the blurred one does not smear over it, and a blurred thing reaches only as far as its blur.
                    float weight = (tapDistance < centerDistance && tapRadius < length(offset)) ? 0.0 : 1.0;
                    sum += picture.sample(lin, tapUV).rgb * weight;
                    weights += weight;
                }
                color = sum / weights;
            }
        }
        if (pp.effects.x > 0.0) {
            float3 glow = glowNear.sample(lin, uv).rgb * 0.7 + glowFar.sample(lin, uv).rgb * 0.9;
            color = 1.0 - (1.0 - color) * (1.0 - clamp(glow * pp.effects.x * 1.2, 0.0, 1.0));
        }
        if (pp.effects.y > 0.0) {
            float2 q = (uv - 0.5) * float2(u.viewport.x / u.viewport.y, 1.0);
            color *= 1.0 - pp.effects.y * 0.6 * smoothstep(0.3, 1.0, length(q) * 1.15);
        }
        FragOut o;
        o.color = float4(color, 1.0);
        o.id = 0;
        return o;
    }

    vertex ShadowOut shadowVertex(uint vid [[vertex_id]],
                                  device const FaceVertex* verts [[buffer(0)]],
                                  constant Uniforms& u [[buffer(1)]]) {
        ShadowOut o;
        o.position = u.lightViewProj * float4(float3(verts[vid].position), 1.0);
        return o;
    }

    fragment FragOut faceFragment(FaceOut in [[stage_in]],
                                  constant Uniforms& u [[buffer(1)]],
                                  constant uint* sel [[buffer(2)]],
                                  constant DrawParams& p [[buffer(3)]],
                                  depth2d<float> shadowMap [[texture(1)]],
                                  depth2d<float> viewDepth [[texture(3)]],
                                  depth2d<float> glassBack [[texture(4)]],
                                  texture2d<float> occlusionMap [[texture(5)]]) {
        if (u.clipOn != 0 && dot(in.world, u.clipPlane.xyz) - u.clipPlane.w > 1e-4) discard_fragment();
        bool render = u.renderParams.x > 0.5;
        float3 fn = facing(in.normal, in.world, u);
        float lit = render ? shadowVisibility(in.world, fn, u, shadowMap) : 1.0;
        float occlusion = 1.0;
        float4 refraction = float4(0.0);
        // Occlusion and contact shadows read the depth the camera sees, so they are left out of the mirrored view (the reflection).
        if (render && u.renderParams.z < 0.5 && u.evenLight == 0) {
            float2 uv = in.position.xy / u.viewport;
            if (p.material != 2u) {
                constexpr sampler nearestSampler(coord::normalized, filter::nearest, address::clamp_to_edge);
                if (u.look2.x > 0.0) occlusion = occlusionMap.sample(nearestSampler, uv).r;
                lit = min(lit, contactShadow(in.world, fn, in.position.xy, u, viewDepth));
            } else if (u.look1.x > 0.5 && u.look3.z > 0.0 && (p.style & 4096u) != 0u) {
                refraction = glassRefraction(in.world, fn, toViewer(in.world, u), uv, p.color.rgb, u, shadowMap, viewDepth, glassBack);
            }
        }
        return shadeFace(in.normal, in.world, in.id, false, 1e9, u, sel, p, lit, occlusion, refraction);
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
        if (in.id == u.hovered || isSelected(in.id, sel + u.selectedCount, u.hoverGroupCount)) alpha *= 2.0;
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
                gone.fade = 1.0;
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
                gone.fade = 1.0;
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
        bool fading = (p.style & 512u) != 0;
        float2 offset = (nrm * side + d * (fading ? 0.0 : (atB ? 1.0 : -1.0))) * thickness * 0.5;
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
        o.fade = fading ? float(atB ? (s.id >> 16) : (s.id & 0xFFFFu)) / 65535.0
                        : ((p.style & 1024u) != 0 ? (atB ? 1.0 : 0.0) : 1.0);
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
        float fade = (p.style & 1024u) != 0 ? smoothstep(0.0, 0.8, in.fade) : in.fade;
        o.color = float4(c.rgb, c.a * coverage * fade);
        o.id = p.pickable != 0 ? in.id : 0;
        return o;
    }
    """
}
