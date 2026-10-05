// App settings (⌘,).
// Copyright © 2026 Atle Mo. All rights reserved.
import SwiftUI

enum Preferences {
    static let trackpadScroll = "trackpadScroll"
    static let invertZoom = "invertZoom"
    static let showGrid = "showGrid"
    static let showAxes = "showAxes"
    static let showConstraints = "showConstraints"
    static let showWelcome = "showWelcome"
    static let snapToGrid = "snapToGrid"
    static let unitSystem = "unitSystem"
    static let gridSizeMetric = "gridSizeMetric"
    static let gridSizeUS = "gridSizeUS"
    static let sketchPaper = "sketchPaper"
    static let antialiasing = "antialiasing"
    /// The guided first part (the box with a lid) has been finished.
    static let tutorialCompleted = "tutorialCompleted"

    /// The tools pinned to a toolbar group (see ToolGroups.swift), by the group's id.
    static func toolbarPins(_ group: String) -> String { "toolbarPins.\(group)" }

    /// What a two-finger trackpad scroll does in the viewport; ⇧ switches to the other one.
    enum TrackpadScroll: String, CaseIterable, Identifiable {
        case pan, orbit
        var id: String { rawValue }
        var title: String { self == .pan ? "Pan (like Apple's 3D viewers)" : "Orbit (like many CAD apps)" }
    }

    static var trackpadScrollMode: TrackpadScroll {
        TrackpadScroll(rawValue: UserDefaults.standard.string(forKey: trackpadScroll) ?? "") ?? .pan
    }
    static var invertsZoom: Bool { UserDefaults.standard.bool(forKey: invertZoom) }
    /// Show the welcome window at launch instead of an empty document (on by default).
    static var showsWelcome: Bool { UserDefaults.standard.object(forKey: showWelcome) as? Bool ?? true }
    /// Sketch points snap to a grid that follows the zoom (on by default; ⌥ turns all snapping off).
    static var snapsToGrid: Bool { UserDefaults.standard.object(forKey: snapToGrid) as? Bool ?? true }

    /// Multisampling in the 3D view: samples per pixel (1 is off). Read at launch; 4 by default.
    static var antialiasingSamples: Int { UserDefaults.standard.object(forKey: antialiasing) as? Int ?? 4 }
    static let antialiasingChoices: [(samples: Int, title: String)] = [(1, "Off"), (2, "2×"), (4, "4×"), (8, "8×")]

    /// The colour of the background while a sketch is open, like tinted drafting paper, so it's obvious
    /// you're sketching. Soft blue by default; "None" keeps the model's background.
    enum SketchPaper: String, CaseIterable, Identifiable {
        case blue, green, cream, none
        var id: String { rawValue }
        var title: String {
            switch self {
            case .blue: return "Soft blue"
            case .green: return "Soft green"
            case .cream: return "Cream"
            case .none: return "None (same as the model)"
            }
        }
        /// The paper colour in a light and in a dark window; nil for None.
        func color(dark: Bool) -> SIMD3<Float>? {
            switch self {
            case .blue: return dark ? SIMD3(0.10, 0.17, 0.29) : SIMD3(0.78, 0.87, 0.96)
            case .green: return dark ? SIMD3(0.10, 0.20, 0.17) : SIMD3(0.78, 0.92, 0.84)
            case .cream: return dark ? SIMD3(0.19, 0.17, 0.12) : SIMD3(0.96, 0.93, 0.82)
            case .none: return nil
            }
        }
        /// The toolbar's colour while sketching (it carries white controls): a deeper shade of the paper,
        /// or the system accent colour, which is itself blue, for blue and None.
        var toolbarTint: Color {
            switch self {
            case .green: return Color(red: 0.16, green: 0.46, blue: 0.33)
            case .cream: return Color(red: 0.55, green: 0.47, blue: 0.27)
            case .blue: return Color(nsColor: .controlAccentColor)  // tones of the system's colour, as it is in sketch mode
            case .none: return Color(nsColor: .controlAccentColor)
            }
        }
    }
    static var sketchPaperSetting: SketchPaper {
        SketchPaper(rawValue: UserDefaults.standard.string(forKey: sketchPaper) ?? "") ?? .blue
    }

    /// Which units the grid is laid out in. By default whatever macOS is set to (System Settings ▸
    /// General ▸ Language & Region ▸ Measurement System); everything inside a model stays in mm.
    enum UnitSystem: String, CaseIterable, Identifiable {
        case system, metric, us
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: return Locale.current.measurementSystem == .us ? "Same as system (US)" : "Same as system (Metric)"
            case .metric: return "Metric (mm)"
            case .us: return "US (inches)"
            }
        }
        var isUS: Bool { self == .system ? Locale.current.measurementSystem == .us : self == .us }
    }

    /// One choice for the size of a grid square; `mm` 0 is "Automatic", which follows the zoom.
    struct GridSize: Hashable, Identifiable {
        var title: String
        var mm: Double
        var id: Double { mm }
    }
    static let automaticGrid = GridSize(title: "Automatic (follows zoom)", mm: 0)
    static let metricGridSizes = [automaticGrid] + [1.0, 2, 5, 10, 25, 50, 100].map { GridSize(title: "\(Int($0)) mm", mm: $0) }
    static let usGridSizes = [automaticGrid] + [("1/16\"", 1.0 / 16), ("1/8\"", 1.0 / 8), ("1/4\"", 0.25), ("1/2\"", 0.5),
                                                ("1\"", 1), ("2\"", 2), ("6\"", 6), ("1 ft", 12)].map { GridSize(title: $0.0, mm: $0.1 * 25.4) }

    static var unitSystemSetting: UnitSystem {
        UnitSystem(rawValue: UserDefaults.standard.string(forKey: unitSystem) ?? "") ?? .system
    }
    /// The chosen grid square in mm, or 0 for automatic.
    static var gridSizeMM: Double {
        UserDefaults.standard.double(forKey: unitSystemSetting.isUS ? gridSizeUS : gridSizeMetric)
    }

    /// A length in mm as a ruler label in the grid's units: "25", or "0.25" in a US grid (inches).
    static func rulerText(_ mm: Double, us: Bool) -> String {
        String(format: "%g", ((us ? mm / 25.4 : mm) * 1e4).rounded() / 1e4)
    }
}

struct SettingsView: View {
    @AppStorage(Preferences.trackpadScroll) private var trackpadScroll = Preferences.TrackpadScroll.pan
    @AppStorage(Preferences.invertZoom) private var invertZoom = false
    @AppStorage(Preferences.showGrid) private var showGrid = true
    @AppStorage(Preferences.showAxes) private var showAxes = true
    @AppStorage(Preferences.showConstraints) private var showConstraints = true
    @AppStorage(Preferences.showWelcome) private var showWelcome = true
    @AppStorage(Preferences.unitSystem) private var unitSystem = Preferences.UnitSystem.system
    @AppStorage(Preferences.gridSizeMetric) private var gridSizeMetric = 0.0
    @AppStorage(Preferences.gridSizeUS) private var gridSizeUS = 0.0
    @AppStorage(Preferences.sketchPaper) private var sketchPaper = Preferences.SketchPaper.blue
    @AppStorage(Preferences.antialiasing) private var antialiasing = 4
    @AppStorage(Preferences.accentSource) private var accentSource = Preferences.AccentSource.simplMaker
    @ObservedObject private var updater = Updater.shared

    private enum Pane: String, CaseIterable, Identifiable {
        case general = "General", license = "License", navigation = "Navigation", viewport = "Viewport"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .license: return "key"
            case .navigation: return "hand.draw"
            case .viewport: return "cube"
            }
        }
    }
    @State private var pane = Pane.general
    @Environment(\.accent) private var accent

    private var panes: [Pane] { Pane.allCases.filter { $0 != .license || LicenseManager.shared.isEnforced } }

    /// The categories, as a row of buttons in the app's accent colour (a TabView draws its selection grey).
    private var categoryBar: some View {
        HStack(spacing: DS.Spacing.space2) {
            ForEach(panes) { p in
                let selected = p == pane
                Button { pane = p } label: {
                    VStack(spacing: DS.Spacing.space1) {
                        Image(systemName: p.icon).font(.system(size: 17)).frame(height: 22)
                        Text(p.rawValue).font(.system(size: 11))
                    }
                    .frame(minWidth: 62)
                    .padding(.horizontal, DS.Spacing.space3)
                    .padding(.vertical, DS.Spacing.space2)
                    .foregroundStyle(selected ? accent : Color.primary)
                    .background(selected ? accent.opacity(0.16) : .clear,
                                in: RoundedRectangle(cornerRadius: DS.Radius.xl3, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()  // the selection already shows in the accent colour; the ring would be the system's
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.vertical, DS.Spacing.space4)
        .frame(maxWidth: .infinity)
    }

    var body: some View {
        VStack(spacing: 0) {
            categoryBar
            Divider()
            switch pane {
            case .general: generalPane
            case .license: LicenseView(license: .shared)
            case .navigation: navigationPane
            case .viewport: viewportPane
            }
        }
        .frame(width: 460, height: 560)
        .navigationTitle(pane.rawValue)
    }

    @ViewBuilder private var generalPane: some View {
        Form {
            Toggle("Show the welcome window at launch", isOn: $showWelcome)
            Text("Off, SimplMaker opens an empty part at launch instead. The window is always available under Window → Welcome to SimplMaker.")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {  // one row, so no divider between them
                Picker("Accent color", selection: $accentSource) {
                    ForEach(Preferences.AccentSource.allCases) { Text($0.title).tag($0) }
                }
                Text("The highlight color of tools and selections. While you sketch, the system's color is always used, since the sketch paper is tinted to match it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if updater.isAvailable {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.automaticallyChecksForUpdates = $0 }))
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var navigationPane: some View {
        Form {
            Picker("Two-finger scroll", selection: $trackpadScroll) {
                ForEach(Preferences.TrackpadScroll.allCases) { Text($0.title).tag($0) }
            }
            Text("Hold ⇧ while scrolling to do the other one. Pinch zooms, rotate spins the view, and dragging on empty space orbits.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Invert mouse-wheel zoom", isOn: $invertZoom)
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var viewportPane: some View {
        Form {
            Toggle("Show grid", isOn: $showGrid)
            Picker("Units", selection: $unitSystem) {
                ForEach(Preferences.UnitSystem.allCases) { Text($0.title).tag($0) }
            }
            if unitSystem.isUS {
                Picker("Grid square", selection: $gridSizeUS) {
                    ForEach(Preferences.usGridSizes) { Text($0.title).tag($0.mm) }
                }
            } else {
                Picker("Grid square", selection: $gridSizeMetric) {
                    ForEach(Preferences.metricGridSizes) { Text($0.title).tag($0.mm) }
                }
            }
            Text("The size of one square of the sketch grid, which \"Snap to Grid\" snaps to. Automatic picks a round size that follows the zoom; a fixed size is thinned out only when zoomed far out.")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {  // one row, so no divider between them
                Picker("Sketch background", selection: $sketchPaper) {
                    ForEach(Preferences.SketchPaper.allCases) { Text($0.title).tag($0) }
                }
                Text("While a sketch is open the background is tinted like drafting paper, so it's clear you're in sketch mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {  // one row, so no divider between them
                Picker("Antialiasing", selection: $antialiasing) {
                    ForEach(Preferences.antialiasingChoices, id: \.samples) { Text($0.title).tag($0.samples) }
                }
                Text("Smooths the jagged edges of lines and bodies. Takes effect the next time SimplMaker starts. Higher is smoother but uses more graphics memory; 4× is hardly noticeable on a Mac with Apple silicon.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("Show axes", isOn: $showAxes)
            Toggle("Show sketch constraints", isOn: $showConstraints)
        }
        .formStyle(.grouped)
    }
}
