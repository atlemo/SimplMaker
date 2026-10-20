// The Render view: a solid floor and a light you set, to make the model ready for presentation.
// Copyright © 2026 Atle Mo. All rights reserved.
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
            case .light: return "Light Grey"
            case .mid: return "Grey"
            case .charcoal: return "Charcoal"
            case .sand: return "Sand"
            case .slate: return "Slate Blue"
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
    /// How much of the part shows in the floor, 0 (none) to 1.
    var reflection: Double = 0.35
    /// How blurred the reflection is, 0 (a mirror) to 1: it stays sharp where a body meets the floor and softens with height.
    var reflectionBlur: Double = 0.25
    /// Bodies cast shadows, and how soft their edges are, 0 (sharp) to 1.
    var shadows = true
    var softness: Double = 0.4

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
        reflection = try c.decodeIfPresent(Double.self, forKey: .reflection) ?? d.reflection
        reflectionBlur = try c.decodeIfPresent(Double.self, forKey: .reflectionBlur) ?? d.reflectionBlur
        shadows = try c.decodeIfPresent(Bool.self, forKey: .shadows) ?? d.shadows
        softness = try c.decodeIfPresent(Double.self, forKey: .softness) ?? d.softness
    }

    mutating func apply(_ preset: Preset) {
        switch preset {
        case .studio: brightness = 0.8; direction = -100; height = 50; ambient = 0.5; softness = 0.4
        case .soft: brightness = 0.5; direction = -100; height = 65; ambient = 0.7; softness = 0.85
        case .dramatic: brightness = 1.2; direction = -130; height = 25; ambient = 0.22; softness = 0.15
        }
    }

    /// The way to the main light, as a unit vector (Z up).
    var lightDirection: SIMD3<Float> {
        let az = Float(direction * .pi / 180), el = Float(height * .pi / 180)
        return SIMD3(cos(el) * cos(az), cos(el) * sin(az), sin(el))
    }

    /// How light the floor is, the same sum the shader makes for a face turned straight up (see shadeFace), with
    /// or without the main light (in a shadow it is left out).
    private func shade(mainLight: Bool) -> Float {
        let l = lightDirection
        let across = simd_length(SIMD2(l.x, l.y))
        let fillUp: Float = across > 1e-4 ? 0.35 / (1 + 0.35 * 0.35).squareRoot() : 1  // the fill's Z, as the shader makes it
        return Float(ambient) + Float(brightness) * ((mainLight ? 0.7 * max(l.z, 0) : 0) + 0.3 * fillUp)
    }
    var floorShade: Float { shade(mainLight: true) }

    /// The floor as it is lit, in a shadow, and the backdrop it fades into (a little darker, so the model sits in a pool of light).
    var floorColor: SIMD3<Float> { simd_clamp(floor.rgb * floorShade, SIMD3(repeating: 0), SIMD3(repeating: 1)) }
    var floorShadowColor: SIMD3<Float> { shadows ? simd_clamp(floor.rgb * shade(mainLight: false), SIMD3(repeating: 0), SIMD3(repeating: 1)) : floorColor }
    var backdropColor: SIMD3<Float> { floorColor * 0.86 }

    /// How strongly the floor shows the part, as the opacity of the reflection at the foot of a body.
    var reflectionStrength: Float { Float(reflection) * 0.5 }
    /// How wide the light is, as the tangent of the angle it spans: a shadow's edge grows by this much for every mm of
    /// distance between the thing casting it and where it falls.
    var lightWidth: Float { 0.01 + 0.14 * Float(softness) }

    static let key = "renderSettings"

    static func load() -> RenderSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(RenderSettings.self, from: data) else { return RenderSettings() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// The Render view's options, at the top left of the view while it is on.
struct RenderPanel: View {
    @Bindable var model: DocumentModel
    static let width: CGFloat = 270

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space5) {
            HStack {
                Text("Render").font(.headline)
                Spacer()
                HeaderIconButton(systemImage: "xmark", help: "Close these options (the render view stays on)") { model.showRenderOptions = false }
            }
            VStack(alignment: .leading, spacing: DS.Spacing.space2) {
                Text("Floor").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
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
                slider("Reflection", value: $model.renderSettings.reflection, range: 0...1)
                slider("Blur", value: $model.renderSettings.reflectionBlur, range: 0...1)
                    .disabled(model.renderSettings.reflection == 0)
            }
            VStack(alignment: .leading, spacing: DS.Spacing.space2) {
                Text("Light").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                HStack(spacing: DS.Spacing.space2) {
                    ForEach(RenderSettings.Preset.allCases) { preset in
                        Button(preset.title) { model.renderSettings.apply(preset) }
                            .controlSize(.small)
                    }
                }
                slider("Brightness", value: $model.renderSettings.brightness, range: 0.2...1.5)
                slider("Direction", value: $model.renderSettings.direction, range: -180...180, unit: "°")
                slider("Height", value: $model.renderSettings.height, range: 5...90, unit: "°")
                slider("Ambient", value: $model.renderSettings.ambient, range: 0...1)
                Toggle("Shadows", isOn: $model.renderSettings.shadows)
                    .toggleStyle(.switch)
                    .help("The bodies cast shadows on the floor and on each other")
                slider("Softness", value: $model.renderSettings.softness, range: 0...1)
                    .disabled(!model.renderSettings.shadows)
            }
            Toggle("Show edges", isOn: $model.renderSettings.showEdges)
                .toggleStyle(.switch)
                .help("Draw the lines along the edges of the bodies")
            Text("The grid is replaced by a floor. Turn the view off with the Render button.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Spacing.space6)
        .frame(width: Self.width)
        .panelGlass(in: .rect(cornerRadius: DS.Radius.window))
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String = "") -> some View {
        HStack {
            Text(title).font(.callout).frame(width: 78, alignment: .leading)
            Slider(value: value, in: range)
                .controlSize(.small)
        }
        .help(unit.isEmpty ? title : "\(title): \(Int(value.wrappedValue.rounded()))\(unit)")
    }
}
