// The Render view: a solid floor and a light you set, to make the model ready for presentation.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import simd

/// What the Render view looks like: the floor, and the light. A view setting, kept between launches, not saved
/// in the part.
struct RenderSettings: Codable, Equatable {
    /// The colour of the floor (and, a little darker, of the backdrop it fades into).
    enum Floor: String, Codable, CaseIterable, Identifiable {
        case white, light, mid, charcoal, sand, slate
        var id: String { rawValue }

        var title: String {
            switch self {
            case .white: return "White"
            case .light: return "Silver"
            case .mid: return "Graphite"
            case .charcoal: return "Charcoal"
            case .sand: return "Sand"
            case .slate: return "Slate"
            }
        }

        var rgb: SIMD3<Float> {
            switch self {
            case .white: return SIMD3(0.97, 0.97, 0.97)
            case .light: return SIMD3(0.78, 0.79, 0.81)
            case .mid: return SIMD3(0.5, 0.51, 0.53)
            case .charcoal: return SIMD3(0.17, 0.175, 0.19)
            case .sand: return SIMD3(0.86, 0.8, 0.69)
            case .slate: return SIMD3(0.36, 0.45, 0.58)
            }
        }
    }

    /// Light settings to start from.
    enum Preset: String, CaseIterable, Identifiable {
        case studio, soft, dramatic
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    /// How much work the picture is worth: "Simple" is the fast everyday look; the others switch on, together, the
    /// settings of the Advanced tab that make it look photographed. Not stored: it is what the settings add up to.
    enum Quality: String, CaseIterable, Identifiable {
        case simple, realistic, photo
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var detail: String {
            switch self {
            case .simple: return "Fast. Flat light, soft shadows and a reflection."
            case .realistic: return "Physically based light, occlusion, contact shadows, a little glow."
            case .photo: return "Everything on and a little stronger. Slower; export is the best."
            }
        }
    }

    /// The room the shiny things reflect, and the light's colour. Made in the shader, not photographs.
    enum Environment: String, Codable, CaseIterable, Identifiable {
        case studio, lightTent, overcast, sunset, darkStudio
        var id: String { rawValue }
        var title: String {
            switch self {
            case .studio: return "Studio"
            case .lightTent: return "Light tent"
            case .overcast: return "Overcast"
            case .sunset: return "Sunset"
            case .darkStudio: return "Dark studio"
            }
        }

        struct Colors {
            var zenith, skyHorizon, groundHorizon, groundDown: SIMD3<Float>
            /// How bright the tall soft boxes round the room are, and the main light's reflection.
            var strips, key: Float
            /// The colour of the main light.
            var tint: SIMD3<Float>
        }

        var colors: Colors {
            switch self {
            case .studio:  // the colours the shader always had
                return Colors(zenith: SIMD3(1.05, 1.07, 1.1), skyHorizon: SIMD3(0.34, 0.37, 0.43), groundHorizon: SIMD3(0.62, 0.63, 0.65),
                              groundDown: SIMD3(0.2, 0.21, 0.24), strips: 1.5, key: 2.2, tint: SIMD3(1, 1, 1))
            case .lightTent:
                return Colors(zenith: SIMD3(1.3, 1.3, 1.32), skyHorizon: SIMD3(0.92, 0.92, 0.94), groundHorizon: SIMD3(0.85, 0.85, 0.86),
                              groundDown: SIMD3(0.5, 0.5, 0.52), strips: 0.5, key: 1.2, tint: SIMD3(1, 1, 1))
            case .overcast:
                return Colors(zenith: SIMD3(0.86, 0.9, 0.98), skyHorizon: SIMD3(0.62, 0.66, 0.72), groundHorizon: SIMD3(0.42, 0.4, 0.37),
                              groundDown: SIMD3(0.16, 0.15, 0.15), strips: 0, key: 0.4, tint: SIMD3(0.96, 0.98, 1))
            case .sunset:
                return Colors(zenith: SIMD3(0.28, 0.34, 0.56), skyHorizon: SIMD3(1.0, 0.56, 0.3), groundHorizon: SIMD3(0.4, 0.28, 0.24),
                              groundDown: SIMD3(0.1, 0.08, 0.09), strips: 0.3, key: 3.0, tint: SIMD3(1.0, 0.74, 0.52))
            case .darkStudio:
                return Colors(zenith: SIMD3(0.07, 0.08, 0.11), skyHorizon: SIMD3(0.05, 0.05, 0.07), groundHorizon: SIMD3(0.05, 0.05, 0.06),
                              groundDown: SIMD3(0.02, 0.02, 0.03), strips: 3.0, key: 3.0, tint: SIMD3(0.82, 0.9, 1))
            }
        }
    }

    /// How many pictures an exported render is made from, each a little to one side, averaged: smoother edges, and
    /// the soft effects (occlusion, soft shadows) lose their grain.
    enum ExportQuality: String, Codable, CaseIterable, Identifiable {
        case standard, high, maximum
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var frames: Int {
            switch self {
            case .standard: return 1
            case .high: return 16
            case .maximum: return 64
            }
        }
    }

    var floor = Floor.white
    /// The strength of the main light, about 0.2 to 1.5.
    var brightness: Double = 0.8
    /// Where the main light shines from: degrees around the part, from the X axis toward Y.
    var direction: Double = -100
    /// How high the main light stands, in degrees above the floor.
    var height: Double = 50
    /// The light that comes from everywhere, 0 to 1: it keeps the shadowed sides from going black.
    var ambient: Double = 0.5
    /// The body edges stay drawn (off: bodies are drawn as plain shapes, as in a picture).
    var showEdges = false
    /// A little grain over everything in the view (the backdrop, the floor and the bodies), 0 (none) to 1.
    var noise: Double = 0.1
    /// How much of the part shows in the floor, 0 (none) to 1.
    var reflection: Double = 0.35
    /// How blurred the reflection is, 0 (a mirror) to 1: it stays sharp where a body meets the floor and softens with height.
    var reflectionBlur: Double = 0.25
    /// Bodies cast shadows, and how soft their edges are, 0 (sharp) to 1.
    var shadows = true
    var softness: Double = 0.4

    // The quality settings (the Advanced tab). A `Quality` preset sets them all together.
    /// Light worked out in linear colour and shown through a filmic curve, with a rough-to-glossy finish on every body, a
    /// room that reflects in them and a softbox overhead. Off: the fast flat look.
    var physicalLight = false
    /// Brightness of the whole picture, in stops (-2 to +2).
    var exposure: Double = 0
    /// How glossy plain and wooden bodies are, 0 (matte) to 1 (polished). Needs physical light.
    var finish: Double = 0.5
    var environment = Environment.studio
    /// A big soft light overhead, 0 to 1. Needs physical light.
    var softbox: Double = 0
    /// Ambient occlusion: how dark the corners and gaps get (0 = off), and how far it reaches, as a part of the size of the model.
    var occlusion: Double = 0
    var occlusionRadius: Double = 0.5
    /// Short sharp shadows where bodies touch the floor and each other, 0 (off) to 1.
    var contactShadows: Double = 0
    /// Glow round the brightest parts, 0 to 1.
    var bloom: Double = 0
    /// Darker picture corners, 0 to 1.
    var vignette: Double = 0
    /// Blur in front of and behind the part, 0 (off) to 1. The part itself stays sharp. No quality preset sets it: it is off until
    /// it is turned on in the Advanced tab, where the sharp spot is chosen too.
    var depthOfField: Double = 0
    /// Glass bends what is behind it (the floor and the room), and thicker glass is darker.
    var refraction = false
    var exportQuality = ExportQuality.standard

    init() {}

    /// Settings kept by an older version lack the newer ones: those keep their defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RenderSettings()
        floor = try c.decodeIfPresent(Floor.self, forKey: .floor) ?? d.floor
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? d.brightness
        direction = try c.decodeIfPresent(Double.self, forKey: .direction) ?? d.direction
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? d.height
        ambient = try c.decodeIfPresent(Double.self, forKey: .ambient) ?? d.ambient
        showEdges = try c.decodeIfPresent(Bool.self, forKey: .showEdges) ?? d.showEdges
        noise = try c.decodeIfPresent(Double.self, forKey: .noise) ?? d.noise
        reflection = try c.decodeIfPresent(Double.self, forKey: .reflection) ?? d.reflection
        reflectionBlur = try c.decodeIfPresent(Double.self, forKey: .reflectionBlur) ?? d.reflectionBlur
        shadows = try c.decodeIfPresent(Bool.self, forKey: .shadows) ?? d.shadows
        softness = try c.decodeIfPresent(Double.self, forKey: .softness) ?? d.softness
        physicalLight = try c.decodeIfPresent(Bool.self, forKey: .physicalLight) ?? d.physicalLight
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? d.exposure
        finish = try c.decodeIfPresent(Double.self, forKey: .finish) ?? d.finish
        environment = try c.decodeIfPresent(Environment.self, forKey: .environment) ?? d.environment
        softbox = try c.decodeIfPresent(Double.self, forKey: .softbox) ?? d.softbox
        occlusion = try c.decodeIfPresent(Double.self, forKey: .occlusion) ?? d.occlusion
        occlusionRadius = try c.decodeIfPresent(Double.self, forKey: .occlusionRadius) ?? d.occlusionRadius
        contactShadows = try c.decodeIfPresent(Double.self, forKey: .contactShadows) ?? d.contactShadows
        bloom = try c.decodeIfPresent(Double.self, forKey: .bloom) ?? d.bloom
        vignette = try c.decodeIfPresent(Double.self, forKey: .vignette) ?? d.vignette
        depthOfField = try c.decodeIfPresent(Double.self, forKey: .depthOfField) ?? d.depthOfField
        refraction = try c.decodeIfPresent(Bool.self, forKey: .refraction) ?? d.refraction
        exportQuality = try c.decodeIfPresent(ExportQuality.self, forKey: .exportQuality) ?? d.exportQuality
    }

    mutating func apply(_ quality: Quality) {
        switch quality {
        case .simple:
            physicalLight = false; exposure = 0; finish = 0.5; softbox = 0; occlusion = 0; occlusionRadius = 0.5
            contactShadows = 0; bloom = 0; vignette = 0; refraction = false; exportQuality = .standard
        case .realistic:
            physicalLight = true; exposure = 0; finish = 0.5; softbox = 0.35; occlusion = 0.6; occlusionRadius = 0.5
            contactShadows = 0.6; bloom = 0.25; vignette = 0.2; refraction = true; exportQuality = .high
        case .photo:
            physicalLight = true; exposure = 0; finish = 0.6; softbox = 0.5; occlusion = 0.85; occlusionRadius = 0.6
            contactShadows = 0.8; bloom = 0.35; vignette = 0.3; refraction = true; exportQuality = .maximum
        }
    }

    /// The quality preset the settings are exactly at, if any (else they are the user's own: "Custom").
    var matchingQuality: Quality? {
        Quality.allCases.first { quality in
            var t = self
            t.apply(quality)
            return t.physicalLight == physicalLight && abs(t.exposure - exposure) < 0.01 && abs(t.finish - finish) < 0.01
                && abs(t.softbox - softbox) < 0.01 && abs(t.occlusion - occlusion) < 0.01
                && abs(t.occlusionRadius - occlusionRadius) < 0.01 && abs(t.contactShadows - contactShadows) < 0.01
                && abs(t.bloom - bloom) < 0.01 && abs(t.vignette - vignette) < 0.01
                && t.refraction == refraction && t.exportQuality == exportQuality
        }
    }

    /// Whether the picture is made in its own pass and then touched up (glow, blur, darker corners).
    var usesPostEffects: Bool { bloom > 0.005 || vignette > 0.005 || depthOfField > 0.005 }

    mutating func apply(_ preset: Preset) {
        switch preset {
        case .studio: brightness = 0.8; direction = -100; height = 50; ambient = 0.5; softness = 0.4
        case .soft: brightness = 0.5; direction = -100; height = 65; ambient = 0.7; softness = 0.85
        case .dramatic: brightness = 1.2; direction = -130; height = 25; ambient = 0.22; softness = 0.15
        }
    }

    /// The preset the light is exactly set to, if any (else it is the user's own: "Custom").
    var matchingPreset: Preset? {
        Preset.allCases.first { preset in
            var t = self
            t.apply(preset)
            // The softness of the shadows is the shadows' own setting: it is set by a preset but leaving it is not leaving the preset.
            return abs(t.brightness - brightness) < 0.005 && abs(t.direction - direction) < 0.5 && abs(t.height - height) < 0.5
                && abs(t.ambient - ambient) < 0.005
        }
    }

    /// The light's direction as a compass bearing seen from above, for the dial: 0° at the top (+Y), clockwise, 0 to 360.
    var bearing: Double {
        get { (90 - direction).truncatingRemainder(dividingBy: 360) + (90 - direction < 0 ? 360 : 0) }
        set {
            var d = (90 - newValue).truncatingRemainder(dividingBy: 360)
            if d > 180 { d -= 360 } else if d <= -180 { d += 360 }
            direction = d
        }
    }

    /// The way to the main light, as a unit vector (Z up).
    var lightDirection: SIMD3<Float> {
        let az = Float(direction * .pi / 180), el = Float(height * .pi / 180)
        return SIMD3(cos(el) * cos(az), cos(el) * sin(az), sin(el))
    }

    // The physical light's numbers, the same as the shader's (see physicalShade).
    static let keyScale: Float = 1.5
    static let fillScale: Float = 0.25
    static let ambientScale: Float = 0.28
    static let softboxScale: Float = 0.3

    /// sRGB to linear light and back (the gamma 2.2 the shader uses), and the filmic curve (see `display` in the shader).
    static func decode(_ c: SIMD3<Float>) -> SIMD3<Float> { SIMD3(pow(max(c.x, 0), 2.2), pow(max(c.y, 0), 2.2), pow(max(c.z, 0), 2.2)) }
    static func encode(_ c: SIMD3<Float>) -> SIMD3<Float> { SIMD3(pow(max(c.x, 0), 1 / 2.2), pow(max(c.y, 0), 1 / 2.2), pow(max(c.z, 0), 1 / 2.2)) }
    static func filmic(_ x: SIMD3<Float>) -> SIMD3<Float> {
        let a = simd_max(x, .zero)
        return simd_clamp((a * (2.51 * a + 0.03)) / (a * (2.43 * a + 0.59) + 0.14), .zero, SIMD3(repeating: 1))
    }
    /// What a linear colour looks like on the screen.
    func display(_ linear: SIMD3<Float>) -> SIMD3<Float> { Self.encode(Self.filmic(linear * exposureScale)) }
    var exposureScale: Float { Float(pow(2.0, exposure)) }

    /// How light the floor is, the same sum the shader makes for a face turned straight up (see shadeFace), with
    /// or without the main light (in a shadow it is left out).
    private func shade(mainLight: Bool) -> SIMD3<Float> {
        let l = lightDirection
        let across = simd_length(SIMD2(l.x, l.y))
        let fillUp: Float = across > 1e-4 ? 0.35 / (1 + 0.35 * 0.35).squareRoot() : 1  // the fill's Z, as the shader makes it
        if physicalLight {
            let c = environment.colors
            let sky = c.zenith * 0.8 + c.skyHorizon * 0.2
            let key = c.tint * (mainLight ? Float(brightness) * Self.keyScale * max(l.z, 0) : 0)
            let irradiance = key + SIMD3(repeating: Float(brightness) * Self.fillScale * fillUp)
                + sky * Float(ambient) * Self.ambientScale + SIMD3(repeating: Float(softbox) * Self.softboxScale)
            return display(Self.decode(floor.rgb) * irradiance)
        }
        let v = Float(ambient) + Float(brightness) * ((mainLight ? 0.7 * max(l.z, 0) : 0) + 0.3 * fillUp)
        return floor.rgb * v
    }

    /// The floor as it is lit, in a shadow, and the backdrop it fades into (a little darker, so the model sits in a pool of light).
    var floorColor: SIMD3<Float> { simd_clamp(shade(mainLight: true), SIMD3(repeating: 0), SIMD3(repeating: 1)) }
    var floorShadowColor: SIMD3<Float> { shadows ? simd_clamp(shade(mainLight: false), SIMD3(repeating: 0), SIMD3(repeating: 1)) : floorColor }
    var backdropColor: SIMD3<Float> { floorColor * 0.86 }

    /// How strongly the floor shows the part, as the opacity of the reflection at the foot of a body.
    var reflectionStrength: Float { Float(reflection) * 0.5 }
    /// How wide the light is, as the tangent of the angle it spans: a shadow's edge grows by this much for every mm of
    /// distance between the thing casting it and where it falls.
    var lightWidth: Float { 0.01 + 0.14 * Float(softness) }

    static let key = "renderSettings"

    /// What a new user starts with, and what Reset goes back to: the Realistic quality.
    static var fresh: RenderSettings {
        var s = RenderSettings()
        s.apply(.realistic)
        return s
    }

    static func load() -> RenderSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(RenderSettings.self, from: data) else { return fresh }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
