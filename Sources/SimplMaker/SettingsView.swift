// App settings (⌘,).
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct SettingsView: View {
    @State private var navigation = Preferences.navigationConfig
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
    @AppStorage(Preferences.sendUsageStatistics) private var sendUsageStatistics = true
    @ObservedObject private var updater = Updater.shared
    private enum Pane: String, CaseIterable, Identifiable {
        case general = "General", navigation = "Navigation", viewport = "Viewport", shortcuts = "Shortcuts", ai = "AI"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .navigation: return "hand.draw"
            case .viewport: return "cube"
            case .shortcuts: return "keyboard"
            case .ai: return "sparkles"
            }
        }
    }
    @State private var pane = Pane.general
    @Environment(\.accent) private var accent

    private var panes: [Pane] {
        Pane.allCases.filter { $0 != .ai || AIFeature.isAvailable }
    }

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
            case .navigation: navigationPane
            case .viewport: viewportPane
            case .shortcuts: ShortcutsPane()
            case .ai: AISettingsPane()
            }
        }
        .frame(width: 520)
        .frame(minHeight: 360, idealHeight: 560, maxHeight: .infinity)  // the height can be dragged, the width is fixed
        .background(SettingsHeightMemory())
        .navigationTitle(pane.rawValue)
    }

    @ViewBuilder private var generalPane: some View {
        Form {
            VStack(alignment: .leading, spacing: 8) {  // one row, so no divider between them
                Toggle("Show the welcome window at launch", isOn: $showWelcome)
                Text("Off, SimplMaker opens an empty part at launch instead. The window is always available under Window → Welcome to SimplMaker.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
            if Telemetry.isOfficialBuild {
                VStack(alignment: .leading, spacing: 8) {  // one row, so no divider between them
                    Toggle("Share anonymous usage statistics", isOn: $sendUsageStatistics)
                    Text("Helps improve SimplMaker: which version and macOS you use, and which features get used. Never your parts, file names or anything personal. Takes full effect the next time SimplMaker starts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var navigationPane: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {  // one row, so no divider between them
                    Picker("Navigate like", selection: Binding(
                        get: { navigation.matchingPreset },
                        set: { navigation.apply($0) })) {
                        ForEach(NavigationPreset.choosable) { Text($0.title).tag($0) }
                        if navigation.matchingPreset == .custom { Text(NavigationPreset.custom.title).tag(NavigationPreset.custom) }
                    }
                    Text("Sets what the mouse buttons, the wheel and the trackpad's scrolling do, as in that app. Change any of them below. Your direction and speed choices stay.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Mouse") {
                bindingsGrid(note: "The left button only navigates on empty space; on a face, an edge or a handle it selects or drags that. ⌃-click is a right-click on a Mac.") {
                    bindingsRow("Left button", $navigation.left, unavailable: [.control])
                    bindingsRow("Right button", $navigation.right)
                    bindingsRow("Middle button", $navigation.middle)
                    bindingsRow("Wheel", $navigation.wheel)
                }
            }
            Section("Trackpad") {
                bindingsGrid(note: "Two fingers on the trackpad. Pinch zooms.") {
                    bindingsRow("Scroll", $navigation.trackpad)
                }
                Toggle("Rotate gesture spins the view", isOn: $navigation.rotateSpins)
            }
            Section("Mouse and trackpad") {
                Toggle("Invert orbit up and down", isOn: $navigation.invertOrbitVertical)
                Toggle("Invert orbit left and right", isOn: $navigation.invertOrbitHorizontal)
                Toggle("Invert pan up and down", isOn: $navigation.invertPanVertical)
                Toggle("Invert pan left and right", isOn: $navigation.invertPanHorizontal)
                Toggle("Invert zoom (wheel, scroll and drag)", isOn: $navigation.invertZoom)
                speedSlider("Orbit speed", value: $navigation.orbitSpeed)
                speedSlider("Zoom speed", value: $navigation.zoomSpeed)
            }
            Section {
                Button("Reset Navigation") { navigation = .simplMaker() }
                    .disabled(navigation == .simplMaker())
            }
        }
        .formStyle(.grouped)
        .onChange(of: navigation) { _, new in Preferences.navigationConfig = new }
    }

    private static let bindingLabelWidth: CGFloat = 100
    private static let bindingPickerWidth: CGFloat = 80

    private func speedSlider(_ title: String, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: NavigationConfig.speedRange)
                Text(String(format: "%.2g×", value.wrappedValue))
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }

    /// Rows of what each input does with each modifier key held, under a header of the keys.
    private func bindingsGrid<Rows: View>(note: String, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    Color.clear.frame(width: Self.bindingLabelWidth, height: 1)
                    ForEach(NavModifier.allCases) { Text($0.symbol).font(.caption).foregroundStyle(.secondary).frame(width: Self.bindingPickerWidth) }
                }
                rows()
            }
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func bindingsRow(_ title: String, _ bindings: Binding<NavBindings>, unavailable: Set<NavModifier> = []) -> some View {
        GridRow {
            Text(title).frame(width: Self.bindingLabelWidth, alignment: .leading)  // the same in every grid, so the columns line up
            ForEach(NavModifier.allCases) { modifier in
                Picker(title, selection: bindings[modifier]) {
                    ForEach(NavAction.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: Self.bindingPickerWidth)
                .disabled(unavailable.contains(modifier))
            }
        }
    }

    @ViewBuilder private var viewportPane: some View {
        Form {
            Toggle("Show grid", isOn: $showGrid)
            Picker("Units", selection: $unitSystem) {
                ForEach(Preferences.UnitSystem.allCases) { Text($0.title).tag($0) }
            }
            VStack(alignment: .leading, spacing: 8) {  // one row, so no divider between them
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
            }
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

private extension Binding where Value == NavBindings {
    subscript(modifier: NavModifier) -> Binding<NavAction> {
        Binding<NavAction>(get: { wrappedValue[modifier] }, set: { wrappedValue[modifier] = $0 })
    }
}


/// Put in the Settings window's content: opens the window at the height the user last dragged it to, and keeps that up
/// to date. Done on the window itself because a content-sized window opens at the content's natural height, whatever
/// ideal height the view asks for.
private struct SettingsHeightMemory: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Tracker() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Tracker: NSView {
        private var observed = false

        override func viewDidMoveToWindow() {
            guard let window, !observed else { return }
            observed = true
            let saved = UserDefaults.standard.double(forKey: Preferences.settingsHeight)
            if saved >= 360 {
                // After SwiftUI has sized the window to its content, or it would size it back.
                DispatchQueue.main.async { [weak window] in
                    guard let window else { return }
                    let visible = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? CGFloat(saved)
                    let height = min(CGFloat(saved), visible - (window.frame.height - window.contentLayoutRect.height))
                    var frame = window.frame
                    let delta = height - window.contentLayoutRect.height
                    frame.origin.y -= delta  // keep the top edge where it is
                    frame.size.height += delta
                    window.setFrame(frame, display: true)
                }
            }
            NotificationCenter.default.addObserver(self, selector: #selector(resized),
                                                   name: NSWindow.didEndLiveResizeNotification, object: window)
        }

        @objc private func resized() {
            guard let window else { return }
            UserDefaults.standard.set(Double(window.contentLayoutRect.height), forKey: Preferences.settingsHeight)
        }
    }
}
