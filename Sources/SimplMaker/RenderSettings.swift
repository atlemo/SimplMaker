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

/// The Render view's options, at the top left of the view while it is on, in two tabs. Simple: the quality preset, the
/// floor, the room, the light and the shadows, and the export, everything an everyday render needs. Advanced: each of the
/// settings a quality preset sets, one by one. Orange marks values, the selection and the one main button (Export render). A double-click on a
/// control puts it back to its default and Reset puts back all of them. The X hides the panel (the view stays on); the
/// Render button in the toolbar turns the view off.
struct RenderPanel: View {
    @Bindable var model: DocumentModel
    @Environment(\.accent) private var accent
    static let width: CGFloat = 324
    private let labelWidth: CGFloat = 90
    private let valueWidth: CGFloat = 44
    private let defaults = RenderSettings()
    @State private var tab: Tab

    init(model: DocumentModel, tab: Tab = .simple) {
        _model = Bindable(model)
        _tab = State(initialValue: tab)
    }

    enum Tab: String, CaseIterable {
        case simple = "Simple", advanced = "Advanced"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Spacing.space6) {
                HStack {
                    Text("Render").font(.headline)
                    Spacer()
                    Button("Reset") { model.renderSettings = RenderSettings.fresh }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(model.renderSettings == RenderSettings.fresh)
                        .help("Put every render setting back to its default")
                    HeaderIconButton(systemImage: "xmark", help: "Close these options (the Render view stays on; View ▸ Render Options brings them back)") {
                        model.showRenderOptions = false
                    }
                }
                SegmentedRow(items: Tab.allCases.map { t in
                    SegmentedRow.Item(title: t.rawValue, selected: tab == t) { tab = t }
                })
            }
            .padding(.horizontal, DS.Spacing.space6)
            .padding(.top, DS.Spacing.space6)
            .padding(.bottom, DS.Spacing.space5)
            Divider()
            // Taller than the window: the tab scrolls.
            ViewThatFits(in: .vertical) {
                tabContent
                ScrollView { tabContent }.scrollBounceBehavior(.basedOnSize)
            }
        }
        .frame(width: Self.width)
        .panelGlass(in: .rect(cornerRadius: DS.Radius.window))
    }

    @ViewBuilder private var tabContent: some View {
        switch tab {
        case .simple: simpleTab
        case .advanced: advancedTab
        }
    }

    private var simpleTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Spacing.space6) {
                qualityGroup
                Divider()
                floorGroup
                Divider()
                lightingGroup
                Divider()
                shadowsGroup
                Divider()
                switchRow("Show edges", isOn: $model.renderSettings.showEdges, help: "Draw the lines along the edges of the bodies")
            }
            .padding(DS.Spacing.space6)
            Divider()
            exportGroup
                .padding(DS.Spacing.space6)
        }
    }

    private var advancedTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Spacing.space6) {
                Text("Each setting a quality preset sets, by itself. Change one and the preset becomes Custom.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                physicalGroup
                Divider()
                occlusionGroup
                Divider()
                cameraGroup
                Divider()
                glassGroup
            }
            .padding(DS.Spacing.space6)
            Divider()
            VStack(alignment: .leading, spacing: DS.Spacing.space6) {
                sliderRow("Noise", value: $model.renderSettings.noise, range: 0...1, reset: defaults.noise, show: percent)
                    .help("A little grain over the backdrop, the floor and the bodies")
                Text("Double-click any control to reset it.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            .padding(DS.Spacing.space6)
        }
    }

    // MARK: groups

    private var qualityGroup: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space5) {
            header("Quality", detail: model.renderSettings.matchingQuality?.title ?? "Custom")
            SegmentedRow(items: RenderSettings.Quality.allCases.map { q in
                SegmentedRow.Item(title: q.title, selected: model.renderSettings.matchingQuality == q) { model.renderSettings.apply(q) }
            } + [SegmentedRow.Item(title: "Custom", selected: model.renderSettings.matchingQuality == nil, action: nil)])
            Text(model.renderSettings.matchingQuality?.detail ?? "Your own mix of the Advanced settings.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var floorGroup: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space5) {
            header("Floor", detail: model.renderSettings.floor.title)
            HStack(spacing: DS.Spacing.space2) {
                ForEach(RenderSettings.Floor.allCases) { floor in
                    let c = floor.rgb
                    ColorSwatch(color: Color(.sRGB, red: Double(c.x), green: Double(c.y), blue: Double(c.z)),
                                name: floor.title, current: model.renderSettings.floor == floor) {
                        model.renderSettings.floor = floor
                    }
                    .help(floor.title)
                }
            }
            sliderRow("Reflection", value: $model.renderSettings.reflection, range: 0...1, reset: defaults.reflection, show: percent)
            sliderRow("Blur", value: $model.renderSettings.reflectionBlur, range: 0...1, reset: defaults.reflectionBlur, show: percent)
                .disabled(model.renderSettings.reflection == 0)
                .opacity(model.renderSettings.reflection == 0 ? DS.opacityDisabled : 1)
        }
    }

    private var lightingGroup: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space5) {
            header("Lighting")
            PresetPicker(current: model.renderSettings.matchingPreset) { model.renderSettings.apply($0) }
            row("Room") {
                Picker("Room", selection: $model.renderSettings.environment) {
                    ForEach(RenderSettings.Environment.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .help("The room that shiny bodies reflect, and the colour of the light")
            }
            row("Direction") {
                DirectionDial(bearing: $model.renderSettings.bearing, reset: defaults.bearing)
                Text("Drag to rotate").foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Text("\(Int(model.renderSettings.bearing.rounded()) % 360)°").monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: valueWidth, alignment: .trailing)
            }
            .help("Which way the main light shines from, seen from above (0° is the far side of the part)")
            sliderRow("Brightness", value: $model.renderSettings.brightness, range: 0.2...1.5, reset: defaults.brightness, show: percent)
            sliderRow("Height", value: $model.renderSettings.height, range: 5...90, reset: defaults.height) { "\(Int($0.rounded()))°" }
            sliderRow("Ambient", value: $model.renderSettings.ambient, range: 0...1, reset: defaults.ambient, show: percent)
        }
    }

    private var shadowsGroup: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space5) {
            HStack {
                header("Shadows")
                Spacer()
                Toggle("Shadows", isOn: $model.renderSettings.shadows)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .help("The bodies cast shadows on the floor and on each other")
            }
            sliderRow("Softness", value: $model.renderSettings.softness, range: 0...1, reset: defaults.softness, show: percent)
                .disabled(!model.renderSettings.shadows)
                .opacity(model.renderSettings.shadows ? 1 : DS.opacityDisabled)
        }
    }

    private var exportGroup: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space6) {
            Button { model.exportImageWithDialog() } label: {
                Label("Export render", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SolidAccentButtonStyle(accent: accent))
            .help("Save what the view shows as a picture, with or without the background")
            Text("While rendering, the floor replaces the grid. Double-click any control to reset it.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var physicalGroup: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space5) {
            switchRow("Physical light", isOn: $model.renderSettings.physicalLight,
                      help: "Light worked out as light, shown through a filmic curve: highlights roll off instead of clipping, every body has a finish and reflects the room")
            Group {
                sliderRow("Exposure", value: $model.renderSettings.exposure, range: -2...2, reset: defaults.exposure) {
                    String(format: "%+.1f", $0)
                }
                sliderRow("Finish", value: $model.renderSettings.finish, range: 0...1, reset: defaults.finish) {
                    $0 < 0.34 ? "Matte" : $0 < 0.67 ? "Satin" : "Gloss"
                }
                .help("How glossy plain and wooden bodies are")
                sliderRow("Softbox", value: $model.renderSettings.softbox, range: 0...1, reset: defaults.softbox, show: percent)
                    .help("A big soft light overhead, which also shows in shiny bodies")
            }
            .disabled(!model.renderSettings.physicalLight)
            .opacity(model.renderSettings.physicalLight ? 1 : DS.opacityDisabled)
        }
    }

    private var occlusionGroup: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space5) {
            header("Corners and contact")
            sliderRow("Occlusion", value: $model.renderSettings.occlusion, range: 0...1, reset: defaults.occlusion, show: percent)
                .help("Ambient occlusion: corners, gaps and the foot of the part get darker, as they do where light can hardly reach")
            sliderRow("Reach", value: $model.renderSettings.occlusionRadius, range: 0.1...1, reset: defaults.occlusionRadius, show: percent)
                .disabled(model.renderSettings.occlusion == 0)
                .opacity(model.renderSettings.occlusion == 0 ? DS.opacityDisabled : 1)
                .help("How far from a corner the darkening reaches")
            sliderRow("Contact", value: $model.renderSettings.contactShadows, range: 0...1, reset: defaults.contactShadows, show: percent)
                .help("Short, sharp shadows where bodies touch the floor and each other")
        }
    }

    private var cameraGroup: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space5) {
            header("Camera")
            sliderRow("Glow", value: $model.renderSettings.bloom, range: 0...1, reset: defaults.bloom, show: percent)
                .help("A soft glow round what is brighter than the floor")
            sliderRow("Vignette", value: $model.renderSettings.vignette, range: 0...1, reset: defaults.vignette, show: percent)
                .help("Darker corners of the picture")
            sliderRow("Depth blur", value: $model.renderSettings.depthOfField, range: 0...1, reset: defaults.depthOfField, show: percent)
                .help("Depth of field: what is at the focus point stays sharp, what is nearer and farther blurs. Not part of any quality preset")
            row("Focus") {
                Button(model.pickingRenderFocus ? "Click on the model…" : "Select focus point") { model.togglePickingRenderFocus() }
                    .help(model.pickingRenderFocus ? "Click the spot that should be sharp (Esc cancels)" : "Then click on the part: that spot is sharp, the rest blurs by its distance from it")
                Spacer(minLength: 0)
                if model.renderFocusPoint != nil {
                    Button("Auto") { model.setRenderFocus(nil) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Focus on the middle of the part again")
                }
            }
        }
    }

    private var glassGroup: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space5) {
            switchRow("Glass refraction", isOn: $model.renderSettings.refraction,
                      help: "Glass bends the floor and the room behind it, and thicker glass is darker. Needs physical light")
                .disabled(!model.renderSettings.physicalLight)
                .opacity(model.renderSettings.physicalLight ? 1 : DS.opacityDisabled)
        }
    }

    // MARK: pieces

    private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    /// A group's name, quieter than the controls under it, and optionally what is chosen in it.
    private func header(_ title: String, detail: String? = nil) -> some View {
        HStack {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            if let detail {
                Spacer()
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    /// One row of the grid: the label column, then whatever the control needs.
    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: DS.Spacing.space4) {
            Text(title).frame(width: labelWidth, alignment: .leading)
            content()
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, reset: Double,
                           show: @escaping (Double) -> String) -> some View {
        row(title) {
            Slider(value: value, in: range).tint(accent)
            Text(show(value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: valueWidth, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture(count: 2).onEnded { value.wrappedValue = reset })
    }

    private func switchRow(_ title: String, isOn: Binding<Bool>, help: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch)
        }
        .help(help)
    }
}

/// A row of segments, one selected: the tabs and the presets. A segment without an action ("Custom") only shows where the
/// settings are, and is not something to click.
private struct SegmentedRow: View {
    struct Item {
        var title: String
        var selected: Bool
        var action: (() -> Void)?
    }
    let items: [Item]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in segment(item) }
        }
        .padding(2)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: DS.Radius.lg))
        .overlay { RoundedRectangle(cornerRadius: DS.Radius.lg).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1) }
    }

    private func segment(_ item: Item) -> some View {
        Text(item.title)
            .lineLimit(1)
            .foregroundStyle(item.selected ? Color.primary : item.action == nil ? Color.secondary.opacity(0.6) : Color.primary.opacity(0.85))
            .frame(maxWidth: .infinity, minHeight: DS.ControlHeight.large)
            .background {
                if item.selected { RoundedRectangle(cornerRadius: DS.Radius.md).fill(Color.primary.opacity(0.2)) }
            }
            .contentShape(Rectangle())
            .onTapGesture { item.action?() }
            .accessibilityAddTraits(item.selected ? .isSelected : [])
    }
}

/// The light presets as a segmented control. The selected one is plain to see; "Custom" is where the settings are once
/// one of the lights has been adjusted, and is not something to click.
private struct PresetPicker: View {
    let current: RenderSettings.Preset?
    let choose: (RenderSettings.Preset) -> Void

    var body: some View {
        SegmentedRow(items: RenderSettings.Preset.allCases.map { preset in
            SegmentedRow.Item(title: preset.title, selected: current == preset) { choose(preset) }
        } + [SegmentedRow.Item(title: "Custom", selected: current == nil, action: nil)])
    }
}

/// An angle as a dial, for the light's direction: 0° at the top, clockwise, as seen from above. Drag it round.
private struct DirectionDial: View {
    @Binding var bearing: Double
    let reset: Double
    @Environment(\.accent) private var accent
    private let size: CGFloat = 34

    var body: some View {
        let radius = size / 2 - 7
        let a = bearing * .pi / 180
        let dot = CGPoint(x: size / 2 + radius * sin(a), y: size / 2 - radius * cos(a))
        ZStack {
            Circle().strokeBorder(Color.primary.opacity(0.3), lineWidth: 1)
            Path { p in
                p.move(to: CGPoint(x: size / 2, y: size / 2))
                p.addLine(to: dot)
            }
            .stroke(Color.primary.opacity(0.45), lineWidth: 1.5)
            Circle().fill(accent).frame(width: 7, height: 7).position(dot)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            let dx = g.location.x - size / 2, dy = g.location.y - size / 2
            guard hypot(dx, dy) > 2 else { return }
            let b = atan2(dx, -dy) * 180 / .pi
            bearing = b < 0 ? b + 360 : b
        })
        .simultaneousGesture(TapGesture(count: 2).onEnded { bearing = reset })
        .accessibilityLabel("Light direction")
        .accessibilityValue("\(Int(bearing.rounded())) degrees")
    }
}


/// The panel's one main button: solid in the accent colour with white text.
private struct SolidAccentButtonStyle: ButtonStyle {
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.vertical, DS.Spacing.space4)
            .background(RoundedRectangle(cornerRadius: DS.Radius.lg).fill(accent))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
    }
}
