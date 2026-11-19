// The Split workspace's screens: the tool row in the ribbon, the list of splits and bodies on the left, the split's settings and what it
// comes to on the right, and the export of the pieces. The model is SplitStudio.swift; the geometry is PrintSplitBuilder.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
#if os(macOS)
import AppKit
import CADCore
import CADKernel
import SwiftUI

// MARK: - Ribbon

/// The printer in the ribbon: its name, and a menu of the popular printers and a custom volume.
private struct PrinterMenu: View {
    @Bindable var model: DocumentModel
    let split: PrintSplit
    @Environment(\.toolsOnTint) private var onTint
    @Environment(\.toolsInk) private var toolsInk

    var body: some View {
        let ink = onTint ? toolsInk : Color.primary
        let preset = PrinterPreset.preset(split.printer)
        Menu {
            Picker("Printer", selection: Binding(get: { split.printer }, set: { id in
                model.updateSplit(split.id, "Change Printer") { $0.printer = id }
            })) {
                ForEach(PrinterPreset.makers, id: \.self) { maker in
                    Section {
                        ForEach(PrinterPreset.catalog.filter { $0.maker == maker }) { p in
                            Text("\(p.title)   \(p.sizeText)").tag(p.id)
                        }
                    }
                }
                Section { Text("Custom volume").tag(PrinterPreset.customID) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: DS.Spacing.space3) {
                Icon("printer", size: 16, renderedStroke: Icon.toolStroke)
                VStack(alignment: .leading, spacing: 0) {
                    Text(preset?.title ?? "Custom volume").font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(preset?.sizeText ?? split.customVolume.joined(separator: " × ")).font(.system(size: 10)).opacity(0.7).lineLimit(1)
                }
                Icon("chevron-down", size: 8, weight: .medium).opacity(0.7)
            }
            .foregroundStyle(ink)
            .frame(maxWidth: 190, minHeight: ToolListMetrics.toolMinHeight)
            .padding(.horizontal, DS.Spacing.space3)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .toolTip("The printer the pieces have to fit: its build volume less the margin")
    }
}

/// How many pieces across one axis: a menu of Auto and 1 to 8, showing what the split came to.
private struct CountMenu: View {
    @Bindable var model: DocumentModel
    let split: PrintSplit
    let axis: MoldAxis
    @Environment(\.toolsOnTint) private var onTint
    @Environment(\.toolsInk) private var toolsInk

    var body: some View {
        let ink = onTint ? toolsInk : Color.primary
        let shown = model.activeSplitResult?.counts[axis.index]
        let byHand = split.cuts != nil
        Menu {
            Picker("Pieces across \(axis.rawValue.uppercased())", selection: Binding(get: { split.counts[axis.index] }, set: { n in
                model.updateSplit(split.id, "Change Cuts") { $0.counts[axis.index] = n }
            })) {
                Text("Automatic").tag(0)
                ForEach(1...8, id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: DS.Spacing.space1) {
                Text(axis.rawValue.uppercased()).font(.system(size: 13, weight: .semibold))
                Text(shown.map { "\($0)" } ?? "–").font(.system(size: 13).monospacedDigit())
                    .opacity(split.counts[axis.index] == 0 ? 0.6 : 1)
            }
            .foregroundStyle(ink)
            .frame(minWidth: ToolListMetrics.toolMinWidth, minHeight: ToolListMetrics.toolMinHeight)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(byHand)
        .toolTip(byHand ? "The cuts are placed by hand (see the panel on the right)" : "How many pieces across \(axis.rawValue.uppercased()): Automatic uses the fewest that fit the printer")
    }
}

/// The Split workspace's tool row: Printer · Pieces · Connector · Fit · View · Export, live sections that work on the split chosen on the
/// left (not a wizard: any of them can be changed at any time).
struct SplitToolbar: View {
    @Bindable var model: DocumentModel

    var body: some View {
        HStack(spacing: DS.Spacing.space3) {
            if let split = model.activeSplit {
                let built = model.activeSplitResult?.isBuilt == true
                MoldGroup(title: "Printer") { PrinterMenu(model: model, split: split) }
                RibbonDivider()
                MoldGroup(title: "Pieces") {
                    ForEach(MoldAxis.allCases, id: \.self) { CountMenu(model: model, split: split, axis: $0) }
                }
                RibbonDivider()
                MoldGroup(title: "Connector") {
                    ForEach(ConnectorKind.allCases, id: \.self) { kind in
                        ToolButton(title: kind.title, icon: kind.symbol, active: split.connector == kind, help: "\(kind.title): \(kind.help)") {
                            model.updateSplit(split.id, "Change Connector") { $0.choose(kind) }
                        }
                    }
                    ToolButton(title: "Separate", icon: "unlink", active: split.separate && split.connector.canBeSeparate,
                               help: "Make the pin or key a part of its own: a socket in each piece, and the pin printed apart (or cut from a rod)") {
                        model.updateSplit(split.id, split.separate ? "Pins on the Pieces" : "Separate Pins") { $0.separate.toggle() }
                    }
                    .disabled(!split.connector.canBeSeparate)
                }
                RibbonDivider()
                MoldGroup(title: "Fit") {
                    ForEach([SplitFit.tight, .standard, .loose], id: \.self) { fit in
                        AxisButton(label: String(format: "%.1f", fit.clearance ?? 0), active: split.fit == fit, help: "\(fit.title): \(fit.help)") {
                            model.updateSplit(split.id, "Change Fit") { $0.fit = fit }
                        }
                    }
                }
                .disabled(split.connector == .none)
                RibbonDivider()
                MoldGroup(title: "View") {
                    ToolButton(title: "Open", icon: "expand", active: model.splitOpenAmount > 0, help: "Draw the pieces apart") {
                        model.splitOpenAmount = model.splitOpenAmount > 0 ? 0 : 0.7
                        model.sceneRevision += 1
                    }
                    .disabled(!built || (model.activeSplitResult?.pieces.count ?? 0) < 2)
                }
                RibbonDivider()
                MoldGroup(title: "Export") {
                    ToolButton(title: "Export", icon: "download", help: "Write the pieces, laid out for printing, as STL, 3MF or STEP") {
                        model.exportSplitPieces()
                    }
                    .disabled(!built)
                }
            } else {
                Text(model.bodies.isEmpty ? "Model a body in Design first, then split it here." : "Choose a body on the left to split.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 44)
        .fixedSize()
    }
}

// MARK: - Left: splits and bodies

/// The splits of the part, and the bodies a split can be made of.
struct SplitSidebar: View {
    @Bindable var model: DocumentModel

    var body: some View {
        VStack(spacing: Panel.inset) {
            SidebarPanel(title: "Splits", open: .constant(true), accessory: { EmptyView() }) {
                SplitList(model: model)
            }
            SidebarPanel(title: "Bodies", open: .constant(true), accessory: { EmptyView() }) {
                SplitBodyList(model: model)
            }
        }
        .frame(width: Panel.sidebarWidth)
        .frame(maxHeight: .infinity)
    }
}

private struct SplitList: View {
    @Bindable var model: DocumentModel

    var body: some View {
        if model.document.printSplits.isEmpty {
            VStack(spacing: DS.Spacing.space3) {
                Text("No split yet")
                    .font(.system(size: 13, weight: .medium))
                Text("Make one from a body below: it is cut into pieces that fit your printer, with connectors to put them back together.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(Panel.inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            List(selection: Binding(get: { model.activeSplit?.id }, set: { if let id = $0 { model.selectSplit(id) } })) {
                ForEach(model.document.printSplits) { split in
                    SplitRow(model: model, split: split)
                        .tag(split.id)
                        .contextMenu {
                            Button("Delete Split", role: .destructive) { model.deleteSplit(split.id) }
                        }
                }
            }
            .listStyle(.sidebar)
        }
    }
}

private struct SplitRow: View {
    let model: DocumentModel
    let split: PrintSplit

    var body: some View {
        let result = model.splitResults[split.id]
        let bodyName = model.bodies.first { $0.id == split.body }?.name ?? "missing body"
        HStack(spacing: DS.Spacing.space3) {
            Icon("puzzle", size: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(split.name).lineLimit(1)
                Text(result.map { $0.isBuilt ? "\(bodyName) · \($0.pieces.count) \($0.pieces.count == 1 ? "piece" : "pieces")" : bodyName } ?? bodyName)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if model.splitBuilding, model.activeSplit?.id == split.id {
                ProgressView().controlSize(.small)
            } else if let result, result.error != nil {
                Icon("triangle-alert", size: 13).foregroundStyle(.red).help(result.error ?? "")
            } else if let result, !result.warnings.isEmpty {
                Icon("triangle-alert", size: 13).foregroundStyle(.orange).help(result.warnings.joined(separator: "\n"))
            }
        }
    }
}

private struct SplitBodyList: View {
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
                        Button("Split") { model.makeSplit(of: body.id) }
                            .controlSize(.small)
                            .help("Cut \(body.name) into pieces that fit the printer")
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }
}

// MARK: - Right: settings and result

struct SplitInspectorColumn: View {
    @Bindable var model: DocumentModel

    var body: some View {
        SidebarPanel(title: "Split", open: .constant(true), headerTrailing: PanelTouch.panelToggleRoom, accessory: { EmptyView() }) {
            PrintSplitInspector(model: model)
        }
        .frame(width: Panel.inspectorWidth)
        .frame(maxHeight: .infinity)
    }
}

private struct PrintSplitInspector: View {
    @Bindable var model: DocumentModel

    var body: some View {
        if let split = model.activeSplit {
            let result = model.splitResults[split.id]
            Form {
                Section {
                    LabeledContent("Name") {
                        ExpressionField(text: split.name, monospaced: false, completes: false) { v in
                            model.updateSplit(split.id, "Rename Split") { $0.name = v.isEmpty ? $0.name : v }
                        }
                    }
                    LabeledContent("Body", value: model.bodies.first { $0.id == split.body }?.name ?? "missing")
                }
                Section("Result") { SplitResultRows(model: model, split: split, result: result) }
                if let result, result.isBuilt, result.pieces.count > 1 || !result.allFit {
                    Section("Pieces") { SplitPieceRows(result: result) }
                }
                Section("Printer") {
                    Picker("Printer", selection: Binding(get: { split.printer }, set: { id in model.updateSplit(split.id, "Change Printer") { $0.printer = id } })) {
                        ForEach(PrinterPreset.makers, id: \.self) { maker in
                            Section {
                                ForEach(PrinterPreset.catalog.filter { $0.maker == maker }) { Text($0.title).tag($0.id) }
                            }
                        }
                        Section { Text("Custom volume").tag(PrinterPreset.customID) }
                    }
                    if let preset = PrinterPreset.preset(split.printer) {
                        LabeledContent("Build volume", value: preset.sizeText)
                    } else {
                        ForEach(0..<3, id: \.self) { i in
                            LabeledContent(["Width (X)", "Depth (Y)", "Height (Z)"][i]) {
                                ExpressionField(text: split.customVolume[i], commit: { v in
                                    model.updateSplit(split.id, "Change Build Volume") { $0.customVolume[i] = v }
                                })
                            }
                        }
                    }
                    size("Margin", split.margin, split, "Change Margin", help: "Kept free all round the build volume: the skirt, the brim and the edge of the bed") { $0.margin = $1 }
                    if let usable = result?.usableVolume, usable != .zero {
                        LabeledContent("Usable", value: String(format: "%.0f × %.0f × %.0f mm", usable.x, usable.y, usable.z))
                    }
                    Toggle("Turn pieces to fit", isOn: Binding(get: { split.turn }, set: { v in model.updateSplit(split.id, "Change Turning") { $0.turn = v } }))
                        .help("A piece may stand on the bed any way up, so a long piece can lie down or stand up. The export lays each piece that way")
                }
                Section("Cuts") {
                    Picker("Cuts", selection: Binding(get: { split.cuts != nil }, set: { model.setSplitCutsByHand(split.id, $0) })) {
                        Text("Automatic").tag(false)
                        Text("By hand").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if split.cuts == nil {
                        ForEach(MoldAxis.allCases, id: \.self) { axis in
                            Picker("Pieces across \(axis.rawValue.uppercased())", selection: Binding(get: { split.counts[axis.index] }, set: { n in
                                model.updateSplit(split.id, "Change Cuts") { $0.counts[axis.index] = n }
                            })) {
                                Text("Automatic").tag(0)
                                ForEach(1...8, id: \.self) { Text("\($0)").tag($0) }
                            }
                        }
                        Text("Automatic uses the fewest pieces that fit, cut evenly.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        SplitCutRows(model: model, split: split)
                    }
                }
                Section("Connectors") {
                    Picker("Type", selection: Binding(get: { split.connector }, set: { kind in model.updateSplit(split.id, "Change Connector") { $0.choose(kind) } })) {
                        ForEach(ConnectorKind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Text(split.connector.help).font(.caption).foregroundStyle(.secondary)
                    if split.connector.canBeSeparate {
                        Toggle("Separate part", isOn: Binding(get: { split.separate }, set: { v in
                            model.updateSplit(split.id, v ? "Separate Pins" : "Pins on the Pieces") { $0.separate = v }
                        }))
                        .help("The \(split.looseName) is not printed on a piece: both pieces get a socket, and the \(split.looseName) is exported as a part of its own")
                    }
                    if split.connector != .none {
                        size(split.connector.sizeLabel, split.connectorSize, split, "Change Connector Size") { $0.connectorSize = $1 }
                        size(split.separate && split.connector.canBeSeparate ? "Depth in each piece" : split.connector.lengthLabel, split.connectorLength, split, "Change Connector Length") { $0.connectorLength = $1 }
                        size("Spacing", split.spacing, split, "Change Connector Spacing", help: "About how far apart the connectors are on a wide cut") { $0.spacing = $1 }
                        Picker("Fit", selection: Binding(get: { split.fit }, set: { f in model.updateSplit(split.id, "Change Fit") { $0.fit = f } })) {
                            ForEach(SplitFit.allCases, id: \.self) { f in
                                Text(f.clearance.map { "\(f.title) · \(String(format: "%.1f", $0)) mm" } ?? f.title).tag(f)
                            }
                        }
                        .help(split.fit.help)
                        if split.fit == .custom {
                            size("Clearance", split.customClearance, split, "Change Clearance", help: "The gap all round a connector in its socket") { $0.customClearance = $1 }
                        }
                        Text(split.fit.help).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("View") {
                    LabeledContent("Apart") {
                        Slider(value: $model.splitOpenAmount, in: 0...1)
                            .disabled(result?.isBuilt != true)
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            Text("Make a split from a body on the left, and its settings are here.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(Panel.inset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    /// A size field: the text is an expression like any other size, so a parameter can be used.
    private func size(_ label: String, _ text: String, _ split: PrintSplit, _ action: String, help: String? = nil,
                      _ set: @escaping (inout PrintSplit, String) -> Void) -> some View {
        LabeledContent(label) {
            ExpressionField(text: text) { v in model.updateSplit(split.id, action) { set(&$0, v) } }
        }
        .help(help ?? "")
    }
}

/// The cuts by hand: each an axis and a place along it, and a button for one more.
private struct SplitCutRows: View {
    @Bindable var model: DocumentModel
    let split: PrintSplit

    var body: some View {
        let cuts = split.cuts ?? []
        if cuts.isEmpty {
            Text("No cuts: the body stays in one piece.").font(.caption).foregroundStyle(.secondary)
        }
        ForEach(Array(cuts.enumerated()), id: \.offset) { i, cut in
            HStack(spacing: DS.Spacing.space3) {
                Picker("Axis", selection: Binding(get: { cut.axis }, set: { a in model.updateSplit(split.id, "Change Cut") { $0.cuts?[i].axis = a } })) {
                    ForEach(MoldAxis.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                ExpressionField(text: cut.position) { v in model.updateSplit(split.id, "Move Cut") { $0.cuts?[i].position = v } }
                Button { model.updateSplit(split.id, "Remove Cut") { $0.cuts?.remove(at: i) } } label: { Icon("x", size: 12) }
                    .buttonStyle(.borderless)
                    .help("Remove this cut")
            }
        }
        Button("Add Cut") {
            // A new cut goes through the middle of the body, across the axis it is longest in.
            let bounds = model.result?.body(split.body)?.bounds
            let ext = bounds.map { $0.max - $0.min } ?? SIMD3(1, 1, 1)
            let axis: MoldAxis = ext.x >= ext.y && ext.x >= ext.z ? .x : ext.y >= ext.z ? .y : .z
            let middle = bounds.map { ($0.min[axis.index] + $0.max[axis.index]) / 2 } ?? 0
            model.updateSplit(split.id, "Add Cut") { $0.cuts?.append(PrintSplitCut(axis: axis, position: PrintSplitBuilder.text(middle))) }
        }
        .controlSize(.small)
        Text("A cut is a plane across an axis, at a coordinate of the world.").font(.caption).foregroundStyle(.secondary)
    }
}

/// The pieces, each with its size and whether it fits.
private struct SplitPieceRows: View {
    let result: PrintSplitResult

    var body: some View {
        ForEach(result.pieces) { piece in
            HStack(spacing: DS.Spacing.space3) {
                Text(piece.name.components(separatedBy: " part ").last.map { "Part \($0)" } ?? piece.name).lineLimit(1)
                Spacer(minLength: 0)
                Text(String(format: "%.0f × %.0f × %.0f", piece.size.x, piece.size.y, piece.size.z))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Icon(piece.fits ? "check" : "triangle-alert", size: 12)
                    .foregroundStyle(piece.fits ? Color.green : Color.red)
                    .help(piece.fits ? "Fits the printer" : "Too big for the printer")
            }
        }
    }
}

/// What the split comes to: an error in words, the numbers worth having (pieces, plates, connectors) and the warnings.
private struct SplitResultRows: View {
    let model: DocumentModel
    let split: PrintSplit
    let result: PrintSplitResult?

    var body: some View {
        if model.splitBuilding, result == nil {
            HStack { ProgressView().controlSize(.small); Text("Cutting…") }
        } else if let result {
            if let error = result.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else {
                LabeledContent("Pieces", value: "\(result.pieces.count)")
                LabeledContent("Body", value: String(format: "%.0f × %.0f × %.0f mm", result.bodySize.x, result.bodySize.y, result.bodySize.z))
                if result.connectorCount > 0 { LabeledContent("Connectors", value: "\(result.connectorCount)") }
                if !result.dowels.isEmpty {
                    LabeledContent("\(split.looseName.capitalized)s to print", value: "\(result.dowels.count)")
                        .help("Each one joins two pieces: they are exported with the pieces")
                }
                LabeledContent("Plates", value: "\(result.plates)")
                    .help("How many builds the pieces take, packed in rows on the bed")
                if result.seconds >= 1 { LabeledContent("Built in", value: String(format: "%.1f s", result.seconds)) }
            }
            ForEach(result.warnings, id: \.self) { w in
                Label(w, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
            if model.splitBuilding {
                HStack { ProgressView().controlSize(.small); Text("Updating…").foregroundStyle(.secondary) }
            }
        }
    }
}

// MARK: - Export

extension DocumentModel {
    /// Writes the pieces of the active split (and the loose dowels), laid out for printing (see `PrintSplitBuilder.printLayout`): as one
    /// file or one each.
    func exportSplitPieces() {
        guard let split = activeSplit, let built = splitResults[split.id], built.isBuilt else {
            alert = AlertInfo(title: "There is nothing to export", message: "The split has not been built. Fix what the Split panel says first.")
            return
        }
        let layout = PrintSplitBuilder.printLayout(built)
        let placed = layout.bodies
        guard !placed.isEmpty, let choice = Self.askExportChoice(bodyCount: placed.count, noun: "pieces") else { return }
        choice.remember()
        switch choice.grouping {
        case .onePart:
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(CADService.safeFileName(split.name)).\(choice.fileExtension)"
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url, write(placed, format: choice.format, to: url) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .individualParts:
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = "Export"
            panel.message = "Choose where to put the \(placed.count) pieces of \(split.name), one file each."
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            let written = writeIndividually(placed, format: choice.format, into: folder)
            if written.count == placed.count { NSWorkspace.shared.activateFileViewerSelecting(written) }
        }
    }
}
#endif
