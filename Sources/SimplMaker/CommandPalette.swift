// The command palette (⌘K): type a few letters of anything the menus and toolbar can do, or of a feature in the
// part, and press Return. The commands are the ones the menus run; this is only another way to reach them.
// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import SwiftUI

/// One thing the palette can do.
struct PaletteItem: Identifiable {
    let id: String
    let title: String
    /// Where it lives in the menus ("Create", "View"), shown after the title and searched too.
    let group: String
    /// Words that find it besides its title ("fillet" for "Round Corner").
    var keywords = ""
    /// Its shortcut as the menus show it, or its state ("On").
    var detail: String?
    let perform: @MainActor () -> Void
}

enum PaletteSearch {
    /// The items that match every word of the query, best first. An empty query lists everything in its given order.
    /// A word scores most when the title starts with it, then when a word of the title does, then when it is inside the
    /// title; letters in order (`xtr` for Extrude) score least. The group and keywords count for less than the title.
    static func rank(_ query: String, _ items: [PaletteItem]) -> [PaletteItem] {
        let words = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return items }
        var scored: [(item: PaletteItem, score: Int, order: Int)] = []
        for (order, item) in items.enumerated() {
            let title = item.title.lowercased()
            var total = 0
            var matchedAll = true
            for word in words {
                let s = score(word, title: title, other: (item.group + " " + item.keywords).lowercased())
                if s == 0 { matchedAll = false; break }
                total += s
            }
            if matchedAll { scored.append((item, total - title.count / 4, order)) }
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }.map(\.item)
    }

    private static func score(_ word: String, title: String, other: String) -> Int {
        if title.hasPrefix(word) { return 100 }
        let titleWords = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if titleWords.contains(where: { $0.hasPrefix(word) }) { return 80 }
        if title.contains(word) { return 50 }
        let otherWords = other.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if otherWords.contains(where: { $0.hasPrefix(word) }) { return 30 }
        if other.contains(word) { return 15 }
        if word.count >= 2, isSubsequence(word, of: title) { return 10 }
        return 0
    }

    private static func isSubsequence(_ word: String, of text: String) -> Bool {
        var rest = word[...]
        for ch in text where ch == rest.first { rest = rest.dropFirst(); if rest.isEmpty { return true } }
        return rest.isEmpty
    }
}

extension DocumentModel {
    /// Everything the palette offers for this part right now: the tools that fit what the user is doing, the view and file
    /// commands, and "Edit" for each feature.
    func paletteItems() -> [PaletteItem] {
        var items: [PaletteItem] = []
        func add(_ title: String, _ group: String, keywords: String = "", shortcut: ShortcutCommand? = nil, detail: String? = nil,
                 _ perform: @escaping @MainActor () -> Void) {
            items.append(PaletteItem(id: "\(group).\(title)", title: title, group: group, keywords: keywords,
                                     detail: detail ?? shortcut.flatMap { Shortcuts.label($0) }, perform: perform))
        }
        let defaults = UserDefaults.standard
        func flag(_ key: String) -> Bool { defaults.object(forKey: key) as? Bool ?? true }
        func flip(_ key: String) { defaults.set(!flag(key), forKey: key) }
        func state(_ on: Bool) -> String { on ? "On" : "Off" }

        if sketchSession != nil {
            for tool in SketchTool.allCases {
                add(tool.rawValue, "Sketch", keywords: Self.paletteKeywords[tool.rawValue] ?? "",
                    shortcut: tool.family[0] == tool ? .sketch(tool) : nil) { self.setSketchTool(tool) }
            }
            add("Finish Sketch", "Sketch", keywords: "done exit close") { self.finishSketch() }
        } else {
            let groups: [(String, [DesignTool])] = [("Create", DesignTool.shapes + DesignTool.primitives + [.plane, .canvas]),
                                                    ("Modify", DesignTool.modifiers + [.mirror, .pattern]),
                                                    ("Inspect", DesignTool.inspect)]
            for (group, tools) in groups {
                for tool in tools {
                    add(tool.rawValue, group, keywords: Self.paletteKeywords[tool.rawValue] ?? "", shortcut: .tool(tool)) { self.run(tool) }
                }
            }
            add("New Sketch…", "Sketch", keywords: "draw") { self.startSketch() }
            add("New Sketch on XY Plane", "Sketch", keywords: "draw top") { self.beginSketch(on: .xy) }
            add("New Sketch on XZ Plane", "Sketch", keywords: "draw front") { self.beginSketch(on: .xz) }
            add("New Sketch on YZ Plane", "Sketch", keywords: "draw right side") { self.beginSketch(on: .yz) }
        }

        for v in StandardView.allCases { add("\(v.title) View", "View", shortcut: .view(v)) { self.show(v) } }
        add("Fit All", "View", keywords: "zoom", shortcut: .fitAll) { self.fitView() }
        add("Orthographic Projection", "View", keywords: "perspective camera", shortcut: .orthographic, detail: state(orthographic)) { self.orthographic.toggle() }
        for style in VisualStyle.allCases { add("\(style.title) Style", "View", keywords: "visual wireframe shaded edges") { self.visualStyle = style } }
        if visualStyle.isShaded {
            add("FDM 3D Print Preview", "View", keywords: "layers slicer", detail: state(printPreview)) { self.setPrintPreview(!self.printPreview) }
        }
        add("Show or Hide UI", "View", keywords: "panels toolbar clean", shortcut: .hideUI, detail: state(uiHidden)) { self.toggleUIHidden() }
        add("Render", "View", keywords: "shadows reflection picture", detail: state(renderView)) { self.setRenderView(!self.renderView) }
        add("Section Analysis", "View", keywords: "cut slice", detail: state(sectionActive)) { self.setSectionAnalysis(!self.sectionActive) }
        add("Exploded View", "View", keywords: "assembly separate", detail: state(explodeOn)) { self.setExplodedView(!self.explodeOn) }
        add("Show Grid", "View", shortcut: .showGrid, detail: state(flag(Preferences.showGrid))) { flip(Preferences.showGrid) }
        add("Show Axes", "View", shortcut: .showAxes, detail: state(flag(Preferences.showAxes))) { flip(Preferences.showAxes) }
        add("Show Constraints", "View", detail: state(flag(Preferences.showConstraints))) { flip(Preferences.showConstraints) }
        add("Snap to Grid", "View", shortcut: .snapToGrid, detail: state(flag(Preferences.snapToGrid))) { flip(Preferences.snapToGrid) }
        add("Browser", "View", keywords: "sidebar show hide", shortcut: .browser, detail: state(showSidebar)) { self.showSidebar.toggle() }
        add("Timeline", "View", keywords: "history show hide", shortcut: .timeline, detail: state(showTimeline)) { self.showTimeline.toggle() }
        add("Inspector", "View", keywords: "properties show hide", shortcut: .inspector, detail: state(showInspector)) { self.showInspector.toggle() }

        add("Export…", "File", keywords: "save stl step 3mf print") { self.exportWithDialog() }
        add("Import STEP…", "File", keywords: "open", shortcut: .importSTEP) { self.importSTEP() }
        add("Import STL…", "File", keywords: "open mesh") { self.importSTL() }
        add("Import SVG as Sketch…", "File", keywords: "open drawing vector") { self.importSVG() }
        add("Import DXF as Sketch…", "File", keywords: "open drawing cad laser") { self.importDXF() }
        add("Rebuild", "Model", keywords: "regenerate refresh", shortcut: .rebuild) { self.regenerate() }
        if fileURL != nil { add("Rename…", "File", keywords: "name") { RenameDocument.shared.rename() } }
        if let id = selectedFeature, let feature = document.features.first(where: { $0.id == id }), case .sketch = feature.kind {
            add("Export \(feature.name) as DXF…", "File", keywords: "laser cnc drawing") { self.exportDXF(sketch: id) }
        }

        for feature in document.features {
            add("Edit \(feature.name)", "Feature", keywords: "change open select") { self.editFeature(feature.id) }
        }
        return items
    }

    /// Other names people know a tool by.
    private static let paletteKeywords: [String: String] = [
        "Extrude": "pad boss push pull cut", "Revolve": "lathe spin", "Sweep": "rail path", "Loft": "blend",
        "Fillet": "round edge", "Chamfer": "bevel edge", "Hole": "drill bore countersink", "Shell": "hollow",
        "Thread": "screw bolt", "Move": "translate rotate turn", "Scale": "resize", "Combine": "join union cut subtract merge",
        "Split Body": "cut divide", "Lay on Floor": "flat orient print", "Mirror": "reflect symmetry", "Pattern": "array copies",
        "Measure": "distance ruler", "Canvas": "image picture reference", "Round Corner": "fillet", "Spline": "curve bezier",
        "Trim": "cut", "Extend": "lengthen", "Dimension": "size constraint", "Gear": "cog teeth",
    ]
}

/// The palette itself: a search field over a list, floating near the top of the window.
struct CommandPaletteView: View {
    @Bindable var model: DocumentModel
    @State private var items: [PaletteItem] = []
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    private var results: [PaletteItem] { PaletteSearch.rank(query, items) }

    var body: some View {
        let shown = results
        ZStack(alignment: .top) {
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .onTapGesture { close() }
            VStack(spacing: 0) {
                HStack(spacing: DS.Spacing.space4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search tools and commands", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .focused($focused)
                        .onSubmit { run(shown, selected) }
                        .accessibilityLabel("Search tools and commands")
                }
                .padding(.horizontal, DS.Spacing.space5)
                .frame(height: 40)
                Divider()
                if shown.isEmpty {
                    Text("Nothing matches “\(query)”")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 56)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                                    row(item, highlighted: index == selected)
                                        .id(item.id)
                                        .contentShape(Rectangle())
                                        .onTapGesture { run(shown, index) }
                                }
                            }
                            .padding(DS.Spacing.space2)
                        }
                        .frame(maxHeight: 340)
                        .onChange(of: selected) { _, new in
                            if shown.indices.contains(new) { proxy.scrollTo(shown[new].id) }
                        }
                    }
                }
            }
            .frame(width: 520)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.window))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.window).strokeBorder(Color.primary.opacity(0.12)))
            .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
            .padding(.top, 90)
            .onKeyPress(.downArrow) { move(1, in: shown.count); return .handled }
            .onKeyPress(.upArrow) { move(-1, in: shown.count); return .handled }
            .onKeyPress(.escape) { close(); return .handled }
        }
        .onAppear { items = model.paletteItems(); focused = true }
        .onChange(of: query) { selected = 0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command palette")
    }

    private func row(_ item: PaletteItem, highlighted: Bool) -> some View {
        HStack(spacing: DS.Spacing.space4) {
            Text(item.title).lineLimit(1)
            Text(item.group).font(.caption).foregroundStyle(highlighted ? .primary : .secondary)
            Spacer(minLength: DS.Spacing.space4)
            if let detail = item.detail {
                Text(detail).font(.system(size: 12, design: .rounded)).foregroundStyle(highlighted ? .primary : .secondary)
            }
        }
        .padding(.horizontal, DS.Spacing.space4)
        .frame(height: 28)
        .background(highlighted ? DS.brand.opacity(0.22) : Color.clear, in: RoundedRectangle(cornerRadius: DS.Radius.menuItem))
    }

    private func move(_ step: Int, in count: Int) {
        guard count > 0 else { return }
        selected = min(max(selected + step, 0), count - 1)
    }

    private func close() { model.showPalette = false }

    /// Closes the palette first, so the window has its focus back when the command runs (a file dialog, a tool's panel).
    private func run(_ shown: [PaletteItem], _ index: Int) {
        guard shown.indices.contains(index) else { return }
        let action = shown[index].perform
        close()
        DispatchQueue.main.async { action() }
    }
}
