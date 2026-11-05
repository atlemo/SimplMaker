// The names and readers of the app's preferences (UserDefaults keys and their typed settings), without any settings screen,
// so the Mac and the iPad app share them.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

enum Preferences {
    static let trackpadScroll = "trackpadScroll"
    static let invertZoom = "invertZoom"
    static let navigation = "navigation"
    static let showGrid = "showGrid"
    static let showAxes = "showAxes"
    static let showConstraints = "showConstraints"
    static let showShapeCentres = "showShapeCentres"
    static let showWelcome = "showWelcome"
    static let settingsHeight = "settingsWindowHeight"  // the height the user dragged the Settings window to
    static let snapToGrid = "snapToGrid"
    static let unitSystem = "unitSystem"
    static let gridSizeMetric = "gridSizeMetric"
    static let gridSizeUS = "gridSizeUS"
    static let sketchPaper = "sketchPaper"
    static let antialiasing = "antialiasing"
    /// The guided first part (the desk organizer) has been finished.
    static let tutorialCompleted = "tutorialCompleted"
    /// Anonymous usage statistics are sent (see Telemetry.swift); on by default.
    static let sendUsageStatistics = "sendUsageStatistics"

    /// The tools pinned to a toolbar group (see ToolGroups.swift), by the group's id.
    static func toolbarPins(_ group: String) -> String { "toolbarPins.\(group)" }

    /// How the mouse, trackpad and wheel navigate the viewport (see NavigationConfig), stored as JSON. Before
    /// there were bindings to edit, the Settings held only the trackpad's scroll mode and one inversion.
    static var navigationConfig: NavigationConfig {
        get {
            let defaults = UserDefaults.standard
            if let data = defaults.string(forKey: navigation)?.data(using: .utf8),
               let config = try? JSONDecoder().decode(NavigationConfig.self, from: data) {
                return config
            }
            return .simplMaker(trackpadOrbits: defaults.string(forKey: trackpadScroll) == "orbit",
                               invertZoom: defaults.bool(forKey: invertZoom))
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue), let text = String(data: data, encoding: .utf8) else { return }
            UserDefaults.standard.set(text, forKey: navigation)
        }
    }
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
        /// The toolbar's colour while sketching: a deeper shade of the paper, or the system accent colour for
        /// blue and None. The controls on it take black or white by contrast (`ContrastColor`), since the
        /// accent colour can be anything from graphite to yellow.
        #if os(macOS)
        var toolbarNSColor: NSColor {
            switch self {
            case .green: return NSColor(srgbRed: 0.16, green: 0.46, blue: 0.33, alpha: 1)
            case .cream: return NSColor(srgbRed: 0.55, green: 0.47, blue: 0.27, alpha: 1)
            case .blue, .none: return .controlAccentColor  // tones of the system's colour, as it is in sketch mode
            }
        }
        var toolbarTint: Color { Color(nsColor: toolbarNSColor) }
        #endif
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
