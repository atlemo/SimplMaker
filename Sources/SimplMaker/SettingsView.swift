// App settings (⌘,).
// Copyright © 2026 Atle Mo. All rights reserved.
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
        var toolbarNSColor: NSColor {
            switch self {
            case .green: return NSColor(srgbRed: 0.16, green: 0.46, blue: 0.33, alpha: 1)
            case .cream: return NSColor(srgbRed: 0.55, green: 0.47, blue: 0.27, alpha: 1)
            case .blue, .none: return .controlAccentColor  // tones of the system's colour, as it is in sketch mode
            }
        }
        var toolbarTint: Color { Color(nsColor: toolbarNSColor) }
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
        case general = "General", license = "License", navigation = "Navigation", viewport = "Viewport", shortcuts = "Shortcuts", ai = "AI"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .license: return "key"
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
        Pane.allCases.filter { ($0 != .license || LicenseManager.shared.isEnforced) && ($0 != .ai || AIFeature.isAvailable) }
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
            case .license: LicenseView(license: .shared)
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
            VStack(alignment: .leading, spacing: 8) {  // one row, so no divider between them
                Toggle("Share anonymous usage statistics", isOn: $sendUsageStatistics)
                Text("Helps improve SimplMaker: which version and macOS you use, and which features get used. Never your parts, file names or anything personal. Takes full effect the next time SimplMaker starts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
