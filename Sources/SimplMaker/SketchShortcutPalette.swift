// The sketch shortcut palette: Spacebar while sketching opens a small floating panel of the tools used most, one click
// from the pointer. A search field reaches every sketch tool, and Customize chooses which tools the panel shows.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
#if os(macOS)
import AppKit
#endif
import SwiftUI

/// Which tools the panel shows, and how that choice is stored.
enum SketchShortcutList {
    /// What the panel shows until the user customizes it.
    static let defaults: [SketchTool] = [
        .select, .line, .rectangle, .centerRectangle, .slot, .circle,
        .arc3Point, .tangentArc, .bezier, .polygon, .ellipse, .point,
        .text, .fillet, .trim, .extend, .dimension, .projectEdge,
    ]

    private static let prefix = "v1:"

    /// The stored choice, or the defaults when nothing was stored. The prefix tells "never customized" from "all removed".
    static func decode(_ stored: String) -> [SketchTool] {
        guard stored.hasPrefix(prefix) else { return defaults }
        var seen = Set<SketchTool>()
        return stored.dropFirst(prefix.count).split(separator: ",").compactMap { SketchTool(rawValue: String($0)) }.filter { seen.insert($0).inserted }
    }

    static func encode(_ tools: [SketchTool]) -> String { prefix + tools.map(\.rawValue).joined(separator: ",") }

    /// Every tool whose name (or the name of its way of drawing) contains the words typed.
    static func search(_ query: String) -> [SketchTool] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        return SketchTool.allCases.filter { tool in
            let name = (tool.menuTitle + " " + tool.rawValue + " " + tool.modeTitle).lowercased()
            return words.allSatisfy { name.contains($0) }
        }
    }
}

struct SketchShortcutPalette: View {
    @Bindable var model: DocumentModel
    @AppStorage(Preferences.sketchShortcutTools) private var stored = ""
    @State private var query = ""
    @State private var customizing = false
    /// Where the panel was dragged to, from where it opens; remembered between uses (see `remember`).
    @AppStorage(Preferences.sketchShortcutX) private var savedX = 0.0
    @AppStorage(Preferences.sketchShortcutY) private var savedY = 0.0
    @State private var offset = CGSize.zero
    @State private var dragStart: CGSize?
    @State private var windowSize = CGSize(width: 1200, height: 800)
    @FocusState private var searchFocused: Bool

    private static let columns = Array(repeating: GridItem(.fixed(40), spacing: DS.Spacing.space2), count: 6)

    private var pinned: [SketchTool] { SketchShortcutList.decode(stored) }
    private var results: [SketchTool] { SketchShortcutList.search(query) }

    var body: some View {
        ZStack {
            Color.black.opacity(0.001)  // a click outside the panel closes it
                .ignoresSafeArea()
                .onTapGesture { close() }
            panel
                .offset(clamped(offset))
                .padding(.leading, model.showSidebar ? Panel.sidebarWidth + Panel.margin : 0)
                .padding(.trailing, model.showInspector ? Panel.inspectorWidth + Panel.margin : 0)
        }
        .onDisappear { model.pointerOverSketchShortcuts = false }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { windowSize = $0 }
        .onAppear {
            offset = CGSize(width: savedX, height: savedY)
            searchFocused = true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sketch shortcuts")
    }

    private var panel: some View {
        VStack(spacing: DS.Spacing.space4) {
            header
            if customizing {
                customizeGrid
            } else if !query.isEmpty {
                searchResults
            } else {
                grid(pinned)
            }
            if !customizing { searchField }
        }
        .padding(DS.Spacing.space5)
        .frame(width: 302)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.window))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.window).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.window))
        .onHover { over in
            // The viewport under the panel sets the sketch tool's cursor; over the panel it is a normal arrow.
            model.pointerOverSketchShortcuts = over
            #if os(macOS)
            if over { NSCursor.arrow.set() }
            #endif
        }
        .gesture(moveGesture)  // the header, and the gaps between the tools, move the panel
        .onKeyPress(.escape) {
            if customizing { customizing = false } else if !query.isEmpty { query = "" } else { close() }
            return .handled
        }
    }

    private var header: some View {
        HStack {
            Text(customizing ? "Customize Shortcuts" : "Sketch Shortcuts")
                .font(.system(size: 15, weight: .medium))
            Spacer(minLength: DS.Spacing.space4)
            Button(customizing ? "Done" : "Customize") { customizing.toggle() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(DS.brand)
                .toolTip(customizing ? "Go back to the shortcuts" : "Choose which tools this panel shows")
        }
    }

    /// The drag is measured on the screen, not in the panel's own space: the panel moves with the pointer, and a drag measured
    /// in the space of what moves jitters (each move changes what the next one is measured against).
    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                let start = dragStart ?? offset
                dragStart = start
                offset = clamped(CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height))
            }
            .onEnded { _ in
                dragStart = nil
                savedX = offset.width
                savedY = offset.height
            }
    }

    /// Keeps the middle of the panel inside the window, so a remembered place never leaves it out of reach after the window shrinks.
    private func clamped(_ size: CGSize) -> CGSize {
        let x = max(windowSize.width / 2 - 60, 0), y = max(windowSize.height / 2 - 40, 0)
        return CGSize(width: min(max(size.width, -x), x), height: min(max(size.height, -y), y))
    }

    // MARK: shortcuts

    private func grid(_ tools: [SketchTool]) -> some View {
        Group {
            if tools.isEmpty {
                Text("No tools here yet. Choose Customize to add some.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 56)
            } else {
                LazyVGrid(columns: Self.columns, spacing: DS.Spacing.space2) {
                    ForEach(tools) { tool in
                        Button { choose(tool) } label: { cell(tool, marked: nil) }
                            .buttonStyle(.plain)
                            .toolTip(tool.help)
                            .accessibilityLabel(tool.menuTitle)
                    }
                }
            }
        }
    }

    /// `marked` is nil in the regular panel (no circles, the tool in use is tinted) and says whether the tool is shown while customizing.
    private func cell(_ tool: SketchTool, marked: Bool?) -> some View {
        ShortcutCell(tool: tool, marked: marked, current: marked == nil && model.sketchSession?.tool == tool)
    }

    private var searchField: some View {
        HStack(spacing: DS.Spacing.space3) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 12))
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit { if let first = results.first { choose(first) } }
                .onKeyPress { press in
                    // The key that opened the panel (Space unless changed in Settings) closes it too, until a word is being typed.
                    guard query.isEmpty, press.modifiers.isEmpty,
                          Shortcuts.chord(.sketchPanel)?.key == press.characters.lowercased().first else { return .ignored }
                    close()
                    return .handled
                }
                .accessibilityLabel("Search sketch tools")
        }
        .padding(.horizontal, DS.Spacing.space4)
        .frame(height: 28)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: DS.Radius.menuItem))
    }

    private var searchResults: some View {
        VStack(spacing: 0) {
            if results.isEmpty {
                Text("Nothing matches “\(query)”")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 40)
            } else {
                ForEach(Array(results.enumerated()), id: \.element.id) { index, tool in
                    Button { choose(tool) } label: {
                        HStack(spacing: DS.Spacing.space4) {
                            Icon(tool.symbol, size: 16, renderedStroke: Icon.toolStroke).frame(width: 20)
                            Text(tool.menuTitle).lineLimit(1)
                            Spacer(minLength: DS.Spacing.space4)
                            if let key = tool.keyLabel, tool.family[0] == tool {
                                Text(key).font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, DS.Spacing.space3)
                        .frame(height: 28)
                        .background(index == 0 ? DS.brand.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: DS.Radius.menuItem))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .toolTip(tool.help)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: customize

    private var customizeGrid: some View {
        let chosen = pinned
        return VStack(spacing: DS.Spacing.space4) {
            Text("Click a tool to add it to the panel or take it off.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            LazyVGrid(columns: Self.columns, spacing: DS.Spacing.space2) {
                ForEach(SketchTool.allCases) { tool in
                    let isOn = chosen.contains(tool)
                    Button { toggle(tool, in: chosen) } label: { cell(tool, marked: isOn) }
                        .buttonStyle(.plain)
                        .toolTip(tool.help)
                        .accessibilityLabel(tool.menuTitle)
                        .accessibilityValue(isOn ? "Shown" : "Hidden")
                }
            }
            Button("Reset to Default") { stored = "" }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(DS.brand)
                .disabled(!stored.hasPrefix("v1:"))
        }
    }

    private func toggle(_ tool: SketchTool, in chosen: [SketchTool]) {
        var next = chosen
        if let i = next.firstIndex(of: tool) { next.remove(at: i) } else { next.append(tool) }
        stored = SketchShortcutList.encode(next)
    }

    // MARK: actions

    private func choose(_ tool: SketchTool) {
        close()
        model.setSketchTool(tool)
    }

    private func close() { model.showSketchShortcuts = false }
}

/// One tool in the grid: lit on hover, tinted when it is the tool in use, and with a check while customizing.
private struct ShortcutCell: View {
    let tool: SketchTool
    let marked: Bool?
    let current: Bool
    @State private var hovered = false

    var body: some View {
        Icon(tool.symbol, size: 18, renderedStroke: Icon.toolStroke)
            .foregroundStyle(current ? DS.brand : .primary)
            .frame(width: 40, height: 36)
            .background(background, in: RoundedRectangle(cornerRadius: DS.Radius.menuItem))
            .overlay(alignment: .topTrailing) {
                if let marked {
                    Image(systemName: marked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 10))
                        .foregroundStyle(marked ? DS.brand : Color.secondary.opacity(0.5))
                        .padding(2)
                }
            }
            .opacity(marked == false && !hovered ? 0.55 : 1)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
    }

    private var background: Color {
        if current { return DS.brand.opacity(hovered ? 0.28 : 0.18) }
        return hovered ? Color.primary.opacity(0.1) : Color.clear
    }
}
