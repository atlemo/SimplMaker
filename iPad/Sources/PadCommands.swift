// The menu commands for a hardware keyboard (hold ⌘ to see them) and the View menu in the toolbar: the Mac's View, Sketch, Create,
// Modify and Inspect menus, acting on the document in front. A shortcut that is a plain letter (E for Extrude) is left out here, since
// on the iPad it would take the key away from a field being typed in.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import SwiftUI

extension View {
    /// The command's shortcut, when it uses ⌘, ⌃ or ⌥.
    @ViewBuilder func padShortcut(_ command: ShortcutCommand) -> some View {
        if let key = Shortcuts.keyboardShortcut(command), !key.modifiers.isEmpty { keyboardShortcut(key) } else { self }
    }
}

/// The View menu's contents: used by the menu bar and by the View button in the toolbar.
struct PadViewControls: View {
    let model: DocumentModel?
    @AppStorage(Preferences.showConstraints) private var showConstraints = true
    @AppStorage(Preferences.snapToGrid) private var snapToGrid = true
    @AppStorage(Preferences.showGrid) private var showGrid = true
    @AppStorage(Preferences.showAxes) private var showAxes = true

    var body: some View {
        Button("Command Palette…", systemImage: "magnifyingglass") { model?.showPalette.toggle() }
            .padShortcut(.palette)
            .disabled(model == nil)
        Divider()
        Button("Fit All", systemImage: "arrow.up.left.and.down.right.magnifyingglass") { model?.fitView() }.padShortcut(.fitAll)
        Menu("Standard Views", systemImage: "cube") {
            ForEach(StandardView.allCases) { v in
                Button(v.title) { model?.show(v) }.padShortcut(.view(v))
            }
        }
        Toggle("Orthographic Projection", isOn: Binding(get: { model?.orthographic ?? false }, set: { model?.orthographic = $0 }))
            .padShortcut(.orthographic)
        Picker("Visual Style", selection: Binding(get: { model?.visualStyle ?? .standard }, set: { model?.visualStyle = $0 })) {
            ForEach(VisualStyle.allCases) { style in Text(style.title).tag(style) }
        }
        .disabled(model == nil)
        Divider()
        Toggle("FDM 3D Print Preview", isOn: Binding(get: { model?.printPreview ?? false }, set: { model?.setPrintPreview($0) }))
            .disabled(model == nil || !(model?.visualStyle.isShaded ?? true))
        Toggle("Render", isOn: Binding(get: { model?.renderView ?? false }, set: { model?.setRenderView($0) })).disabled(model == nil)
        Toggle("Render Options", isOn: Binding(get: { model?.showRenderOptions ?? false }, set: { model?.showRenderOptions = $0 }))
            .disabled(model == nil || !(model?.renderView ?? false))
        Toggle("Turntable", isOn: Binding(get: { model?.renderSpinning ?? false }, set: { model?.renderSpinning = $0 }))
            .disabled(model == nil || !(model?.renderView ?? false))
        Toggle("Section Analysis", isOn: Binding(get: { model?.sectionActive ?? false }, set: { model?.setSectionAnalysis($0) })).disabled(model == nil)
        Toggle("Exploded View", isOn: Binding(get: { model?.explodeOn ?? false }, set: { model?.setExplodedView($0) })).disabled(model == nil)
        Divider()
        Toggle("Show Grid", isOn: $showGrid).padShortcut(.showGrid)
        Toggle("Show Axes", isOn: $showAxes).padShortcut(.showAxes)
        Toggle("Show Constraints", isOn: $showConstraints)
        Toggle("Snap to Grid", isOn: $snapToGrid).padShortcut(.snapToGrid)
        Divider()
        Button((model?.showSidebar ?? true) ? "Hide Browser" : "Show Browser") { model?.showSidebar.toggle() }.padShortcut(.browser)
        Button((model?.showTimeline ?? true) ? "Hide Timeline" : "Show Timeline") { model?.showTimeline.toggle() }.padShortcut(.timeline)
        Button((model?.showInspector ?? true) ? "Hide Inspector" : "Show Inspector") { model?.showInspector.toggle() }.padShortcut(.inspector)
        Button((model?.uiHidden ?? false) ? "Show UI" : "Hide UI") { model?.toggleUIHidden() }.padShortcut(.hideUI).disabled(model == nil)
        Button((model?.showAppearance ?? false) ? "Hide Appearance" : "Show Appearance") { model?.toggleAppearance() }
            .padShortcut(.appearance)
            .disabled(model == nil || model?.sketchSession != nil)
    }
}

struct PadCommands: Commands {
    @FocusedValue(\.documentModel) private var model

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Menu("Import") {
                Button("STEP…") { model?.importSTEP() }.padShortcut(.importSTEP)
                Button("STL…") { model?.importSTL() }
                Button("SVG as Sketch…") { model?.importSVG() }
                Button("DXF as Sketch…") { model?.importDXF() }
            }
            .disabled(model == nil)
            Divider()
            Button("Export…") { model?.exportWithDialog() }.disabled(model == nil)
            Button("Export Image…") { model?.exportImageWithDialog() }.disabled(model == nil)
        }
        CommandGroup(before: .toolbar) {
            PadViewControls(model: model)
        }
        CommandMenu("Sketch") {
            Button("New Sketch…") { model?.startSketch() }.disabled(model == nil)
            Menu("New Sketch On") {
                Button("XY Plane") { model?.beginSketch(on: .xy) }
                Button("XZ Plane") { model?.beginSketch(on: .xz) }
                Button("YZ Plane") { model?.beginSketch(on: .yz) }
                Button("Selected Face") { if let p = model?.selectedFacePlane { model?.beginSketch(on: p) } }
                    .disabled(model?.selectedFacePlane == nil)
            }
            .disabled(model == nil)
            if model?.sketchSession != nil {
                Divider()
                ForEach(SketchTool.allCases) { tool in Button(tool.menuTitle) { model?.setSketchTool(tool) } }
                Button("Offset Selection…") { model?.beginSketchOffset() }.disabled(!(model?.sketchSession?.canOffset ?? false))
                ForEach(SketchTransformTool.allCases) { tool in
                    Button(tool == .scale ? "Scale Selection…" : tool == .pattern ? "Pattern Selection" : "\(tool.rawValue) Selection") { model?.beginSketchTransform(tool) }
                        .disabled(!((tool == .pattern ? model?.sketchSession?.canPattern : tool == .mirror ? model?.sketchSession?.canMirror : model?.sketchSession?.canTransform) ?? false))
                }
                Divider()
                Toggle("Slice View", isOn: Binding(get: { model?.sketchSlice ?? false }, set: { model?.sketchSlice = $0 }))
                Button("Finish Sketch") { model?.finishSketch() }
            }
        }
        CommandMenu("Create") {
            ForEach(DesignTool.shapes) { tool in toolItem(tool) }
            Divider()
            ForEach(DesignTool.primitives) { tool in toolItem(tool) }
            Divider()
            toolItem(.plane, title: "Construction Plane")
            toolItem(.canvas, title: "Canvas (Reference Image)…")
            Divider()
            Button("Rebuild") { model?.regenerate() }.padShortcut(.rebuild).disabled(model == nil)
        }
        CommandMenu("Modify") {
            ForEach(DesignTool.modifiers) { tool in toolItem(tool) }
            Divider()
            toolItem(.mirror)
            toolItem(.pattern)
        }
        CommandMenu("Inspect") {
            ForEach(DesignTool.inspect) { tool in toolItem(tool) }
        }
    }

    private func toolItem(_ tool: DesignTool, title: String? = nil) -> some View {
        Button(title ?? tool.rawValue) { model?.run(tool) }.padShortcut(.tool(tool)).disabled(model == nil)
    }
}
