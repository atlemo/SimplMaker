// Auto-complete for the words in numeric fields: while a name is typed where a value belongs, a small
// list under the field offers the parameters (and functions) that fit. Tab or Return takes the highlighted one
// (the first, or the one ↑ ↓ moved to), Esc closes the list.
//
// One controller serves every field. It listens for edits in the window's field editor, so it works the same
// for the AppKit fields in the viewport (ValueField) and for SwiftUI text fields, which can't be subclassed:
// those say they are focused with `completesParameters`.
//
// Copyright © 2026 Atle Mo. All rights reserved.
import AppKit
import CADCore
import SwiftUI

/// An AppKit text field that completes the words typed in it.
@MainActor
protocol ParameterCompleting: AnyObject {
    /// The words it may complete; nil leaves the field alone (a field for plain text).
    var completionSource: (() -> [CompletionCandidate])? { get }
}

extension DocumentModel {
    /// The parameters of this document, as words for an expression field. `excluding` leaves out one name:
    /// a parameter's own, which would only make a loop.
    func completionCandidates(excluding name: String? = nil) -> [CompletionCandidate] {
        let values = parameterValues
        return document.parameters.compactMap { p in
            guard p.name != name, ParameterEvaluator.isValidName(p.name) else { return nil }
            let detail = values.values[p.name].map { p.unit.format($0.value) } ?? "error"
            return CompletionCandidate(name: p.name, detail: detail)
        }
    }
}

@MainActor
final class ParameterCompleter: NSObject {
    static let shared = ParameterCompleter()

    /// Words offered in the SwiftUI field that has the focus, and who asked.
    private var swiftUISource: (owner: UUID, words: () -> [CompletionCandidate])?

    private let panel = CompletionPanel()
    private weak var editor: NSTextView?
    private var word: ExpressionCompletion.Word?
    private var items: [CompletionCandidate] = []
    private var selected = 0
    private var applying = false
    private var keyMonitor: Any?

    var isShowing: Bool { editor != nil && !items.isEmpty }
    /// The suggestions on offer, for tests.
    var offered: [String] { isShowing ? items.map(\.name) : [] }

    private override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(textChanged(_:)), name: NSText.didChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(selectionChanged(_:)), name: NSTextView.didChangeSelectionNotification, object: nil)
        center.addObserver(self, selector: #selector(editingEnded(_:)), name: NSText.didEndEditingNotification, object: nil)
        center.addObserver(self, selector: #selector(windowLeft(_:)), name: NSWindow.didResignKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(windowLeft(_:)), name: NSWindow.willCloseNotification, object: nil)
    }

    @objc private func textChanged(_ note: Notification) {
        if let tv = note.object as? NSTextView, tv.isFieldEditor, !applying { refresh(tv) }
    }

    /// The caret moved without typing (a click, ← →): the list belongs to the word it sat in.
    @objc private func selectionChanged(_ note: Notification) {
        if let tv = note.object as? NSTextView, tv === editor, !applying { refresh(tv) }
    }

    @objc private func editingEnded(_ note: Notification) {
        if note.object as AnyObject? === editor { hide() }
    }

    @objc private func windowLeft(_ note: Notification) { hide() }

    // MARK: SwiftUI fields

    func setSwiftUISource(owner: UUID, _ words: @escaping () -> [CompletionCandidate]) { swiftUISource = (owner, words) }

    func clearSwiftUISource(owner: UUID) {
        guard swiftUISource?.owner == owner else { return }  // another field has taken over
        swiftUISource = nil
        hide()
    }

    private func words(for editor: NSTextView) -> (() -> [CompletionCandidate])? {
        if let field = editor.delegate as? ParameterCompleting { return field.completionSource }
        return editor.delegate is NSTextField ? swiftUISource?.words : nil
    }

    // MARK: showing

    private func refresh(_ tv: NSTextView) {
        let range = tv.selectedRange()
        guard let words = words(for: tv), tv.window != nil, range.length == 0,
              let found = ExpressionCompletion.suggestions(in: tv.string, caret: range.location, parameters: words())
        else { return hide() }
        if editor !== tv || found.items != items { selected = 0 }
        editor = tv
        word = found.word
        items = found.items
        show()
    }

    private func show() {
        guard let editor, let window = editor.window, let field = editor.delegate as? NSView else { return hide() }
        panel.list.set(items, selected: selected)
        let fieldRect = window.convertToScreen(field.convert(field.bounds, to: nil))
        let size = panel.list.fittingSize(minWidth: fieldRect.width)
        var origin = NSPoint(x: fieldRect.minX, y: fieldRect.minY - size.height - 2)
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? .infinite
        if origin.y < visible.minY { origin.y = fieldRect.maxY + 2 }  // no room below: above the field
        origin.x = min(max(origin.x, visible.minX), max(visible.maxX - size.width, visible.minX))
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.list.onPick = { [weak self] i in self?.accept(i) }
        panel.list.onHover = { [weak self] i in
            guard let self, i != selected else { return }
            selected = i
            panel.list.set(items, selected: i)
        }
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                MainActor.assumeIsolated { ParameterCompleter.shared.handle(event) } ? nil : event
            }
        }
    }

    func hide() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        guard panel.isVisible || editor != nil else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        editor = nil
        word = nil
        items = []
        selected = 0
    }

    // MARK: keys

    /// Keys for the list while it shows; true when it used the key (the field never sees it).
    func handle(_ event: NSEvent) -> Bool {
        guard isShowing, let editor, event.window === editor.window else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        switch event.keyCode {
        case 125, 126:  // ↓ ↑
            guard modifiers.isEmpty else { return false }
            selected = (selected + (event.keyCode == 125 ? 1 : items.count - 1)) % items.count
            panel.list.set(items, selected: selected)
            return true
        case 48:  // Tab
            guard modifiers.isEmpty else { hide(); return false }
            accept(selected)
            return true
        case 36, 76:  // Return
            // The word is already whole (a name typed out in full): Return ends the field as always.
            if let word, items.indices.contains(selected), word.prefix == items[selected].name { hide(); return false }
            accept(selected)
            return true
        case 53:  // Esc closes the list, and only the list
            hide()
            return true
        default:
            return false
        }
    }

    /// Puts the chosen word in the field, in place of what was typed of it.
    func accept(_ index: Int) {
        guard items.indices.contains(index), let editor, let word else { return }
        let candidate = items[index]
        applying = true  // the edit is ours: no new list for the word just completed
        editor.insertText(candidate.insertion, replacementRange: NSRange(location: word.range.lowerBound, length: word.range.count))
        applying = false
        hide()
    }
}

// MARK: - The list

/// The floating list. It never takes the keyboard: the field keeps the typing.
private final class CompletionPanel: NSPanel {
    let list = CompletionListView(frame: .zero)

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        let blur = NSVisualEffectView()
        blur.material = .menu
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = DS.Radius.menuItem * 2
        blur.layer?.masksToBounds = true
        list.autoresizingMask = [.width, .height]
        blur.addSubview(list)
        contentView = blur
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class CompletionListView: NSView {
    private var items: [CompletionCandidate] = []
    private var selected = 0
    var onPick: ((Int) -> Void)?
    var onHover: ((Int) -> Void)?

    private static let rowHeight: CGFloat = 22
    private static let footerHeight: CGFloat = 20
    private static let inset = DS.Spacing.space2
    private static let nameFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private static let detailFont = NSFont.systemFont(ofSize: 11)

    override var isFlipped: Bool { true }

    func set(_ items: [CompletionCandidate], selected: Int) {
        self.items = items
        self.selected = selected
        needsDisplay = true
    }

    func fittingSize(minWidth: CGFloat) -> NSSize {
        let widest = items.map { item in
            let name = (item.name as NSString).size(withAttributes: [.font: Self.nameFont]).width
            let detail = (item.detail as NSString).size(withAttributes: [.font: Self.detailFont]).width
            return name + detail + 3 * DS.Spacing.space5
        }.max() ?? 0
        return NSSize(width: max(minWidth, widest, 180) + 2 * Self.inset,
                      height: CGFloat(items.count) * Self.rowHeight + Self.footerHeight + 2 * Self.inset)
    }

    private func rowRect(_ i: Int) -> NSRect {
        NSRect(x: Self.inset, y: Self.inset + CGFloat(i) * Self.rowHeight, width: bounds.width - 2 * Self.inset, height: Self.rowHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (i, item) in items.enumerated() {
            let row = rowRect(i)
            let on = i == selected
            if on {
                NSColor.selectedContentBackgroundColor.setFill()
                NSBezierPath(roundedRect: row, xRadius: DS.Radius.menuItem, yRadius: DS.Radius.menuItem).fill()
            }
            let ink = on ? NSColor.alternateSelectedControlTextColor : NSColor.labelColor
            let quiet = on ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.8) : NSColor.secondaryLabelColor
            let name = item.name as NSString
            let nameSize = name.size(withAttributes: [.font: Self.nameFont])
            name.draw(at: NSPoint(x: row.minX + DS.Spacing.space3, y: row.midY - nameSize.height / 2),
                      withAttributes: [.font: Self.nameFont, .foregroundColor: ink])
            let detail = item.detail as NSString
            let detailSize = detail.size(withAttributes: [.font: Self.detailFont])
            detail.draw(at: NSPoint(x: row.maxX - DS.Spacing.space3 - detailSize.width, y: row.midY - detailSize.height / 2),
                        withAttributes: [.font: Self.detailFont, .foregroundColor: quiet])
        }
        let hint = "⇥ complete   ↑↓ choose" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.detailFont, .foregroundColor: NSColor.secondaryLabelColor]
        let size = hint.size(withAttributes: attributes)
        hint.draw(at: NSPoint(x: Self.inset + DS.Spacing.space3, y: bounds.height - Self.inset - Self.footerHeight / 2 - size.height / 2 + 1),
                  withAttributes: attributes)
    }

    private func row(at event: NSEvent) -> Int? {
        let p = convert(event.locationInWindow, from: nil)
        return items.indices.first { rowRect($0).contains(p) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { if let i = row(at: event) { onHover?(i) } }
    override func mouseDown(with event: NSEvent) { if let i = row(at: event) { onPick?(i) } }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - SwiftUI fields

private struct CompletesParameters: ViewModifier {
    let model: DocumentModel?
    let excluding: String?
    let focused: Bool
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { update(focused) }
            .onChange(of: focused) { _, now in update(now) }
            .onDisappear { ParameterCompleter.shared.clearSwiftUISource(owner: owner) }
    }

    private func update(_ now: Bool) {
        guard now, let model else { return ParameterCompleter.shared.clearSwiftUISource(owner: owner) }
        let excluded = excluding
        ParameterCompleter.shared.setSwiftUISource(owner: owner) { [weak model] in model?.completionCandidates(excluding: excluded) ?? [] }
    }
}

extension View {
    /// Offers the document's parameters while a name is typed in this text field. `focused` is whether the
    /// field has the keyboard; with no `model` the field completes nothing.
    func completesParameters(_ model: DocumentModel?, excluding name: String? = nil, focused: Bool) -> some View {
        modifier(CompletesParameters(model: model, excluding: name, focused: focused))
    }
}

extension EnvironmentValues {
    /// The document whose parameters the expression fields in the inspector complete; nil in a field to leave alone.
    @Entry var completionModel: DocumentModel?
}
