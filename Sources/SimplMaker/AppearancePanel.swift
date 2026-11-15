// The Appearance panel: gives bodies, or single faces of them, colours and materials. Opens with A, or View ▸ Show Appearance.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
#if os(macOS)
import AppKit
#endif
import CADCore
import SwiftUI

extension BodyColor {
    var color: Color {
        let c = components
        return Color(.sRGB, red: c.red, green: c.green, blue: c.blue)
    }

    /// The nearest 8-bit sRGB colour to a SwiftUI colour.
    init?(_ color: Color) {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        self.init(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent))
    }

}

/// A ready-made colour in the Appearance panel.
struct ColorPreset: Identifiable {
    let name: String
    let color: BodyColor
    var id: String { name }

    init(_ name: String, _ hex: String) {
        self.name = name
        color = BodyColor(hex: hex) ?? BodyColor(red: 0.5, green: 0.5, blue: 0.5)
    }

    /// Metals and wood first, then plain colours.
    static let all: [ColorPreset] = [
        ColorPreset("Aluminium", "#C9CDD2"), ColorPreset("Steel", "#8E959C"), ColorPreset("Graphite", "#4A4F55"),
        ColorPreset("Brass", "#C9A65A"), ColorPreset("Copper", "#C07A4F"), ColorPreset("Wood", "#B5834F"),
        ColorPreset("White", "#F2F2F0"), ColorPreset("Black", "#2A2A2C"), ColorPreset("Red", "#D23B30"),
        ColorPreset("Orange", "#E8812A"), ColorPreset("Yellow", "#E9C53A"), ColorPreset("Green", "#4CA35A"),
        ColorPreset("Teal", "#2F9C9A"), ColorPreset("Blue", "#3A78D0"), ColorPreset("Navy", "#2A3F7A"),
        ColorPreset("Purple", "#8A55C4"), ColorPreset("Pink", "#E07AA8"),
    ]
}

struct AppearancePanel: View {
    let model: DocumentModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accent) private var accent
    /// A custom colour being picked: shown on the bodies at once, kept (one undo step) once the
    /// picking pauses, so dragging round the colour wheel doesn't fill the undo list.
    @State private var pending: PendingColor?

    struct PendingColor: Equatable {
        var color: BodyColor
        var bodies: [FeatureID]
        /// Set when the colour is for faces (the panel's Faces mode), and `bodies` is empty.
        var faces: [FaceRef] = []
    }

    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: DS.Spacing.space2), count: 6) }

    private var targets: [FeatureID] { model.appearanceTargets }
    private var faceTargets: [FaceRef] { model.appearanceFaces }
    /// The panel is changing single faces, not whole bodies.
    private var isFaces: Bool { model.appearanceMode == .faces }
    private var hasTargets: Bool { isFaces ? !faceTargets.isEmpty : !targets.isEmpty }

    /// The viewport's own body colour, for the Default swatch.
    private var defaultColor: Color {
        let f = ViewportPalette.make(dark: colorScheme == .dark, increaseContrast: false).face
        return Color(.sRGB, red: Double(f.x), green: Double(f.y), blue: Double(f.z))
    }

    var body: some View {
        // A sidebar list, as the Parameters panel is, so that it opens and folds the same way: each part is a row.
        List {
            SegmentedPicker(selection: Binding(get: { model.appearanceMode }, set: { switchMode(to: $0) }),
                            options: [.bodies, .faces]) { $0 == .bodies ? "Bodies" : "Faces" }
                .help("Colour and material for whole bodies, or for single faces of them")
                .panelRow()
            Text(targetText)
                .font(.callout)
                .foregroundStyle(hasTargets ? .primary : .secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .panelRow()
            Group {
                LazyVGrid(columns: columns, spacing: DS.Spacing.space2) {
                    ColorSwatch(color: isFaces ? (faceTargets.first.flatMap { model.displayColor(of: $0.body)?.color } ?? defaultColor) : defaultColor,
                                name: isFaces ? "Same as body" : "Default", current: isCurrent(nil), isDefault: true) { apply(nil) }
                    ForEach(ColorPreset.all) { p in
                        ColorSwatch(color: p.color.color, name: p.name, current: isCurrent(p.color)) { apply(p.color) }
                    }
                }
                .panelRow()
                HStack(alignment: .center) {
                    // The label is our own text, so it and the colour well share one centre line (the picker's own label sits on a baseline).
                    Text("Custom Colour")
                    Spacer()
                    ColorPicker("Custom Colour", selection: customColor, supportsOpacity: false)
                        .labelsHidden()
                        .help(isFaces ? "Pick any colour for the selected faces" : "Pick any colour for the selected bodies")
                    if let c = sharedColor {
                        Text(c.hex).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                .panelRow()
                materialRow.panelRow()
                if isFaces {
                    if faceTargets.contains(where: { model.ownLook(of: $0) != nil }) {
                        Button("Same as Body") { model.resetFaces(faceTargets) }
                            .help("Take the colour and material of the selected faces away: they look like their body again")
                            .panelRow()
                    }
                } else {
                    opacityRow.panelRow()
                }
            }
            .disabled(!hasTargets)
            if isFaces { faceSummary.panelRow() } else { bodyList.panelRow() }
        }
        .listStyle(.sidebar)
        .panelListTop()
        .task(id: pending) {
            guard let p = pending else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            commit(p)
        }
        .onDisappear { if let p = pending { commit(p) } }
        .onChange(of: model.showAppearance) { _, open in if !open, let p = pending { commit(p) } }  // folded: keep what is picked
    }

    /// Plain, metal, glass or wood for the selected bodies. Materials show in the Render view.
    private var materialRow: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space2) {
            Text("Material").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: DS.Spacing.space2) {
                MaterialTile(material: nil, baseColor: sharedColor?.color ?? defaultColor, current: isCurrentMaterial(nil)) { setMaterial(nil) }
                ForEach(BodyMaterial.allCases, id: \.self) { m in
                    MaterialTile(material: m, baseColor: sharedColor?.color ?? defaultColor, current: isCurrentMaterial(m)) { setMaterial(m) }
                }
            }
            if isFaces ? faceTargets.contains(where: { model.displayRoughness(of: $0) != nil })
                       : targets.contains(where: { model.displayMaterial(of: $0)?.hasRoughness == true }) {
                roughnessRow
            }
            Text("Materials show in the Render view.").font(.caption).foregroundStyle(.tertiary)
        }
    }

    /// How rough the selected plastic or metal bodies are. The Render view follows the slider while it is dragged; letting go is one undo step.
    private var roughnessRow: some View {
        let rough = targets.filter { model.displayMaterial(of: $0)?.hasRoughness == true }
        let roughFaces = faceTargets.filter { model.displayRoughness(of: $0) != nil }
        let shown = (isFaces ? roughFaces.first.flatMap { model.displayRoughness(of: $0) } : rough.first.flatMap { model.displayRoughness(of: $0) }) ?? 0.35
        return HStack(spacing: DS.Spacing.space4) {
            Text("Roughness").font(.callout)
            Slider(value: Binding(get: { shown }, set: { value in
                if isFaces { model.previewFaceRoughness(value, of: roughFaces) } else { model.previewBodyRoughness(value, of: rough) }
            }), in: 0...1) { editing in
                guard !editing else { return }
                if isFaces {
                    if let p = model.faceRoughnessPreview { model.setFaceRoughness(p.roughness, of: roughFaces) }
                } else if let p = model.roughnessPreview {
                    model.setBodyRoughness(p.roughness, of: rough)
                }
            }
            .tint(accent)
            Text(shown < 0.25 ? "Glossy" : shown < 0.65 ? "Satin" : "Matte")
                .font(.caption).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
        }
        .padding(.top, DS.Spacing.space2)
        .help("From a glossy, polished surface to a matte one. Double-click to go back to the material's own")
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if isFaces { model.setFaceRoughness(nil, of: roughFaces) } else { model.setBodyRoughness(nil, of: rough) }
        })
    }

    /// How see-through the selected bodies are in the normal view, to look at what is inside or behind them. The view follows the
    /// slider while it is dragged; letting go is one undo step. Double-click goes back to solid.
    private var opacityRow: some View {
        let shown = targets.first.map { model.displayOpacity(of: $0) } ?? 1
        return VStack(alignment: .leading, spacing: DS.Spacing.space2) {
            HStack(spacing: DS.Spacing.space4) {
                Text("Opacity").font(.callout)
                Slider(value: Binding(get: { shown }, set: { model.previewBodyOpacity($0, of: targets) }),
                       in: DocumentModel.minimumOpacity...1) { editing in
                    if !editing, let p = model.opacityPreview { model.setBodyOpacity(p.opacity, of: targets) }
                }
                .tint(accent)
                Text("\(Int((shown * 100).rounded()))%")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
            }
            Text("Lower it to see through a body, in the normal view and the Render view. For clear, tinted glass pick the Glass material.").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.top, DS.Spacing.space2)
        .help("Double-click to make the bodies solid again")
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.setBodyOpacity(nil, of: targets) })
    }

    /// Whether every selected body has this material (nil = plain).
    private func isCurrentMaterial(_ material: BodyMaterial?) -> Bool {
        if isFaces { return !faceTargets.isEmpty && faceTargets.allSatisfy { model.displayMaterial(of: $0) == material } }
        return !targets.isEmpty && targets.allSatisfy { model.displayMaterial(of: $0) == material }
    }

    private func setMaterial(_ material: BodyMaterial?) {
        if isFaces { model.setFaceMaterial(material, of: faceTargets) } else { model.setBodyMaterial(material, of: targets) }
    }

    /// Changes between bodies and faces; a colour still being picked is kept for what it was picked for first.
    private func switchMode(to mode: DocumentModel.AppearanceMode) {
        if let p = pending { commit(p) }
        model.appearanceMode = mode
    }

    /// Faces mode's list: what to do, and the faces that already have a look of their own.
    private var faceSummary: some View {
        let painted = model.facesWithOwnLook
        return VStack(alignment: .leading, spacing: DS.Spacing.space2) {
            Text("Faces").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Text("Click a face in the view. ⇧- or ⌘-click adds more faces.").font(.callout).foregroundStyle(.tertiary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if !painted.isEmpty {
                HStack {
                    Text(painted.count == 1 ? "1 face has its own look" : "\(painted.count) faces have their own look").font(.callout)
                    Spacer()
                    Button("Reset All") { model.resetFaces(painted) }
                        .help("Every face looks like its body again")
                }
            }
        }
    }

    /// Every body, to select from without hunting for it in the view. ⇧- or ⌘-click adds to the selection.
    private var bodyList: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space2) {
            Text("Bodies").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            if model.bodies.isEmpty {
                Text("No bodies yet").font(.callout).foregroundStyle(.tertiary)
            }
            VStack(spacing: DS.Spacing.space1) {
                ForEach(model.bodies) { b in
                    AppearanceBodyRow(name: b.name, color: model.displayColor(of: b.id)?.color ?? defaultColor,
                                      selected: targets.contains(b.id), hidden: model.isHidden(b.id), action: {
                        let flags = NSEvent.modifierFlags
                        model.selectBody(b.id, additive: flags.contains(.shift) || flags.contains(.command))
                    }, toggleHidden: { model.setHidden([b.id], !model.isHidden(b.id)) })
                }
            }
        }
    }

    private var targetText: String {
        if isFaces {
            guard !faceTargets.isEmpty else { return "Select faces in the view, then pick a colour or a material." }
            let bodyNames = model.bodies.filter { b in faceTargets.contains { $0.body == b.id } }.map(\.name)
            let count = faceTargets.count == 1 ? "1 face" : "\(faceTargets.count) faces"
            return "Colour of " + count + " on " + ListFormatter.localizedString(byJoining: bodyNames)
        }
        guard !targets.isEmpty else { return "Select bodies in the view or in the list below, then pick a colour." }
        let names = model.bodies.filter { targets.contains($0.id) }.map(\.name)
        return "Colour of " + ListFormatter.localizedString(byJoining: names)
    }

    /// The colour every selected body has (nil if they differ or have none).
    private var sharedColor: BodyColor? {
        if isFaces {
            guard let first = faceTargets.first.flatMap({ model.displayColor(of: $0) }) else { return nil }
            return isCurrent(first) ? first : nil
        }
        guard let first = targets.first.flatMap({ model.displayColor(of: $0) }) else { return nil }
        return isCurrent(first) ? first : nil
    }

    /// Whether every selected body has this colour (nil = the default).
    private func isCurrent(_ color: BodyColor?) -> Bool {
        if isFaces {
            // The first swatch stands for "like the body": a face with no colour of its own.
            if color == nil { return !faceTargets.isEmpty && faceTargets.allSatisfy { model.ownLook(of: $0)?.color == nil } }
            return !faceTargets.isEmpty && faceTargets.allSatisfy { model.displayColor(of: $0) == color }
        }
        return !targets.isEmpty && targets.allSatisfy { model.displayColor(of: $0) == color }
    }

    private var customColor: Binding<Color> {
        Binding(get: { sharedColor?.color ?? defaultColor },
                set: { new in
                    guard let c = BodyColor(new) else { return }
                    if isFaces {
                        let faces = faceTargets
                        guard !faces.isEmpty else { return }
                        model.previewFaceColor(c, of: faces)
                        pending = PendingColor(color: c, bodies: [], faces: faces)
                        return
                    }
                    let ids = targets
                    guard !ids.isEmpty else { return }
                    model.previewBodyColor(c, of: ids)
                    pending = PendingColor(color: c, bodies: ids)
                })
    }

    private func apply(_ color: BodyColor?) {
        if let p = pending { commit(p) }
        if isFaces { model.setFaceColor(color, of: faceTargets) } else { model.setBodyColor(color, of: targets) }
    }

    private func commit(_ p: PendingColor) {
        pending = nil
        if p.faces.isEmpty { model.setBodyColor(p.color, of: p.bodies) } else { model.setFaceColor(p.color, of: p.faces) }
    }
}

/// One colour to pick: a round swatch, ringed when the selected bodies have it.
struct ColorSwatch: View {
    @Environment(\.accent) private var accent
    let color: Color
    let name: String
    let current: Bool
    var isDefault = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .overlay { Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 1) }
                .overlay {
                    if isDefault {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.black.opacity(0.55))
                    }
                }
                .padding(3)
                .overlay {
                    Circle().strokeBorder(current ? accent : hovering && isEnabled ? Color.primary.opacity(0.3) : .clear,
                                          lineWidth: 2)
                }
                .frame(width: 30, height: 30)
                .contentShape(Circle())
                .opacity(isEnabled ? 1 : DS.opacityDisabled)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: DS.Duration.instant), value: hovering)
        .help(isDefault && name == "Default" ? "Default colour" : name)
        .accessibilityLabel(isDefault && name == "Default" ? "Default colour" : name)
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}

private extension Color {
    /// This colour moved part of the way toward another (macOS 14 has no Color.mix).
    func shifted(toward other: NSColor, by fraction: Double) -> Color {
        guard let c = NSColor(self).usingColorSpace(.sRGB),
              let m = c.blended(withFraction: fraction, of: other) else { return self }
        return Color(nsColor: m)
    }
}

/// One material to pick: a small picture of it in the body's colour, ringed when the selected bodies have it.
struct MaterialTile: View {
    @Environment(\.accent) private var accent
    let material: BodyMaterial?
    let baseColor: Color
    let current: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    private var name: String {
        switch material {
        case nil: "Plain"
        case .plastic: "Plastic"
        case .metal: "Metal"
        case .glass: "Glass"
        case .wood: "Wood"
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                preview
                    .frame(height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.18), lineWidth: 1) }
                    .padding(2)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(current ? accent : hovering && isEnabled ? Color.primary.opacity(0.3) : .clear, lineWidth: 2)
                    }
                Text(name).font(.caption)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : DS.opacityDisabled)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: DS.Duration.instant), value: hovering)
        .help(material == nil ? "Plain colour" : name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(current ? .isSelected : [])
    }

    @ViewBuilder private var preview: some View {
        switch material {
        case nil:
            baseColor
        case .plastic:
            ZStack {
                baseColor
                // A soft glossy highlight and a darker underside, as on a moulded part.
                LinearGradient(colors: [.clear, .black.opacity(0.22)], startPoint: .center, endPoint: .bottom)
                Ellipse().fill(.white.opacity(0.7)).frame(width: 18, height: 7).blur(radius: 2.5).offset(x: -6, y: -8)
            }
        case .metal:
            LinearGradient(stops: [.init(color: baseColor.shifted(toward: NSColor.white, by: 0.55), location: 0),
                                   .init(color: baseColor, location: 0.35),
                                   .init(color: baseColor.shifted(toward: NSColor.black, by: 0.45), location: 0.55),
                                   .init(color: baseColor.shifted(toward: NSColor.white, by: 0.3), location: 0.8),
                                   .init(color: baseColor.shifted(toward: NSColor.black, by: 0.2), location: 1)],
                           startPoint: .top, endPoint: .bottom)
        case .glass:
            ZStack {
                Color.primary.opacity(0.06)
                baseColor.opacity(0.45)
                LinearGradient(colors: [.white.opacity(0.85), .white.opacity(0)], startPoint: .topLeading, endPoint: .center)
            }
        case .wood:
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(baseColor))
                for i in 0..<9 {
                    let y = size.height * (CGFloat(i) + 0.5) / 9
                    var line = Path()
                    line.move(to: CGPoint(x: 0, y: y))
                    line.addCurve(to: CGPoint(x: size.width, y: y + (i % 2 == 0 ? 2 : -2)),
                                  control1: CGPoint(x: size.width * 0.3, y: y - 3), control2: CGPoint(x: size.width * 0.7, y: y + 3))
                    context.stroke(line, with: .color(.black.opacity(0.18)), lineWidth: 1)
                }
            }
        }
    }
}

/// A body in the Appearance panel: its colour and name (a click selects it) and an eye that shows or hides it. The eye of a
/// hidden body is always there; a shown body's appears while the pointer is over the row.
struct AppearanceBodyRow: View {
    @Environment(\.accent) private var accent
    let name: String
    let color: Color
    let selected: Bool
    let hidden: Bool
    let action: () -> Void
    let toggleHidden: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: DS.Spacing.labelGap) {
            Button(action: action) {
                HStack(spacing: DS.Spacing.labelGap) {
                    Circle()
                        .fill(color)
                        .overlay { Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1) }
                        .frame(width: 14, height: 14)
                    Text(name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(hidden ? .secondary : .primary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if hidden || hovering {
                Button(action: toggleHidden) {
                    Image(systemName: hidden ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                        .frame(width: PanelTouch.rowButtonWidth, height: DS.ControlHeight.sidebarRow)  // the header's button column
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(hidden ? "Show this body" : "Hide this body")
                .accessibilityLabel(hidden ? "Show" : "Hide")  // the eye symbol's own name is always "Show"
            }
        }
        .padding(.leading, DS.Spacing.space3)
        .padding(.trailing, DS.Spacing.space2)
        .frame(height: DS.ControlHeight.sidebarRow)
        .background(selected ? accent.opacity(0.18) : hovering ? Color.primary.opacity(0.07) : .clear,
                    in: RoundedRectangle(cornerRadius: DS.Radius.sidebarItem, style: .continuous))
        // The eye is in the same column as the Browser's, under the header's collapse arrow: the row reaches as far as
        // the header's own inset, and the pill a little beyond the eye (the padding above).
        .padding(.trailing, -(PanelTouch.rowTrailingBleed + DS.Spacing.space2))
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private extension View {
    /// One part of the Appearance list: no row background or separator, the list's own inset.
    func panelRow() -> some View {
        listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .panelRowInsets()
    }
}
