// The Mold workspace's screens: the tool row in the ribbon, the list of molds and bodies on the left, the mold's settings and what
// it comes to on the right, and the export of the halves. The model is MoldStudio.swift; the plan is docs/MOLD-PLAN.md.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
#if canImport(AppKit)
import AppKit
#endif
import CADCore
import CADKernel
import SwiftUI
import simd

// MARK: - Ribbon

/// One group of the Mold ribbon: its tools as buttons and the group's name under them, as in Design.
struct MoldGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @Environment(\.toolsOnTint) private var onTint
    @Environment(\.toolsInk) private var toolsInk

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Spacing.space1) { content }
                .environment(\.toolTitles, false)
            Text(title)
                .font(.system(size: 11))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle((onTint ? toolsInk : Color.primary).opacity(0.8))
                .padding(.horizontal, ToolListMetrics.labelPadding)
                .frame(minHeight: ToolListMetrics.labelMinHeight)
        }
    }
}

/// A one-letter choice in the ribbon (the axis the mold is parted across), drawn like a tool button.
struct AxisButton: View {
    let label: String
    let active: Bool
    let help: String
    let action: () -> Void
    @Environment(\.accent) private var accent
    @Environment(\.toolsOnTint) private var onTint
    @Environment(\.toolsInk) private var toolsInk
    @State private var hovering = false

    var body: some View {
        let ink = onTint ? toolsInk : Color.primary
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .frame(minWidth: ToolListMetrics.toolMinWidth, minHeight: ToolListMetrics.toolMinHeight)
                .foregroundStyle(active && !onTint ? accent : ink)
                .background(active ? (onTint ? toolsInk.opacity(0.24) : accent.opacity(0.16)) : (hovering ? ink.opacity(onTint ? 0.14 : 0.07) : .clear),
                            in: RoundedRectangle(cornerRadius: DS.Radius.xl3, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .toolTip(help)
        .accessibilityLabel(help)
    }
}

/// The Mold workspace's tool row: Parting · Gate & Vents · Keys · View · Export, live sections that work on the mold chosen on the
/// left (not a wizard: any of them can be changed at any time).
struct MoldToolbar: View {
    @Bindable var model: DocumentModel

    var body: some View {
        HStack(spacing: DS.Spacing.space3) {
            if let mold = model.activeMold, !model.choosingWorkspaceBody {
                let built = model.activeMoldResult?.isBuilt == true
                MoldGroup(title: "Parting") {
                    ForEach(MoldAxis.allCases, id: \.self) { axis in
                        AxisButton(label: axis.rawValue.uppercased(), active: mold.parting == .middle(axis),
                                   help: "Part the mold across \(axis.rawValue.uppercased()), through the middle of the body") {
                            model.updateMold(mold.id, "Change Parting") { $0.parting = .middle(axis); $0.partingOffset = "0 mm" }
                        }
                    }
                }
                RibbonDivider()
                MoldGroup(title: "Pieces") {
                    AxisButton(label: "2", active: mold.pieces == 2, help: "Two halves: the simplest mold, and the quickest to print") {
                        model.updateMold(mold.id, "Two Pieces") { $0.pieces = 2 }
                    }
                    AxisButton(label: "4", active: mold.pieces == 4,
                               help: "Four pieces: each half is cut again, so each piece is pulled out sideways as well as away. Lets go of more shapes.") {
                        model.updateMold(mold.id, "Four Pieces") { $0.pieces = 4 }
                    }
                }
                RibbonDivider()
                MoldGroup(title: "Gate & Vents") {
                    ToolButton(title: "Gate", icon: "cone", active: model.moldPicking == .gate,
                               help: model.moldPicking == .gate ? "Click on the body where the silicone goes in: the gate is the pour hole (Esc cancels)"
                                   : "The gate is the hole you pour the silicone in through. Place it by clicking on the body; it starts at the highest point.") { model.toggleMoldPick(.gate) }
                    ToolButton(title: "Vent", icon: "circle-dot", active: model.moldPicking == .vent,
                               help: model.moldPicking == .vent ? "Click on the body to add a vent; Esc when done"
                                   : "A vent is a small hole that lets air out while you pour. Add one by clicking on the body, at the top of a pocket that air would be trapped in") { model.toggleMoldPick(.vent) }
                    ToolButton(title: "Auto Vents", icon: "waypoints",
                               help: "Add a vent at the top of every lobe of the body that the gate does not reach: where air would be trapped") { model.addAutomaticVents() }
                        .disabled(!built)
                    ToolButton(title: "Clear Vents", icon: "circle-x", help: "Take away every vent") {
                        model.updateMold(mold.id, "Clear Vents") { $0.vents = [] }
                    }
                    .disabled(mold.vents.isEmpty)
                }
                RibbonDivider()
                MoldGroup(title: "Keys") {
                    ToolButton(title: "Keys", icon: "pyramid", active: mold.keys,
                               help: "Cone keys on the seams make the pieces go together one way only") {
                        model.updateMold(mold.id, mold.keys ? "Remove Keys" : "Add Keys") { $0.keys.toggle() }
                    }
                }
                RibbonDivider()
                MoldGroup(title: "Check") {
                    ToolButton(title: "Release", icon: "scan", active: model.moldCheckView,
                               help: "Colour the body by whether the pieces can let go of it when they are pulled apart: red is an undercut") { model.toggleMoldCheck() }
                        .disabled(model.activeMoldResult?.analysis == nil)
                }
                RibbonDivider()
                MoldGroup(title: "View") {
                    ToolButton(title: "Open", icon: "expand", active: model.moldOpenAmount > 0,
                               help: "Draw the pieces apart to see the cavity") {
                        model.moldOpenAmount = model.moldOpenAmount > 0 ? 0 : 0.7
                        model.sceneRevision += 0  // the offsets are read from the amount on the next update
                    }
                    .disabled(!built)
                }
                RibbonDivider()
                MoldGroup(title: "Export") {
                    ToolButton(title: "Export", icon: "download", help: "Write the pieces, laid out for printing, as STL, 3MF or STEP") {
                        model.exportMoldHalves()
                    }
                    .disabled(!built)
                }
            } else {
                Text(Hint.text(model.bodies.isEmpty ? "Model a body in Design first, then make its mold here." : "Click a body in the 3D view, or choose one on the left, to make a mold of."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .workspaceRowHeight()
        .fixedSize()
    }
}

// MARK: - Left: molds and bodies

/// The molds of the part, and the bodies a mold can be made of.
struct MoldSidebar: View {
    @Bindable var model: DocumentModel
    @State private var listOpen = true
    @State private var bodiesOpen = true

    var body: some View {
        VStack(spacing: Panel.inset) {
            SidebarPanel(title: "Molds", open: $listOpen, headerLeading: max(0, PanelTouch.panelToggleRoom - 8), accessory: { EmptyView() }) {
                MoldList(model: model)
            }
            .frame(maxHeight: listOpen ? .infinity : PanelTouch.headerHeight)
            SidebarPanel(title: "Bodies", open: $bodiesOpen, accessory: {
                HeaderIconButton(systemImage: "cursorarrow.click", help: "Pick the body in the 3D view") { model.startChoosingWorkspaceBody() }
            }) {
                MoldBodyList(model: model)
            }
            .frame(maxHeight: bodiesOpen ? .infinity : PanelTouch.headerHeight)
        }
        .frame(width: Panel.sidebarWidth)
        .frame(maxHeight: .infinity)
    }
}

private struct MoldList: View {
    @Bindable var model: DocumentModel

    var body: some View {
        if model.document.molds.isEmpty {
            VStack(spacing: DS.Spacing.space3) {
                Text("No mold yet")
                    .font(.system(size: 13, weight: .medium))
                Text("Make one from a body below: the mold is two or four pieces to print, with a cavity in the shape of the body, to cast silicone or resin in.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(Panel.inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            List(selection: Binding(get: { model.activeMold?.id }, set: { if let id = $0 { model.selectMold(id) } })) {
                ForEach(model.document.molds) { mold in
                    MoldRow(model: model, mold: mold)
                        .tag(mold.id)
                        .contextMenu {
                            Button("Delete Mold", role: .destructive) { model.deleteMold(mold.id) }
                        }
                }
            }
            .listStyle(.sidebar)
        }
    }
}

private struct MoldRow: View {
    let model: DocumentModel
    let mold: MoldSetup

    var body: some View {
        let result = model.moldResults[mold.id]
        let bodyName = model.bodies.first { $0.id == mold.body }?.name ?? "missing body"
        HStack(spacing: DS.Spacing.space3) {
            Icon("cuboid", size: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(mold.name).lineLimit(1)
                Text(bodyName).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if model.moldBuilding, model.activeMold?.id == mold.id {
                ProgressView().controlSize(.small)
            } else if let result, result.error != nil {
                Icon("triangle-alert", size: 13).foregroundStyle(.red).help(result.error ?? "")
            } else if let result, !result.warnings.isEmpty {
                Icon("triangle-alert", size: 13).foregroundStyle(.orange).help(result.warnings.joined(separator: "\n"))
            }
        }
    }
}

private struct MoldBodyList: View {
    let model: DocumentModel

    var body: some View {
        let bodies = model.bodies
        if bodies.isEmpty {
            Text("This part has no body yet. Model one in Design, then come back.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(Panel.inset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            List {
                ForEach(bodies) { body in
                    HStack(spacing: DS.Spacing.space3) {
                        Icon("box", size: 14)
                        Text(body.name).lineLimit(1)
                        Spacer(minLength: 0)
                        Button("Make Mold") { model.makeMold(of: body.id) }
                            .rowTextButton()
                            .help("Make a mold around \(body.name)")
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }
}

// MARK: - Right: settings and result

struct MoldInspectorColumn: View {
    @Bindable var model: DocumentModel
    @State private var open = true

    var body: some View {
        SidebarPanel(title: "Mold", open: $open, headerTrailing: PanelTouch.panelToggleRoom, accessory: { EmptyView() }) {
            MoldInspector(model: model)
        }
        .frame(width: Panel.inspectorWidth)
        .frame(maxHeight: open ? .infinity : PanelTouch.headerHeight, alignment: .top)
    }
}

private struct MoldInspector: View {
    @Bindable var model: DocumentModel

    var body: some View {
        if let mold = model.activeMold, !model.choosingWorkspaceBody {
            let result = model.moldResults[mold.id]
            Form {
                Section {
                    LabeledContent("Name") {
                        ExpressionField(text: mold.name, monospaced: false, completes: false) { v in
                            model.updateMold(mold.id, "Rename Mold") { $0.name = v.isEmpty ? $0.name : v }
                        }
                    }
                    LabeledContent("Body", value: model.bodies.first { $0.id == mold.body }?.name ?? "missing")
                }
                Section("Result") { MoldResultRows(model: model, mold: mold, result: result) }
                if let analysis = result?.analysis { Section("Check") { MoldCheckRows(model: model, analysis: analysis) } }
                Section("Parting") {
                    Picker("Casting", selection: Binding(get: { mold.casting }, set: { c in model.updateMold(mold.id, "Change Casting") { $0.casting = c } })) {
                        Text("Silicone").tag(MoldCasting.silicone)
                        Text("Rigid resin").tag(MoldCasting.resin)
                    }
                    .help("Silicone is peeled out of a mild undercut, so it only warns; a rigid resin is stuck in one, so the mold is refused")
                    Picker("Plane", selection: Binding(get: { partingTag(mold.parting) }, set: { tag in
                        if let choice = model.moldPartingChoices.first(where: { partingTag($0.parting) == tag }) {
                            model.updateMold(mold.id, "Change Parting") { $0.parting = choice.parting }
                        }
                    })) {
                        ForEach(model.moldPartingChoices, id: \.title) { Text($0.title).tag(partingTag($0.parting)) }
                    }
                    size("Offset", mold.partingOffset, mold, "Move Parting Plane") { $0.partingOffset = $1 }
                    Picker("Pieces", selection: Binding(get: { mold.pieces }, set: { n in model.updateMold(mold.id, "Change Pieces") { $0.pieces = n } })) {
                        Text("Two halves").tag(2)
                        Text("Four pieces").tag(4)
                    }
                    .help("Four pieces cut each half again across a second plane: each piece is pulled out sideways as well as away, so more shapes let go")
                    if mold.pieces == 4 {
                        // The second plane is square to an axis other than the parting plane's.
                        let partingAxis: MoldAxis? = result.flatMap { r in MoldAxis.allCases.first { abs(simd_dot(r.partingNormal, $0.vector)) > 0.5 } }
                        Picker("Second cut", selection: Binding(get: { mold.cross }, set: { c in model.updateMold(mold.id, "Change Second Cut") { $0.cross = c } })) {
                            Text("Automatic").tag(MoldAxis?.none)
                            ForEach(MoldAxis.allCases.filter { $0 != partingAxis }, id: \.self) { Text("Across \($0.rawValue.uppercased())").tag(MoldAxis?.some($0)) }
                        }
                        .help("The second plane, through the middle of the body. Automatic picks one that holds the pour direction, so the gate and vents are cut lengthways")
                    }
                    Picker("Pour from", selection: Binding(get: { mold.up }, set: { d in model.updateMold(mold.id, "Change Pour Direction") { $0.up = d } })) {
                        ForEach(MoldDirection.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                    }
                    .help("The way up while the silicone is poured: the gate goes in at the body's highest point this way")
                    size("Wall", mold.wall, mold, "Change Wall") { $0.wall = $1 }
                }
                Section("Gate · where you pour") {
                    size("Diameter", mold.gateDiameter, mold, "Change Gate") { $0.gateDiameter = $1 }
                    LabeledContent("Position") {
                        HStack(spacing: DS.Spacing.space3) {
                            Text(mold.gatePoint == nil ? "Highest point" : "Placed by hand").foregroundStyle(.secondary)
                            if mold.gatePoint != nil {
                                Button("Reset") { model.updateMold(mold.id, "Reset Gate") { $0.gatePoint = nil } }.controlSize(.small)
                            }
                        }
                    }
                }
                Section("Vents · where air escapes") {
                    size("Diameter", mold.ventDiameter, mold, "Change Vents") { $0.ventDiameter = $1 }
                    if mold.vents.isEmpty {
                        Text("None. Add one at the top of a pocket where air would be trapped.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(mold.vents.enumerated()), id: \.offset) { i, v in
                        LabeledContent("Vent \(i + 1)") {
                            HStack(spacing: DS.Spacing.space3) {
                                Text(String(format: "%.0f, %.0f, %.0f", v.x, v.y, v.z)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Button { model.updateMold(mold.id, "Remove Vent") { $0.vents.remove(at: i) } } label: { Icon("x", size: 12) }
                                    .buttonStyle(.borderless)
                                    .help("Remove this vent")
                            }
                        }
                    }
                }
                Section("Keys") {
                    Toggle("Keys on the seams", isOn: Binding(get: { mold.keys }, set: { v in model.updateMold(mold.id, v ? "Add Keys" : "Remove Keys") { $0.keys = v } }))
                    if mold.keys {
                        size("Size", mold.keyDiameter, mold, "Change Keys") { $0.keyDiameter = $1 }
                        size("Clearance", mold.keyClearance, mold, "Change Key Clearance") { $0.keyClearance = $1 }
                    }
                }
                Section("View") {
                    LabeledContent("Open") {
                        Slider(value: $model.moldOpenAmount, in: 0...1)
                            .disabled(result?.isBuilt != true)
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            Text("Click a body in the 3D view, and the mold's settings are here.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(Panel.inset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    /// A size field: the text is an expression like any other size, so a parameter can be used.
    private func size(_ label: String, _ text: String, _ mold: MoldSetup, _ action: String, _ set: @escaping (inout MoldSetup, String) -> Void) -> some View {
        LabeledContent(label) {
            ExpressionField(text: text) { v in model.updateMold(mold.id, action) { set(&$0, v) } }
        }
    }

    private func partingTag(_ p: MoldParting) -> String {
        switch p {
        case .middle(let axis): "middle-\(axis.rawValue)"
        case .plane(.xy): "plane-xy"
        case .plane(.xz): "plane-xz"
        case .plane(.yz): "plane-yz"
        case .plane(.plane(let id)): "plane-\(id)"
        case .plane(.face(let ref)): "face-\(ref.body)-\(ref.face)"
        }
    }
}

/// Whether the halves can let go of the body: the undercut and no-draft shares, and what the colours of the Check view mean.
private struct MoldCheckRows: View {
    let model: DocumentModel
    let analysis: MoldAnalysis

    var body: some View {
        LabeledContent("Undercuts") {
            Text(analysis.hasUndercuts ? String(format: "%d face%@, %.0f%%", analysis.undercutFaces.count, analysis.undercutFaces.count == 1 ? "" : "s", analysis.undercutShare * 100) : "None")
                .foregroundStyle(analysis.hasUndercuts ? Color.red : Color.secondary)
        }
        LabeledContent("No draft", value: String(format: "%.0f%% of the surface", analysis.noDraftShare * 100))
        if model.moldCheckView {
            HStack(spacing: DS.Spacing.space5) {
                legend("Lets go", MoldAnalysis.Release.free)
                legend("No draft", .noDraft)
                legend("Undercut", .undercut)
            }
            .font(.caption)
        }
        Button(model.moldCheckView ? "Back to the mold" : "Show on the body") { model.toggleMoldCheck() }
            .controlSize(.small)
    }

    private func legend(_ title: String, _ release: MoldAnalysis.Release) -> some View {
        let c = DocumentModel.releaseColor(release)
        return HStack(spacing: DS.Spacing.space1) {
            Circle().fill(Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))).frame(width: 9, height: 9)
            Text(title).foregroundStyle(.secondary)
        }
    }
}

/// What the mold comes to: an error in words, the warnings, and the numbers worth having (the silicone to mix, the size of the block).
private struct MoldResultRows: View {
    let model: DocumentModel
    let mold: MoldSetup
    let result: MoldResult?

    var body: some View {
        if model.moldBuilding, result == nil {
            HStack { ProgressView().controlSize(.small); Text("Building…") }
        } else if let result {
            if let error = result.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else {
                // The cavity holds the body, the gate and the vents: this is the silicone (or resin) to mix, plus a little to spare.
                LabeledContent("Silicone", value: Self.millilitres(result.cavityVolume))
                    .help("What the cavity holds: the body, the gate and the vents. Mix a little more than this.")
                LabeledContent("Block", value: String(format: "%.0f × %.0f × %.0f mm", result.blockSize.x, result.blockSize.y, result.blockSize.z))
                if result.seconds >= 1 { LabeledContent("Built in", value: String(format: "%.1f s", result.seconds)) }  // only a heavy body is worth saying
            }
            ForEach(result.warnings, id: \.self) { w in
                Label(w, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
            if model.moldBuilding {
                HStack { ProgressView().controlSize(.small); Text("Updating…").foregroundStyle(.secondary) }
            }
        }
    }

    static func millilitres(_ mm3: Double) -> String {
        let ml = mm3 / 1000
        return ml < 10 ? String(format: "%.1f mL", ml) : String(format: "%.0f mL", ml)
    }
}

// MARK: - Export

#if os(macOS)
extension DocumentModel {
    /// Writes the pieces of the active mold, laid out for printing (see `MoldBuilder.printLayout`): as one file or one each.
    func exportMoldHalves() {
        guard let mold = activeMold, let built = moldResults[mold.id], built.isBuilt else {
            alert = AlertInfo(title: "There is nothing to export", message: "The mold has not been built. Fix what the Mold panel says first.")
            return
        }
        let placed = MoldBuilder.printLayout(built)
        let noun = mold.pieces == 4 ? "pieces" : "halves"
        guard placed.count == built.pieces.count, let choice = Self.askExportChoice(bodyCount: placed.count, noun: noun) else { return }
        choice.remember()
        switch choice.grouping {
        case .onePart:
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(CADService.safeFileName(mold.name)).\(choice.fileExtension)"
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url, write(placed, format: choice.format, to: url) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .individualParts:
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = "Export"
            panel.message = "Choose where to put the \(noun) of \(mold.name), one file each."
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            let written = writeIndividually(placed, format: choice.format, into: folder)
            if written.count == placed.count { NSWorkspace.shared.activateFileViewerSelecting(written) }
        }
    }
}
#endif
