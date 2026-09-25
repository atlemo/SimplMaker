// App settings (⌘,).
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

enum Preferences {
    static let trackpadScroll = "trackpadScroll"
    static let invertZoom = "invertZoom"
    static let showGrid = "showGrid"
    static let showConstraints = "showConstraints"

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
}

struct SettingsView: View {
    @AppStorage(Preferences.trackpadScroll) private var trackpadScroll = Preferences.TrackpadScroll.pan
    @AppStorage(Preferences.invertZoom) private var invertZoom = false
    @AppStorage(Preferences.showGrid) private var showGrid = true
    @AppStorage(Preferences.showConstraints) private var showConstraints = true

    var body: some View {
        TabView {
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
                    Toggle("Show sketch constraints", isOn: $showConstraints)
                }
                .formStyle(.grouped)
            }
        }
        .frame(width: 460, height: 260)
    }
}
