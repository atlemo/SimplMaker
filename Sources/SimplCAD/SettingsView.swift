// App settings (⌘,).
// SPDX-License-Identifier: GPL-3.0-or-later
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

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                Form {
                    Toggle("Show the welcome window at launch", isOn: $showWelcome)
                    Text("Off, SimplCAD opens an empty part at launch instead. The window is always available under Window → Welcome to SimplCAD.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .formStyle(.grouped)
            }
            Tab("Navigation", systemImage: "hand.draw") {
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
            Tab("Viewport", systemImage: "cube") {
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
                    Toggle("Show axes", isOn: $showAxes)
                    Toggle("Show sketch constraints", isOn: $showConstraints)
                }
                .formStyle(.grouped)
            }
        }
        .frame(width: 460, height: 380)
    }
}
