// The 3D viewport: an MTKView subclass for input, wrapped for SwiftUI.
//
// Navigation (see README):
//   trackpad: two-finger scroll = pan (or orbit, see Settings), ⇧ swaps, pinch = zoom, rotate = spin
//   mouse:    left-drag on empty space = orbit, right/middle-drag = pan, wheel = zoom
//   click = select face/edge/profile (⇧/⌘ to add), Esc = clear selection
// In sketch mode, clicks go to the active sketch tool; see SketchSession.
//
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CADCore
import CADKernel
import MetalKit
import SwiftUI

final class ViewportMTKView: MTKView, NSPopoverDelegate, NSTextFieldDelegate {
    var renderer: Renderer?
    weak var model: DocumentModel?

    private var lastDrag: NSPoint?
    private var lastPoint: NSPoint?
    private var dragged = false
    private var sketchDrag = false
    private var handleDrag = false
    private var labels: [EntityID: DimensionLabelView] = [:]
    private var glyphViews: [String: ConstraintGlyphView] = [:]
    private var prompt: CursorPromptView?
    private var mouseInside = false
    var showConstraints = true
    private var popover: NSPopover?
    private var popoverID: EntityID?
    /// The drag handle's size, typed beside the arrow.
    private var handleField: ValueField?
    private var seenHandleFocusRequest = 0
    private var handlePreviewTask: Task<Void, Never>?
    /// Typed values for the sketch step in progress (a line's length and angle, ...), beside the cursor.
    private var sketchPanel: NSStackView?
    private var sketchFields: [SketchInput: ValueField] = [:]
    private var sketchFieldOrder: [SketchInput] = []

    override var acceptsFirstResponder: Bool { true }

    // MARK: appearance

    /// Picks viewport colours for light/dark mode and Increase Contrast.
    func applyAppearance() {
        guard let renderer else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        renderer.palette = .make(dark: dark, increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
        let b = renderer.palette.background
        clearColor = MTLClearColor(red: Double(b.x), green: Double(b.y), blue: Double(b.z), alpha: 1)
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(displayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        applyAppearance()
    }

    @objc private func displayOptionsChanged(_ note: Notification) { applyAppearance() }
    override var isFlipped: Bool { true }  // origin top-left, like the ID texture

    override func draw(_ dirtyRect: NSRect) {
        renderer?.draw(in: self)
        updateLabels()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect,
                                                               .mouseEnteredAndExited, .cursorUpdate],
                                       owner: self))
    }

    // MARK: pointer

    /// Crosshair while drawing, hands over draggable geometry, arrow otherwise.
    private var currentCursor: NSCursor {
        guard let model else { return .arrow }
        if sketchDrag, model.sketchSession?.tool == .select { return .closedHand }
        if let session = model.sketchSession {
            switch session.tool {
            case .select: return session.hoverIsDraggable ? .openHand : .arrow
            case .dimension, .trim, .extend, .fillet: return session.hoverEntity != nil ? .pointingHand : .arrow
            default: return .crosshair
            }
        }
        if model.isPickingSketchPlane {
            switch model.hovered?.kind {
            case .plane, .face: return .pointingHand
            default: return .arrow
            }
        }
        if model.hovered?.kind == .handle { return handleDrag ? .closedHand : .openHand }
        return .arrow
    }

    override func cursorUpdate(with event: NSEvent) { currentCursor.set() }
    private func updateCursor() { if window?.isKeyWindow == true { currentCursor.set() } }

    // MARK: picking and sketch-plane coordinates

    private func location(_ event: NSEvent) -> NSPoint { convert(event.locationInWindow, from: nil) }

    private func requestPick(at p: NSPoint) {
        let scale = window?.backingScaleFactor ?? 2
        renderer?.pickRequest = SIMD2(Int(p.x * scale), Int(p.y * scale))
        needsDisplay = true
    }

    func pickResult(_ raw: UInt32) {
        guard let renderer, renderer.hovered != raw else { return }
        renderer.hovered = raw
        model?.hover(raw == 0 ? nil : PickID(raw: raw))
        if model?.sketchSession != nil { sketchEvent(.moved, at: nil, additive: false) }
        updateCursor()
        needsDisplay = true
    }

    /// Cursor position on the active sketch plane, in sketch (u, v) coordinates.
    private func sketchUV(_ p: NSPoint) -> SIMD2<Double>? {
        guard let renderer, let frame = model?.sketchSession?.frame else { return nil }
        let ray = renderer.camera.ray(at: p, viewSize: bounds.size)
        let o = SIMD3<Double>(Double(ray.origin.x), Double(ray.origin.y), Double(ray.origin.z))
        let d = SIMD3<Double>(Double(ray.direction.x), Double(ray.direction.y), Double(ray.direction.z))
        let n = frame.normal
        let denom = (d * n).sum()
        guard abs(denom) > 1e-9 else { return nil }
        let t = ((frame.origin - o) * n).sum() / denom
        let hit = o + t * d - frame.origin
        return SIMD2((hit * frame.xAxis).sum(), (hit * frame.yAxis).sum())
    }

    @discardableResult
    private func sketchEvent(_ phase: SketchMouse.Phase, at p: NSPoint?, additive: Bool) -> Bool {
        guard let model, let renderer else { return false }
        let point = p ?? lastPoint
        let hovered = renderer.hovered == 0 ? nil : PickID(raw: renderer.hovered)
        let handled = model.sketchMouse(SketchMouse(phase: phase, uv: point.flatMap { sketchUV($0) },
                                                    pick: hovered, additive: additive))
        refreshOverlay()
        updateCursor()
        return handled
    }

    // MARK: mouse

    override func mouseMoved(with event: NSEvent) {
        let p = location(event)
        lastPoint = p
        requestPick(at: p)
        if model?.sketchSession != nil { sketchEvent(.moved, at: p, additive: false) }
    }

    override func mouseEntered(with event: NSEvent) { mouseInside = true }
    override func mouseExited(with event: NSEvent) {
        mouseInside = false
        pickResult(0)
        needsDisplay = true  // hides the cursor prompt
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = location(event)
        lastDrag = p
        dragged = false
        sketchDrag = false
        if model?.sketchSession != nil {
            let additive = event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command)
            sketchDrag = sketchEvent(.down, at: p, additive: additive)
        } else if let renderer, PickID(raw: renderer.hovered).kind == .handle {
            handleDrag = true
            model?.beginHandleDrag()
            updateCursor()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if sketchDrag {
            let p = location(event)
            lastPoint = p
            sketchEvent(.dragged, at: p, additive: false)
            return
        }
        if handleDrag, let renderer {
            let ray = renderer.camera.ray(at: location(event), viewSize: bounds.size)
            model?.dragHandle(rayOrigin: SIMD3(Double(ray.origin.x), Double(ray.origin.y), Double(ray.origin.z)),
                              direction: SIMD3(Double(ray.direction.x), Double(ray.direction.y), Double(ray.direction.z)))
            refreshOverlay()
            return
        }
        drag(event) { self.renderer?.camera.orbit(dx: $0, dy: $1) }
    }

    override func mouseUp(with event: NSEvent) {
        defer { lastDrag = nil; sketchDrag = false; handleDrag = false; updateCursor() }
        if handleDrag {
            model?.endHandleDrag()
            refreshOverlay()
            return
        }
        if sketchDrag {
            sketchEvent(.up, at: location(event), additive: false)
            return
        }
        guard !dragged, let renderer, let model, model.sketchSession == nil else { return }
        let additive = event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command)
        model.click(renderer.hovered == 0 ? nil : PickID(raw: renderer.hovered), additive: additive)
        refreshOverlay()
    }

    override func rightMouseDown(with event: NSEvent) { lastDrag = location(event); dragged = false }
    override func rightMouseDragged(with event: NSEvent) { drag(event, pan) }
    override func otherMouseDown(with event: NSEvent) { lastDrag = location(event); dragged = false }
    override func otherMouseDragged(with event: NSEvent) { drag(event, pan) }

    private func pan(_ dx: Float, _ dy: Float) {
        renderer?.camera.pan(dx: dx, dy: dy, viewHeight: Float(bounds.height))
    }

    private func drag(_ event: NSEvent, _ apply: (Float, Float) -> Void) {
        let p = location(event)
        guard let last = lastDrag else { lastDrag = p; return }
        let dx = Float(p.x - last.x), dy = Float(p.y - last.y)
        if abs(dx) + abs(dy) > 0 { dragged = true }
        apply(dx, -dy)  // view is flipped: screen-up is negative y
        lastDrag = p
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        guard let renderer else { return }
        if event.hasPreciseScrollingDeltas {  // trackpad
            let dx = Float(event.scrollingDeltaX), dy = Float(event.scrollingDeltaY)
            var orbit = Preferences.trackpadScrollMode == .orbit
            if event.modifierFlags.contains(.shift) { orbit.toggle() }
            if orbit {
                renderer.camera.orbit(dx: -dx, dy: dy)
            } else {
                renderer.camera.pan(dx: dx, dy: dy, viewHeight: Float(bounds.height))
            }
        } else {
            let delta = Float(event.scrollingDeltaY) * (Preferences.invertsZoom ? 1 : -1)
            renderer.camera.zoom(pow(1.1, delta))
        }
        needsDisplay = true
    }

    override func rotate(with event: NSEvent) {
        renderer?.camera.orbit(dx: Float(event.rotation) * 4, dy: 0)
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        renderer?.camera.zoom(Float(1 / (1 + event.magnification)))
        needsDisplay = true
    }

    // MARK: keyboard

    override func keyDown(with event: NSEvent) {
        guard let model else { return super.keyDown(with: event) }
        let plainKey = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        if let session = model.sketchSession, plainKey {
            switch event.keyCode {
            case 53: session.escape(); refreshOverlay(); return                                      // Esc
            case 51, 117: model.sketchCommand { $0.deleteSelection() }; refreshOverlay(); return     // ⌫ ⌦
            case 36, 76:                                                                              // Return
                if session.typed.isEmpty { model.finishSketch() } else { model.sketchCommand { $0.commitTyped() }; refreshOverlay() }
                return
            case 48 where !session.inputFields.isEmpty:                                               // Tab
                focusSketchField(session.inputFields[0], typing: nil)
                return
            default: break
            }
            // Typing a number while drawing goes into the first field that has no value yet.
            let fields = session.inputFields
            if !fields.isEmpty, let chars = event.characters, chars.count == 1, "0123456789.-".contains(chars) {
                focusSketchField(fields.first { session.typed[$0] == nil } ?? fields[0], typing: chars)
                return
            }
            if let key = event.charactersIgnoringModifiers?.lowercased().first,
               let tool = SketchTool.allCases.first(where: { $0.key == key }) {
                model.setSketchTool(tool)
                refreshOverlay()
                return
            }
        } else if event.keyCode == 53 {
            if model.isPickingSketchPlane { model.cancelSketchPlanePick() } else { model.clearSelection() }
            refreshOverlay()
            return
        } else if plainKey, event.charactersIgnoringModifiers?.lowercased() == "e", !model.selectedRegions.isEmpty {
            model.extrudeSelectedProfiles()
            refreshOverlay()
            return
        }
        super.keyDown(with: event)
    }

    /// A click on a viewport label: picks the plane it names, or opens the dimension it belongs to.
    private func labelClicked(_ id: EntityID) {
        guard let model else { return }
        if model.isPickingSketchPlane, let plane = OriginPlane(labelID: id) {
            model.click(plane.pickID, additive: false)
            refreshOverlay()
        } else {
            model.sketchSession?.editingDimension = id
        }
    }

    func refreshOverlay() {
        guard let renderer, let model else { return }
        renderer.setOverlay(model.sketchOverlay())
        renderer.selected = model.highlighted
        needsDisplay = true
    }

    // MARK: dimension editor popover

    /// Shows the dimension editor as a popover on the label being edited, and closes it when done.
    private func syncPopover() {
        guard let model, let session = model.sketchSession, let id = session.editingDimension,
              let label = labels[id], !label.isHidden else {
            if popover != nil { closePopover() }
            return
        }
        guard popoverID != id || popover?.isShown != true else { return }
        popover?.close()
        let p = NSPopover()
        p.behavior = .transient
        p.delegate = self
        p.contentViewController = NSHostingController(rootView: DimensionEditor(
            model: model, session: session, dimensionID: id,
            onDone: { [weak self] in self?.closePopover() }))
        p.show(relativeTo: label.bounds, of: label, preferredEdge: .maxY)
        popover = p
        popoverID = id
    }

    private func closePopover() {
        let p = popover
        popover = nil
        popoverID = nil
        p?.close()
        model?.sketchSession?.editingDimension = nil
        refreshOverlay()
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover, closed === popover else { return }
        popover = nil
        popoverID = nil
        model?.sketchSession?.editingDimension = nil
        needsDisplay = true
    }

    // MARK: dimension labels

    private func updateLabels() {
        guard let renderer, let model else { return }
        let wanted = model.dimensionLabels()
        let ids = Set(wanted.map(\.id))
        for (id, view) in labels where !ids.contains(id) {
            view.removeFromSuperview()
            labels[id] = nil
        }
        for l in wanted {
            let view: DimensionLabelView
            if let existing = labels[l.id] {
                view = existing
            } else {
                view = DimensionLabelView(frame: .zero)
                let id = l.id
                view.onClick = { [weak self] in self?.labelClicked(id) }
                addSubview(view)
                labels[l.id] = view
            }
            view.stringValue = l.text
            view.isEditingHighlight = l.editing
            view.sizeToFit()
            if let p = renderer.camera.project(l.world, viewSize: bounds.size) {
                view.isHidden = false
                view.setFrameOrigin(NSPoint(x: p.x - view.frame.width / 2, y: p.y - view.frame.height / 2))
            } else {
                view.isHidden = true
            }
        }
        updateGlyphs()
        updatePrompt()
        syncPopover()
        syncHandleField()
        syncSketchFields()
    }

    // MARK: typed values

    /// Keeps the handle's size field just right of the arrow tip, showing the stored size.
    private func syncHandleField() {
        guard let renderer, let model, let h = model.dragHandle, let text = model.handleFieldText else {
            if let f = handleField {
                if f.currentEditor() != nil { window?.makeFirstResponder(self) }
                f.removeFromSuperview()
                handleField = nil
            }
            return
        }
        let field: ValueField
        if let handleField {
            field = handleField
        } else {
            field = ValueField(frame: .zero)
            field.delegate = self
            field.toolTip = "Type a size or an expression, then press Return · Esc cancels"
            addSubview(field)
            handleField = field
        }
        if field.currentEditor() == nil { field.stringValue = text }
        field.textColor = model.previewInvalid ? .systemRed : .labelColor
        let tip = h.base + h.direction * h.value
        guard let p = renderer.camera.project(SIMD3(Float(tip.x), Float(tip.y), Float(tip.z)), viewSize: bounds.size) else {
            field.isHidden = true
            return
        }
        field.isHidden = false
        let size = NSSize(width: 110, height: 24)
        let x = min(max(p.x + 26, 0), max(bounds.width - size.width, 0))
        let y = min(max(p.y - size.height / 2, 0), max(bounds.height - size.height, 0))
        field.frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
        if model.handleFocusRequest != seenHandleFocusRequest {
            // A new feature: select its size so typing replaces it (outside drawing, to be safe).
            seenHandleFocusRequest = model.handleFocusRequest
            DispatchQueue.main.async { [weak self, weak field] in
                guard let field, field.superview != nil else { return }
                self?.window?.makeFirstResponder(field)
                field.selectText(nil)
            }
        }
    }

    /// Previews a typed handle size once typing pauses.
    private func scheduleHandlePreview(_ text: String) {
        handlePreviewTask?.cancel()
        handlePreviewTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, let model = self.model else { return }
            if !model.previewHandle(text) { self.handleField?.textColor = .systemRed }
            self.refreshOverlay()
        }
    }

    /// Shows the fields for the sketch step in progress next to where the next point will go.
    private func syncSketchFields() {
        guard let renderer, let model, let session = model.sketchSession, !session.inputFields.isEmpty,
              let t = session.target()?.position else {
            removeSketchFields()
            return
        }
        let inputs = session.inputFields
        if inputs != sketchFieldOrder { buildSketchFields(inputs) }
        guard let panel = sketchPanel else { return }
        for input in inputs {
            guard let f = sketchFields[input] else { continue }
            if f.currentEditor() == nil {
                f.stringValue = session.typed[input] ?? session.liveValue(input).map { formatDimension($0, kind: input.unit) } ?? ""
            }
            f.textColor = session.typedIsInvalid(input) ? .systemRed : (session.typed[input] != nil ? .labelColor : .secondaryLabelColor)
        }
        let world = session.frame.point(t.x, t.y)
        guard let p = renderer.camera.project(SIMD3(Float(world.x), Float(world.y), Float(world.z)), viewSize: bounds.size) else {
            panel.isHidden = true
            return
        }
        panel.isHidden = false
        let size = panel.fittingSize
        let x = min(max(p.x + 20, 0), max(bounds.width - size.width, 0))
        let y = min(max(p.y + 20, 0), max(bounds.height - size.height, 0))
        panel.frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    private func buildSketchFields(_ inputs: [SketchInput]) {
        removeSketchFields()
        let panel = NSStackView()
        panel.orientation = .horizontal
        panel.spacing = 6
        panel.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 4)
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        panel.layer?.cornerRadius = 5
        panel.layer?.borderWidth = 0.5
        panel.layer?.borderColor = NSColor.separatorColor.cgColor
        for input in inputs {
            let label = NSTextField(labelWithString: input.symbol)
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.toolTip = input.rawValue
            let field = ValueField(frame: .zero)
            field.input = input
            field.delegate = self
            field.toolTip = "\(input.rawValue): type a value or an expression · Tab for the next · Return to place it"
            field.widthAnchor.constraint(equalToConstant: 92).isActive = true
            panel.addArrangedSubview(label)
            panel.addArrangedSubview(field)
            sketchFields[input] = field
        }
        addSubview(panel)
        sketchPanel = panel
        sketchFieldOrder = inputs
    }

    private func removeSketchFields() {
        guard let panel = sketchPanel else { return }
        if sketchFields.values.contains(where: { $0.currentEditor() != nil }) { window?.makeFirstResponder(self) }
        panel.removeFromSuperview()
        sketchPanel = nil
        sketchFields = [:]
        sketchFieldOrder = []
    }

    /// Moves typing into a sketch field, starting it with `typing` or selecting what's there.
    private func focusSketchField(_ input: SketchInput, typing text: String?) {
        guard let session = model?.sketchSession else { return }
        syncSketchFields()
        guard let field = sketchFields[input] else { return }
        if let text {
            session.setTyped(input, text)
            field.stringValue = text
        }
        window?.makeFirstResponder(field)
        if let text {
            field.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
            refreshOverlay()
        } else {
            field.selectText(nil)
        }
    }

    func controlTextDidChange(_ note: Notification) {
        guard let field = note.object as? ValueField else { return }
        if field === handleField {
            field.textColor = .labelColor
            scheduleHandlePreview(field.stringValue)
        } else if let input = field.input, let session = model?.sketchSession {
            session.setTyped(input, field.stringValue)
            refreshOverlay()
        }
    }

    func controlTextDidEndEditing(_ note: Notification) {
        // Clicking away from the handle's field keeps what was typed, if it's a usable size.
        guard let field = note.object as? ValueField, field === handleField, let model else { return }
        handlePreviewTask?.cancel()
        if field.stringValue != model.handleFieldText, !model.commitHandle(field.stringValue) { model.cancelHandleEdit() }
        refreshOverlay()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let field = control as? ValueField, let model else { return false }
        let newline = selector == #selector(NSResponder.insertNewline(_:))
        let cancel = selector == #selector(NSResponder.cancelOperation(_:))
        if field === handleField {
            if newline {
                handlePreviewTask?.cancel()
                guard model.commitHandle(field.stringValue) else {
                    NSSound.beep()
                    field.textColor = .systemRed
                    return true
                }
                field.stringValue = model.handleFieldText ?? field.stringValue
                window?.makeFirstResponder(self)
            } else if cancel {
                handlePreviewTask?.cancel()
                model.cancelHandleEdit()
                field.stringValue = model.handleFieldText ?? ""
                window?.makeFirstResponder(self)
            } else {
                return false
            }
            refreshOverlay()
            return true
        }
        guard let input = field.input, let session = model.sketchSession else { return false }
        let tab = selector == #selector(NSResponder.insertTab(_:)), backtab = selector == #selector(NSResponder.insertBacktab(_:))
        if newline {
            session.setTyped(input, field.stringValue)
            if session.typedIsInvalid(input) { NSSound.beep(); return true }
            window?.makeFirstResponder(self)
            model.sketchCommand { $0.commitTyped() }
        } else if cancel {
            session.clearTyped()
            window?.makeFirstResponder(self)
        } else if tab || backtab {
            session.setTyped(input, field.stringValue)
            let order = sketchFieldOrder
            guard let i = order.firstIndex(of: input) else { return true }
            let next = order[(i + (tab ? 1 : order.count - 1)) % order.count]
            if let f = sketchFields[next] {
                window?.makeFirstResponder(f)
                f.selectText(nil)
            }
        } else {
            return false
        }
        refreshOverlay()
        return true
    }

    /// Keeps the instruction ("Select a plane or planar face") just below and right of the cursor.
    private func updatePrompt() {
        guard let text = model?.cursorPrompt, mouseInside, let p = lastPoint else {
            prompt?.isHidden = true
            return
        }
        let view: CursorPromptView
        if let prompt {
            view = prompt
        } else {
            view = CursorPromptView(frame: .zero)
            addSubview(view)
            prompt = view
        }
        if view.stringValue != text {
            view.stringValue = text
            view.sizeToFit()
            view.setFrameSize(NSSize(width: view.frame.width + 12, height: view.frame.height + 6))
        }
        let size = view.frame.size
        let x = min(max(p.x + 18, 0), max(bounds.width - size.width, 0))
        let y = min(max(p.y + 18, 0), max(bounds.height - size.height, 0))
        view.setFrameOrigin(NSPoint(x: x, y: y))
        view.isHidden = false
    }

    private func updateGlyphs() {
        guard let renderer, let model else { return }
        let wanted = showConstraints ? (model.sketchSession.map { SketchOverlayBuilder.glyphs($0) } ?? []) : []
        let ids = Set(wanted.map(\.id))
        for (id, view) in glyphViews where !ids.contains(id) {
            view.removeFromSuperview()
            glyphViews[id] = nil
        }
        for g in wanted {
            let view: ConstraintGlyphView
            if let existing = glyphViews[g.id] {
                view = existing
            } else {
                view = ConstraintGlyphView(frame: .zero)
                let constraint = g.constraint
                view.onClick = { [weak self] additive in
                    self?.model?.selectSketchItem(constraint, additive: additive)
                    self?.refreshOverlay()
                }
                addSubview(view)
                glyphViews[g.id] = view
            }
            view.stringValue = g.symbol
            view.toolTip = "\(g.help) constraint · click to select, ⌫ to delete"
            view.isSelectedGlyph = g.selected
            view.sizeToFit()
            view.setFrameSize(NSSize(width: max(view.frame.width, 14), height: view.frame.height))
            if let p = renderer.camera.project(g.world, viewSize: bounds.size) {
                view.isHidden = false
                view.setFrameOrigin(NSPoint(x: p.x + 8 + CGFloat(g.stack) * 17, y: p.y + 6))
            } else {
                view.isHidden = true
            }
        }
    }
}

/// A small clickable constraint symbol.
final class ConstraintGlyphView: NSTextField {
    var onClick: ((_ additive: Bool) -> Void)?
    var isSelectedGlyph = false {
        didSet {
            backgroundColor = isSelectedGlyph ? .selectedContentBackgroundColor : .controlBackgroundColor
            textColor = isSelectedGlyph ? .alternateSelectedControlTextColor : .secondaryLabelColor
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = true
        alignment = .center
        backgroundColor = .controlBackgroundColor
        textColor = .secondaryLabelColor
        font = .systemFont(ofSize: 10, weight: .semibold)
        wantsLayer = true
        layer?.cornerRadius = 3
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func mouseDown(with event: NSEvent) {
        onClick?(event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command))
    }
}

/// The instruction that follows the cursor while the app waits for a pick. Clicks pass through it.
final class CursorPromptView: NSTextField {
    override init(frame: NSRect) {
        super.init(frame: frame)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = true
        alignment = .center
        backgroundColor = .windowBackgroundColor
        textColor = .labelColor
        font = .systemFont(ofSize: 13)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A small clickable value label for a sketch dimension.
final class DimensionLabelView: NSTextField {
    var onClick: (() -> Void)?
    var isEditingHighlight = false {
        didSet {
            backgroundColor = isEditingHighlight ? NSColor.selectedContentBackgroundColor
                                                 : NSColor.textBackgroundColor.withAlphaComponent(0.85)
            textColor = isEditingHighlight ? .alternateSelectedControlTextColor : .labelColor
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = true
        backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.85)
        font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        textColor = .labelColor
        wantsLayer = true
        layer?.cornerRadius = 3
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// A small editable number field in the viewport (a handle's size, a typed sketch value).
final class ValueField: NSTextField {
    /// The sketch value this field edits; nil for the drag handle's field.
    var input: SketchInput?

    override init(frame: NSRect) {
        super.init(frame: frame)
        isEditable = true
        isSelectable = true
        isBordered = true
        isBezeled = true
        bezelStyle = .roundedBezel
        alignment = .center
        font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        usesSingleLineMode = true
        cell?.isScrollable = true
        cell?.wraps = false
        focusRingType = .exterior
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// SwiftUI wrapper. The revision numbers are passed in so SwiftUI calls updateNSView exactly
/// when geometry, selection, overlay or camera requests change.
struct ViewportView: NSViewRepresentable {
    let model: DocumentModel
    let sceneRevision: Int
    let overlayRevision: Int
    let highlighted: [UInt32]
    let fitRevision: Int
    let cameraRevision: Int
    let orthographic: Bool
    let showGrid: Bool
    let showConstraints: Bool

    final class Coordinator {
        var sceneRevision = -1
        var fitRevision = -1
        var cameraRevision = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ViewportMTKView {
        let view = ViewportMTKView(frame: .zero, device: nil)
        guard let renderer = Renderer() else { return view }
        view.device = renderer.device
        view.renderer = renderer
        view.model = model
        view.colorPixelFormat = Renderer.colorFormat
        view.depthStencilPixelFormat = Renderer.depthFormat
        view.applyAppearance()
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        renderer.onPick = { [weak view] raw in view?.pickResult(raw) }
        return view
    }

    func updateNSView(_ view: ViewportMTKView, context: Context) {
        guard let renderer = view.renderer else { return }
        let c = context.coordinator
        if c.sceneRevision != sceneRevision {
            c.sceneRevision = sceneRevision
            renderer.setScene(model.meshes)
            renderer.hovered = 0
        }
        if c.fitRevision != fitRevision, let b = model.sceneBounds {
            c.fitRevision = fitRevision
            renderer.camera.fit(min: b.min, max: b.max)
        }
        renderer.camera.orthographic = orthographic
        renderer.showGrid = showGrid
        view.showConstraints = showConstraints
        if c.cameraRevision != cameraRevision, let cmd = model.cameraCommand {
            c.cameraRevision = cameraRevision
            switch cmd.command {
            case .look(let target, let normal):
                renderer.camera.look(along: normal, at: target)
            case .standard(let v):
                renderer.camera.setStandard(v)
                if let b = model.sceneBounds { renderer.camera.fit(min: b.min, max: b.max) }
            }
        }
        renderer.setOverlay(model.sketchOverlay())
        renderer.selected = highlighted
        view.needsDisplay = true
    }
}
