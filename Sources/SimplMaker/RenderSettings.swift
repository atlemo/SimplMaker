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
    }

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

/// The Render view's options, at the top left of the view while it is on: four groups (floor, lighting, shadows, display)
/// on one grid of label, control and value. Orange marks values and the selection, nothing else. A double-click on a
/// control puts it back to its default and Reset puts back all of them. The X hides the panel (the view stays on); the
/// Render button in the toolbar turns the view off.
struct RenderPanel: View {
    @Bindable var model: DocumentModel
    @Environment(\.accent) private var accent
    static let width: CGFloat = 324
    private let labelWidth: CGFloat = 90
    private let valueWidth: CGFloat = 44
    private let defaults = RenderSettings()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Spacing.space6) {
                HStack {
                    Text("Render").font(.headline)
                    Spacer()
                    Button("Reset") { model.renderSettings = RenderSettings() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(model.renderSettings == defaults)
                        .help("Put every render setting back to its default")
                    HeaderIconButton(systemImage: "xmark", help: "Close these options (the Render view stays on; View ▸ Render Options brings them back)") {
                        model.showRenderOptions = false
                    }
                }
                floorGroup
                Divider()
                lightingGroup
                Divider()
                shadowsGroup
                Divider()
                displayGroup
            }
            .padding(DS.Spacing.space6)
            Divider()
            VStack(alignment: .leading, spacing: DS.Spacing.space6) {
                Text("While rendering, the floor replaces the grid. Double-click any control to reset it.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Button { model.exportRender() } label: {
                    Label("Export render", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .help("Save what the view shows as a PNG picture")
            }
            .padding(DS.Spacing.space6)
        }
        .frame(width: Self.width)
        .panelGlass(in: .rect(cornerRadius: DS.Radius.window))
    }

    // MARK: groups

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

    private var displayGroup: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space5) {
            switchRow("Show edges", isOn: $model.renderSettings.showEdges, help: "Draw the lines along the edges of the bodies")
            sliderRow("Noise", value: $model.renderSettings.noise, range: 0...1, reset: defaults.noise, show: percent)
                .help("A little grain over the backdrop, the floor and the bodies")
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

/// The light presets as a segmented control. The selected one is plain to see; "Custom" is where the settings are once
/// one of the lights has been adjusted, and is not something to click.
private struct PresetPicker: View {
    let current: RenderSettings.Preset?
    let choose: (RenderSettings.Preset) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(RenderSettings.Preset.allCases) { preset in
                segment(preset.title, selected: current == preset) { choose(preset) }
            }
            segment("Custom", selected: current == nil, action: nil)
        }
        .padding(2)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: DS.Radius.lg))
        .overlay { RoundedRectangle(cornerRadius: DS.Radius.lg).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1) }
    }

    private func segment(_ title: String, selected: Bool, action: (() -> Void)?) -> some View {
        Text(title)
            .foregroundStyle(selected ? Color.primary : action == nil ? Color.secondary.opacity(0.6) : Color.primary.opacity(0.85))
            .frame(maxWidth: .infinity, minHeight: DS.ControlHeight.large)
            .background {
                if selected { RoundedRectangle(cornerRadius: DS.Radius.md).fill(Color.primary.opacity(0.2)) }
            }
            .contentShape(Rectangle())
            .onTapGesture { action?() }
            .accessibilityAddTraits(selected ? .isSelected : [])
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
