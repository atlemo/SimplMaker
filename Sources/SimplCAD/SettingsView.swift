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
}

struct SettingsView: View {
    @AppStorage(Preferences.trackpadScroll) private var trackpadScroll = Preferences.TrackpadScroll.pan
    @AppStorage(Preferences.invertZoom) private var invertZoom = false
    @AppStorage(Preferences.showGrid) private var showGrid = true
    @AppStorage(Preferences.showAxes) private var showAxes = true
    @AppStorage(Preferences.showConstraints) private var showConstraints = true
    @AppStorage(Preferences.showWelcome) private var showWelcome = true

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
                    Toggle("Show axes", isOn: $showAxes)
                    Toggle("Show sketch constraints", isOn: $showConstraints)
                }
                .formStyle(.grouped)
            }
        }
        .frame(width: 460, height: 260)
    }
}
