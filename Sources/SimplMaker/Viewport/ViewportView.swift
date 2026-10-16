// The 3D viewport: an MTKView subclass for input, wrapped for SwiftUI.
//
// Navigation (see README):
//   trackpad: two-finger scroll = pan, ⇧ = orbit, pinch = zoom, rotate = spin
//   mouse:    left-drag on empty space = orbit, right/middle-drag = pan, wheel = zoom
//   All of it can be changed in Settings → Navigation (see NavigationConfig).
//   click = select face/edge/profile (⇧/⌘ to add), Esc = clear selection
// In sketch mode, clicks go to the active sketch tool; see SketchSession.
//
// Copyright © 2026 Atle Mo. All rights reserved.
import AppKit
import CADCore
import CADKernel
import MetalKit
import SwiftUI

final class ViewportMTKView: MTKView, NSPopoverDelegate, NSTextFieldDelegate {
    /// The view's multisampling follows the renderer's, whose pipelines are built for it.
    var renderer: Renderer? { didSet { sampleCount = renderer?.sampleCount ?? 1 } }
    weak var model: DocumentModel?

    private var lastDrag: NSPoint?
    private var lastPoint: NSPoint?
    private var dragged = false
    /// Where the button went down: a press that wanders less than a few points is still a click.
    private var downPoint: NSPoint?
    private var sketchDrag = false
    private var handleDrag = false
    /// A hole's move dot is being dragged.
    private var holeMoveDrag = false
    private var sectionDrag = false
    private var planeResizeDrag = false
    /// The Move/Rotate manipulator: what it draws, the part under the pointer, and the drag in progress.
    private var manipulatorView: ManipulatorView?
    private var manipulatorLayout: ManipulatorLayout?
    private var manipulatorHover: ManipulatorPart?
    private var manipulatorDrag: ManipulatorDrag?
    /// The mouse went down on the toolbar strip (the view extends under it): the window is being dragged
    /// by it, so the view stays out of it until the button comes up.
    private var windowDrag = false
    private var labels: [EntityID: DimensionLabelView] = [:]
    private var glyphViews: [String: ConstraintGlyphView] = [:]
    private var mouseInside = false
    var showConstraints = true
    private var popover: NSPopover?
    private var popoverID: EntityID?
    /// The drag handles' sizes, typed beside their arrows, by slot (a hole has one for its depth, one for its diameter).
    private var handleFields: [Int: ValueField] = [:]
    /// The feature whose size each handle field shows, and the size it showed.
    private var handleFieldFeatures: [Int: (id: FeatureID, text: String)] = [:]
    private var seenHandleFieldReset = 0
    private var seenHandleFocusRequest = 0
    private var handlePreviewTask: Task<Void, Never>?
    /// Where Text tool input is typed, at the clicked spot.
    private var textEntryField: ValueField?
    /// The text the typing box is changing (nil: a new text), to refill it when that changes.
    private var textEntryFor: EntityID?
    /// Options for the selected feature (Join/Cut, Flip, OK, Cancel), below the size field.
    private var featureHUD: SelfSizingHostingView<FeatureHUD>?
    /// The sketch Pattern tool's options (grid or circle, OK, Cancel), under its fields.
    private var patternHUD: SelfSizingHostingView<SketchPatternHUD>?
    /// Typed values for the sketch step in progress (a line's length and angle, ...), beside the cursor.
    private var sketchPanel: SketchFieldPanel?
    private var sketchFields: [SketchInput: ValueField] = [:]
    private var sketchFieldOrder: [SketchInput] = []
    /// Holds the controls typed into or clicked (the handle's field and options, the sketch fields,
    /// the Text tool's box) above the floating panels, which cover the viewport's own subviews.
    private let controlsLayer = ControlsLayer()

    override var acceptsFirstResponder: Bool { true }

    /// Whether a point (in this view) is on the toolbar strip at the top, which drags the window.
    private func isOnToolbar(_ p: NSPoint) -> Bool { topInset > 0 && p.y < topInset }

    /// Only the strip under the toolbar moves the window; the rest of the view is for the model.
    override var mouseDownCanMoveWindow: Bool {
        guard let window else { return false }
        return isOnToolbar(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    /// The layer for controls, on top of the window's content. Its controls are placed in the
    /// viewport's coordinates (see fitControls). Called before each placement, so it stays on top
    /// as panels come and go. It sits beside the content view, in the window's frame view: AppKit
    /// doesn't support subviews added to a SwiftUI hosting view.
    @discardableResult
    private func raiseControls() -> NSView {
        guard let content = window?.contentView?.superview ?? window?.contentView else { return self }
        if controlsLayer.superview !== content || content.subviews.last !== controlsLayer {
            content.addSubview(controlsLayer, positioned: .above, relativeTo: nil)
        }
        return controlsLayer
    }

    /// Shrinks the layer to just around its controls, so it covers nothing else (a click beside them
    /// must reach the viewport or a panel). Its bounds start where they do, so they keep the
    /// viewport's coordinates.
    private func fitControls() {
        let shown = controlsLayer.subviews.filter { !$0.isHidden }
        guard let content = controlsLayer.superview, let first = shown.first else {
            controlsLayer.frame = .zero
            return
        }
        let area = shown.dropFirst().reduce(first.frame) { $0.union($1.frame) }
        let frame = convert(area, to: content)
        if controlsLayer.frame != frame { controlsLayer.frame = frame }
        if controlsLayer.bounds.origin != area.origin { controlsLayer.setBoundsOrigin(area.origin) }
    }

    // MARK: appearance

    /// While a sketch is open the background is tinted like drafting paper (a setting).
    var sketching = false
    /// The viewport is in a dark appearance. The labels over it pick their own colours from this, so
    /// they stay readable over the sketch paper whatever the window around them is doing.
    private(set) var isDark = false
    var sketchPaper = Preferences.SketchPaper.blue

    /// Picks viewport colours for light/dark mode and Increase Contrast.
    func applyAppearance() {
        guard let renderer else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        isDark = dark
        labels.values.forEach { $0.dark = dark }
        glyphViews.values.forEach { $0.dark = dark }
        renderer.palette = .make(dark: dark, increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
                                 paper: sketching ? sketchPaper.color(dark: dark) : nil)
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
        if window == nil { controlsLayer.removeFromSuperview() } else if !controlsLayer.subviews.isEmpty { raiseControls() }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(displayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        applyAppearance()
    }

    @objc private func displayOptionsChanged(_ note: Notification) { applyAppearance() }
    override var isFlipped: Bool { true }  // origin top-left, like the ID texture

    /// How much of the view the floating panels cover: left, right, and at the bottom (timeline, status).
    /// A change glides (see `shownInsets`), so hiding a panel slides the picture to the middle of the new free space
    /// along with the panel, instead of jumping.
    var panelInsets: (left: CGFloat, right: CGFloat, bottom: CGFloat) = (0, 0, 0) {
        didSet {
            guard panelInsets != oldValue else { return }
            glideInsets(to: panelInsets)
        }
    }

    /// The insets the camera is centred on right now: `panelInsets`, or on the way to them.
    private var shownInsets: (left: CGFloat, right: CGFloat, bottom: CGFloat) = (0, 0, 0)
    private var insetAnimation: Task<Void, Never>?
    /// Whether a frame has been drawn, so the first insets (the window opening) are taken at once.
    private var hasDrawn = false

    private func glideInsets(to goal: (left: CGFloat, right: CGFloat, bottom: CGFloat)) {
        insetAnimation?.cancel()
        insetAnimation = nil
        let start = shownInsets
        if !hasDrawn || window == nil || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            shownInsets = goal
            needsDisplay = true
            return
        }
        let began = Date()
        let duration = DS.Duration.base
        insetAnimation = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let t = CGFloat(min(Date().timeIntervalSince(began) / duration, 1))
                let e = 1 - (1 - t) * (1 - t)  // ease out, like the panels
                self.shownInsets = (start.left + (goal.left - start.left) * e,
                                    start.right + (goal.right - start.right) * e,
                                    start.bottom + (goal.bottom - start.bottom) * e)
                self.needsDisplay = true
                if t >= 1 { break }
                try? await Task.sleep(for: .milliseconds(16))
            }
            if !Task.isCancelled { self?.insetAnimation = nil }
        }
    }

    /// Points our window covers at the top (the toolbar, which the view extends under).
    private var topInset: CGFloat {
        guard let window else { return 0 }
        let frame = convert(bounds, to: nil)  // window coordinates, origin bottom-left
        return max(0, frame.maxY - window.contentLayoutRect.maxY)
    }

    /// Centres the camera on the part of the view the panels and toolbar leave uncovered.
    func updateCameraInsets() {
        guard let renderer, bounds.width > 1, bounds.height > 1 else { return }
        let w = bounds.width, h = bounds.height
        let top = min(topInset, h * 0.3)
        // Where the picture is centred follows the gliding insets; how big a fit makes it uses the final ones.
        let sl = min(shownInsets.left, w * 0.45), sr = min(shownInsets.right, w * 0.45), sb = min(shownInsets.bottom, h * 0.3)
        renderer.camera.centerShift = SIMD2(Float((sl - sr) / w), Float((sb - top) / h))
        let left = min(panelInsets.left, w * 0.45), right = min(panelInsets.right, w * 0.45)
        let bottom = min(panelInsets.bottom, h * 0.3)
        renderer.camera.visibleFraction = SIMD2(Float((w - left - right) / w), Float((h - top - bottom) / h))
    }

    var viewAspect: Float { Float(bounds.width / max(bounds.height, 1)) }

    override func draw(_ dirtyRect: NSRect) {
        updateCameraInsets()
        updateSketchGrid()
        syncSketchScale()
        renderer?.draw(in: self)
        hasDrawn = true
        updateLabels()
        updateSketchRulers()
        layoutViewCube()
    }

    // MARK: view cube

    private var viewCube: ViewCubeView?
    private var cameraAnimation: Task<Void, Never>?
    /// Whether the view is moving by itself (a turn to a view, leaving a sketch).
    var isAnimatingCamera: Bool { cameraAnimation != nil }

    func stopCameraAnimation() {
        cameraAnimation?.cancel()
        cameraAnimation = nil
    }

    /// The navigation cube, in the top-right corner of the part of the view the panels leave free.
    private func layoutViewCube() {
        guard renderer != nil else { return }
        let cube = viewCube ?? {
            let c = ViewCubeView(frame: NSRect(origin: .zero, size: ViewCubeView.size))
            c.camera = { [weak self] in self?.renderer?.camera }
            c.lookAlong = { [weak self] n in self?.animateCamera(along: n) }
            c.orbit = { [weak self] dx, dy in
                self?.cameraAnimation?.cancel()
                self?.renderer?.camera.orbit(dx: dx, dy: dy)
                self?.needsDisplay = true
            }
            c.home = { [weak self] in self?.model?.show(.home) }
            c.turn = { [weak self] direction in
                guard let self, let renderer = self.renderer, self.model?.sketchSession != nil else { return }
                var goal = renderer.camera.pose
                goal.roll = renderer.camera.quarterTurnedRoll(direction)
                self.animateCamera(to: goal, duration: 0.25)
            }
            c.accent = { [weak self] in Preferences.nsAccent(sketching: self?.model?.sketchSession != nil) }
            addSubview(c)
            viewCube = c
            return c
        }()
        let right = min(shownInsets.right, bounds.width * 0.45)
        cube.frame.origin = NSPoint(x: bounds.width - right - ViewCubeView.size.width - DS.Spacing.space4,
                                    y: topInset + DS.Spacing.space4)
        cube.offersTurning = model?.sketchSession != nil
        cube.needsDisplay = true
    }

    /// Turns the camera smoothly to look from `direction` (a unit vector from the model toward the
    /// eye), about the same target and at the same distance.
    private func animateCamera(along direction: SIMD3<Float>) {
        guard let renderer else { return }
        var goal = renderer.camera
        goal.look(along: direction, at: goal.target)
        animateCamera(to: goal.pose, duration: 0.3)
    }

    /// Moves the camera smoothly to `goal`. The user taking hold of the view (orbit, pan, zoom, a new view)
    /// ends it where it is; with Reduce Motion on, it jumps.
    func animateCamera(to goal: CameraPose, duration: TimeInterval = 0.5) {
        guard let renderer else { return }
        stopCameraAnimation()
        let start = renderer.camera.pose
        guard !start.isClose(to: goal) else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            renderer.camera.pose = goal
            needsDisplay = true
            return
        }
        let began = Date()
        cameraAnimation = Task { @MainActor [weak self] in
            var last = start
            while !Task.isCancelled {
                guard let self, let renderer = self.renderer else { return }
                if renderer.camera.pose != last { break }  // moved by something else in between: let it be
                let t = Float(min(Date().timeIntervalSince(began) / duration, 1))
                last = start.blended(to: goal, CameraPose.eased(t))
                renderer.camera.pose = last
                self.needsDisplay = true
                if t >= 1 { break }
                try? await Task.sleep(for: .milliseconds(16))
            }
            if !Task.isCancelled { self?.cameraAnimation = nil }  // a newer animation is not ours to clear
        }
    }

    // MARK: sketch grid and rulers

    /// Tells the sketch session the zoom, so what is too small to be worth showing goes away (and comes back
    /// when zoomed in), and sizes drawn in pixels follow.
    private func syncSketchScale() {
        guard let session = model?.sketchSession else { return }
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        guard let a = sketchUV(c), let b = sketchUV(NSPoint(x: c.x + 1, y: c.y)),
              session.setViewScale(mmPerPixel: simdLength(b - a)) else { return }
        DispatchQueue.main.async { [weak self] in self?.refreshOverlay() }
    }

    /// Rulers along the sketch axes (keyed "u:25", "v:-50") and the origin marker.
    var gridSetting = ""
    private var rulerLabels: [String: AxisLabelView] = [:]
    private var originMarker: OriginMarkerView?

    /// Sketch grid spacing at the current zoom (see gridSteps).
    private func sketchGridSteps() -> (minor: Double, major: Double, snap: Double)? {
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        guard let a = sketchUV(c), let b = sketchUV(NSPoint(x: c.x + 1, y: c.y)) else { return nil }
        return Self.gridSteps(mmPerPixel: simdLength(b - a))
    }

    /// Grid spacing for a zoom: minor lines about 40 px apart (1, 2 or 5 × 10ⁿ mm) or the square chosen in
    /// Settings (stepped up when it would be under 12 px wide), a major line every fifth (fourth in
    /// inches), and the snapping step, which lands on the minor lines too.
    static func gridSteps(mmPerPixel: Double) -> (minor: Double, major: Double, snap: Double) {
        let fixed = Preferences.gridSizeMM
        if fixed > 0 {
            let us = Preferences.unitSystemSetting.isUS
            var minor = fixed
            while minor < 12 * mmPerPixel, minor.isFinite { minor *= us ? 4 : 10 }
            return (minor, minor * (us ? 4 : 5), minor)
        }
        let minor = niceStep(40 * mmPerPixel)
        let twos = abs(minor / pow(10, floor(log10(minor))) - 2) < 1e-9
        return (minor, minor * 5, minor / (twos ? 4 : 5))
    }

    /// The grid in the plane of the sketch being edited, over the part of it that's in view.
    private func updateSketchGrid() {
        guard let renderer else { return }
        guard let session = model?.sketchSession, let steps = sketchGridSteps() else { renderer.setSketchGrid(nil); return }
        let corners = [NSPoint(x: 0, y: 0), NSPoint(x: bounds.width, y: 0), NSPoint(x: 0, y: bounds.height),
                       NSPoint(x: bounds.width, y: bounds.height), NSPoint(x: bounds.midX, y: bounds.midY)].compactMap { sketchUV($0) }
        let reach = 60 * steps.major  // cap: a plane seen edge-on reaches to the horizon
        let center = corners.last ?? .zero
        func span(_ values: [Double], _ mid: Double) -> ClosedRange<Double> {
            let lo = max((values.min() ?? mid) - steps.major, mid - reach), hi = min((values.max() ?? mid) + steps.major, mid + reach)
            return (lo / steps.major).rounded(.down) * steps.major...(hi / steps.major).rounded(.up) * steps.major
        }
        renderer.setSketchGrid(SketchGrid(frame: session.frame, minor: steps.minor, major: steps.major,
                                          u: span(corners.map(\.x), center.x), v: span(corners.map(\.y), center.y),
                                          lines: renderer.showGrid))
    }

    /// Numbers at the major grid lines along the sketch's axes, and the origin marker.
    private func updateSketchRulers() {
        guard let renderer, let grid = renderer.sketchGrid else {
            rulerLabels.values.forEach { $0.removeFromSuperview() }
            rulerLabels = [:]
            originMarker?.removeFromSuperview()
            originMarker = nil
            return
        }
        func anywhere(_ u: Double, _ v: Double) -> CGPoint? {
            let w = grid.frame.point(u, v)
            return renderer.camera.project(SIMD3(Float(w.x), Float(w.y), Float(w.z)), viewSize: bounds.size)
        }
        func screen(_ u: Double, _ v: Double) -> CGPoint? {
            guard let p = anywhere(u, v), bounds.insetBy(dx: -40, dy: -40).contains(p) else { return nil }
            return p
        }
        // Which way the numbers sit off their axis on screen: below the horizontal one, right of the vertical one,
        // or the nearest to that once the view is rolled.
        func offset(alongU: Bool) -> CGVector {
            guard let a = anywhere(0, 0), let b = alongU ? anywhere(1, 0) : anywhere(0, 1) else { return alongU ? CGVector(dx: 0, dy: 1) : CGVector(dx: 1, dy: 0) }
            let len = max(hypot(b.x - a.x, b.y - a.y), 1e-9)
            var n = CGVector(dx: -(b.y - a.y) / len, dy: (b.x - a.x) / len)  // across the axis
            if alongU ? (n.dy < -1e-6 || (abs(n.dy) <= 1e-6 && n.dx < 0)) : (n.dx < -1e-6 || (abs(n.dx) <= 1e-6 && n.dy < 0)) {
                n = CGVector(dx: -n.dx, dy: -n.dy)
            }
            return n
        }
        let acrossU = offset(alongU: true), acrossV = offset(alongU: false)
        var wanted: [String: (text: String, point: CGPoint, alongU: Bool)] = [:]
        for (alongU, range) in [(true, grid.u), (false, grid.v)] {
            var k = (range.lowerBound / grid.major).rounded()
            while k * grid.major <= range.upperBound + 1e-9 {
                let value = k * grid.major
                k += 1
                guard abs(value) > 1e-9, let p = alongU ? screen(value, 0) : screen(0, value) else { continue }
                let text = Preferences.rulerText(value, us: Preferences.unitSystemSetting.isUS)
                wanted[(alongU ? "u:" : "v:") + text] = (text, p, alongU)
            }
        }
        for (key, view) in rulerLabels where wanted[key] == nil {
            view.removeFromSuperview()
            rulerLabels[key] = nil
        }
        for (key, w) in wanted {
            let view = rulerLabels[key] ?? {
                let v = AxisLabelView(text: w.text)
                addSubview(v, positioned: .below, relativeTo: nil)
                rulerLabels[key] = v
                return v
            }()
            let size = view.frame.size
            // Off the axis by 6 points, whichever way it runs: the label's own size decides how far its middle goes.
            let n = w.alongU ? acrossU : acrossV
            let reach = 6 + abs(n.dx) * size.width / 2 + abs(n.dy) * size.height / 2
            view.setFrameOrigin(NSPoint(x: w.point.x + n.dx * reach - size.width / 2, y: w.point.y + n.dy * reach - size.height / 2))
        }
        if let p = screen(0, 0) {
            let marker = originMarker ?? {
                let m = OriginMarkerView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
                addSubview(m, positioned: .below, relativeTo: nil)
                originMarker = m
                return m
            }()
            marker.isHidden = false
            marker.setFrameOrigin(NSPoint(x: p.x - 10, y: p.y - 10))
        } else {
            originMarker?.isHidden = true
        }
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
        if manipulatorDrag != nil { return .closedHand }
        if manipulatorHover != nil { return .openHand }
        if sketchDrag, model.sketchSession?.tool == .select { return .closedHand }
        if let session = model.sketchSession {
            switch session.tool {
            case .select: return session.hoverIsDraggable ? .openHand : .arrow
            case .dimension, .distance, .trim, .extend, .fillet: return session.hoverEntity != nil ? .pointingHand : .arrow
            default: return .crosshair
            }
        }
        if model.isPickingSketchPlane {
            switch model.hovered?.kind {
            case .plane, .face: return .pointingHand
            default: return .arrow
            }
        }
        if let tool = model.pendingTool {
            guard let h = model.hovered, tool.accepts(h.kind) else { return .arrow }
            return .pointingHand
        }
        if planeResizeDrag { return .closedHand }
        if model.hovered?.kind == .handle || model.hovered?.kind == .planeEdge { return handleDrag || holeMoveDrag || sectionDrag ? .closedHand : .openHand }
        return .arrow
    }

    override func cursorUpdate(with event: NSEvent) { currentCursor.set() }
    /// Sets the cursor for the pointer being here. A rebuild or a pick coming in while the pointer is elsewhere
    /// (dragging a parameter's name in the sidebar) must not take its cursor away.
    private func updateCursor() {
        guard let window, window.isKeyWindow else { return }
        let inside = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        if inside || lastDrag != nil { currentCursor.set() }
    }

    // MARK: picking and sketch-plane coordinates

    private func location(_ event: NSEvent) -> NSPoint { convert(event.locationInWindow, from: nil) }

    private func pickPixel(_ p: NSPoint) -> SIMD2<Int> {
        let scale = window?.backingScaleFactor ?? 2
        return SIMD2(Int(p.x * scale), Int(p.y * scale))
    }

    private func requestPick(at p: NSPoint) {
        renderer?.pickRequest = pickPixel(p)
        needsDisplay = true
    }

    /// The pixel whose pick result `renderer.hovered` holds.
    private var pickedPixel: SIMD2<Int>?
    /// A click waiting for the pick under the pointer, which the pointer's last move may not have delivered yet.
    private var pendingClick: (pixel: SIMD2<Int>, action: () -> Void)?

    /// The origin plane whose name the pointer is over (while the planes are offered): that plane lights up, not
    /// whichever plane happens to lie under the label in this view.
    private var hoveredPlaneLabel: OriginPlane?

    private func labelHover(_ id: EntityID, inside: Bool) {
        guard let model, let renderer else { return }
        let plane = inside && model.showsOriginPlanes ? OriginPlane(labelID: id) : nil
        guard hoveredPlaneLabel != plane else { return }
        hoveredPlaneLabel = plane
        if let plane {
            renderer.hovered = plane.pickID.raw
            model.hover(plane.pickID)
            needsDisplay = true
        } else {
            if let lastPoint { requestPick(at: lastPoint) }  // back to what is under the pointer
        }
    }

    func pickResult(_ result: UInt32, at pixel: SIMD2<Int>?) {
        pickedPixel = pixel
        applyPick(result)
        if let pending = pendingClick, pending.pixel == pixel {
            pendingClick = nil
            pending.action()
        }
    }

    private func applyPick(_ result: UInt32) {
        var raw = hoveredPlaneLabel?.pickID.raw ?? result
        if raw != 0, model?.isLockedPick(PickID(raw: raw)) == true { raw = 0 }  // a locked body or sketch is not there to hover
        guard let renderer, renderer.hovered != raw else { return }
        renderer.hovered = raw
        model?.hover(raw == 0 ? nil : PickID(raw: raw))
        if let model, model.pendingTool == .thread { renderer.selected = model.highlighted }  // the face it would thread
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
        // Snap within about 8 pixels; the grid step is a round number of mm, at least 12 pixels apart.
        var tolerance: Double?, gridStep: Double?
        if let point, let a = sketchUV(point), let b = sketchUV(NSPoint(x: point.x + 1, y: point.y)) {
            let mmPerPixel = simdLength(b - a)
            tolerance = 8 * mmPerPixel
            // The same spacing as the drawn grid, so points snap onto its lines.
            if Preferences.snapsToGrid { gridStep = sketchGridSteps()?.snap ?? Self.niceStep(12 * mmPerPixel) }
        }
        let handled = model.sketchMouse(SketchMouse(phase: phase, uv: point.flatMap { sketchUV($0) },
                                                    pick: hovered, additive: additive, tolerance: tolerance,
                                                    gridStep: gridStep, snapping: !NSEvent.modifierFlags.contains(.option)))
        refreshOverlay()
        updateCursor()
        return handled
    }

    /// The smallest of 1, 2 or 5 × 10ⁿ mm that is at least `minimum`.
    nonisolated static func niceStep(_ minimum: Double) -> Double {
        guard minimum > 0, minimum.isFinite else { return 1 }
        let base = pow(10, floor(log10(minimum)))
        for m in [1.0, 2, 5, 10] where base * m >= minimum { return base * m }
        return base * 10
    }

    override func flagsChanged(with event: NSEvent) {
        // ⌥ turns snapping off and on while drawing: update the preview right away.
        if model?.sketchSession != nil { sketchEvent(.moved, at: nil, additive: false) }
        super.flagsChanged(with: event)
    }

    // MARK: mouse

    override func mouseMoved(with event: NSEvent) {
        let p = location(event)
        lastPoint = p
        requestPick(at: p)
        updatePrompt()  // the prompt drops out once the pointer moves onto the toolbar
        if manipulatorDrag == nil {
            let over = manipulatorLayout?.hit(p)
            if over != manipulatorHover {
                manipulatorHover = over
                manipulatorView?.hover = over
                updateCursor()
            }
        }
        if let renderer, let model, model.pendingTool == .thread {
            // The hole nearest the pointer lights up on a face with several.
            let ray = renderer.camera.ray(at: p, viewSize: bounds.size)
            model.hoverRay = (SIMD3(Double(ray.origin.x), Double(ray.origin.y), Double(ray.origin.z)),
                              SIMD3(Double(ray.direction.x), Double(ray.direction.y), Double(ray.direction.z)))
            renderer.selected = model.highlighted
        }
        if model?.sketchSession != nil { sketchEvent(.moved, at: p, additive: false) }
    }

    override func mouseEntered(with event: NSEvent) { mouseInside = true }
    override func mouseExited(with event: NSEvent) {
        mouseInside = false
        pickResult(0, at: nil)
        updatePrompt()
        needsDisplay = true  // hides the cursor prompt
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { return showContextMenu(event) }  // ⌃-click = right-click
        window?.makeFirstResponder(self)
        let p = location(event)
        windowDrag = isOnToolbar(p)
        if windowDrag { return }  // the window follows the mouse; the view must not react to it as well
        let additive = event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command)
        if let model, let layout = manipulatorLayout, let part = layout.hit(p), let start = model.manipulatorDragStart,
           let drag = ManipulatorDrag(part: part, at: p, layout: layout, start: start) {
            model.beginManipulatorDrag(part)
            manipulatorDrag = drag
            lastDrag = p
            dragged = false
            updateCursor()
            refreshOverlay()
            return
        }
        if event.clickCount == 2, model?.sketchSession == nil, let renderer {
            let f = renderer.camera.forward
            model?.doubleClick(renderer.hovered == 0 ? nil : PickID(raw: renderer.hovered),
                               viewDirection: SIMD3(Double(f.x), Double(f.y), Double(f.z)), additive: additive)
            refreshOverlay()
            return
        }
        if event.clickCount == 2, let session = model?.sketchSession, session.tool == .select || session.tool == .text,
           let h = session.hover, session.beginEditingText(anchoredAt: h) {
            refreshOverlay()  // a text's dot or letters: change its words in place
            return
        }
        if event.clickCount == 2, let session = model?.sketchSession, session.tool == .select, session.hover.flatMap({ session.sketch.curve($0) }) != nil {
            session.selectConnected(additive: additive)  // the whole chain of joined curves
            refreshOverlay()
            return
        }
        lastDrag = p
        downPoint = p
        dragged = false
        sketchDrag = false
        if model?.sketchSession != nil {
            let additive = event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command)
            sketchDrag = sketchEvent(.down, at: p, additive: additive)
        } else if let renderer, renderer.hovered == PickID.moveHandle.raw {
            holeMoveDrag = true
            model?.beginHoleMove()
            updateCursor()
        } else if let renderer, PickID(raw: renderer.hovered).kind == .planeEdge {
            planeResizeDrag = true
            model?.beginPlaneResize(PickID(raw: renderer.hovered))
            updateCursor()
        } else if let renderer, renderer.hovered == PickID.sectionHandle.raw {
            let ray = renderer.camera.ray(at: p, viewSize: bounds.size)
            sectionDrag = true
            model?.beginSectionDrag(rayOrigin: SIMD3(Double(ray.origin.x), Double(ray.origin.y), Double(ray.origin.z)),
                                    direction: SIMD3(Double(ray.direction.x), Double(ray.direction.y), Double(ray.direction.z)))
            updateCursor()
        } else if let renderer, PickID(raw: renderer.hovered).kind == .handle {
            handleDrag = true
            model?.beginHandleDrag(slot: PickID(raw: renderer.hovered).handleSlot)
            updateCursor()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if windowDrag { return }
        if manipulatorDrag != nil, let renderer {
            if let v = manipulatorDrag?.values(at: location(event), camera: renderer.camera, viewSize: bounds.size) {
                model?.previewManipulator(v)
            }
            refreshOverlay()
            return
        }
        if sketchDrag {
            let p = location(event)
            lastPoint = p
            sketchEvent(.dragged, at: p, additive: false)
            return
        }
        if holeMoveDrag, let renderer, let model {
            let ray = renderer.camera.ray(at: location(event), viewSize: bounds.size)
            // How long 1 mm on the hole's face looks here, so the hole moves in round steps.
            var pointsPerMM: Double?
            if let (id, hole) = model.selectedHole, let face = model.holeFace(id, hole), let a = model.holeMoveDot {
                let b = a + face.xAxis
                if let pa = renderer.camera.project(SIMD3(Float(a.x), Float(a.y), Float(a.z)), viewSize: bounds.size),
                   let pb = renderer.camera.project(SIMD3(Float(b.x), Float(b.y), Float(b.z)), viewSize: bounds.size) {
                    pointsPerMM = Double(hypot(pb.x - pa.x, pb.y - pa.y))
                }
            }
            model.moveHole(rayOrigin: SIMD3(Double(ray.origin.x), Double(ray.origin.y), Double(ray.origin.z)),
                           direction: SIMD3(Double(ray.direction.x), Double(ray.direction.y), Double(ray.direction.z)),
                           pointsPerMM: pointsPerMM)
            refreshOverlay()
            return
        }
        if sectionDrag, let renderer, let model {
            let ray = renderer.camera.ray(at: location(event), viewSize: bounds.size)
            model.dragSection(rayOrigin: SIMD3(Double(ray.origin.x), Double(ray.origin.y), Double(ray.origin.z)),
                              direction: SIMD3(Double(ray.direction.x), Double(ray.direction.y), Double(ray.direction.z)),
                              snapping: !event.modifierFlags.contains(.option))  // ⌥ turns the snapping off, as in sketches
            refreshOverlay()
            return
        }
        if planeResizeDrag, let renderer, let model {
            let ray = renderer.camera.ray(at: location(event), viewSize: bounds.size)
            // How long 1 mm in the side's way looks here, so it moves in round steps.
            var pointsPerMM: Double?
            if let l = model.planeResizeLine {
                let a = l.point, b = l.point + l.direction
                if let pa = renderer.camera.project(SIMD3(Float(a.x), Float(a.y), Float(a.z)), viewSize: bounds.size),
                   let pb = renderer.camera.project(SIMD3(Float(b.x), Float(b.y), Float(b.z)), viewSize: bounds.size) {
                    pointsPerMM = Double(hypot(pb.x - pa.x, pb.y - pa.y))
                }
            }
            model.dragPlaneEdge(rayOrigin: SIMD3(Double(ray.origin.x), Double(ray.origin.y), Double(ray.origin.z)),
                                direction: SIMD3(Double(ray.direction.x), Double(ray.direction.y), Double(ray.direction.z)),
                                pointsPerMM: pointsPerMM)
            refreshOverlay()
            return
        }
        if handleDrag, let renderer {
            let ray = renderer.camera.ray(at: location(event), viewSize: bounds.size)
            // How long 1 mm along the arrow looks here, so the size can go in round steps.
            var pointsPerMM: Double?
            if let h = model?.dragHandle {
                let a = h.base, b = h.base + h.direction
                if let pa = renderer.camera.project(SIMD3(Float(a.x), Float(a.y), Float(a.z)), viewSize: bounds.size),
                   let pb = renderer.camera.project(SIMD3(Float(b.x), Float(b.y), Float(b.z)), viewSize: bounds.size) {
                    pointsPerMM = Double(hypot(pb.x - pa.x, pb.y - pa.y))
                }
            }
            model?.dragHandle(rayOrigin: SIMD3(Double(ray.origin.x), Double(ray.origin.y), Double(ray.origin.z)),
                              direction: SIMD3(Double(ray.direction.x), Double(ray.direction.y), Double(ray.direction.z)),
                              pointsPerMM: pointsPerMM)
            refreshOverlay()
            return
        }
        navigateByDragging(event, bindings: navigation.left)
    }

    override func mouseUp(with event: NSEvent) {
        if windowDrag { windowDrag = false; return }
        defer { lastDrag = nil; rollDragRaw = nil; sketchDrag = false; handleDrag = false; holeMoveDrag = false; sectionDrag = false; planeResizeDrag = false; manipulatorDrag = nil; updateCursor() }
        if manipulatorDrag != nil {
            model?.endManipulatorDrag()
            refreshOverlay()
            return
        }
        if sectionDrag {
            model?.endSectionDrag()
            refreshOverlay()
            return
        }
        if holeMoveDrag {
            model?.endHoleMove()
            refreshOverlay()
            return
        }
        if planeResizeDrag {
            model?.endPlaneResize()
            refreshOverlay()
            return
        }
        if handleDrag {
            model?.endHandleDrag()
            refreshOverlay()
            return
        }
        if sketchDrag {
            sketchEvent(.up, at: location(event), additive: false)
            return
        }
        // A double-click's second release isn't a click: the double-click already did its job.
        guard !dragged, event.clickCount < 2, renderer != nil, let model, model.sketchSession == nil else { return }
        let p = location(event)
        let additive = event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command)
        let pixel = pickPixel(p)
        // The click acts on what is under the pointer now: if the last move's pick hasn't come back (or was for
        // another pixel), ask again and click when it arrives.
        let inside = pixel.x >= 0 && pixel.y >= 0 && p.x <= bounds.width && p.y <= bounds.height
        if pickedPixel == pixel || !inside {
            pendingClick = nil
            performClick(at: p, additive: additive)
        } else {
            let action: () -> Void = { [weak self] in self?.performClick(at: p, additive: additive) }
            pendingClick = (pixel, action)
            requestPick(at: p)
            // Should the pick never come back, click on what is known.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, let pending = self.pendingClick, pending.pixel == pixel else { return }
                self.pendingClick = nil
                pending.action()
            }
        }
    }

    private func performClick(at p: NSPoint, additive: Bool) {
        guard let renderer, let model, model.sketchSession == nil else { return }
        let ray = renderer.camera.ray(at: p, viewSize: bounds.size)
        model.clickRay = (SIMD3(Double(ray.origin.x), Double(ray.origin.y), Double(ray.origin.z)),
                          SIMD3(Double(ray.direction.x), Double(ray.direction.y), Double(ray.direction.z)))
        let next = renderer.camera.ray(at: CGPoint(x: p.x + 1, y: p.y), viewSize: bounds.size)
        model.clickRayNext = (SIMD3(Double(next.origin.x), Double(next.origin.y), Double(next.origin.z)),
                              SIMD3(Double(next.direction.x), Double(next.direction.y), Double(next.direction.z)))
        var pick = renderer.hovered == 0 ? nil : PickID(raw: renderer.hovered)
        // While a plane is being asked for, the grid floor (the XY plane) answers too.
        if pick == nil, renderer.showGrid, model.showsOriginPlanes, let ray = model.clickRay,
           ray.direction.z.magnitude > 1e-9, -ray.origin.z / ray.direction.z > 0 {
            pick = OriginPlane.xy.pickID
        }
        model.click(pick, additive: additive)
        refreshOverlay()
    }

    override func rightMouseDown(with event: NSEvent) { lastDrag = location(event); downPoint = lastDrag; dragged = false; rollDragRaw = nil }
    /// A right-click without dragging (dragging pans) opens the menu for what's under the cursor.
    override func rightMouseUp(with event: NSEvent) {
        defer { lastDrag = nil }
        if !dragged { showContextMenu(event) }
    }

    private func showContextMenu(_ event: NSEvent) {
        guard let model, let renderer else { return }
        let p = location(event)
        let pick = renderer.hovered == 0 ? nil : PickID(raw: renderer.hovered)
        let r = renderer.camera.ray(at: p, viewSize: bounds.size)
        let ray = (SIMD3(Double(r.origin.x), Double(r.origin.y), Double(r.origin.z)),
                   SIMD3(Double(r.direction.x), Double(r.direction.y), Double(r.direction.z)))
        // For "Hole Here": how big a point is where the right-click lands (see clickRayNext).
        let next = renderer.camera.ray(at: CGPoint(x: p.x + 1, y: p.y), viewSize: bounds.size)
        model.clickRayNext = (SIMD3(Double(next.origin.x), Double(next.origin.y), Double(next.origin.z)),
                              SIMD3(Double(next.direction.x), Double(next.direction.y), Double(next.direction.z)))
        var items = model.contextItems(for: pick, ray: ray)
        if model.sketchSession == nil, model.pendingTool == nil {
            items += [.separator, .action(model.sectionActive ? "Turn Off Section Analysis" : "Section Analysis",
                                          symbol: DesignTool.sectionAnalysis.symbol) {
                model.setSectionAnalysis(!model.sectionActive)
            }]
        }
        if model.sketchSession == nil, model.pendingTool == nil, model.visualStyle.isShaded {
            items += [.separator, .action(model.printPreview ? "Leave 3D Print Preview" : "FDM 3D Print Preview",
                                          symbol: "square.stack.3d.up") { model.setPrintPreview(!model.printPreview) }]
        }
        let menu = ContextMenuBuilder.menu(items) { [weak self] in self?.refreshOverlay() }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    override func rightMouseDragged(with event: NSEvent) { navigateByDragging(event, bindings: navigation.right) }
    override func otherMouseDown(with event: NSEvent) { lastDrag = location(event); downPoint = lastDrag; dragged = false; rollDragRaw = nil }
    override func otherMouseDragged(with event: NSEvent) { navigateByDragging(event, bindings: navigation.middle) }

    /// The navigation settings, read again only when they change (this is asked for on every mouse move).
    private var navigation: NavigationConfig {
        let raw = UserDefaults.standard.string(forKey: Preferences.navigation)
        if let cachedNavigation, cachedNavigationSource == raw { return cachedNavigation }
        let config = Preferences.navigationConfig
        cachedNavigation = config
        cachedNavigationSource = raw
        return config
    }
    private var cachedNavigation: NavigationConfig?
    private var cachedNavigationSource: String?

    /// Orbits, pans or zooms by a drag, as the settings bind the button and the modifier keys held.
    private func navigateByDragging(_ event: NSEvent, bindings: NavBindings) {
        var action = navAction(bindings[NavModifier(event.modifierFlags)])
        // ⇧ with the key that rolls snaps the roll; ⇧ alone is its own binding.
        let snapping = event.modifierFlags.contains(.shift)
        if snapping, event.modifierFlags.contains(.option), navAction(bindings.option) == .roll { action = .roll }
        let config = navigation
        let before = lastDrag
        drag(event) { dx, dyUp in  // `drag` gives dy upward-positive
            guard let renderer else { return }
            if action == .roll {
                // The picture follows the pointer round the middle of the free part of the view; with ⇧ it
                // lands on every 15°, however the pointer wandered between.
                guard let before, let angle = turnAroundCenter(from: before, to: location(event)) else { return }
                let raw = (rollDragRaw ?? renderer.camera.roll) + angle
                rollDragRaw = raw
                renderer.camera.roll = snapping ? (raw / Self.rollSnap).rounded() * Self.rollSnap : remainder(raw, 2 * .pi)
                return
            }
            config.navigate(&renderer.camera, action, input: .drag, dx: dx, dy: -dyUp, viewHeight: Float(bounds.height))
        }
    }

    /// Where a roll drag would have the picture without snapping, so the snapping doesn't eat small movements.
    private var rollDragRaw: Float?
    static let rollSnap = Float.pi / 12

    /// Rolling turns a sketch's picture; with nothing to roll, the input does nothing.
    private func navAction(_ action: NavAction) -> NavAction {
        action == .roll && model?.sketchSession == nil ? .none : action
    }

    /// How far, counter-clockwise on screen, the pointer went round the middle of the view between two points.
    private func turnAroundCenter(from a: NSPoint, to b: NSPoint) -> Float? {
        guard let shift = renderer?.camera.centerShift else { return nil }
        let c = NSPoint(x: bounds.midX + CGFloat(shift.x) * bounds.width / 2, y: bounds.midY - CGFloat(shift.y) * bounds.height / 2)
        let va = CGVector(dx: a.x - c.x, dy: c.y - a.y), vb = CGVector(dx: b.x - c.x, dy: c.y - b.y)  // y up
        guard hypot(va.dx, va.dy) > 8, hypot(vb.dx, vb.dy) > 8 else { return nil }  // too near the middle to have a direction
        let turn = atan2(va.dx * vb.dy - va.dy * vb.dx, va.dx * vb.dx + va.dy * vb.dy)
        return Float(turn)
    }

    private func drag(_ event: NSEvent, _ apply: (Float, Float) -> Void) {
        let p = location(event)
        guard let last = lastDrag else { lastDrag = p; return }
        let dx = Float(p.x - last.x), dy = Float(p.y - last.y)
        if let down = downPoint, hypot(p.x - down.x, p.y - down.y) > 4 { dragged = true }  // a click may jitter a little
        apply(dx, -dy)  // view is flipped: screen-up is negative y
        lastDrag = p
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        guard let renderer else { return }
        let config = navigation
        let precise = event.hasPreciseScrollingDeltas  // a trackpad
        var dx = Float(event.scrollingDeltaX), dy = Float(event.scrollingDeltaY)
        // Held with ⇧, many mice turn the wheel sideways.
        if !precise, dy == 0 { (dx, dy) = (0, dx) }
        let action = navAction((precise ? config.trackpad : config.wheel)[NavModifier(event.modifierFlags)])
        config.navigate(&renderer.camera, action, input: precise ? .trackpad : .wheel, dx: dx, dy: dy, viewHeight: Float(bounds.height),
                        cursor: ZoomAnchor(point: location(event), viewSize: bounds.size))
        needsDisplay = true
    }

    override func rotate(with event: NSEvent) {
        guard let renderer else { return }
        navigation.rotate(&renderer.camera, degrees: event.rotation, sketching: model?.sketchSession != nil)
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        guard let renderer else { return }
        navigation.pinch(&renderer.camera, magnification: Float(event.magnification),
                         cursor: ZoomAnchor(point: location(event), viewSize: bounds.size))
        needsDisplay = true
    }

    // MARK: keyboard

    override func keyDown(with event: NSEvent) {
        guard let model else { return super.keyDown(with: event) }
        let plainKey = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        if let session = model.sketchSession, plainKey {
            switch event.keyCode {
            case 53: session.escape(); refreshOverlay(); return                                      // Esc
            case 51, 117:                                                                             // ⌫ ⌦
                if session.isPatterning { model.commitSketch(session.deletePattern()) }
                else if session.isMirroring { model.commitSketch(session.deleteMirror()) }
                else if session.isOffsetting { session.cancelOffset() }  // takes the offset back, rather than deleting what it came from
                else { model.sketchCommand { $0.deleteSelection() } }
                refreshOverlay()
                return
            case 36, 76:                                                                              // Return
                if session.typed.isEmpty, !session.isPatterning, !session.isMirroring, !session.isOffsetting { model.finishSketch() } else { model.commitSketchTyped(); refreshOverlay() }
                return
            case 125 where session.tool == .polygon, 126 where session.tool == .polygon:             // ↓ ↑: fewer or more sides
                session.adjustSides(by: event.keyCode == 126 ? 1 : -1)
                refreshOverlay()
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
               let tool = SketchTool.forKey(key, current: session.tool) {
                model.setSketchTool(tool)
                refreshOverlay()
                return
            }
        } else if event.keyCode == 53 {
            if model.isPickingSketchPlane { model.cancelSketchPlanePick() }
            else if model.pendingTool != nil { model.cancelTool() }
            else if model.selection.isEmpty, model.dragHandle != nil || model.featureWithoutHandle != nil { model.finishFeatureEdit() }
            else { model.clearSelection() }
            refreshOverlay()
            return
        } else if plainKey, event.keyCode == 36 || event.keyCode == 76, model.pendingTool != nil || model.dragHandle != nil || model.featureWithoutHandle != nil {  // Return
            if model.pendingTool != nil { model.confirmTool() } else { model.finishFeatureEdit() }
            refreshOverlay()
            return
        } else if Shortcuts.matches(.tool(.extrude), event) {
            model.run(.extrude)
            refreshOverlay()
            return
        }
        super.keyDown(with: event)
    }

    /// A click on a viewport label: picks the plane it names, or opens the dimension it belongs to.
    private func labelClicked(_ id: EntityID) {
        guard let model else { return }
        if model.showsOriginPlanes, let plane = OriginPlane(labelID: id) {
            model.clickRay = nil  // a label click places things at the plane's origin
            model.click(plane.pickID, additive: false)
            refreshOverlay()
        } else if let curve = DimensionLabel.curve(ofReference: id) {
            model.sketchCommand { $0.dimensionReference(curve) }  // a measured size becomes a dimension
            refreshOverlay()
        } else if id != DimensionLabel.pendingID {
            model.sketchSession?.editingDimension = id
        }
    }

    func refreshOverlay() {
        guard let renderer, let model else { return }
        renderer.setOverlay(model.sketchOverlay())
        renderer.selected = model.highlighted
        renderer.wholeBodies = model.picksWholeBodies
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
        // Where each label goes: on its anchor, or for a radius or diameter standing clear of the curve; and
        // never on top of a label placed before it (dimensions first, then the lighter measured sizes).
        var placed: [CGRect] = []
        for l in wanted {
            let view: DimensionLabelView
            if let existing = labels[l.id] {
                view = existing
            } else {
                view = DimensionLabelView(frame: .zero)
                view.dark = isDark
                let id = l.id
                view.onClick = { [weak self] in self?.labelClicked(id) }
                view.onHover = { [weak self] inside in self?.labelHover(id, inside: inside) }
                addSubview(view)
                labels[l.id] = view
            }
            // Only what changed: this runs for every label on every frame.
            let tip = l.reference ? "Measured size · click to make it a dimension you can set"
                : l.isDimension ? "Dimension · click to change its value" : nil
            if view.stringValue != l.text {
                view.stringValue = l.text
                view.sizeToFit()
            }
            view.isReference = l.reference
            view.isDimension = l.isDimension
            view.isEditingHighlight = l.editing
            view.passesClicks = l.passesClicks
            if view.toolTip != tip { view.toolTip = tip }
            guard let p = renderer.camera.project(l.world, viewSize: bounds.size) else {
                view.isHidden = true
                continue
            }
            view.isHidden = false
            var center = p
            if let out = l.outward, let tip = renderer.camera.project(l.world + out, viewSize: bounds.size) {
                let d = CGVector(dx: tip.x - p.x, dy: tip.y - p.y), len = hypot(d.dx, d.dy)
                if len > 1e-3 {
                    let u = CGVector(dx: d.dx / len, dy: d.dy / len)
                    // Half the label's extent along that direction, plus a gap: its near edge clears the curve.
                    let reach = abs(u.dx) * view.frame.width / 2 + abs(u.dy) * view.frame.height / 2 + 8
                    center = CGPoint(x: p.x + u.dx * reach, y: p.y + u.dy * reach)
                }
            }
            var frame = CGRect(x: center.x - view.frame.width / 2, y: center.y - view.frame.height / 2,
                               width: view.frame.width, height: view.frame.height)
            for _ in 0..<8 {
                guard let hit = placed.first(where: { $0.insetBy(dx: -2, dy: -2).intersects(frame) }) else { break }
                frame.origin.y = hit.maxY + 4  // below the one in the way
            }
            view.setFrameOrigin(frame.origin)
            placed.append(frame)
        }
        // Labels sit above the constraint glyphs, so they stay clickable.
        if updateGlyphs(avoiding: placed) { for view in labels.values { addSubview(view) } }
        updatePrompt()
        syncPopover()
        syncManipulator()
        syncDialView()
        syncHandleField()
        syncSketchFields()
        syncPatternHUD()
        syncTextEntry()
        fitControls()
    }

    /// Shows the Move/Rotate manipulator on the selected Move feature, or takes it away.
    private func syncManipulator() {
        guard let renderer, let model, let place = model.manipulatorPlacement,
              let layout = ManipulatorLayout(middle: place.middle, turn: place.turn, frame: place.frame, camera: renderer.camera, viewSize: bounds.size) else {
            manipulatorView?.removeFromSuperview()
            manipulatorView = nil
            manipulatorLayout = nil
            if manipulatorHover != nil { manipulatorHover = nil; updateCursor() }
            return
        }
        let view: ManipulatorView
        if let existing = manipulatorView {
            view = existing
        } else {
            view = ManipulatorView(frame: bounds)
            view.autoresizingMask = [.width, .height]
            addSubview(view)
            manipulatorView = view
        }
        view.frame = bounds
        view.hover = manipulatorHover
        view.active = model.manipulatorActivePart
        view.layout = layout
        manipulatorLayout = layout
    }

    /// The Text tool's field: appears where the tool was clicked, focused, until Return or Esc.
    private func syncTextEntry() {
        guard let renderer, let session = model?.sketchSession, let at = session.pendingText?.position else {
            if let f = textEntryField {
                if f.currentEditor() != nil { window?.makeFirstResponder(self) }
                f.removeFromSuperview()
                textEntryField = nil
            }
            return
        }
        let field: ValueField
        if let textEntryField {
            field = textEntryField
            if textEntryFor != session.editingText {  // now editing another text: show its words
                field.stringValue = session.textEntryInitial
                field.currentEditor()?.selectAll(nil)
            }
        } else {
            field = ValueField(frame: .zero)
            field.alignment = .left
            field.font = .systemFont(ofSize: 13)
            field.placeholderString = "Type the text, then Return"
            field.stringValue = session.textEntryInitial  // editing: the words as they are
            field.delegate = self
            raiseControls().addSubview(field)
            textEntryField = field
            DispatchQueue.main.async { [weak self, weak field] in
                guard let field, field.superview != nil else { return }
                self?.window?.makeFirstResponder(field)
                field.selectText(nil)
            }
        }
        textEntryFor = session.editingText
        raiseControls()
        let w = session.frame.point(at.x, at.y)
        guard let p = renderer.camera.project(SIMD3(Float(w.x), Float(w.y), Float(w.z)), viewSize: bounds.size) else { return }
        let size = NSSize(width: 220, height: 24)
        field.frame = NSRect(x: min(max(p.x, 0), max(bounds.width - size.width, 0)),
                             y: min(max(p.y - size.height - 4, 0), max(bounds.height - size.height, 0)),
                             width: size.width, height: size.height)
    }

    // MARK: typed values

    /// Keeps each arrow's size field just right of its tip, showing the stored size (or the size being dragged).
    /// Tells the taper dial how the camera sees it (which way to spread its arc, and how big to draw it), and redraws
    /// it when that changes.
    private func syncDialView() {
        guard let renderer, let model, model.showsDial else { return }
        let cam = renderer.camera
        func tenth(_ v: SIMD3<Float>) -> SIMD3<Double> { SIMD3(Double((v.x * 10).rounded() / 10), Double((v.y * 10).rounded() / 10), Double((v.z * 10).rounded() / 10)) }
        // How long 1 mm looks, where the dial is.
        let at = cam.target, size = bounds.size
        guard let a = cam.project(at, viewSize: size), let b = cam.project(at + cam.right, viewSize: size) else { return }
        let pointsPerMM = Double(hypot(b.x - a.x, b.y - a.y))
        guard pointsPerMM > 1e-6 else { return }
        let mmPerPoint = exp((log(1 / pointsPerMM) * 10).rounded() / 10)  // to about 10%
        if model.updateDialView(DocumentModel.DialView(forward: tenth(cam.forward), right: tenth(cam.right), mmPerPoint: mmPerPoint)) {
            refreshOverlay()
        }
    }

    private func syncHandleField() {
        guard let renderer, let model, case let handles = model.dragHandles.filter({ model.showsField($0) }), !handles.isEmpty else {
            if !handleFields.isEmpty {
                if handleFields.values.contains(where: { $0.currentEditor() != nil }) { window?.makeFirstResponder(self) }
                handleFields.values.forEach { $0.removeFromSuperview() }
                handleFields = [:]
                handleFieldFeatures = [:]
                featureHUD?.removeFromSuperview()
                featureHUD = nil
            }
            return
        }
        let layer = raiseControls()
        if featureHUD == nil {
            let hud = SelfSizingHostingView(rootView: FeatureHUD(model: model))
            layer.addSubview(hud)
            featureHUD = hud
        }
        let slots = Set(handles.map(\.slot))
        for (slot, field) in handleFields where !slots.contains(slot) {
            if field.currentEditor() != nil { window?.makeFirstResponder(self) }
            field.removeFromSuperview()
            handleFields[slot] = nil
            handleFieldFeatures[slot] = nil
        }
        for slot in slots where handleFields[slot] == nil {
            let field = ValueField(frame: .zero)
            field.handleSlot = slot
            field.completions = { [weak self] in self?.model?.completionCandidates() ?? [] }
            field.delegate = self
            field.onFocus = { [weak self] in self?.model?.activeHandleSlot = slot }
            layer.addSubview(field)
            handleFields[slot] = field
        }
        raiseControls()
        let reset = model.handleFieldReset != seenHandleFieldReset
        if reset {
            // An option beside the fields changed the feature; what was typed is stored already.
            seenHandleFieldReset = model.handleFieldReset
            if handleFields.values.contains(where: { $0.currentEditor() != nil }) { window?.makeFirstResponder(self) }  // ends editing with nothing left to store
        }
        let size = NSSize(width: 110, height: 24)
        var placed: [NSRect] = []
        // The room a hole's move dot needs around it (about 22 points each way), where no field goes.
        let moveDotZone: NSRect? = model.holeMoveDot.flatMap {
            renderer.camera.project(SIMD3(Float($0.x), Float($0.y), Float($0.z)), viewSize: bounds.size)
        }.map { NSRect(x: $0.x - 22, y: $0.y - 22, width: 44, height: 44) }
        // The room the taper dial's arc takes on screen: no arrow's field or the options panel sits on it.
        let dialZone: NSRect? = model.dragHandles.lazy.compactMap { h -> NSRect? in
            guard let dial = h.dial else { return nil }
            let limit = DocumentModel.DragHandle.Dial.limit
            let points = (0...16).compactMap { i -> CGPoint? in
                let a = -limit + 2 * limit * Double(i) / 16
                let q = h.base + dial.radius * (cos(a) * h.direction + sin(a) * dial.side)
                return renderer.camera.project(SIMD3(Float(q.x), Float(q.y), Float(q.z)), viewSize: self.bounds.size)
            }
            guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
                  let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return nil }
            return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).insetBy(dx: -10, dy: -10)
        }.first
        for h in handles {
            guard let field = handleFields[h.slot], let text = model.handleFieldText(for: h.slot) else { continue }
            field.toolTip = "\(h.label): type a size or an expression, then press Return · Tab for the next · Esc cancels"
            // Another feature took the field over (picked in the timeline, which leaves focus where it was):
            // end editing first, which stores what was typed on the feature it was for, then show the new one's size.
            let otherFeature = handleFieldFeatures[h.slot].map { $0.id != h.featureID } ?? false
            if otherFeature, field.currentEditor() != nil {
                handlePreviewTask?.cancel()
                window?.makeFirstResponder(self)
                if field.currentEditor() != nil { field.abortEditing() }
            }
            if reset || otherFeature { handleFieldFeatures[h.slot] = (h.featureID, text); field.stringValue = text }
            if field.currentEditor() == nil { field.stringValue = text }
            if field.currentEditor() == nil { handleFieldFeatures[h.slot] = (h.featureID, text) }
            field.textColor = model.previewInvalid && h.slot == model.activeHandleSlot ? .systemRed : .labelColor
            let tip = h.anchor
            var anchor = renderer.camera.project(SIMD3(Float(tip.x), Float(tip.y), Float(tip.z)), viewSize: bounds.size)
            if h.slot == 0, let layout = manipulatorLayout, let part = model.manipulatorActivePart {
                // On the manipulator's arrow or ring; up beside the middle when that one points at the viewer.
                anchor = layout.anchor(for: part) ?? CGPoint(x: layout.center.x + 40, y: layout.center.y - 40)
            }
            guard let p = anchor else {
                field.isHidden = true
                continue
            }
            field.isHidden = false
            let maxX = max(bounds.width - size.width, 0)
            var x = min(max(p.x + 26, 0), maxX)
            var y = min(max(p.y - size.height / 2, 0), max(bounds.height - size.height, 0))
            // A hole's move dot has to stay easy to grab: a field that would crowd it moves out to the side of it.
            if let dot = moveDotZone, dot.intersects(NSRect(origin: NSPoint(x: x, y: y), size: size)) {
                x = dot.maxX <= maxX ? dot.maxX : max(dot.minX - size.width, 0)
            }
            // An arrow's field stays off the dial's arc: it moves out to the side of it.
            if h.dial == nil, let zone = dialZone, zone.intersects(NSRect(origin: NSPoint(x: x, y: y), size: size)) {
                x = zone.maxX + 6 <= maxX ? zone.maxX + 6 : max(zone.minX - size.width - 6, 0)
            }
            // Two arrows can end close together: the later field steps down out of the earlier one's way.
            for _ in 0..<4 where placed.contains(where: { $0.insetBy(dx: -2, dy: -2).intersects(NSRect(origin: NSPoint(x: x, y: y), size: size)) }) {
                y = min(y + size.height + 4, max(bounds.height - size.height, 0))
            }
            field.frame = clearOfDraggers(NSRect(origin: NSPoint(x: x, y: y), size: size), minX: 0, maxX: maxX,
                                          maxY: max(bounds.height - size.height, 0))
            placed.append(field.frame)
        }
        if let hud = featureHUD, let first = placed.first {  // the options panel sits just below the first field
            let s = hud.fittingSize
            let below = placed.map(\.maxY).max() ?? first.maxY
            var frame = NSRect(x: min(max(first.minX, 0), max(bounds.width - s.width, 0)),
                               y: min(below + 6, max(bounds.height - s.height, 0)), width: s.width, height: s.height)
            if let zone = dialZone, zone.intersects(frame) {  // under the dial's arc, or above it when there's no room
                frame.origin.y = zone.maxY + 6 + s.height <= bounds.height ? zone.maxY + 6 : max(zone.minY - s.height - 6, 0)
            }
            hud.frame = frame
        }
        if model.handleFocusRequest != seenHandleFocusRequest {
            // A new feature: select its size so typing replaces it (outside drawing, to be safe).
            seenHandleFocusRequest = model.handleFocusRequest
            let slot = model.handleFocusSlot ?? handles[0].slot
            model.handleFocusSlot = nil
            DispatchQueue.main.async { [weak self] in
                guard let field = self?.handleFields[slot], field.superview != nil else { return }
                self?.window?.makeFirstResponder(field)
                field.selectText(nil)
            }
        }
    }

    /// Previews a typed handle size once typing pauses.
    private func scheduleHandlePreview(_ text: String, slot: Int) {
        handlePreviewTask?.cancel()
        handlePreviewTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, let model = self.model else { return }
            model.activeHandleSlot = slot
            if !model.previewHandle(text) { self.handleFields[slot]?.textColor = .systemRed }
            self.refreshOverlay()
        }
    }

    /// Shows the fields for the sketch step in progress next to where the next point will go.
    private func syncSketchFields() {
        guard let renderer, let model, let session = model.sketchSession, !session.inputFields.isEmpty,
              let t = session.manipulatorMiddle ?? session.target()?.position else {
            removeSketchFields()
            return
        }
        let inputs = session.inputFields
        if inputs != sketchFieldOrder { buildSketchFields(inputs) }
        guard let panel = sketchPanel else { return }
        raiseControls()
        for input in inputs {
            guard let f = sketchFields[input] else { continue }
            if f.currentEditor() == nil {
                f.stringValue = session.typed[input] ?? session.liveValue(input).map { formatDimension($0, kind: input.unit) } ?? ""
            }
            f.textColor = session.typedIsInvalid(input) ? .systemRed : (session.typed[input] != nil ? .labelColor : .secondaryLabelColor)
        }
        // Beside where the shape starts (a rectangle's corner, a circle's center), so the sizes are typed where
        // they apply; for the other tools beside the next point.
        let startsAtFirstClick: Set<SketchTool> = [.rectangle, .centerRectangle, .circle, .circle2Point, .polygon, .triangle]
        let anchor = session.gearAnchor ?? (session.manipulatorMiddle == nil && startsAtFirstClick.contains(session.tool)
            ? session.clicks.first?.position ?? t : t)
        let world = session.frame.point(anchor.x, anchor.y)
        guard let p = renderer.camera.project(SIMD3(Float(world.x), Float(world.y), Float(world.z)), viewSize: bounds.size) else {
            panel.isHidden = true
            return
        }
        panel.isHidden = false
        let size = panel.fittingSize
        // Beside the next point; under the ring when the manipulator is on.
        let below = session.manipulatorMiddle != nil && !session.isOffsetting
        var x = below ? p.x - size.width / 2 : p.x + 20
        var y = p.y + (below ? ManipulatorLayout.ringRadius + 12 : 20)
        if below, y + size.height > bounds.height - 48 { y = p.y - ManipulatorLayout.ringRadius - 12 - size.height }  // no room: above the ring
        if session.isOffsetting, let tip = manipulatorLayout?.anchor(for: .axis(.x)) {  // beside the arrow's tip
            // Past the tip, on the side the arrow points to, so the field never covers the arrow's body.
            let tail = manipulatorLayout?.arrows.first { $0.axis == .x }?.tail ?? tip
            x = tip.x >= tail.x ? tip.x + 12 : tip.x - 12 - size.width
            y = tip.y - size.height / 2
        }
        // Never under the floating browser or inspector, where it would look like part of them.
        let minX = min(panelInsets.left, bounds.width * 0.45)
        let maxX = max(bounds.width - min(panelInsets.right, bounds.width * 0.45) - size.width, minX)
        x = min(max(x, minX), maxX)
        let maxY = max(bounds.height - min(panelInsets.bottom, bounds.height * 0.3) - size.height, 0)
        y = min(max(y, 0), maxY)
        panel.frame = clearOfDraggers(NSRect(origin: NSPoint(x: x, y: y), size: size), minX: minX, maxX: maxX, maxY: maxY)
    }

    /// The screen areas of the manipulator's draggers (arrows, squares, ring handles, middle dot): no typed-value
    /// field or panel may sit on top of one, or it could not be grabbed.
    private var draggerZones: [NSRect] {
        guard let layout = manipulatorLayout else { return [] }
        func box(_ pts: [CGPoint]) -> NSRect? {
            guard let x0 = pts.map(\.x).min(), let x1 = pts.map(\.x).max(),
                  let y0 = pts.map(\.y).min(), let y1 = pts.map(\.y).max() else { return nil }
            return NSRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0).insetBy(dx: -4, dy: -4)
        }
        var zones = layout.arrows.compactMap { box($0.polygon) } + layout.squares.compactMap { box($0.corners) }
        let r = ManipulatorLayout.handleRadius + 2
        zones += layout.rings.map { NSRect(x: $0.handle.x - r, y: $0.handle.y - r, width: 2 * r, height: 2 * r) }
        let d = ManipulatorLayout.dotRadius + 2
        zones.append(NSRect(x: layout.center.x - d, y: layout.center.y - d, width: 2 * d, height: 2 * d))
        return zones
    }

    /// Moves `rect` the shortest way (to the side, above or below) so it overlaps no dragger, staying inside the
    /// allowed range. Gives it back unchanged when nothing is in the way or nothing clear is found.
    private func clearOfDraggers(_ rect: NSRect, minX: CGFloat, maxX: CGFloat, maxY: CGFloat) -> NSRect {
        let zones = draggerZones
        func blocked(_ r: NSRect) -> Bool { zones.contains { $0.intersects(r) } }
        guard blocked(rect) else { return rect }
        var candidates: [NSRect] = []
        for z in zones where z.intersects(rect) {
            for origin in [NSPoint(x: z.maxX + 6, y: rect.minY), NSPoint(x: z.minX - 6 - rect.width, y: rect.minY),
                           NSPoint(x: rect.minX, y: z.maxY + 6), NSPoint(x: rect.minX, y: z.minY - 6 - rect.height)] {
                candidates.append(NSRect(origin: origin, size: rect.size))
            }
        }
        let fits = candidates.filter {
            $0.minX >= minX && $0.minX <= maxX && $0.minY >= 0 && $0.minY <= maxY && !blocked($0)
        }
        return fits.min { hypot($0.minX - rect.minX, $0.minY - rect.minY) < hypot($1.minX - rect.minX, $1.minY - rect.minY) } ?? rect
    }

    /// Shows the Pattern tool's options just under its fields, or takes them away.
    private func syncPatternHUD() {
        guard model?.sketchSession?.isPatterning == true || model?.sketchSession?.isOffsetting == true,
              let model, let panel = sketchPanel, !panel.isHidden else {
            patternHUD?.removeFromSuperview()
            patternHUD = nil
            return
        }
        let hud: SelfSizingHostingView<SketchPatternHUD>
        if let patternHUD {
            hud = patternHUD
        } else {
            hud = SelfSizingHostingView(rootView: SketchPatternHUD(model: model))
            raiseControls().addSubview(hud)
            patternHUD = hud
        }
        raiseControls()
        let s = hud.fittingSize
        let x = min(max(panel.frame.minX, 0), max(bounds.width - s.width, 0))
        var y = panel.frame.maxY + 6
        if y + s.height > bounds.height { y = max(panel.frame.minY - 6 - s.height, 0) }
        hud.frame = NSRect(x: x, y: y, width: s.width, height: s.height)
    }

    private func buildSketchFields(_ inputs: [SketchInput]) {
        removeSketchFields()
        let panel = SketchFieldPanel()
        panel.orientation = .horizontal
        panel.spacing = DS.Spacing.labelGap
        panel.edgeInsets = NSEdgeInsets(top: DS.Spacing.space2, left: DS.Spacing.labelGap, bottom: DS.Spacing.space2, right: DS.Spacing.space2)
        panel.wantsLayer = true
        panel.layer?.cornerRadius = DS.Radius.sm
        // An accent outline and a shadow set it apart from the panels around the viewport.
        panel.layer?.borderWidth = 1.5
        panel.applyColors()
        panel.layer?.shadowColor = NSColor.black.cgColor
        panel.layer?.shadowOpacity = 0.25
        panel.layer?.shadowRadius = 6
        panel.layer?.shadowOffset = CGSize(width: 0, height: -2)
        for input in inputs {
            let label = NSTextField(labelWithString: input.symbol)
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.toolTip = input.rawValue
            let field = ValueField(frame: .zero)
            field.input = input
            field.completions = { [weak self] in self?.model?.completionCandidates() ?? [] }
            field.delegate = self
            field.toolTip = "\(input.rawValue): type a value or an expression · Tab for the next · Return to place it"
            field.widthAnchor.constraint(equalToConstant: 92).isActive = true
            panel.addArrangedSubview(label)
            panel.addArrangedSubview(field)
            sketchFields[input] = field
        }
        // Start at the size the fields need: added at zero width, its frame would fight the fields'
        // fixed widths the first time it's measured (a "conflicting constraints" log).
        panel.setFrameSize(panel.fittingSize)
        raiseControls().addSubview(panel)
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
        fitControls()
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
        if let slot = field.handleSlot {
            field.textColor = .labelColor
            model?.activeHandleSlot = slot
            model?.handleDraft = field.stringValue
            scheduleHandlePreview(field.stringValue, slot: slot)
        } else if let input = field.input, let session = model?.sketchSession {
            session.setTyped(input, field.stringValue)
            refreshOverlay()
        }
    }

    func controlTextDidEndEditing(_ note: Notification) {
        // Clicking away from the handle's field keeps what was typed, if it's a usable size.
        guard let field = note.object as? ValueField, let slot = field.handleSlot, let model else { return }
        handlePreviewTask?.cancel()
        // Store what was typed on the feature the field was for, even if the handle has just gone.
        let owner = handleFieldFeatures[slot]
        if field.stringValue != (owner?.text ?? model.handleFieldText(for: slot)),
           !model.commitHandle(field.stringValue, for: owner?.id, slot: slot) {
            model.cancelHandleEdit()
        }
        refreshOverlay()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let field = control as? ValueField, let model else { return false }
        let newline = selector == #selector(NSResponder.insertNewline(_:))
        let cancel = selector == #selector(NSResponder.cancelOperation(_:))
        if field === textEntryField {
            guard newline || cancel else { return false }
            let text = field.stringValue
            window?.makeFirstResponder(self)
            if newline { model.sketchCommand { $0.placeText(text) } } else { model.sketchSession?.cancelText() }
            refreshOverlay()
            return true
        }
        if let slot = field.handleSlot {
            let tab = selector == #selector(NSResponder.insertTab(_:)), backtab = selector == #selector(NSResponder.insertBacktab(_:))
            if newline {
                handlePreviewTask?.cancel()
                guard model.commitHandle(field.stringValue, slot: slot) else {
                    NSSound.beep()
                    field.textColor = .systemRed
                    refreshOverlay()  // the options panel grows to say why
                    return true
                }
                field.stringValue = model.handleFieldText(for: slot) ?? field.stringValue
                handleFieldFeatures[slot]?.text = field.stringValue  // stored: nothing left to commit
                window?.makeFirstResponder(self)
                model.finishFeatureEdit()  // done: the handles and their fields go away
            } else if cancel {
                handlePreviewTask?.cancel()
                model.cancelHandleEdit()
                field.stringValue = model.handleFieldText(for: slot) ?? ""
                window?.makeFirstResponder(self)
            } else if tab || backtab {
                // On to the feature's other size, keeping what was typed here if it's usable.
                let order = handleFields.keys.sorted()
                guard order.count > 1, let i = order.firstIndex(of: slot) else { return true }
                handlePreviewTask?.cancel()
                if field.stringValue != (handleFieldFeatures[slot]?.text ?? model.handleFieldText(for: slot)) {
                    guard model.commitHandle(field.stringValue, for: handleFieldFeatures[slot]?.id, slot: slot) else {
                        NSSound.beep()
                        field.textColor = .systemRed
                        refreshOverlay()
                        return true
                    }
                    handleFieldFeatures[slot]?.text = field.stringValue  // stored: nothing left to commit
                }
                if let next = handleFields[order[(i + (tab ? 1 : order.count - 1)) % order.count]] {
                    window?.makeFirstResponder(next)
                    next.selectText(nil)
                }
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
            model.commitSketchTyped()
        } else if cancel {
            session.clearTyped()
            window?.makeFirstResponder(self)
        } else if tab || backtab {
            // Edits already went to the session as they were typed: setting it here too would lock in the
            // live value an untouched field shows, and the shape would stop following the cursor.
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

    /// Tells the model where the cursor is while a prompt is due; the window draws it (CursorPrompt),
    /// so it lies over the floating panels too.
    private func updatePrompt() {
        let at: CGPoint? = model?.cursorPrompt != nil && mouseInside && pointerOverViewport ? lastPoint : nil
        if model?.cursorPromptAt != at { model?.cursorPromptAt = at }
    }

    /// Whether the pointer is over the viewport itself, not the toolbar or a side panel laid over it. The prompt
    /// would otherwise sit under their buttons and tooltips, so it hides there.
    private var pointerOverViewport: Bool {
        guard let window, let p = lastPoint, !isOnToolbar(p) else { return false }
        let hit = window.contentView?.superview?.hitTest(convert(p, to: nil))
        return hit?.isDescendant(of: self) == true
    }

    /// Places the constraint glyphs; true if a new glyph view was added (above everything, labels included).
    private func updateGlyphs(avoiding labelFrames: [CGRect] = []) -> Bool {
        guard let renderer, let model else { return false }
        var created = false
        let wanted = showConstraints ? (model.sketchSession.map { SketchOverlayBuilder.glyphs($0) } ?? []) : []
        let ids = Set(wanted.map(\.id))
        for (id, view) in glyphViews where !ids.contains(id) {
            view.removeFromSuperview()
            glyphViews[id] = nil
        }
        var placedGlyphs: [CGRect] = []
        for g in wanted {
            let view: ConstraintGlyphView
            if let existing = glyphViews[g.id] {
                view = existing
            } else {
                view = ConstraintGlyphView(frame: .zero)
                view.dark = isDark
                let constraint = g.constraint
                view.onClick = { [weak self] additive in
                    self?.model?.selectSketchItem(constraint, additive: additive)
                    self?.refreshOverlay()
                }
                addSubview(view)
                created = true
                glyphViews[g.id] = view
            }
            // Only what changed: this runs for every glyph on every frame.
            let tip = "\(g.help) constraint · click to select, ⌫ to delete"
            if view.stringValue != g.symbol {
                view.stringValue = g.symbol
                view.sizeToFit()
                view.setFrameSize(NSSize(width: max(view.frame.width, 14), height: view.frame.height))
            }
            if view.toolTip != tip { view.toolTip = tip }
            view.isSelectedGlyph = g.selected
            if let p = renderer.camera.project(g.world, viewSize: bounds.size) {
                view.isHidden = false
                // Beside its curve, but not on a value label (or another glyph): moved along until it is clear.
                var frame = CGRect(origin: CGPoint(x: p.x + 8 + CGFloat(g.stack) * 17, y: p.y + 6), size: view.frame.size)
                for _ in 0..<10 {
                    guard let hit = (labelFrames + placedGlyphs).first(where: { $0.insetBy(dx: -1, dy: -1).intersects(frame) }) else { break }
                    frame.origin.x = hit.maxX + 3
                }
                view.setFrameOrigin(frame.origin)
                placedGlyphs.append(frame)
            } else {
                view.isHidden = true
            }
        }
        return created
    }
}

/// A small clickable constraint symbol.
final class ConstraintGlyphView: NSTextField {
    var onClick: ((_ additive: Bool) -> Void)?
    var isSelectedGlyph = false { didSet { if isSelectedGlyph != oldValue { updateAppearance() } } }
    var dark = false { didSet { if dark != oldValue { updateAppearance() } } }

    /// Fixed colours (not the system's dynamic ones), so the symbol keeps its contrast over any sketch paper.
    private func updateAppearance() {
        if isSelectedGlyph {
            backgroundColor = .controlAccentColor  // constraint symbols exist only while sketching
            textColor = .white
        } else {
            backgroundColor = dark ? NSColor(white: 0.14, alpha: 0.92) : NSColor(white: 1, alpha: 0.92)
            textColor = dark ? NSColor(white: 0.85, alpha: 1) : NSColor(white: 0.2, alpha: 1)
        }
        layer?.borderColor = (dark ? NSColor(white: 1, alpha: 0.3) : NSColor(white: 0, alpha: 0.3)).cgColor
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = true
        alignment = .center
        font = .systemFont(ofSize: 10, weight: .semibold)
        wantsLayer = true
        layer?.cornerRadius = DS.Radius.xs
        layer?.borderWidth = 0.5
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func mouseDown(with event: NSEvent) {
        onClick?(event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command))
    }
}

/// A small clickable value label for a sketch dimension (an accent-outlined pill), or a measured size (plain grey text).
final class DimensionLabelView: NSTextField {
    var onClick: (() -> Void)?
    /// The pointer went over the label (true) or left it.
    var onHover: ((Bool) -> Void)?
    // The viewport sets all of these on every frame, and a label's colours and outline are only redone when one changes.
    var isReference = false { didSet { if isReference != oldValue { updateAppearance() } } }
    /// A sketch dimension, the only kind of label whose value can be edited.
    var isDimension = false { didSet { if isDimension != oldValue { updateAppearance() } } }
    var isEditingHighlight = false { didSet { if isEditingHighlight != oldValue { updateAppearance() } } }
    /// See ConstraintGlyphView.dark: the colours are fixed, chosen for the viewport's light or dark look.
    var dark = false { didSet { if dark != oldValue { updateAppearance() } } }
    /// The pointer is over the label (or the margin around it that answers a click): it lights up as a button.
    private var isHovered = false { didSet { updateAppearance() } }
    private var tracking: NSTrackingArea?
    /// Clicks go through to the viewport (a readout beside something that is dragged).
    var passesClicks = false

    private func updateAppearance() {
        if isEditingHighlight {
            backgroundColor = .selectedContentBackgroundColor
            textColor = .alternateSelectedControlTextColor
            layer?.borderWidth = 0
        } else if isHovered {
            backgroundColor = dark ? NSColor(white: 0.14, alpha: 0.95).blended(withFraction: 0.35, of: .controlAccentColor)
                : NSColor(white: 1, alpha: 0.95).blended(withFraction: 0.3, of: .controlAccentColor)
            textColor = dark ? .white : .black
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.borderWidth = 1
        } else {
            let base = dark ? NSColor(white: 0.12, alpha: 0.92) : NSColor(white: 1, alpha: 0.92)
            if isReference {
                // A measurement, not something to edit: plain grey text, no pill, no outline.
                backgroundColor = dark ? NSColor(white: 0.12, alpha: 0.45) : NSColor(white: 1, alpha: 0.45)
                textColor = NSColor(white: dark ? 0.72 : 0.38, alpha: 1)
                layer?.borderWidth = 0
            } else if isDimension {
                // A dimension: a tinted pill with an accent outline, like a field. Opaque enough to read over the grid.
                backgroundColor = base.blended(withFraction: 0.22, of: .controlAccentColor)
                textColor = dark ? .white : .black
                layer?.borderColor = NSColor.controlAccentColor.cgColor
                layer?.borderWidth = 1
            } else {
                backgroundColor = base
                textColor = dark ? .white : .black
                layer?.borderColor = (dark ? NSColor(white: 1, alpha: 0.25) : NSColor(white: 0, alpha: 0.25)).cgColor
                layer?.borderWidth = 0.5
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds.insetBy(dx: -6, dy: -6), options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; NSCursor.pointingHand.set(); onHover?(true) }
    override func mouseExited(with event: NSEvent) { isHovered = false; onHover?(false) }
    override func resetCursorRects() { addCursorRect(bounds.insetBy(dx: -6, dy: -6), cursor: .pointingHand) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = true
        font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        wantsLayer = true
        layer?.cornerRadius = DS.Radius.xs
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func mouseDown(with event: NSEvent) { onClick?() }

    /// A little more than the label itself answers a click: a value is small, and often next to a curve.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isHidden || passesClicks ? nil : frame.insetBy(dx: -6, dy: -6).contains(point) ? self : nil
    }
}

/// Turns right-click menu entries into an NSMenu; each item runs its closure.
@MainActor
enum ContextMenuBuilder {
    final class Target: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        // Not named perform(_:), which NSObject already has and which the menu then sends to a garbage selector.
        @objc func runAction(_ sender: Any?) { run() }
    }

    static func menu(_ items: [ContextItem], after: @escaping () -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            switch item {
            case .separator:
                if !(menu.items.last?.isSeparatorItem ?? true) { menu.addItem(.separator()) }
            case .action(let title, let symbol, let enabled, let action):
                let target = Target { action(); after() }
                let mi = NSMenuItem(title: title, action: #selector(Target.runAction(_:)), keyEquivalent: "")
                mi.target = target
                mi.representedObject = target  // NSMenuItem holds its target weakly
                mi.isEnabled = enabled
                if let symbol { mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
                menu.addItem(mi)
            case .submenu(let title, let children):
                let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                mi.submenu = Self.menu(children, after: after)
                menu.addItem(mi)
            }
        }
        if menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
        return menu
    }
}

/// A small editable number field in the viewport (a handle's size, a typed sketch value).
final class ValueField: NSTextField, ParameterCompleting {
    /// The words typed here that may be completed (the document's parameters); nil for a field of plain text.
    var completions: (() -> [CompletionCandidate])?
    var completionSource: (() -> [CompletionCandidate])? { completions }
    /// The sketch value this field edits; nil for a drag handle's field.
    var input: SketchInput?
    /// Which of the selected feature's arrows this field sizes; nil for a sketch field.
    var handleSlot: Int?
    /// Called when typing moves into this field (by a click or Tab).
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?() }
        return ok
    }

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

/// The panel of value fields over the sketch. Its fill and outline are layer colours, which are fixed when set,
/// so they are set again whenever the appearance it is drawn in changes; otherwise a fill picked in the light
/// appearance stays under the dark appearance's white text.
final class SketchFieldPanel: NSStackView {
    func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
            layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }
}

/// A see-through layer for the viewport's controls, over the floating panels, just the size of
/// the controls in it.
final class ControlsLayer: NSView {
    override var isFlipped: Bool { true }  // the viewport's coordinates
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
    var visualStyle = VisualStyle.standard
    var printPreview = false
    var printLayer = 0.2
    var printNozzle = 0.4
    /// Section analysis: the cutting plane (see Renderer.sectionPlane).
    var sectionPlane: SIMD4<Float>?
    /// Sketching with the slice on: the sketch plane (see Renderer.sketchSlice).
    var sketchSlice: (origin: SIMD3<Float>, normal: SIMD3<Float>)?
    let showGrid: Bool
    /// Grid square and unit setting, so a change in Settings redraws the sketch grid.
    var gridSetting = ""
    var sketchPaper = Preferences.SketchPaper.blue
    var showAxes = true
    let showConstraints: Bool
    /// Widths covered by the floating panels, so the camera centres on what's left.
    var panelInsets: (left: CGFloat, right: CGFloat, bottom: CGFloat) = (0, 0, 0)

    final class Coordinator {
        var sceneRevision = -1
        var fitRevision = -1
        var cameraRevision = 0
        var sketchCamera = SketchCameraMemory()
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
        renderer.onPick = { [weak view] raw, pixel in view?.pickResult(raw, at: pixel) }
        return view
    }

    func updateNSView(_ view: ViewportMTKView, context: Context) {
        guard let renderer = view.renderer else { return }
        view.panelInsets = panelInsets  // before any fit below
        let c = context.coordinator
        // Closing a sketch turns the flat view back to the one it was opened from. Noted before any camera
        // command below, which moves the camera to the new sketch.
        let before = c.sketchCamera.update(sketching: model.sketchSession != nil, camera: renderer.camera.pose)
        if c.sceneRevision != sceneRevision {
            c.sceneRevision = sceneRevision
            renderer.setScene(model.visibleMeshes)
            renderer.hovered = 0
        }
        // Every update: a colour being picked changes nothing else.
        renderer.bodyColors = model.visibleMeshes.map { m in
            model.displayColor(of: m.id).map { c -> SIMD4<Float> in
                let (r, g, b) = c.components
                return SIMD4(Float(r), Float(g), Float(b), 1)
            }
        }
        if c.fitRevision != fitRevision, let b = model.sceneBounds {
            c.fitRevision = fitRevision
            view.updateCameraInsets()
            renderer.camera.fit(min: b.min, max: b.max, aspect: view.viewAspect)
        }
        renderer.camera.orthographic = orthographic
        renderer.visualStyle = visualStyle
        renderer.printPreview = printPreview
        renderer.printLayer = Float(printLayer)
        renderer.printNozzle = Float(printNozzle)
        renderer.sectionPlane = sectionPlane
        renderer.sketchSlice = sketchSlice
        renderer.showGrid = showGrid
        renderer.showAxes = showAxes
        if view.gridSetting != gridSetting {
            view.gridSetting = gridSetting
            view.needsDisplay = true
        }
        if view.sketching != (model.sketchSession != nil) || view.sketchPaper != sketchPaper {
            view.sketching = model.sketchSession != nil
            view.sketchPaper = sketchPaper
            view.applyAppearance()
        }
        view.showConstraints = showConstraints
        if let before, !model.sketchClosedKeepingView { view.animateCamera(to: before) }
        if c.cameraRevision != cameraRevision, let cmd = model.cameraCommand {
            c.cameraRevision = cameraRevision
            view.stopCameraAnimation()
            switch cmd.command {
            case .look(let target, let normal):
                renderer.camera.look(along: normal, at: target)
            case .lookFit(let lo, let hi, let normal):
                view.updateCameraInsets()
                renderer.camera.look(along: normal, at: (lo + hi) / 2)
                renderer.camera.fit(min: lo, max: hi, aspect: view.viewAspect)
            case .standard(let v):
                renderer.camera.setStandard(v)
                if let b = model.sceneBounds {
                    view.updateCameraInsets()
                    renderer.camera.fit(min: b.min, max: b.max, aspect: view.viewAspect)
                }
            }
        }
        renderer.setOverlay(model.sketchOverlay())
        renderer.selected = highlighted
        renderer.wholeBodies = model.picksWholeBodies
        view.needsDisplay = true
    }
}

/// A ruler number along a sketch axis, turned to read upwards, as in other CAD tools. Clicks go
/// through to the viewport.
final class AxisLabelView: NSView {
    private let text: NSAttributedString

    init(text: String) {
        self.text = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        let size = self.text.size()
        super.init(frame: NSRect(x: 0, y: 0, width: ceil(size.height) + 2, height: ceil(size.width) + 2))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let size = text.size()
        ctx.translateBy(x: bounds.midX, y: bounds.midY)
        ctx.rotate(by: .pi / 2)  // reads bottom to top
        text.draw(at: NSPoint(x: -size.width / 2, y: -size.height / 2))
    }
}

/// The sketch origin: a grey disc with one quarter light, where the axes cross.
final class OriginMarkerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 2, dy: 2)
        let disc = NSBezierPath(ovalIn: r)
        NSColor.secondaryLabelColor.withAlphaComponent(0.55).setFill()
        disc.fill()
        let c = NSPoint(x: r.midX, y: r.midY)
        let quarter = NSBezierPath()
        quarter.move(to: c)
        quarter.appendArc(withCenter: c, radius: r.width / 2, startAngle: 90, endAngle: 180)
        quarter.close()
        NSColor.windowBackgroundColor.withAlphaComponent(0.9).setFill()
        quarter.fill()
        NSColor.secondaryLabelColor.setStroke()
        disc.lineWidth = 1.2
        disc.stroke()
    }
}

/// A SwiftUI panel placed by frame that keeps its frame the size of its contents, growing down
/// from its top edge: when a message appears in it later, it gets taller instead of squeezing
/// the message and the buttons into the old height.
final class SelfSizingHostingView<Content: View>: NSHostingView<Content> {
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.superview != nil else { return }
            let size = self.fittingSize
            if size != self.frame.size { self.setFrameSize(size) }  // the viewport is flipped: the top stays put
        }
    }
}
