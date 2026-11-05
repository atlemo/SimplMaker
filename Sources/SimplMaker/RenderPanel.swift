// The Render view's options panel (Mac). The settings themselves are in RenderSettings.swift, which the iPad app shares.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import simd

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
            Button { model.renderSpinning.toggle() } label: {
                Label(model.renderSpinning ? "Pause turntable" : "Play turntable",
                      systemImage: model.renderSpinning ? "pause.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .help("Slowly turn the part around so every side comes into view")
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
