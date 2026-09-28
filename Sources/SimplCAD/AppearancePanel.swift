// The Appearance panel: gives bodies colours. Opens with A, or View ▸ Show Appearance.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
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
    /// A custom colour being picked: shown on the bodies at once, kept (one undo step) once the
    /// picking pauses, so dragging round the colour wheel doesn't fill the undo list.
    @State private var pending: PendingColor?

    struct PendingColor: Equatable {
        var color: BodyColor
        var bodies: [FeatureID]
    }

    static let width: CGFloat = 244
    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: DS.Spacing.space2), count: 6) }

    private var targets: [FeatureID] { model.appearanceTargets }

    /// The viewport's own body colour, for the Default swatch.
    private var defaultColor: Color {
        let f = ViewportPalette.make(dark: colorScheme == .dark, increaseContrast: false).face
        return Color(.sRGB, red: Double(f.x), green: Double(f.y), blue: Double(f.z))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space5) {
            HStack {
                Text("Appearance").font(.headline)
                Spacer()
                HeaderIconButton(systemImage: "xmark", help: "Close the Appearance panel (A)") { close() }
            }
            Text(targetText)
                .font(.callout)
                .foregroundStyle(targets.isEmpty ? .secondary : .primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Group {
                LazyVGrid(columns: columns, spacing: DS.Spacing.space2) {
                    ColorSwatch(color: defaultColor, name: "Default", current: isCurrent(nil), isDefault: true) { apply(nil) }
                    ForEach(ColorPreset.all) { p in
                        ColorSwatch(color: p.color.color, name: p.name, current: isCurrent(p.color)) { apply(p.color) }
                    }
                }
                HStack {
                    ColorPicker("Custom Colour", selection: customColor, supportsOpacity: false)
                        .help("Pick any colour for the selected bodies")
                    Spacer()
                    if let c = sharedColor {
                        Text(c.hex).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            .disabled(targets.isEmpty)
            Divider()
            bodyList
        }
        .padding(DS.Spacing.space6)
        .frame(width: Self.width)
        .glassEffect(.regular, in: .rect(cornerRadius: DS.Radius.window))
        .task(id: pending) {
            guard let p = pending else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            commit(p)
        }
        .onDisappear { if let p = pending { commit(p) } }
    }

    /// Every body, to select from without hunting for it in the view. ⇧- or ⌘-click adds to the selection.
    private var bodyList: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space2) {
            Text("Bodies").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            if model.bodies.isEmpty {
                Text("No bodies yet").font(.callout).foregroundStyle(.tertiary)
            }
            ScrollView {
                VStack(spacing: DS.Spacing.space1) {
                    ForEach(model.bodies) { b in
                        AppearanceBodyRow(name: b.name, color: model.displayColor(of: b.id)?.color ?? defaultColor,
                                          selected: targets.contains(b.id), hidden: model.isHidden(b.id)) {
                            let flags = NSEvent.modifierFlags
                            model.selectBody(b.id, additive: flags.contains(.shift) || flags.contains(.command))
                        }
                    }
                }
            }
            // As tall as the rows, up to about eight of them; then it scrolls.
            .frame(height: min(CGFloat(model.bodies.count) * (DS.ControlHeight.sidebarRow + DS.Spacing.space1), 240))
        }
    }

    private var targetText: String {
        guard !targets.isEmpty else { return "Select bodies in the view or in the list below, then pick a colour." }
        let names = model.bodies.filter { targets.contains($0.id) }.map(\.name)
        return "Colour of " + ListFormatter.localizedString(byJoining: names)
    }

    /// The colour every selected body has (nil if they differ or have none).
    private var sharedColor: BodyColor? {
        guard let first = targets.first.flatMap({ model.displayColor(of: $0) }) else { return nil }
        return isCurrent(first) ? first : nil
    }

    /// Whether every selected body has this colour (nil = the default).
    private func isCurrent(_ color: BodyColor?) -> Bool {
        !targets.isEmpty && targets.allSatisfy { model.displayColor(of: $0) == color }
    }

    private var customColor: Binding<Color> {
        Binding(get: { sharedColor?.color ?? defaultColor },
                set: { new in
                    let ids = targets
                    guard let c = BodyColor(new), !ids.isEmpty else { return }
                    model.previewBodyColor(c, of: ids)
                    pending = PendingColor(color: c, bodies: ids)
                })
    }

    private func apply(_ color: BodyColor?) {
        if let p = pending { commit(p) }
        model.setBodyColor(color, of: targets)
    }

    private func commit(_ p: PendingColor) {
        pending = nil
        model.setBodyColor(p.color, of: p.bodies)
    }

    private func close() {
        if let p = pending { commit(p) }
        model.showAppearance = false
    }
}

/// One colour to pick: a round swatch, ringed when the selected bodies have it.
struct ColorSwatch: View {
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
                    Circle().strokeBorder(current ? Color.accentColor : hovering && isEnabled ? Color.primary.opacity(0.3) : .clear,
                                          lineWidth: 2)
                }
                .frame(width: 30, height: 30)
                .contentShape(Circle())
                .opacity(isEnabled ? 1 : DS.opacityDisabled)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: DS.Duration.instant), value: hovering)
        .help(isDefault ? "Default colour" : name)
        .accessibilityLabel(isDefault ? "Default colour" : name)
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}

/// A body in the Appearance panel: its colour and name; a click selects it.
struct AppearanceBodyRow: View {
    let name: String
    let color: Color
    let selected: Bool
    let hidden: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.labelGap) {
                Circle()
                    .fill(color)
                    .overlay { Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1) }
                    .frame(width: 14, height: 14)
                Text(name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if hidden {
                    Image(systemName: "eye.slash").foregroundStyle(.secondary).help("Hidden")
                }
            }
            .foregroundStyle(hidden ? .secondary : .primary)
            .padding(.horizontal, DS.Spacing.space3)
            .frame(height: DS.ControlHeight.sidebarRow)
            .background(selected ? Color.accentColor.opacity(0.18) : hovering ? Color.primary.opacity(0.07) : .clear,
                        in: RoundedRectangle(cornerRadius: DS.Radius.sidebarItem, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
