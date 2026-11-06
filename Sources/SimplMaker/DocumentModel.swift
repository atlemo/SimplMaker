// App state: the document, undo, background regeneration, selection, files.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
#if os(macOS)
import AppKit
#endif
import CADCore
import CADKernel
import Observation
import simd
import UniformTypeIdentifiers

/// A problem to report in an alert: the title states what went wrong, the message what to do.
struct AlertInfo: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

/// A big STL import under way: what it is doing, and how far it has got (nil if that can't be told).
struct ImportProgress: Equatable {
    var title: String
    var detail: String
    var fraction: Double?
}

/// A rebuild under way: the feature it is on, and how many of those it has to build are done.
struct RegenProgress: Equatable {
    var done: Int
    var total: Int
    var feature: String
}

@MainActor
@Observable
final class DocumentModel {
    private(set) var document: CADDocument
    /// Counts the changes made to the document (also undo and redo), so a reader can tell whether it has changed since.
    private(set) var documentRevision = 0
    private(set) var result: RegenResult?
    private(set) var meshes: [BodyMesh] = []
    private(set) var sceneRevision = 0
    private(set) var fitRevision = 0
    private(set) var isRegenerating = false
    /// How far a rebuild has got, once it has taken long enough to be worth showing (nil otherwise).
    private(set) var regenProgress: RegenProgress?
    /// Sketches a new feature has just hidden, still drawn until its rebuild lands, so the profile doesn't
    /// vanish for a moment before the solid made from it appears.
    private var sketchesHiddenPendingRebuild: Set<FeatureID> = []
    /// The highlight of what a new feature was made from, kept on screen (the selection itself is already
    /// cleared) until the rebuild lands, so it doesn't fade out ahead of the solid.
    private var highlightPendingRebuild: [UInt32] = []
    /// A STEP or STL file is being read (see importSTEP).
    private(set) var isImporting = false
    /// What a big import is doing, for a card over the view and the status bar. Nil while a file is only being read.
    private(set) var importProgress: ImportProgress?
    /// A file the iPad has just written for the user to keep or send (an export): the app's share sheet takes it from here.
    var exportedFile: URL?
    /// What the iPad has to ask the person for (a file to import, a picture) in place of the Mac's open panel; see `FileRequest`.
    var fileRequest: FileRequest?
    /// The iPad's Export chooser (the formats to pick from) is showing, or the picture export's.
    var showExportChooser = false
    var showImageExport = false
    /// The Settings sheet (iPad; the Mac has a Settings window).
    var showSettings = false
    /// The About and licences sheet (iPad).
    var showAbout = false
    /// What to do with an STL that has a lot of triangles: asks the user by default. Tests put their own answer here.
    #if os(macOS)
    @ObservationIgnored var meshReduction: @MainActor (String, Int) -> MeshReduction = DocumentModel.askAboutMeshReduction
    #else
    /// No dialog on the iPad: a mesh too big for the importer is reduced to a size that works, any other goes in as it is.
    @ObservationIgnored var meshReduction: @MainActor (String, Int) -> MeshReduction = { _, count in
        count > KBody.maxSTLTriangles ? .reduce(to: DocumentModel.reducedMeshSizes[1].triangles) : .importAsIs
    }
    #endif
    /// Asks what the Export dialog asks (given the number of bodies). Replaced in tests.
    #if os(macOS)
    @ObservationIgnored var exportChoice: @MainActor (Int) -> ExportChoice? = DocumentModel.askExportChoice
    #endif

    var selection: [PickID] = []
    private(set) var hovered: PickID?
    private var selectedFeatureStorage: FeatureID?
    /// A sketch whose Edit / Delete bar (the iPad's) was put away: by finishing it, or by tapping empty space while it was picked. Picking
    /// the sketch again in the browser or the timeline clears this.
    var dismissedSketchBar: FeatureID?
    /// The arrow being dragged or typed for, when the selected feature has more than one (see `DragHandle.slot`).
    var activeHandleSlot = 0
    var selectedFeature: FeatureID? {
        get { selectedFeatureStorage }
        set {
            guard newValue != selectedFeatureStorage else { return }
            selectedFeatureStorage = newValue
            activeHandleSlot = 0
            dialFieldOpen = nil
            if newValue != newFeature { newFeature = nil }  // moved on: Cancel no longer removes it
            // The Section Analysis tool waits for a plane: a sketch, plane or canvas picked in the browser is one.
            if pendingTool == .sectionAnalysis, let id = newValue { beginSection(feature: id) }
            overlayRevision += 1
        }
    }
    /// The sketch being edited, if any.
    private(set) var sketchSession: SketchSession?
    /// A new sketch is waiting for the user to click an origin plane or a flat face.
    private(set) var isPickingSketchPlane = false
    /// The feature just created by a tool, while it is still being sized: Cancel takes it out again.
    var newFeature: FeatureID?
    @ObservationIgnored var documentBeforeNewFeature: CADDocument?
    /// `newFeature` has not been through a complete rebuild yet: if that one fails, the feature is taken out again.
    @ObservationIgnored private var newFeatureUnbuilt = false
    /// A tool waiting for the user to pick what it needs (a profile, a path, a face...). See DesignTools.swift.
    var pendingTool: DesignTool? {
        didSet {
            if pendingTool == nil { reselecting = nil; splitBodies = nil }  // cancelling the tool ends a re-pick too
            if pendingTool != oldValue { toolMissed = false }
        }
    }
    /// The Split tool has its bodies and waits for the face, plane or profile to split them with.
    var splitBodies: [FeatureID]?
    /// The Measure tool's last readout, for the picks and the scene it was made for.
    @ObservationIgnored var measureCache: (key: MeasureCacheKey, value: MeasureReadout?)?
    /// The waiting tool's last click was on something it can't use: its prompt says why.
    var toolMissed = false
    /// The pointer's ray while the Thread tool waits, so the face a click would thread lights up.
    @ObservationIgnored var hoverRay: (origin: SIMD3<Double>, direction: SIMD3<Double>)?
    /// Round faces next to each face, found once per rebuild (see roundFace).
    @ObservationIgnored var roundNeighbors: [FaceRef: [(face: String, cylinder: KCylinder)]] = [:]
    /// An extrude, revolve or sweep whose profiles are being picked again (its tool waits for picks).
    var reselecting: FeatureID?
    /// The pointer ray of the latest click in the viewport, for placing things where the user clicked.
    @ObservationIgnored var clickRay: (origin: SIMD3<Double>, direction: SIMD3<Double>)?
    /// The ray one point to the right of the click: how big a point is where the click lands.
    @ObservationIgnored var clickRayNext: (origin: SIMD3<Double>, direction: SIMD3<Double>)?
    /// Side length of the origin plane squares shown while picking, in mm.
    var sketchPlaneSize: Double = 25
    /// Bumped whenever the sketch overlay needs rebuilding.
    var overlayRevision = 0
    /// Whether the sketch that was closed last was closed to start a tool, which leaves the camera alone.
    private(set) var sketchClosedKeepingView = false
    /// Camera request for the viewport (look at a sketch plane, standard views), with a revision counter.
    private(set) var cameraCommand: (command: CameraCommand, revision: Int)?
    var showInspector = true
    /// The timeline bar along the bottom.
    var showTimeline = true
    /// The browser (bodies, sketches, timeline, parameters) on the left.
    var showSidebar = true
    /// The browser panel and the parameters panel are each open or folded up to their header.
    var browserOpen = true
    var parametersOpen = true
    /// The Appearance panel, for giving bodies colours (A, or View ▸ Show Appearance).
    var showAppearance = false
    /// A colour shown on bodies while it is being picked, before it is kept (see previewBodyColor).
    private(set) var colorPreview: (bodies: [FeatureID], color: BodyColor)?
    /// A roughness being set with the slider, shown on bodies until it is let go (see previewBodyRoughness).
    private(set) var roughnessPreview: (bodies: [FeatureID], roughness: Double)?
    /// Orthographic projection (View menu), on by default: sizes and alignments read truer than in perspective.
    var orthographic = true
    /// How bodies are drawn: shaded or wireframe, with or without edges (View ▸ Visual Style).
    var visualStyle = VisualStyle.standard
    /// The command palette (⌘K) is open.
    var showPalette = false
    /// Shaded bodies drawn like an FDM print, with layer lines (View ▸ FDM 3D Print Preview). Not saved.
    var printPreview = false
    /// The print preview's layer height and nozzle width, in mm, and whether its options panel is open.
    var printLayer = 0.2
    var printNozzle = 0.4
    var showPrintOptions = false
    static let printLayerHeights = [0.12, 0.16, 0.2, 0.24]
    static let printNozzles = [0.2, 0.4, 0.6, 0.8]

    /// Section analysis (Inspect ▸ Section Analysis): the plane the bodies are cut by, and whether the cut shows. Not saved.
    var section: SectionCut?
    var sectionOn = true
    /// Sketching: everything between the sketch's plane and the camera is cut away, to reach a sketch that lies
    /// between walls. A view setting: not saved, no undo step.
    var sketchSlice = false
    /// Sketching: an X at the middle of every closed shape, not just while a point tool is drawing. Kept between launches.
    var showShapeCentres = UserDefaults.standard.bool(forKey: Preferences.showShapeCentres) {
        didSet { UserDefaults.standard.set(showShapeCentres, forKey: Preferences.showShapeCentres) }
    }
    /// The sketch plane the renderer slices at, while sketching with the slice on.
    var sketchSlicePlane: (origin: SIMD3<Float>, normal: SIMD3<Float>)? {
        guard sketchSlice, let f = sketchSession?.frame else { return nil }
        let o = f.origin, n = simd_normalize(f.normal)
        return (SIMD3(Float(o.x), Float(o.y), Float(o.z)), SIMD3(Float(n.x), Float(n.y), Float(n.z)))
    }
    /// The Exploded View (View menu): the bodies slide apart from the middle of the part by `explodeAmount` (0...1),
    /// all ways or along one axis. Not saved.
    var explodeOn = false
    var explodeAmount = 0.5
    var explodeDirection = ExplodeDirection.all
    var showExplodeOptions = false
    @ObservationIgnored var bodyBoxesCache: (revision: Int, hidden: Set<FeatureID>, value: [(min: SIMD3<Float>, max: SIMD3<Float>)])?
    /// The cutting plane's arrow being dragged: the offset it started from, and where along the arrow the grab was.
    @ObservationIgnored var sectionDrag: (offset: Double, base: SIMD3<Double>, direction: SIMD3<Double>, grab: Double)?

    /// Turns the print preview on or off; on, it opens its options (and the render view, which restyles the bodies too, goes off).
    func setPrintPreview(_ on: Bool) {
        printPreview = on
        if on { showPrintOptions = true; renderView = false; restorePanelsHiddenByRender() }
    }

    /// The Render view (the Render button): a solid floor and a light you set, for presentation. Not saved.
    var renderView = false

    /// Show/Hide UI: the panels and the toolbar are put away, leaving the 3D view alone. Not saved.
    private(set) var uiHidden = false
    /// What was open when the UI was hidden, to bring back.
    @ObservationIgnored private var panelsHiddenByUI = (sidebar: false, inspector: false, timeline: false, appearance: false, renderOptions: false)

    func toggleUIHidden() {
        if uiHidden {
            showSidebar = panelsHiddenByUI.sidebar
            showInspector = panelsHiddenByUI.inspector
            showTimeline = panelsHiddenByUI.timeline
            showAppearance = panelsHiddenByUI.appearance
            showRenderOptions = panelsHiddenByUI.renderOptions
        } else {
            panelsHiddenByUI = (showSidebar, showInspector, showTimeline, showAppearance, showRenderOptions)
            showSidebar = false; showInspector = false; showTimeline = false; showAppearance = false; showRenderOptions = false
        }
        uiHidden.toggle()
    }
    /// Its floor and light, kept between launches, and whether its options panel is open.
    var renderSettings = RenderSettings.load() {
        didSet { renderSettings.save() }
    }
    var showRenderOptions = false
    /// Whether the Render view's turntable is playing: the camera circles the part slowly. Not saved; ends with the Render view.
    var renderSpinning = false
    /// Whether the Export Image dialog is open.
    var showExportImage = false
    /// Where the Render view's depth blur is sharp, in the world; nil = the middle of the part. Not saved.
    var renderFocusPoint: SIMD3<Double>?
    /// The next click in the view sets the focus point (Select focus point in the Render options).
    var pickingRenderFocus = false

    /// Starts or cancels picking the focus point: the next click on the part (or the floor) sets it.
    func togglePickingRenderFocus() {
        pickingRenderFocus.toggle()
        if pickingRenderFocus, pendingTool != nil { cancelTool() }
        overlayRevision += 1
    }

    func setRenderFocus(_ point: SIMD3<Double>?) {
        renderFocusPoint = point
        pickingRenderFocus = false
        // Choosing where it is sharp means wanting the blur: switch it on (gently) if it is off.
        if point != nil, renderSettings.depthOfField == 0 { renderSettings.depthOfField = 0.35 }
        overlayRevision += 1
    }

    /// Where a ray from the camera first meets the part (or, failing that, the floor): the point to focus on.
    func focusPoint(origin o: SIMD3<Double>, direction d: SIMD3<Double>) -> SIMD3<Double>? {
        var best: Double?
        let shifts = explodeOffsets
        let shown = visibleMeshes
        for (n, body) in shown.enumerated() {
            let shift = shifts.count == shown.count ? SIMD3<Double>(shifts[n]) : .zero
            let p = body.mesh.positions, ix = body.mesh.indices
            func vertex(_ i: UInt32) -> SIMD3<Double> { SIMD3(Double(p[Int(i) * 3]), Double(p[Int(i) * 3 + 1]), Double(p[Int(i) * 3 + 2])) + shift }
            for t in stride(from: 0, to: ix.count - 2, by: 3) {
                let a = vertex(ix[t]), b = vertex(ix[t + 1]), c = vertex(ix[t + 2])
                let e1 = b - a, e2 = c - a
                let h = simd_cross(d, e2)
                let det = simd_dot(e1, h)
                if abs(det) < 1e-12 { continue }
                let f = 1 / det
                let s = o - a
                let u = f * simd_dot(s, h)
                if u < 0 || u > 1 { continue }
                let q = simd_cross(s, e1)
                let v = f * simd_dot(d, q)
                if v < 0 || u + v > 1 { continue }
                let tHit = f * simd_dot(e2, q)
                if tHit > 1e-6, best == nil || tHit < best! { best = tHit }
            }
        }
        if best == nil, d.z < -1e-9, o.z > 0 { best = -o.z / d.z }  // the floor
        return best.map { o + d * $0 }
    }
    /// The 3D view, for the one thing the model asks of it: a picture of what it shows (Export Image).
    #if os(macOS)
    @ObservationIgnored weak var viewportView: ViewportMTKView?
    #endif

    /// The browser, inspector and timeline the Render view hid when it came on (they were open), to bring back when it goes off
    /// (unless they have been opened since).
    @ObservationIgnored private var panelsHiddenByRender = (sidebar: false, inspector: false, timeline: false)

    private func restorePanelsHiddenByRender() {
        if panelsHiddenByRender.sidebar { showSidebar = true }
        if panelsHiddenByRender.inspector { showInspector = true }
        if panelsHiddenByRender.timeline { showTimeline = true }
        panelsHiddenByRender = (false, false, false)
    }

    /// Turns the Render view on or off; on, it opens its options, hides the browser and inspector (the toolbar buttons
    /// bring them back), leaves the print preview and needs a shaded style.
    func setRenderView(_ on: Bool) {
        let wasOn = renderView
        renderView = on
        if !on { renderSpinning = false; restorePanelsHiddenByRender() }
        if on {
            if !wasOn {
                panelsHiddenByRender = (showSidebar, showInspector, showTimeline)
                showSidebar = false
                showInspector = false
                showTimeline = false
            }
            showRenderOptions = true
            printPreview = false
            if !visualStyle.isShaded { visualStyle = .standard }
        }
    }
    var fileURL: URL?
    var alert: AlertInfo?
    /// What an AI client connected to SimplMaker is doing to this part right now ("Creating Box1"), shown in the
    /// status bar so the user can tell the model is being changed from outside. Nil when nothing is. Not saved.
    var aiActivity: String?

    @ObservationIgnored var undoManager: UndoManager?
    /// Called with every new document, so the file can snapshot it off the main thread.
    @ObservationIgnored var onDocumentChange: (@Sendable (CADDocument) -> Void)?
    @ObservationIgnored private var generation = 0
    /// Rebuilds run one at a time: while one runs, only the newest request waits (a drag asks
    /// many times a second, and piling those up made every one of them slower).
    @ObservationIgnored private var regenRunning = false
    @ObservationIgnored private var rebuildWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var queuedRegen: (@MainActor () -> Void)?
    /// The newest rebuild whose result is on screen: older results arriving later are dropped.
    @ObservationIgnored private var appliedGeneration = 0
    /// A rebuild whose threads are expected to take this many seconds shows the model without them first
    /// (see `Regenerator.regenerate(progressiveThreads:)`). Quick threads aren't worth a flicker.
    @ObservationIgnored var progressiveThreads: TimeInterval = 0.4
    /// What earlier rebuilds left after each feature, so the next one starts at the first change.
    @ObservationIgnored private let regenCache = RegenCache()
    @ObservationIgnored private let meshCache = MeshCache()

    init(document: CADDocument = CADDocument()) {
        self.document = document
        regenerate(fit: true)
    }

    // MARK: editing (every change goes through here: undo + regenerate)

    func mutate(_ actionName: String, _ change: (inout CADDocument) -> Void) {
        var doc = document
        change(&doc)
        guard doc != document else { return }
        replace(with: doc, actionName: actionName)
    }

    /// Changes something that isn't part of the model (which handle a feature's typed field is for): no undo
    /// step and nothing to rebuild.
    func setPresentation(_ id: FeatureID, _ change: (inout Feature) -> Void) {
        guard let i = document.index(of: id) else { return }
        var f = document.features[i]
        change(&f)
        guard f != document.features[i] else { return }
        document.features[i] = f
        documentRevision += 1
        onDocumentChange?(document)
        overlayRevision += 1
    }

    private func replace(with doc: CADDocument, actionName: String) {
        let old = document
        document = doc
        documentRevision += 1
        onDocumentChange?(doc)
        syncSession()
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.replace(with: old, actionName: actionName) }
        }
        undoManager?.setActionName(actionName)
        if doc.ignoringPresentation == old.ignoringPresentation {  // only visibility or names changed: nothing to rebuild
            sceneRevision += 1
            overlayRevision += 1
        } else {
            regenerate()
        }
    }

    // MARK: timeline marker

    /// How many features the model is built from: the marker's position in the timeline.
    var markerPosition: Int { document.rollback.map { min($0, document.features.count) } ?? document.features.count }

    /// Moves the timeline marker: the model is rebuilt from the features before it only.
    func setMarker(_ position: Int) {
        let p = min(max(position, 0), document.features.count)
        guard p != markerPosition else { return regenerate() }  // drop a drag preview
        if sketchSession != nil { finishSketch() }
        pendingTool = nil
        mutate("Move Timeline Marker") { $0.rollback = p == $0.features.count ? nil : p }
        if let id = selectedFeature, let i = document.index(of: id), i >= p { selectedFeature = nil }
    }

    /// A feature picked for editing that the marker has rolled back is built again: the marker moves to
    /// just after it (later features stay rolled back), so its handle has something to show.
    func bringIntoModel(_ id: FeatureID) {
        guard let i = document.index(of: id), i >= markerPosition else { return }
        setMarker(i + 1)
    }

    /// Shows the model as it would be with the marker at `position`, while the marker is dragged.
    func previewMarker(_ position: Int) {
        var doc = document
        let p = min(max(position, 0), doc.features.count)
        doc.rollback = p == doc.features.count ? nil : p
        regenerate(preview: doc)
    }

    // MARK: visibility

    func isHidden(_ id: FeatureID) -> Bool { document.hidden.contains(id) }

    /// Shows or hides bodies and sketches (by the id of the feature that made them), as one undo step.
    func setHidden(_ ids: [FeatureID], _ hidden: Bool) {
        let noun = ids.count == 1 ? (document.features.first { $0.id == ids[0] }.map { f -> String in
            switch f.kind {
            case .sketch: return "Sketch"
            case .image: return "Canvas"
            default: return "Body"
            }
        } ?? "") : "Items"
        mutate(hidden ? "Hide \(noun)" : "Show \(noun)") { doc in
            if hidden { doc.hidden.formUnion(ids) } else { doc.hidden.subtract(ids) }
        }
        if hidden { selection.removeAll { $0.isFace || $0.isEdge ? ids.contains(meshes[safe: $0.body]?.id ?? "") : false } }
    }

    // MARK: locking

    func isLocked(_ id: FeatureID) -> Bool { document.locked.contains(id) }

    /// Whether a body or sketch can be locked (planes and canvases can't).
    func isLockable(_ id: FeatureID) -> Bool {
        isSketch(id) || bodies.contains { $0.id == id }
    }

    /// Locks or unlocks bodies and sketches (by the id of the feature that made them), as one undo step.
    /// A locked one is still drawn, but can't be picked, selected or edited until it is unlocked.
    func setLocked(_ ids: [FeatureID], _ locked: Bool) {
        let ids = ids.filter(isLockable)
        guard !ids.isEmpty else { return }
        let noun = ids.count == 1 ? (isSketch(ids[0]) ? "Sketch" : "Body") : "Items"
        mutate(locked ? "Lock \(noun)" : "Unlock \(noun)") { doc in
            if locked { doc.locked.formUnion(ids) } else { doc.locked.subtract(ids) }
        }
        if locked {
            selection.removeAll { isLockedPick($0) }
            if let f = selectedFeature, ids.contains(f) { selectedFeature = nil }
        }
    }

    private func isSketch(_ id: FeatureID) -> Bool {
        if case .sketch? = document.features.first(where: { $0.id == id })?.kind { return true }
        return false
    }

    /// The body, or the sketch, a pick in the viewport belongs to.
    func owner(of pick: PickID) -> FeatureID? {
        switch pick.kind {
        case .face, .edge: return meshes[safe: pick.body]?.id
        case .region: return profile(of: pick)?.sketch
        case .sketchCurve: return curve(of: pick)?.sketch
        default: return nil
        }
    }

    /// Whether a pick belongs to something locked. A sketch being edited keeps its own picks (it has no
    /// pick slot of a finished sketch), and snapping to a locked body's edges goes by geometry, not picks.
    func isLockedPick(_ pick: PickID) -> Bool {
        guard !document.locked.isEmpty, let id = owner(of: pick) else { return false }
        return document.locked.contains(id)
    }

    /// Bodies and sketches that own what's selected in the viewport: highlighted in the browser.
    /// The body selected as a whole (from the browser), if that's what's selected.
    var selectedBody: FeatureID? {
        guard selection.count == 1, let pick = selection.first, pick.isWholeBody else { return nil }
        return meshes[safe: pick.body]?.id
    }

    /// Every body selected as a whole (from the browser), in the order they were picked; empty when anything
    /// else (a face, an edge, a profile) is selected too.
    var selectedBodies: [FeatureID] {
        guard !selection.isEmpty, selection.allSatisfy(\.isWholeBody) else { return [] }
        return selection.compactMap { meshes[safe: $0.body]?.id }
    }

    /// The browser's selection changed to these bodies (⌘- or ⇧-click, or ⌘A in the list). While a tool waits for
    /// bodies, each body that was added or taken out is a click for the tool; otherwise they become the selection.
    func selectBodies(_ ids: [FeatureID], replacing current: [FeatureID]) {
        let ids = ids.filter { !isLocked($0) }
        if pendingTool != nil {
            for id in Set(ids).symmetricDifference(current) { selectBody(id) }
            return
        }
        if sketchSession != nil { finishSketch() }
        selectedFeature = nil
        selection = ids.compactMap { id in meshes.firstIndex { $0.id == id }.map { PickID(wholeBody: $0) } }
    }

    /// A body clicked in the browser: selected whole, with no tool or handle, the way a click on it
    /// in the viewport would. While a tool waits for bodies, it picks the body for the tool instead.
    /// `additive` (⇧-click) adds the body to the selection, or takes it out again.
    func selectBody(_ id: FeatureID, additive: Bool = false) {
        guard !isLocked(id), let index = meshes.firstIndex(where: { $0.id == id }) else { return }
        let pick = PickID(wholeBody: index)
        if let tool = pendingTool {
            if tool.accepts(.face) { toolClick(tool, pick) }
            return
        }
        if sketchSession != nil { finishSketch() }
        selectedFeature = nil
        if additive {
            if let i = selection.firstIndex(of: pick) { selection.remove(at: i) } else { selection.append(pick) }
        } else {
            selection = [pick]
        }
    }

    /// The feature that made a picked face or edge, from its name (every face is named "<feature>.…", and an
    /// edge "<face>|<face>"): for an edge, the later of its two faces' features, since that is the one that
    /// cut it. Nil for anything else, or when that feature is gone.
    func creatingFeature(of pick: PickID) -> FeatureID? {
        guard let name = name(of: pick) else { return nil }
        let owners = name.split(separator: "|").compactMap { face -> (id: FeatureID, index: Int)? in
            let id = String(face.prefix { $0 != "." })
            return document.index(of: id).map { (id, $0) }
        }
        return owners.max { $0.index < $1.index }?.id
    }

    /// The features the timeline lights up, in timeline order: the one open for editing, the one that made
    /// the body selected in the browser (a body's id is its feature's), and the ones that made the faces
    /// and edges picked in the viewport (a chamfered edge lights its chamfer).
    var timelineMarks: [FeatureID] {
        var ids = Set(selection.compactMap { creatingFeature(of: $0) })
        if let id = selectedFeature ?? selectedBody { ids.insert(id) }
        return document.features.map(\.id).filter(ids.contains)
    }

    var browserHighlights: Set<FeatureID> {
        var ids = Set<FeatureID>()
        for pick in selection {
            switch pick.kind {
            case .face, .edge: if let id = meshes[safe: pick.body]?.id { ids.insert(id) }
            case .region: if let p = profile(of: pick) { ids.insert(p.sketch) }
            case .sketchCurve: if let c = curve(of: pick) { ids.insert(c.sketch) }
            default: break
            }
        }
        return ids
    }

    /// Bodies the viewport draws.
    var visibleMeshes: [BodyMesh] { meshes.filter { !document.hidden.contains($0.id) } }

    /// Bodies for the browser, in creation order.
    /// The bodies, with the names given to them (renaming a body needs no rebuild).
    var bodies: [BodyResult] {
        (result?.bodies ?? []).map { b in
            var b = b
            if let name = document.bodyNames[b.id] { b.name = name }
            return b
        }
    }

    /// Sketch features for the browser.
    var sketches: [Feature] { document.features.filter { if case .sketch = $0.kind { true } else { false } } }
    /// Construction planes in document order. A plane's position here, plus 3 (after the origin
    /// planes), is its index in plane pick IDs.
    var planeFeatures: [Feature] { document.features.filter { if case .plane = $0.kind { true } else { false } } }

    /// Reference images (Canvas features) in document order.
    var imageFeatures: [Feature] { document.features.filter { if case .image = $0.kind { true } else { false } } }

    /// The construction plane a plane pick points at (nil for the origin planes).
    func constructionPlane(of pick: PickID) -> FeatureID? {
        guard pick.kind == .plane, pick.element >= OriginPlane.allCases.count else { return nil }
        return planeFeatures[safe: pick.element - OriginPlane.allCases.count]?.id
    }

    /// The plane a pick means: an origin plane, a construction plane, or a flat face.
    func planeRef(of pick: PickID) -> PlaneRef? {
        if let origin = OriginPlane(pick: pick) { return origin.planeRef }
        if let id = constructionPlane(of: pick) { return .plane(id) }
        return faceRef(pick).map { .face($0) }
    }

    func setParameter(_ name: String, expression: String) {
        let values = parameterValues
        mutate("Change \(name)") { $0.setParameterExpression(name, expression, values: values) }
    }

    /// Shows a parameter's new expression while its name is dragged, without an undo step.
    func previewParameter(_ name: String, expression: String) {
        var doc = document
        guard let i = doc.parameters.firstIndex(where: { $0.name == name }) else { return }
        doc.parameters[i].expression = expression
        regenerate(preview: doc)
        // The sketch being edited follows too: re-solved from what is stored, at the new values.
        if let session = sketchSession, let f = doc.features.first(where: { $0.id == session.featureID }), case .sketch(let sf) = f.kind {
            session.reload(sf.sketch, parameters: ParameterEvaluator.evaluate(doc.parameters))
            overlayRevision += 1
        }
    }

    /// Drops a parameter preview (the name was dragged back to where it began): the model and the sketch go back to the document's.
    func cancelParameterPreview() {
        regenerate()
        guard let session = sketchSession, let f = document.features.first(where: { $0.id == session.featureID }),
              case .sketch(let sf) = f.kind else { return }
        session.reload(sf.sketch, parameters: ParameterEvaluator.evaluate(document.parameters))
        overlayRevision += 1
    }

    /// Makes a parameter a length, an angle or a plain number. A plain value ("10 mm") moves to
    /// the new unit ("10 deg", "10"); an expression stays as it is.
    func setParameterUnit(_ name: String, _ unit: UnitKind) {
        mutate("Change \(name)") { doc in
            guard let i = doc.parameters.firstIndex(where: { $0.name == name }), doc.parameters[i].unit != unit else { return }
            doc.parameters[i].unit = unit
            let text = doc.parameters[i].expression.trimmingCharacters(in: .whitespaces)
            if let match = text.wholeMatch(of: /(-?[0-9]+(?:[.,][0-9]+)?)\s*(mm|cm|m|in|deg|rad|°)?/) {
                let suffix = unit == .length ? " mm" : unit == .angle ? " deg" : ""
                doc.parameters[i].expression = String(match.1) + suffix
            }
        }
    }

    func addParameter() {
        mutate("Add Parameter") { doc in
            var n = 1
            while doc.parameters.contains(where: { $0.name == "p\(n)" }) { n += 1 }
            doc.parameters.append(Parameter("p\(n)", "10 mm"))
        }
    }

    /// Renames a parameter and every expression that uses it. Returns why not, if it can't.
    @discardableResult
    func renameParameter(_ old: String, to new: String) -> String? {
        var doc = document
        do { try doc.renameParameter(old, to: new) } catch { return "\(error)" }
        mutate("Rename \(old)") { $0 = doc }
        return nil
    }

    /// Renames a sketch or other feature (an empty name keeps the old one).
    func renameFeature(_ id: FeatureID, to name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        updateFeature(id, "Rename") { $0.name = n }
    }

    /// Renames a body (an empty name goes back to its "BodyN" name).
    func renameBody(_ id: FeatureID, to name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        mutate("Rename Body") { doc in doc.bodyNames[id] = n.isEmpty ? nil : n }
    }

    // MARK: browser folders

    /// A folder just made from the browser's header, for the list to start naming.
    var pendingFolderRename: String?
    /// The same for a folder just made in the Parameters list.
    var pendingParameterFolderRename: String?

    /// Makes a folder (inside `parent`, or at the top), with these items in it, and returns its id.
    @discardableResult
    func newFolder(in parent: String? = nil, holding items: [FeatureID] = []) -> String {
        var id = ""
        mutate(items.isEmpty ? "New Folder" : "New Folder with Items") { doc in
            id = doc.addFolder(in: parent)
            doc.move(items, toFolder: id)
        }
        return id
    }

    func renameFolder(_ id: String, to name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        mutate("Rename Folder") { doc in
            if let i = doc.folders.firstIndex(where: { $0.id == id }) { doc.folders[i].name = n }
        }
    }

    /// Deletes a folder, keeping what is in it: that moves up a level.
    func deleteFolder(_ id: String) {
        mutate("Delete Folder") { $0.removeFolder(id) }
    }

    /// Puts bodies, sketches, planes and canvases in a folder (nil: back in their usual group).
    func move(items: [FeatureID], toFolder id: String?) {
        mutate("Move to Folder") { $0.move(items, toFolder: id) }
    }

    /// Drag and drop in the browser: bodies, sketches, planes or canvases placed at `target`'s row. A body also joins the folder `target` is in.
    func reorder(_ moved: [FeatureID], onto target: FeatureID) {
        let bodyIDs = bodies.map(\.id)
        let isBody = bodyIDs.contains(target)
        let siblings: [FeatureID]
        if isBody { siblings = bodyIDs }
        else if sketches.contains(where: { $0.id == target }) { siblings = sketches.map(\.id) }
        else if planeFeatures.contains(where: { $0.id == target }) { siblings = planeFeatures.map(\.id) }
        else { siblings = imageFeatures.map(\.id) }
        let moved = moved.filter { siblings.contains($0) }
        guard !moved.isEmpty else { return }
        mutate("Reorder") { doc in
            var group = siblings
            if isBody {
                let home = doc.folder(of: target)
                doc.move(moved, toFolder: home)
                group = siblings.filter { doc.folder(of: $0) == home }
            }
            doc.reorder(moved, onto: target, among: group)
        }
    }

    func move(folder id: String, into parent: String?) {
        mutate("Move Folder") { $0.moveFolder(id, into: parent) }
    }

    /// Everything in a folder and the folders inside it: what its eye shows and hides.
    func items(inFolder id: String) -> [FeatureID] { document.items(inTree: id) }

    /// The bodies in a folder and the folders inside it, in the browser's order.
    func bodies(inFolder id: String) -> [BodyResult] {
        let inside = Set(document.items(inTree: id))
        return bodies.filter { inside.contains($0.id) }
    }

    // MARK: appearance

    /// Bodies the Appearance panel colours: those selected whole, or owning a selected face or edge.
    var appearanceTargets: [FeatureID] {
        let ids = Set(selection.compactMap { $0.isFace || $0.isEdge ? meshes[safe: $0.body]?.id : nil })
        return bodies.map(\.id).filter(ids.contains)
    }

    /// The colour a body is drawn in: the one being picked for it, else its own; nil = the default.
    func displayColor(of id: FeatureID) -> BodyColor? {
        if let p = colorPreview, p.bodies.contains(id) { return p.color }
        // A piece of a split body looks like the body it came from until it is given a colour of its own.
        return document.bodyColors[id] ?? document.bodyColors[Regenerator.rootBody(id)]
    }

    /// Gives bodies a colour (nil goes back to the default), as one undo step. Needs no rebuild.
    func setBodyColor(_ color: BodyColor?, of ids: [FeatureID]) {
        colorPreview = nil
        overlayRevision += 1  // redraw, in case the preview was all that changed
        guard !ids.isEmpty else { return }
        let noun = ids.count == 1 ? "Colour" : "Colours"
        mutate(color == nil ? "Reset \(noun)" : "Change \(noun)") { doc in
            for id in ids { doc.bodyColors[id] = color }
        }
    }

    /// The material a body is drawn in (in the Render view); a piece of a split body has its parent's until given its own.
    func displayMaterial(of id: FeatureID) -> BodyMaterial? {
        document.bodyMaterials[id] ?? document.bodyMaterials[Regenerator.rootBody(id)]
    }

    /// How rough a body is drawn (0 polished to 1 matte): what is being set, else its own, else its material's. Nil for a
    /// material with no roughness.
    func displayRoughness(of id: FeatureID) -> Double? {
        guard let material = displayMaterial(of: id), material.hasRoughness else { return nil }
        if let p = roughnessPreview, p.bodies.contains(id) { return p.roughness }
        return document.bodyRoughness[id] ?? document.bodyRoughness[Regenerator.rootBody(id)] ?? material.defaultRoughness
    }

    /// Shows a roughness on bodies while the slider is dragged, without changing the document.
    func previewBodyRoughness(_ roughness: Double, of ids: [FeatureID]) {
        roughnessPreview = ids.isEmpty ? nil : (ids, roughness)
        overlayRevision += 1
    }

    /// Gives bodies a roughness (nil goes back to their material's), as one undo step. Needs no rebuild.
    func setBodyRoughness(_ roughness: Double?, of ids: [FeatureID]) {
        roughnessPreview = nil
        overlayRevision += 1
        guard !ids.isEmpty else { return }
        mutate(roughness == nil ? "Reset Roughness" : "Change Roughness") { doc in
            for id in ids { doc.bodyRoughness[id] = roughness }
        }
    }

    /// Makes bodies of a material (nil = plain), as one undo step. Needs no rebuild. A material looks wrong over the
    /// default grey, so bodies without a colour of their own are given one that suits it. A roughness set for the
    /// old material is dropped: each material has its own to start from.
    func setBodyMaterial(_ material: BodyMaterial?, of ids: [FeatureID]) {
        guard !ids.isEmpty else { return }
        let fallback: BodyColor? = material.flatMap { BodyColor(hex: Self.materialColors[$0] ?? "") }
        let noun = ids.count == 1 ? "Material" : "Materials"
        colorPreview = nil
        roughnessPreview = nil
        mutate(material == nil ? "Reset \(noun)" : "Change \(noun)") { doc in
            for id in ids {
                doc.bodyMaterials[id] = material
                doc.bodyRoughness[id] = nil
                if let fallback, doc.bodyColors[id] == nil, doc.bodyColors[Regenerator.rootBody(id)] == nil { doc.bodyColors[id] = fallback }
            }
        }
    }

    /// The colour a body gets with a material when it has none of its own.
    static let materialColors: [BodyMaterial: String] = [.plastic: "#E6E4DE", .metal: "#C9CDD2", .glass: "#BFDDEA", .wood: "#B5834F"]

    /// Shows a colour on bodies while it's being picked, without changing the document.
    func previewBodyColor(_ color: BodyColor, of ids: [FeatureID]) {
        colorPreview = ids.isEmpty ? nil : (ids, color)
        overlayRevision += 1
    }

    /// The A key: shows or hides the Appearance panel (outside sketch mode, where A draws an arc).
    func toggleAppearance() {
        guard sketchSession == nil else { return }
        if !showAppearance, pendingTool != nil { cancelTool() }  // clicks now pick bodies to colour
        showAppearance.toggle()
    }

    /// "Appearance…" on a body: selects it whole and opens the panel for it.
    func openAppearance(for body: FeatureID) {
        if pendingTool != nil { cancelTool() }
        if !appearanceTargets.contains(body) { selectBody(body) }
        showAppearance = true
    }

    /// "Appearance…" on several bodies at once: selects them all whole and opens the panel for them.
    func openAppearance(for ids: [FeatureID]) {
        if pendingTool != nil { cancelTool() }
        if Set(appearanceTargets) != Set(ids) { selectBodies(ids, replacing: []) }
        showAppearance = true
    }

    func removeParameter(_ name: String) {
        mutate("Delete \(name)") {
            $0.parameters.removeAll { $0.name == name }
            $0.parameterFolderOf[name] = nil
        }
    }

    /// Makes a folder in the Parameters list (inside `parent`, or at the top), with these parameters in it.
    func newParameterFolder(in parent: String? = nil, holding names: [String] = []) -> String {
        var id = ""
        mutate("New Folder") { doc in
            id = doc.addParameterFolder(in: parent)
            doc.move(parameters: names, toFolder: id)
        }
        return id
    }

    func renameParameterFolder(_ id: String, to name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        mutate("Rename Folder") { doc in
            if let i = doc.parameterFolders.firstIndex(where: { $0.id == id }) { doc.parameterFolders[i].name = n }
        }
    }

    func deleteParameterFolder(_ id: String) { mutate("Delete Folder") { $0.removeParameterFolder(id) } }

    func move(parameters names: [String], toFolder id: String?) {
        mutate("Move to Folder") { $0.move(parameters: names, toFolder: id) }
    }

    func move(parameterFolder id: String, into parent: String?) {
        mutate("Move Folder") { $0.moveParameterFolder(id, into: parent) }
    }

    func updateFeature(_ id: FeatureID, _ actionName: String, _ change: (inout Feature) -> Void) {
        mutate(actionName) { doc in
            if let i = doc.index(of: id) { change(&doc.features[i]) }
        }
    }

    /// The timeline menus ask this for every feature each time the bar is drawn (a selection redraws it), and it is
    /// not cheap on a long timeline: kept until the document changes.
    @ObservationIgnored private var reorderProblems: (revision: Int, byMove: [String: String?]) = (-1, [:])
    /// How many of those were worked out rather than remembered (for tests).
    @ObservationIgnored private(set) var reorderChecksMade = 0

    /// Why a feature can't move to `index` in the timeline, or nil if it can (`CADDocument.reorderProblem`).
    func reorderProblem(_ id: FeatureID, to index: Int) -> String? {
        if reorderProblems.revision != documentRevision { reorderProblems = (documentRevision, [:]) }
        let key = "\(id)|\(index)"
        if let known = reorderProblems.byMove[key] { return known }
        reorderChecksMade += 1
        let problem = document.reorderProblem(id, to: index)
        reorderProblems.byMove[key] = .some(problem)
        return problem
    }

    /// Moves a feature to another place in the timeline (`index` is its new position), unless it
    /// would then come before what it's built from; the reason shows in an alert.
    func moveFeature(_ id: FeatureID, to index: Int) {
        guard let from = document.index(of: id) else { return }
        let to = min(max(index, 0), document.features.count - 1)
        guard to != from else { return }
        if let problem = reorderProblem(id, to: to) {
            alert = AlertInfo(title: "\(featureName(id)) can't go there", message: problem)
            return
        }
        mutate("Move \(featureName(id))") { doc in
            let f = doc.features.remove(at: from)
            doc.features.insert(f, at: to)
        }
    }

    func deleteFeature(_ id: FeatureID) {
        guard !isLocked(id) else { return }
        if sketchSession?.featureID == id { sketchSession = nil }
        mutate("Delete Feature") { doc in
            guard let i = doc.index(of: id) else { return }
            doc.features.remove(at: i)
            if let r = doc.rollback, i < r { doc.rollback = r - 1 }  // the marker stays after the same features
            if doc.rollback == doc.features.count { doc.rollback = nil }  // deleting the last one after it leaves it at the end
        }
        if selectedFeature == id { selectedFeature = nil }
    }

    /// How the next chamfer is measured: the way the Chamfer button works, until another is chosen from its arrow.
    var chamferMode = ChamferMode.equalDistance

    /// A way of chamfering chosen from the toolbar: it becomes the Chamfer button's way, and starts the tool
    /// (or, with the tool already waiting for edges, only changes how it will measure).
    func chooseChamferMode(_ mode: ChamferMode) {
        chamferMode = mode
        if pendingTool == .chamfer { overlayRevision += 1 } else { run(.chamfer) }
    }

    /// Changes how a chamfer feature is measured.
    func setChamferMode(_ mode: ChamferMode, of id: FeatureID) {
        updateFeature(id, "Change Chamfer Type") { f in
            guard case .chamfer(var e) = f.kind else { return }
            e.setMode(mode)
            f.kind = .chamfer(e)
        }
    }

    /// How the next extrude reaches: the way the Extrude button works, until another is chosen from its arrow.
    var extrudeMode = ExtrudeMode.oneDirection

    /// A way of extruding chosen from the toolbar: it becomes the Extrude button's way, and starts the tool
    /// (or, with the tool already waiting for a profile, or profiles being picked again, only changes the way).
    func chooseExtrudeMode(_ mode: ExtrudeMode) {
        extrudeMode = mode
        if pendingTool == .extrude || reselecting != nil { overlayRevision += 1 } else { run(.extrude) }
    }

    /// Changes how an extrude feature reaches.
    func setExtrudeMode(_ mode: ExtrudeMode, of id: FeatureID) {
        updateFeature(id, "Change Extrude Type") { f in
            guard case .extrude(var e) = f.kind else { return }
            e.extent = e.extent.changed(to: mode)
            f.kind = .extrude(e)
        }
    }

    /// The extent a new extrude starts with, for the way the button works now.
    var newExtrudeExtent: ExtrudeExtent {
        switch extrudeMode {
        case .oneDirection: return .distance("4 mm")
        case .mirrored: return .symmetric("4 mm")
        case .twoDirections: return .twoSides("4 mm", back: "2 mm")  // a different start, so the two arrows tell apart
        }
    }

    /// Creates a fillet or chamfer on the selected edges, and all round the selected faces.
    func addEdgeFeature(fillet: Bool) {
        let edges: [EdgeRef] = selection.compactMap { pick in
            guard pick.isEdge, pick.body < meshes.count else { return nil }
            let m = meshes[pick.body]
            guard pick.element < m.mesh.edgeNames.count else { return nil }
            return EdgeRef(body: m.id, edge: m.mesh.edgeNames[pick.element])
        }
        let faces = selection.compactMap { faceRef($0) }
        guard !edges.isEmpty || !faces.isEmpty else { return }
        let base = fillet ? "Fillet" : "Chamfer"
        var edgeFeature = EdgeFeature(edges: edges, faces: faces, size: fillet ? "2 mm" : "1 mm")
        if !fillet {
            edgeFeature.setMode(chamferMode)
            if chamferMode == .twoDistances { edgeFeature.second = "2 mm" }  // a different start, so the two arrows tell apart
        }
        add(Feature(name: document.nextName(base), fillet ? .fillet(edgeFeature) : .chamfer(edgeFeature)))
    }

    /// Puts a new feature in the document as one undo step: at the timeline marker, hiding the sketches it uses.
    /// Nothing else changes (no selection, no handle): what the tools do on top of this is in `add`.
    func commit(_ feature: Feature) {
        mutate("Add \(feature.typeName)") { $0.addFeature(feature) }
    }

    /// Adds a new feature as one undo step, hides the sketches it uses, and selects it so its
    /// drag handle and size field appear.
    func add(_ feature: Feature) {
        documentBeforeNewFeature = document
        newFeatureShrink = nil
        handleNote = nil
        let alreadyHidden = document.hidden
        commit(feature)
        if isRegenerating {
            sketchesHiddenPendingRebuild = Set(feature.sketchesUsed).subtracting(alreadyHidden)
            highlightPendingRebuild = highlighted
        }
        selection = []
        pendingTool = nil
        selectedFeature = feature.id
        newFeature = feature.id
        newFeatureUnbuilt = true
        handleFocusRequest += 1
    }

    var selectedEdgeCount: Int { selection.filter(\.isEdge).count }

    /// What the user is in the middle of in the window, if anything: a sketch being drawn, a tool waiting for picks, a
    /// feature being sized, a handle being dragged. Anything else that changes the part (an AI assistant, say) waits
    /// for it, since it would pull the ground from under them. Nil when the user is just looking.
    var userActivity: String? {
        if sketchSession != nil { return "editing a sketch" }
        if let tool = pendingTool { return "using the \(tool.rawValue) tool" }
        if isPickingSketchPlane { return "choosing where to put a sketch" }
        if reselecting != nil { return "picking profiles again" }
        if newFeature != nil { return "setting the size of a new feature" }
        if handleDragStart != nil || manipulatorStart != nil || holeMoveStart != nil { return "dragging a handle" }
        if isImporting { return "importing a file" }
        return nil
    }

    // MARK: regeneration

    func regenerate(fit: Bool = false, preview: CADDocument? = nil, previewFeature: FeatureID? = nil) {
        generation += 1
        let gen = generation
        var doc = preview ?? document
        if let session = sketchSession, let i = doc.index(of: session.featureID) {
            doc.rollback = min(doc.rollback ?? Int.max, i + 1)  // show the model as it was at this sketch
        }
        isRegenerating = true
        let cache = regenCache, meshCache = self.meshCache, snapshot = doc
        // While an arrow or manipulator is being dragged, the threads after the feature are left out of each preview
        // (see Regenerator.regenerate): built once, on the drop. If leaving them out makes a feature fail that
        // built before (one that works on a thread's faces), the preview is built in full.
        let draftAfter = preview != nil && (handleDragStart != nil || manipulatorStart != nil) ? previewFeature : nil
        let known = Set(result?.errors.keys.map { $0 } ?? [])
        let threadDraftSeconds = progressiveThreads
        let job: @MainActor () -> Void = {
            guard KernelActivity.shared.begin() else { return }  // the app is quitting
            self.regenRunning = true
            let started = Date()
            Task.detached(priority: .userInitiated) {
                defer { KernelActivity.shared.end() }
                let progress: @Sendable (Int, Int, Feature) -> Void = { done, total, feature in
                    // Quick rebuilds (a drag) never show it; a slow one starts to after a moment.
                    guard Date().timeIntervalSince(started) > 0.3 else { return }
                    let step = RegenProgress(done: done, total: total, feature: feature.name)
                    Task { @MainActor in self.noteProgress(step) }
                }
                var r = Regenerator.regenerate(snapshot, cache: cache, draftAfter: draftAfter,
                                               progressiveThreads: draftAfter == nil ? threadDraftSeconds : nil, progress: progress)
                let broken = { (r: RegenResult) in r.errors.keys.contains(where: { !known.contains($0) && $0 != draftAfter }) }
                if draftAfter != nil, broken(r) {
                    r = Regenerator.regenerate(snapshot, cache: cache, progress: progress)
                }
                var fit = fit
                if r.threadsLeftOut > 0, draftAfter == nil {
                    if broken(r) {
                        // A feature that works on a thread's faces can't be built without it: show nothing until it is.
                        r = Regenerator.regenerate(snapshot, cache: cache, progress: progress)
                    } else {
                        // The model without the threads that have to be built goes on screen now, the threads follow.
                        let draftMeshes = meshCache.meshes(for: r.bodies)
                        let newerWaits = await self.showDraft(r, draftMeshes, generation: gen, fit: fit, previewFeature: previewFeature)
                        fit = false
                        if newerWaits {
                            await self.finishRegen(nil, [], generation: gen, fit: false, previewFeature: previewFeature)
                            return
                        }
                        r = Regenerator.regenerate(snapshot, cache: cache, progress: progress)
                    }
                }
                let meshes = meshCache.meshes(for: r.bodies)
                await self.finishRegen(r, meshes, generation: gen, fit: fit, previewFeature: previewFeature)
            }
        }
        if regenRunning { queuedRegen = job } else { job() }
    }

    /// Takes out a feature that was just created and does not build, and says why. `rebuilt` is the rebuild that
    /// showed it failing (its errors are read for the reason); the rebuild without the feature follows.
    func dropFailedNewFeature(_ id: FeatureID, rebuilt r: RegenResult) {
        let name = featureName(id)
        let reason = r.errors[id].map { error -> String in
            let parts = error.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let text = parts.count == 2 && parts[0].lowercased() == (document.features.first { $0.id == id }?.typeName.lowercased() ?? "") ? parts[1] : error
            return text.prefix(1).uppercased() + text.dropFirst()
        } ?? "It could not be built."
        cancelNewFeature()
        alert = AlertInfo(title: "\(name) could not be made", message: reason)
    }

    /// The sizes a just-made fillet or chamfer started with, and how many times they have been halved since.
    @ObservationIgnored private var newFeatureShrink: (id: FeatureID, size: Double, second: Double?, halvings: Int)?

    /// A just-made fillet or chamfer that does not build at its starting size (2 mm, 1 mm) gets half of it, then a
    /// quarter... (up to five times, each a rebuild of its own, one after another) until it builds, so the user has an
    /// arrow to pull and not an alert. False when it has none left to try: the feature is then taken out as before.
    private func shrinkNewEdgeFeature(_ id: FeatureID) -> Bool {
        guard let i = document.index(of: id) else { return false }
        var state: (id: FeatureID, size: Double, second: Double?, halvings: Int)
        if let known = newFeatureShrink, known.id == id {
            state = known
        } else {
            let edgeFeature: EdgeFeature
            switch document.features[i].kind {
            case .fillet(let e), .chamfer(let e): edgeFeature = e
            default: return false
            }
            guard let start = try? parameterValues.value(of: edgeFeature.size, kind: .length), start > 0 else { return false }
            var second: Double?
            if case .chamfer = document.features[i].kind, edgeFeature.mode == .twoDistances {
                second = try? parameterValues.value(of: edgeFeature.second, kind: .length)
            }
            state = (id, start, second, 0)
        }
        func setSizes(_ factor: Double) {
            var doc = document
            Self.set(expression: formatDimension(state.size * factor, kind: .length), of: id, slot: 0, in: &doc)
            if let second = state.second { Self.set(expression: formatDimension(second * factor, kind: .length), of: id, slot: 1, in: &doc) }
            // Quietly, as part of making the feature: undo takes the whole feature away, and no size it had on the way is a step.
            document = doc
            documentRevision += 1
            onDocumentChange?(doc)
        }
        guard state.halvings < 5 else {
            setSizes(1)
            newFeatureShrink = nil
            return false
        }
        state.halvings += 1
        let factor = pow(0.5, Double(state.halvings))
        setSizes(factor)
        newFeatureShrink = state
        handleNote = (id, "\(UnitKind.length.format(state.size)) didn't fit these edges, so it starts at \(UnitKind.length.format(state.size * factor)). Drag the arrow or type a size to change it.")
        newFeatureUnbuilt = true
        regenerate()
        return true
    }

    private func noteProgress(_ step: RegenProgress) {
        guard isRegenerating else { return }  // the rebuild finished while this was on its way
        regenProgress = step
    }

    /// Shows a rebuild that left out its slow threads, and says whether a newer rebuild is already waiting (which makes
    /// the threads of this one not worth building).
    private func showDraft(_ r: RegenResult, _ meshes: [BodyMesh], generation gen: Int, fit: Bool, previewFeature: FeatureID?) -> Bool {
        apply(r, meshes, generation: gen, fit: fit, previewFeature: previewFeature, final: false)
        return queuedRegen != nil
    }

    /// `r` is nil when a draft already shown is all this rebuild comes to.
    private func finishRegen(_ r: RegenResult?, _ meshes: [BodyMesh], generation gen: Int, fit: Bool, previewFeature: FeatureID?) {
        regenRunning = false
        let next = queuedRegen
        queuedRegen = nil
        if let r { apply(r, meshes, generation: gen, fit: fit, previewFeature: previewFeature, final: next == nil) }
        next?()
        resumeRebuildWaiters()
    }

    /// Whether no rebuild is running or waiting.
    var isRebuildIdle: Bool { !regenRunning && queuedRegen == nil }

    /// Waits until the model has been rebuilt for every change made so far: the bodies, sketches and errors in
    /// `result` are then the ones of the current document. Returns at once when no rebuild is running.
    func rebuilt() async {
        guard !isRebuildIdle else { return }
        await withCheckedContinuation { rebuildWaiters.append($0) }
    }

    private func resumeRebuildWaiters() {
        // A rebuild that came out of this one (a new feature that failed is taken out again) keeps them waiting.
        guard isRebuildIdle, !rebuildWaiters.isEmpty else { return }
        let waiting = rebuildWaiters
        rebuildWaiters = []
        for w in waiting { w.resume() }
    }

    /// Shows a rebuild's result. Intermediate ones (a newer rebuild is queued) are shown too, so a
    /// drag keeps moving; `final` is the last of them.
    private func apply(_ r: RegenResult, _ meshes: [BodyMesh], generation gen: Int, fit: Bool, previewFeature: FeatureID?,
                       final: Bool) {
        if final {
            isRegenerating = false
            regenProgress = nil
            sketchesHiddenPendingRebuild = []
            highlightPendingRebuild = []
        }
        guard gen >= appliedGeneration else { return }  // something newer is already on screen (the same rebuild may follow its own draft)
        appliedGeneration = gen
        if let previewFeature, let error = r.errors[previewFeature] {
            // Keep showing the last good model; the handle turns red instead, and says why.
            previewInvalid = true
            // Kernel errors read "fillet: fillet failed (…)"; drop the repeated context.
            let parts = error.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let reason = parts.count == 2 && parts[1].hasPrefix(parts[0]) ? parts[1] : error
            handleProblem = "Can't build it at that size: \(reason)"
            overlayRevision += 1
            return
        }
        if previewFeature == nil, final, newFeatureUnbuilt, let id = newFeature {
            newFeatureUnbuilt = false
            if r.errors[id] != nil {
                // A new fillet or chamfer starts at a size that may be too big for these edges: take the largest of
                // half, a quarter... that builds, and leave its handle to change it.
                if shrinkNewEdgeFeature(id) { return }
                // A tool that fails leaves nothing in the timeline: the feature goes, the model stays as it was.
                dropFailedNewFeature(id, rebuilt: r)
                return
            }
        }
        previewInvalid = false
        handleProblem = nil
        result = r
        roundNeighbors = [:]
        self.meshes = meshes
        selection = selection.filter { pick in
            switch pick.kind {
            case .face, .edge: return pick.body < meshes.count
            case .region: return profile(of: pick) != nil
            case .sketchCurve: return curve(of: pick) != nil
            default: return true
            }
        }
        sceneRevision += 1
        overlayRevision += 1
        if fit { fitRevision += 1 }
        if let session = sketchSession, let frame = r.sketches[session.featureID]?.frame {
            session.frame = frame
            session.followModel(r)
        }
        updateSketchReferences()
    }

    var sceneBounds: (min: SIMD3<Float>, max: SIMD3<Float>)? {
        // Looped over every vertex, and asked for on every viewport update: kept until the scene or what is shown changes.
        let hidden = document.hidden
        if let cached = sceneBoundsCache, cached.revision == sceneRevision, cached.hidden == hidden { return cached.value }
        let value = computeSceneBounds()
        sceneBoundsCache = (sceneRevision, hidden, value)
        return value
    }

    @ObservationIgnored private var sceneBoundsCache: (revision: Int, hidden: Set<FeatureID>, value: (min: SIMD3<Float>, max: SIMD3<Float>)?)?

    private func computeSceneBounds() -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        var any = false
        for m in visibleMeshes {
            let p = m.mesh.positions
            for i in stride(from: 0, to: p.count, by: 3) {
                let v = SIMD3(p[i], p[i + 1], p[i + 2])
                lo = simd_min(lo, v); hi = simd_max(hi, v); any = true
            }
        }
        return any ? (lo, hi) : nil
    }

    func fitView() { fitRevision += 1 }

    // MARK: selection

    func name(of pick: PickID) -> String? {
        if let id = constructionPlane(of: pick) { return featureName(id) }
        guard pick.isFace || pick.isEdge, pick.body >= 0, pick.body < meshes.count else { return nil }
        let m = meshes[pick.body].mesh
        let names = pick.isEdge ? m.edgeNames : m.faceNames
        return pick.element < names.count ? names[pick.element] : nil
    }

    func hover(_ pick: PickID?) { hovered = pick.flatMap { isLockedPick($0) ? nil : $0 } }

    /// `single` (⌥-click) picks one letter of a text instead of the whole text.
    func click(_ pick: PickID?, additive: Bool, single: Bool = false) {
        let pick = pick.flatMap { isLockedPick($0) ? nil : $0 }  // a locked body or sketch is not there to click
        if isPickingSketchPlane {
            // Only a plane or a face answers the question; anything else keeps asking.
            guard let pick else { return }
            if let plane = OriginPlane(pick: pick) {
                beginSketch(on: plane.planeRef)
            } else if let id = constructionPlane(of: pick) {
                beginSketch(on: .plane(id))
            } else if let ref = faceRef(pick) {
                beginSketch(on: .face(ref))
            }
            return
        }
        if let tool = pendingTool {
            toolClick(tool, pick, additive: additive, single: single)
            return
        }
        if let pick, let id = constructionPlane(of: pick) {  // a construction plane: select it, with its offset handle
            selection = []
            selectedFeature = id
            return
        }
        guard let pick, accepts(pick) else {
            if !additive {
                if let sketch = pickedSketch { dismissedSketchBar = sketch }  // a tap on nothing puts the sketch's bar away
                selection = []
            }
            return
        }
        let picks = single ? [pick] : profileGroup(of: pick)
        if additive {
            toggle(picks)
        } else {
            selection = Set(selection) == Set(picks) ? [] : picks
        }
    }

    /// Adds the picks to the selection, or takes them all out again when they are all in it already.
    func toggle(_ picks: [PickID]) {
        if picks.allSatisfy(selection.contains) {
            selection.removeAll(where: picks.contains)
        } else {
            selection += picks.filter { !selection.contains($0) }
        }
    }

    func clearSelection() { selection = [] }

    /// Return (or Esc) after sizing a feature: done with it, so its handle and size field go away.
    func finishFeatureEdit() {
        handleNote = nil
        if let id = newFeature, let r = result, r.errors[id] != nil {
            return dropFailedNewFeature(id, rebuilt: r)  // sized to something that does not build: not kept
        }
        newFeature = nil
        guard dragHandle != nil || featureWithoutHandle != nil else { return }
        selectedFeature = nil
        selection = []
    }

    /// What a plain click can select: faces, edges, and the profiles and curves of visible sketches.
    func accepts(_ pick: PickID) -> Bool {
        switch pick.kind {
        case .face, .edge: return true
        case .plane: return OriginPlane(pick: pick) != nil || constructionPlane(of: pick) != nil
        case .region: return profile(of: pick) != nil
        case .sketchCurve: return curve(of: pick) != nil
        default: return false
        }
    }

    // MARK: sketching

    var parameterValues: ParameterValues { result?.parameters ?? ParameterEvaluator.evaluate(document.parameters) }

    /// The picked face by persistent name, planar or not.
    func faceRef(_ pick: PickID) -> FaceRef? {
        guard pick.isFace, pick.body >= 0, pick.body < meshes.count, let name = name(of: pick) else { return nil }
        return FaceRef(body: meshes[pick.body].id, face: name)
    }

    /// The single selected planar face, as a sketch plane.
    var selectedFacePlane: PlaneRef? {
        // A selected construction plane counts too.
        if selection.isEmpty, let id = selectedFeature, case .plane? = document.features.first(where: { $0.id == id })?.kind,
           result?.planes[id] != nil {
            return .plane(id)
        }
        guard selection.count == 1, let pick = selection.first, let ref = faceRef(pick),
              let body = result?.body(ref.body), (try? body.faceFrame(ref.face)) != nil else { return nil }
        return .face(ref)
    }

    /// The Sketch button: sketches on the selected flat face right away, otherwise asks for a plane
    /// by showing the origin planes in the viewport (see `click`).
    func startSketch() {
        if sketchSession != nil { finishSketch() }
        pendingTool = nil
        if let plane = selectedFacePlane {
            beginSketch(on: plane)
            return
        }
        sketchPlaneSize = OriginPlane.displaySize(for: sceneBounds)
        isPickingSketchPlane = true
        selection = []
        selectedFeature = nil
        overlayRevision += 1
    }

    func cancelSketchPlanePick() {
        guard isPickingSketchPlane else { return }
        isPickingSketchPlane = false
        overlayRevision += 1
    }

    /// Instruction shown next to the cursor while the app waits for a pick.
    /// Where the cursor is in the viewport (window coordinates) while that prompt is showing.
    var cursorPromptAt: CGPoint?
    var cursorPrompt: String? { isPickingSketchPlane ? "Select a plane or planar face" : toolPrompt }

    /// The Render view shows the part alone: finished sketches and the construction planes are left out of it. They come
    /// back while a tool waits for something to be picked (a profile to extrude, a plane to sketch on), which needs them.
    var rendersWithoutSketchesAndPlanes: Bool { renderView && sketchSession == nil && pendingTool == nil && !showsOriginPlanes }

    /// The origin planes are offered while choosing where to sketch or where to put a primitive.
    var showsOriginPlanes: Bool { isPickingSketchPlane || pendingTool?.showsPlanes == true }

    func beginSketch(on plane: PlaneRef) {
        let frame: Frame
        do {
            frame = try Regenerator.sketchFrame(SketchFeature(plane: plane, sketch: Sketch()), result ?? RegenResult())
        } catch {
            alert = AlertInfo(title: "You can't sketch on that face",
                              message: "Choose a flat face or one of the origin planes. (\(error))")
            return
        }
        isPickingSketchPlane = false
        let feature = Feature(name: document.nextName("Sketch"), .sketch(SketchFeature(plane: plane, sketch: Sketch())))
        sketchSession = SketchSession(featureID: feature.id, frame: frame, sketch: Sketch(), parameters: parameterValues)
        updateSketchReferences()
        selection = []
        selectedFeature = feature.id
        mutate("New Sketch") { doc in
            doc.insertAtMarker(feature)  // like every new feature: at the timeline marker, inside the model that is shown
            doc.hidden.remove(feature.id)
        }
        lookAt(frame)
        startSketchSlice(frame)
    }

    /// Turns a sketch from before upright axes to them: everything in it turns with its axes, so
    /// text and shapes drawn level in Sketch mode lie level on the model.
    func straightenAxes(of id: FeatureID) {
        guard sketchSession?.featureID != id else { return }
        mutate("Straighten Sketch Axes") { doc in
            guard let i = doc.index(of: id), case .sketch(var sf) = doc.features[i].kind else { return }
            sf.uprightAxes = true
            doc.features[i].kind = .sketch(sf)
        }
    }

    func editSketch(_ id: FeatureID) {
        guard !isLocked(id), let f = document.features.first(where: { $0.id == id }), case .sketch(let sf) = f.kind else { return }
        if let i = document.index(of: id), i >= markerPosition {
            // The marker has rolled the sketch back, so its face may not exist yet: build it again (the marker moves to
            // just after it, as for any feature picked for editing), then edit it.
            bringIntoModel(id)
            Task { await rebuilt(); editSketch(id) }
            return
        }
        let frame: Frame
        if let r = result?.sketches[id] { frame = r.frame } else {
            switch sf.plane {
            case .xy: frame = .xy
            case .xz: frame = .xz
            case .yz: frame = .yz
            case .face, .plane:
                alert = AlertInfo(title: "This sketch's face or plane is missing",
                                  message: "Fix the features before this sketch first, then edit it again.")
                return
            }
        }
        isPickingSketchPlane = false
        pendingTool = nil
        sketchSession = SketchSession(featureID: id, frame: frame, sketch: sf.sketch, parameters: parameterValues)
        selection = []
        selectedFeature = id
        regenerate()
        lookAt(frame)
        startSketchSlice(frame)
    }

    /// Body edges and corners that lie in the sketch plane, for the sketch to snap to, and every straight body
    /// and circular edge (wherever it is) for Project Edge.
    func updateSketchReferences() {
        guard let session = sketchSession else { return }
        let f = session.frame
        var refs = SketchReferences()
        func local(_ s: [Float], _ i: Int) -> (uv: SIMD2<Double>, w: Double) {
            let p = SIMD3(Double(s[i]), Double(s[i + 1]), Double(s[i + 2])) - f.origin
            return (SIMD2(simd_dot(p, f.xAxis), simd_dot(p, f.yAxis)), simd_dot(p, f.normal))
        }
        for m in visibleMeshes {
            let s = m.mesh.segments, edge = m.mesh.segmentEdge
            let body = result?.body(m.id)
            var first = 0
            while first < edge.count {
                var last = first
                while last + 1 < edge.count, edge[last + 1] == edge[first] { last += 1 }
                defer { first = last + 1 }
                let run = (first...last).map { (a: local(s, $0 * 6), b: local(s, $0 * 6 + 3)) }
                // A straight edge can be projected from anywhere on the body (Project Edge): its ends are flattened
                // onto the plane. One lying in the plane is also followed by the snapping, so the sketch keeps hold of
                // the edge itself, not just of where it is now.
                var model: ModelSnap?
                var ends = (a: run[0].a.uv, b: run[run.count - 1].b.uv)
                if run.count == 1,
                   let name = edge[first] < m.mesh.edgeNames.count ? m.mesh.edgeNames[Int(edge[first])] : nil,
                   let e = try? body?.edgeEnds(name) {
                    func uv(_ p: SIMD3<Double>) -> SIMD2<Double> {
                        let d = p - f.origin
                        return SIMD2(simd_dot(d, f.xAxis), simd_dot(d, f.yAxis))
                    }
                    let straight = ModelSnap(edge: EdgeRef(body: m.id, edge: name), start: uv(e.start), end: uv(e.end))
                    refs.straightEdges[straight.edge] = straight
                    if run[0].a.w.magnitude < 1e-3, run[0].b.w.magnitude < 1e-3 {
                        ends = (straight.start, straight.end)
                        model = straight
                    }
                }
                // A circular edge seen straight on can be projected too (Project Edge), from anywhere on the body.
                if run.count > 1, let name = edge[first] < m.mesh.edgeNames.count ? m.mesh.edgeNames[Int(edge[first])] : nil,
                   let body, let round = Regenerator.roundEdgeSnap(body, edge: EdgeRef(body: m.id, edge: name), frame: f) {
                    refs.roundEdges[round.edge] = round
                }
                // Off the plane, nothing below applies: its segments and points are not in the plane to snap to.
                guard run.contains(where: { abs($0.a.w) < 1e-3 && abs($0.b.w) < 1e-3 }) else { continue }
                for seg in run where abs(seg.a.w) < 1e-3 && abs(seg.b.w) < 1e-3 {
                    refs.segments.append((seg.a.uv, seg.b.uv))
                    refs.segmentModels.append(model)
                }
                // An edge's ends: where its run of segments starts and stops.
                if let model {
                    var start = model, end = model
                    start.endIndex = 0; end.endIndex = 1
                    refs.points.append(model.start); refs.pointModels.append(start)
                    refs.points.append(model.end); refs.pointModels.append(end)
                } else if abs(run[0].a.w) < 1e-3 {
                    refs.points.append(ends.a); refs.pointModels.append(nil)
                    if abs(run[run.count - 1].b.w) < 1e-3 { refs.points.append(ends.b); refs.pointModels.append(nil) }
                }
            }
        }
        session.references = refs
    }

    /// Leaves the sketch. The view goes back to the one from before it was opened, unless a tool is taking over
    /// (extrude and the like): that stays where it is, so the picture doesn't jump.
    func finishSketch(keepingView: Bool = false) {
        if let session = sketchSession, let action = session.keepGearEdit() { commitSketch(action) }
        // A mirror that has its line is kept, as Return would (without one there is nothing to keep).
        if let session = sketchSession, session.isMirroring {
            if session.mirrorSetup?.line == "" { session.cancelMirror() } else { commitSketch(session.commitMirror()) }
        }
        sketchClosedKeepingView = keepingView
        dismissedSketchBar = sketchSession?.featureID
        sketchSession = nil
        overlayRevision += 1
        regenerate()
    }

    private func lookAt(_ frame: Frame) {
        let o = frame.origin, n = frame.normal
        send(.look(target: SIMD3(Float(o.x), Float(o.y), Float(o.z)), normal: SIMD3(Float(n.x), Float(n.y), Float(n.z))))
    }

    func show(_ view: StandardView) { send(.standard(view)) }

    private func send(_ command: CameraCommand) {
        cameraCommand = (command, (cameraCommand?.revision ?? 0) + 1)
    }

    /// Writes the session's sketch into the document (one undo step) and regenerates.
    func commitSketch(_ action: String?) {
        overlayRevision += 1
        guard let action, let session = sketchSession else { return }
        let sketch = session.sketch
        mutate(action) { doc in
            guard let i = doc.index(of: session.featureID), case .sketch(var sf) = doc.features[i].kind else { return }
            sf.sketch = sketch
            doc.features[i].kind = .sketch(sf)
        }
    }

    /// After undo/redo or edits, make the session match the document.
    private func syncSession() {
        guard let session = sketchSession else { return }
        guard let f = document.features.first(where: { $0.id == session.featureID }), case .sketch(let sf) = f.kind else {
            sketchSession = nil  // the sketch itself was undone
            return
        }
        let params = ParameterEvaluator.evaluate(document.parameters)
        if sf.sketch != session.sketch || params.values != session.parameters.values {
            session.reload(sf.sketch, parameters: params)
        }
        overlayRevision += 1
    }

    /// The body edge a pick is, as a reference a sketch can project (nil for anything else).
    func edgeRef(of pick: PickID) -> EdgeRef? {
        guard pick.isEdge, pick.body >= 0, pick.body < meshes.count, let name = name(of: pick) else { return nil }
        return EdgeRef(body: meshes[pick.body].id, edge: name)
    }

    func sketchMouse(_ m: SketchMouse) -> Bool {
        guard let session = sketchSession else { return false }
        var m = m
        m.edge = m.pick.flatMap(edgeRef(of:))
        let r = session.handle(m)
        if m.phase != .moved || !session.clicks.isEmpty || session.anglePicks != nil || (session.tool == .gear && session.gearActive == nil) { overlayRevision += 1 }  // the ghost gear and a placing angle follow the cursor
        commitSketch(r.commit)
        return r.handled
    }

    func sketchCommand(_ command: (SketchSession) -> String?) {
        guard let session = sketchSession else { return }
        if let action = session.keepGearEdit() { commitSketch(action) }  // a gear the fields were changing is kept
        session.cancelPattern()  // a command works on the sketch as it is, not with the pattern's copies shown
        session.cancelMirror()
        session.cancelOffset()   // nor with an offset's preview
        commitSketch(command(session))
    }

    /// Return in the viewport or in a typed field: places what is typed, or keeps the Pattern tool's copies.
    func commitSketchTyped() {
        guard let session = sketchSession else { return }
        commitSketch(session.commitTyped())
    }

    /// Selects a sketch entity or constraint (e.g. from a constraint glyph).
    func selectSketchItem(_ id: EntityID, additive: Bool) {
        guard let session = sketchSession else { return }
        session.select(id, additive: additive)
        overlayRevision += 1
    }

    /// A pattern's button in the viewport: opens that pattern to change it.
    func beginSketchPattern(editing id: EntityID) {
        sketchSession?.beginPattern(editing: id)
        overlayRevision += 1
    }

    /// A mirror's button in the viewport: opens that mirror to change it.
    func beginSketchMirror(editing id: EntityID) {
        sketchSession?.beginMirror(editing: id)
        overlayRevision += 1
    }

    /// Move turns the manipulator on or off; Scale asks for a factor.
    func beginSketchTransform(_ tool: SketchTransformTool) {
        sketchSession?.beginTransform(tool)
        overlayRevision += 1  // the viewport shows or hides the manipulator
    }

    /// Offset shows the offset of the selected curves, with an arrow to drag and a field to type in.
    func beginSketchOffset() {
        sketchSession?.beginOffset()
        overlayRevision += 1  // the viewport shows or hides the arrow
    }

    func setSketchTool(_ tool: SketchTool) {
        if let session = sketchSession, tool != .gear, let action = session.keepGearEdit() { commitSketch(action) }
        sketchSession?.setTool(tool)
        overlayRevision += 1
    }

    // MARK: sketches in the viewport

    /// Every sketch in document order. A sketch's position here, plus one, is the slot its curves and
    /// profiles carry in pick IDs, so picks stay valid when sketches are shown or hidden.
    var sketchSlots: [FeatureID] { sketches.map(\.id) }

    /// A sketch is drawn unless hidden, suppressed or rolled back; the selected sketch always shows.
    func isSketchShown(_ id: FeatureID) -> Bool {
        guard document.activeFeatures.contains(where: { $0.id == id && !$0.suppressed }) else { return false }
        // A hidden sketch stays hidden when selected; it shows only while its profiles are being picked again.
        return !document.hidden.contains(id) || sketchesHiddenPendingRebuild.contains(id) || reselecting.flatMap { profileSource($0)?.sketch } == id
    }

    /// The sketch, region and profile reference a profile pick points at.
    func profile(of pick: PickID) -> (sketch: FeatureID, region: KSketch.Region, ref: ProfileRef)? {
        guard pick.kind == .region, pick.sketchSlot > 0, pick.sketchSlot <= sketchSlots.count else { return nil }
        let id = sketchSlots[pick.sketchSlot - 1]
        guard let r = result?.sketches[id], pick.element < r.regions.count else { return nil }
        let region = r.regions[pick.element]
        return (id, region, ProfileRef(curves: region.tags.split(separator: ",").map(String.init),
                                       hintU: region.sample.x, hintV: region.sample.y))
    }

    /// What a click on a profile stands for. A letter of a text stands for the whole text, so a text is hovered, selected
    /// and extruded in one click (the clicked letter first, and not the insides of its O, B and the like, which a
    /// letter must not fill); anything else, and the tools that take a single profile, stand for themselves.
    func profileGroup(of pick: PickID) -> [PickID] {
        guard pick.kind == .region, pendingTool?.takesWholeTexts ?? true,
              let p = profile(of: pick), let sketch = result?.sketches[p.sketch],
              let text = sketch.text(ofRegion: pick.element) else { return [pick] }
        let letters = sketch.letterRegions(of: text, parameters: parameterValues)
        guard !letters.isEmpty else { return [pick] }
        let picks = letters.map { PickID(region: $0, slot: pick.sketchSlot) }
        return letters.contains(pick.element) ? [pick] + picks.filter { $0 != pick } : picks
    }

    /// The sketch and curve a curve pick points at (finished sketches only).
    func curve(of pick: PickID) -> (sketch: FeatureID, curve: EntityID)? {
        guard pick.kind == .sketchCurve, pick.sketchSlot > 0, pick.sketchSlot <= sketchSlots.count else { return nil }
        let id = sketchSlots[pick.sketchSlot - 1]
        guard let r = result?.sketches[id], pick.element < r.solved.curves.count else { return nil }
        return (id, r.solved.curves[pick.element].id)
    }

    /// Selected profiles, in the order they were picked.
    var selectedProfiles: [(sketch: FeatureID, region: KSketch.Region, ref: ProfileRef)] { selection.compactMap { profile(of: $0) } }
    /// Selected sketch curves, in the order they were picked.
    var selectedCurves: [(sketch: FeatureID, curve: EntityID)] { selection.compactMap { curve(of: $0) } }

    /// Everything the viewport draws for sketches: the one being edited, or the visible finished
    /// sketches with pickable profiles and curves, plus the origin planes and the drag handle.
    func sketchOverlay() -> SketchOverlay {
        var o = SketchOverlay()
        o.images = imageDraws()
        o.imageBorder = imageBorder()
        if let session = sketchSession {
            SketchOverlayBuilder.editing(session, into: &o, showCentres: showShapeCentres)
            // The fill is from the last rebuild: while a gear's fields are changing it, it would show the old gear,
            // and while a text's words are changing, the old words.
            if !session.hasPendingGearEdit, session.editingText == nil, let r = result?.sketches[session.featureID] { SketchOverlayBuilder.regions(r, slot: 0, into: &o) }
            return o
        }
        if showsOriginPlanes {
            SketchOverlayBuilder.originPlanes(size: sketchPlaneSize, into: &o)
            o.planesSeeThrough = true
        }
        // Construction planes, always (unless hidden), pickable to sketch on or to select.
        // Their sides can be dragged, except while a plane is being asked for (a click on a side then picks the plane).
        let planeSize = OriginPlane.displaySize(for: sceneBounds)
        for (slot, f) in planeFeatures.enumerated() where !document.hidden.contains(f.id) && !rendersWithoutSketchesAndPlanes {
            guard let frame = result?.planes[f.id], case .plane(let pf) = f.kind else { continue }
            let edges = showsOriginPlanes || pendingTool != nil ? nil : (0..<4).map { PickID(planeEdge: $0, plane: slot).raw }
            SketchOverlayBuilder.constructionPlane(frame, extent: pf.extent ?? PlaneExtent(side: planeSize),
                                                   id: PickID(plane: OriginPlane.allCases.count + slot).raw, edgeIDs: edges, into: &o)
        }
        addMeasureOverlay(to: &o)
        addSectionOverlay(to: &o)
        if manipulatedFeature == nil {
            // Each arrow is its shaft and then its head (the same segment again, drawn as a triangle).
            for h in dragHandles {
                if let dial = h.dial {
                    SketchOverlayBuilder.dial(center: h.base, axis: h.direction, dial: dial, angle: h.value, into: &o)
                    o.handleInvalid = previewInvalid
                    continue
                }
                // A tiny length at least, so the arrow still points along its direction before it is dragged out.
                let length = abs(h.value) < 0.01 ? (h.value < 0 ? -0.01 : 0.01) : h.value
                let a = h.base, b = h.base + h.direction * length
                let fa = SIMD3<Float>(Float(a.x), Float(a.y), Float(a.z)), fb = SIMD3<Float>(Float(b.x), Float(b.y), Float(b.z))
                let id = (h.slot == 0 ? PickID.handle : PickID.diameterHandle).raw
                let segment = SegmentInstance(ax: fa.x, ay: fa.y, az: fa.z, bx: fb.x, by: fb.y, bz: fb.z, id: id)
                o.handle += [segment, segment]
                o.handleInvalid = previewInvalid
            }
        }
        if let p = holeMoveDot {
            let f = SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z)), id = PickID.moveHandle.raw
            o.moveHandle = [SegmentInstance(ax: f.x, ay: f.y, az: f.z, bx: f.x, by: f.y, bz: f.z, id: id)]
            o.handleInvalid = previewInvalid
        }
        for (i, id) in sketchSlots.enumerated() where isSketchShown(id) && !rendersWithoutSketchesAndPlanes {
            guard let r = result?.sketches[id] else { continue }
            SketchOverlayBuilder.finished(r, slot: i + 1, parameters: parameterValues, into: &o)
            SketchOverlayBuilder.regions(r, slot: i + 1, into: &o)
        }
        // Project waits for a face with profiles picked: the fills would cover the face a click is meant for.
        if pendingTool == .project, !selectedProfiles.isEmpty { o.regionsPickable = false }
        return o
    }

    func dimensionLabels() -> [DimensionLabel] {
        if let session = sketchSession { return SketchOverlayBuilder.labels(session) }
        if showsOriginPlanes { return SketchOverlayBuilder.originPlaneLabels(size: sketchPlaneSize) }
        if pendingTool == .measure { return measureLabels() }
        if sectionActive { return sectionLabels() }
        return []  // the drag handle's size is an editable field; see the viewport
    }

    /// Pick IDs to highlight as selected.
    var highlighted: [UInt32] {
        if selection.isEmpty, sketchSession == nil, !highlightPendingRebuild.isEmpty { return highlightPendingRebuild }
        if let session = sketchSession {
            return (session.selection + session.dimensionPicks).compactMap { session.pickID(for: $0)?.raw }
        }
        guard picksWholeBodies else { return selection.map(\.raw) + threadHighlight }
        // A face or edge picked for a body tool stands for its whole body.
        var out: [UInt32] = []
        for pick in selection {
            let whole = pick.isFace || (pick.isEdge && pendingTool != .pattern)  // Pattern's edges are directions
            let raw = whole ? PickID(wholeBody: pick.body).raw : pick.raw
            if !out.contains(raw) { out.append(raw) }
        }
        return out
    }

    /// The waiting tool works on whole bodies (a click on any face picks its body), so hover and
    /// selection light up whole bodies. Pattern's edges pick a direction, so only its faces do.
    var picksWholeBodies: Bool { pendingTool?.picksBodies == true }

    // MARK: drag handles

    /// An orange arrow on the selected feature; dragging it sets one of the feature's sizes with a
    /// live preview, and the field beside it takes a typed value.
    struct DragHandle {
        var featureID: FeatureID
        /// What the arrow sets, e.g. "Distance" or "Angle".
        var label: String
        var base: SIMD3<Double>
        var direction: SIMD3<Double>
        /// Arrow length, in mm.
        var value: Double
        /// The expression currently stored in the feature.
        var expression: String
        var unit: UnitKind = .length
        /// Arrow millimetres per unit of the value (per mm, or per radian for angles).
        var lengthPerUnit: Double = 1
        /// Largest value allowed (a full turn, for angles).
        var maxValue: Double?
        /// Why the largest value is what it is, when that isn't obvious (a chamfer held under a corner's radius).
        var maxReason: String?
        /// The arrow can be dragged back through its base (an extrude going the other way).
        var allowsNegative = false
        /// Which of the feature's arrows this is: a hole has one for its depth (0) and one for its diameter (1).
        var slot = 0
        /// A dial instead of an arrow: a dot dragged round an arc sets an angle (the taper of an extrude, the turn of
        /// a revolve). It is centred on `base`; `direction` is where it points at 0°, and `value` is the angle in radians.
        var dial: Dial?
        /// The value may be zero (a taper of nothing is no taper).
        var allowsZero = false

        struct Dial {
            /// The way the dot swings towards as the angle grows, at right angles to `direction`.
            var side: SIMD3<Double>
            /// Arc radius, in mm.
            var radius: Double
            /// How far the dot may go: either way from zero (a taper), or round from zero (a revolve's turn), in radians.
            var reach = Dial.limit
            /// The dot goes all the way round (a revolve): its arc is drawn whole, and the angle runs from zero up to `reach`.
            var wraps = false
            /// The arc reaches this far either way, in radians.
            static let limit = 85.0 * Double.pi / 180
        }

        /// Where the handle is grabbed, and where its field sits: the arrow's tip, or the dial's dot.
        var anchor: SIMD3<Double> {
            guard let dial else { return base + direction * value }
            return base + dial.radius * (cos(value) * direction + sin(value) * dial.side)
        }

        /// The value written to the feature for an arrow length.
        func featureValue(_ length: Double) -> Double {
            let v = length / lengthPerUnit
            return maxValue.map { min(v, $0) } ?? v
        }
    }

    /// A parameter-driven value was dragged: ask before replacing the expression with a number.
    struct UnlinkPrompt: Identifiable {
        let id = UUID()
        var featureID: FeatureID
        var label: String
        var unit: UnitKind
        var expression: String
        var value: Double
        var startValue: Double?
        /// Which of the feature's arrows was dragged (see `DragHandle.slot`).
        var slot = 0
        /// A hole dragged over its face (X and Y together), instead of one size.
        var holePosition: SIMD2<Double>?
        /// A move or turn dragged with the manipulator: the values that changed, by `TransformKey` index.
        var transform: [Int: Double]?

        /// The dragged value, as the prompt shows it.
        var valueText: String {
            if let t = transform {
                return t.sorted { $0.key < $1.key }.map { key, v in
                    "\(TransformKey(rawValue: key)?.label ?? "") \(formatDimension(v, kind: key < 3 ? .length : .angle))"
                }.joined(separator: ", ")
            }
            if let uv = holePosition { return "\(formatDimension(uv.x, kind: .length)), \(formatDimension(uv.y, kind: .length))" }
            return formatDimension(value, kind: unit)
        }
    }

    /// Move/Rotate manipulator: the document when a part was grabbed, the values then, and the values now.
    @ObservationIgnored var manipulatorStart: CADDocument?
    @ObservationIgnored var manipulatorBase: TransformValues?
    var manipulatorLive: TransformValues?
    @ObservationIgnored private var handleDragStart: CADDocument?
    /// The document when a hole's move dot was grabbed, and where the dot is being dragged (in the face's u, v).
    @ObservationIgnored var holeMoveStart: CADDocument?
    var holeMovePreview: SIMD2<Double>?
    private(set) var handlePreviewValue: Double?
    /// The latest preview failed (e.g. a fillet too big for its faces); the last good model stays visible.
    var previewInvalid = false
    /// Why the size typed in the handle's field can't be used, shown under the field.
    private(set) var handleProblem: String?
    /// Something to tell the user about the size just given (not an error): a starting size that was made smaller to fit.
    private(set) var handleNote: (feature: FeatureID, text: String)?
    /// What's typed in the handle's field and not stored yet (the viewport keeps this up to date).
    @ObservationIgnored var handleDraft: String?
    /// Bumped when the field should drop its typing and show the stored size again.
    private(set) var handleFieldReset = 0

    /// Before an option beside the field changes the feature (another axis, Join/Cut, flip): store
    /// what's typed on the feature as it is now, then let the field show the new state's size.
    func storeTypedSize() {
        defer { handleDraft = nil; handleFieldReset += 1 }
        guard let draft = handleDraft, draft != handleFieldText else { return }
        commitHandle(draft)
    }
    var unlinkPrompt: UnlinkPrompt?
    /// Bumped when a new feature wants its size typed right away: the viewport focuses the handle's field.
    var handleFocusRequest = 0
    /// The slot the focus request is for (the first field's, when nil).
    var handleFocusSlot: Int?

    /// The slot of an extrude's taper dial (0 and 1 are its arrows).
    static let taperSlot = 2

    /// How the camera sees the taper dial, kept coarse so the dial is only redrawn when it would look different.
    struct DialView: Equatable {
        /// The direction the camera looks and its screen-right, to a tenth.
        var forward: SIMD3<Double>
        var right: SIMD3<Double>
        /// How many mm a point on screen spans, to about 10%.
        var mmPerPoint: Double
    }
    @ObservationIgnored var dialView: DialView?
    /// The feature whose angle field was opened by clicking its dial (a taper of nothing has no field until then).
    var dialFieldOpen: FeatureID?

    /// Whether a handle's field is on screen: arrows always, a dial once it's been used or has an angle.
    func showsField(_ h: DragHandle) -> Bool { h.dial == nil || dialFieldOpen == h.featureID || abs(h.value) > 1e-9 }

    /// Which way the dial's arc is spread, and how big: in the plane of the extrusion's axis and the sketch axis
    /// that faces the camera best, leaning towards the right of the screen, about 80 points across.
    func dialPlacement(axis: SIMD3<Double>, frame: Frame) -> (side: SIMD3<Double>, radius: Double) {
        guard let v = dialView else { return (frame.xAxis, 20) }
        var best = frame.xAxis, bestFacing = -1.0
        for u in [frame.xAxis, frame.yAxis] {
            let facing = abs(simd_dot(simd_cross(axis, u), v.forward))
            if facing > bestFacing * 1.1 { best = u; bestFacing = facing }
        }
        if simd_dot(best, v.right) < 0 { best = -best }
        return (best, 80 * v.mmPerPoint)
    }

    /// Whether a camera change makes the dial look different.
    func updateDialView(_ view: DialView) -> Bool {
        guard dialView != view else { return false }
        dialView = view
        return true
    }

    /// An extrude, a draft or a revolve is selected and shows its dial.
    var showsDial: Bool {
        guard sketchSession == nil, pendingTool == nil, holeMoveStart == nil, let id = selectedFeature else { return false }
        switch document.features.first(where: { $0.id == id })?.kind {
        case .extrude?, .draft?, .revolve?, .twistSweep?: return true
        default: return false
        }
    }

    /// A draft is selected: its dial leans the faces rather than tapering an extrusion.
    var selectedIsDraft: Bool {
        guard let id = selectedFeature, case .draft? = document.features.first(where: { $0.id == id })?.kind else { return false }
        return true
    }

    /// A twist sweep is selected: its dial sets how far the profile has turned at the far end.
    var selectedIsTwist: Bool {
        guard let id = selectedFeature, case .twistSweep? = document.features.first(where: { $0.id == id })?.kind else { return false }
        return true
    }

    /// A revolve is selected: its dial turns the profile round the axis.
    var selectedIsRevolve: Bool {
        guard let id = selectedFeature, case .revolve? = document.features.first(where: { $0.id == id })?.kind else { return false }
        return true
    }

    /// What an arrow's field shows: the stored expression, or the size being dragged.
    func handleFieldText(for slot: Int) -> String? {
        guard let h = selectedHandle(slot) else { return nil }
        if handleDragStart != nil, slot == activeHandleSlot { return formatDimension(h.featureValue(h.value), kind: h.unit) }
        if manipulatorStart != nil, let live = manipulatorLive, let (_, m) = manipulatedFeature {
            return m.rotating ? formatDimension(live.turn[m.arrow.index], kind: .angle) : formatDimension(live.move[m.arrow.index], kind: .length)
        }
        return h.expression
    }

    /// What the active arrow's field shows.
    var handleFieldText: String? { handleFieldText(for: activeHandleSlot) }

    /// The selected feature that is being edited but has no drag handle to carry the OK button (a thread
    /// that runs the full length, a shell, a mirror…). Its OK and Cancel float at the bottom instead.
    var featureWithoutHandle: FeatureID? {
        guard sketchSession == nil, pendingTool == nil, holeMoveStart == nil, let id = selectedFeature, dragHandle == nil,
              let f = document.features.first(where: { $0.id == id }), !f.suppressed else { return nil }
        switch f.kind {
        case .sketch, .importBody, .image: return nil  // a sketch has its own mode; an import and a canvas have nothing to size
        default: return id
        }
    }

    /// The arrow in hand: the one being dragged or typed for.
    var dragHandle: DragHandle? { selectedHandle(activeHandleSlot) }

    /// Every arrow the selected feature shows, by slot: a hole's depth and diameter, or the one arrow of the rest.
    var dragHandles: [DragHandle] {
        guard let id = selectedFeature, sketchSession == nil, pendingTool == nil, holeMoveStart == nil,
              let f = document.features.first(where: { $0.id == id }) else { return [] }
        var slots: [Int]
        switch f.kind {
        case .hole(let h): slots = h.depth == nil ? [0] : [0, 1]
        case .chamfer(let e): slots = e.mode == .equalDistance ? [0] : [0, 1]  // two distances, or a distance and an angle
        case .extrude(let e):
            if case .twoSides = e.extent { slots = [0, 1] } else { slots = [0] }  // one arrow each way
            slots.append(Self.taperSlot)  // and the dial for the taper
        case .draft: slots = [Self.taperSlot]  // the angle is all there is, on a dial
        case .twistSweep: slots = [0, Self.taperSlot]  // the length on an arrow, and the turn at the far end on a dial
        default: slots = [0]
        }
        return slots.compactMap { handle(for: id, slot: $0) }
    }

    private func selectedHandle(_ slot: Int) -> DragHandle? {
        guard sketchSession == nil, pendingTool == nil, holeMoveStart == nil, let id = selectedFeature else { return nil }
        return handle(for: id, slot: slot) ?? (slot > 0 ? handle(for: id, slot: 0) : nil)
    }

    /// The drag handle a feature shows while it's selected.
    func handle(for id: FeatureID, slot: Int = 0) -> DragHandle? {
        guard let f = document.features.first(where: { $0.id == id }), !f.suppressed, let result else { return nil }
        let params = parameterValues
        // A draft has the one handle, the dial, whichever slot asks.
        let slot = { if case .draft = f.kind { return Self.taperSlot } else { return slot } }()
        func handle(_ label: String, _ base: SIMD3<Double>, _ direction: SIMD3<Double>, _ expression: String,
                    unit: UnitKind = .length, per: Double = 1, max: Double? = nil, maxReason: String? = nil,
                    negative: Bool = false) -> DragHandle {
            let v = (try? params.value(of: expression, kind: unit)) ?? 0
            return DragHandle(featureID: id, label: label, base: base, direction: direction,
                              value: slot == activeHandleSlot ? handlePreviewValue ?? v * per : v * per, expression: expression,
                              unit: unit, lengthPerUnit: per, maxValue: max, maxReason: maxReason, allowsNegative: negative,
                              slot: slot)
        }
        switch f.kind {
        case .extrude(let e):
            let base: SIMD3<Double>, n: SIMD3<Double>, dialFrame: Frame
            if let face = e.face {
                guard let body = result.featureInputs[id]?[face.body], let frame = try? body.faceFrame(face.face),
                      let center = try? body.faceCenter(face.face) else { return nil }
                base = center
                n = frame.normal * (e.flipped ? -1 : 1)
                dialFrame = frame
            } else {
                guard let sr = result.sketches[e.sketch], let ref = e.profiles.first,
                      let region = Regenerator.region(ref, in: sr) else { return nil }
                n = sr.frame.normal * (e.flipped ? -1 : 1)
                // An extrude that starts on a face has its arrow there, not on the sketch plane.
                base = sr.frame.point(region.sample.x, region.sample.y) + sr.frame.normal * (result.extrudeStarts[id] ?? 0)
                dialFrame = sr.frame
            }
            if slot == Self.taperSlot {
                // The dial hangs on the arrow's tip and opens the way the extrusion goes.
                let arrow = self.handle(for: id, slot: 0)
                let tip = arrow.map { $0.base + $0.direction * $0.value } ?? base
                let axis = (arrow.map { $0.value < 0 } ?? false) ? -n : n
                let (side, radius) = dialPlacement(axis: axis, frame: dialFrame)
                var h = handle("Taper", tip, axis, e.taper ?? "0 deg", unit: .angle, max: DragHandle.Dial.limit, negative: true)
                h.dial = DragHandle.Dial(side: side, radius: radius)
                h.allowsZero = true
                return h
            }
            switch e.extent {
            case .distance(let d): return handle("Distance", base, n, d, negative: true)
            case .symmetric(let d): return handle("Distance", base, n, d, per: 0.5)
            case .twoSides(let d, let back):
                // One arrow each way from the sketch plane; the second can't be pulled back through the plane.
                return slot == 0 ? handle("Distance 1", base, n, d, negative: true) : handle("Distance 2", base, -n, back)
            case .throughAll, .toFace: return nil  // the length comes from the model, not a size
            }
        case .fillet(let ef), .chamfer(let ef):
            // On the first edge, or the first edge around the first face.
            let ref = ef.edges.first ?? ef.faces.first.flatMap { face in
                (try? result.edgeFeatureInputs[id]?[face.body]?.faceEdges(face.face))?.first.map { EdgeRef(body: face.body, edge: $0) }
            }
            guard let ref, let body = result.edgeFeatureInputs[id]?[ref.body] else { return nil }
            if case .chamfer = f.kind, ef.mode != .equalDistance {
                // Measured on each face: an arrow along each face away from the edge (the first on the face the
                // first distance is on); for an angle, the second arrow sets it, standing off the edge.
                let face = ef.edges.isEmpty ? (ef.faces.first { (try? body.faceEdges($0.face))?.contains(ref.edge) == true }?.face ?? "") : ""
                guard let c = try? body.chamferHandle(ref.edge, face: face, flipped: ef.flipped) else { return nil }
                if slot == 0 { return handle(ef.mode == .twoDistances ? "Distance 1" : "Distance", c.origin, c.first, ef.size) }
                if ef.mode == .twoDistances { return handle("Distance 2", c.origin, c.second, ef.second) }
                let first = (try? params.value(of: ef.size, kind: .length)) ?? 1
                return handle("Angle", c.origin, -c.normal, ef.second, unit: .angle, per: max(2 * first, 6), max: .pi / 2 - 0.01)
            }
            guard let h = try? body.edgeHandle(ref.edge) else { return nil }
            if case .fillet = f.kind { return handle("Radius", h.origin, h.direction, ef.size) }
            // A chamfer round a rounded corner has to stay smaller than the corner's radius (a hair under it:
            // at the radius itself the cone collapses to a point).
            var edges = ef.edges.filter { $0.body == ref.body }.map(\.edge)
            for face in ef.faces where face.body == ref.body { edges += (try? body.faceEdges(face.face)) ?? [] }
            let corner = body.chamferLimit(edges: edges)
            return handle("Distance", h.origin, h.direction, ef.size, max: corner.map { max($0 - 0.01, 0.01) },
                          maxReason: corner.map { "the corner it runs round has a radius of \(UnitKind.length.format($0))" })
        case .revolve(let rv):
            guard let sr = result.sketches[rv.sketch], let ref = rv.profiles.first,
                  let region = Regenerator.region(ref, in: sr),
                  let axis = try? Regenerator.axis(rv.axis, sketch: sr) else { return nil }
            // A dot round the axis, just outside the profile's outer edge at the height the profile is picked, so the
            // field and options sit beside the body. (A tangent arrow ran a full turn's length, a long way off the body.)
            let p = sr.frame.point(region.sample.x, region.sample.y)
            let along = simd_dot(p - axis.origin, axis.direction)
            let center = axis.origin + along * axis.direction
            let radial = p - center
            guard simd_length(radial) > 1e-6 else { return nil }
            let outward = simd_normalize(radial)
            let edge = sr.regions.firstIndex { $0.index == region.index }.map { i in
                let positions = sr.regionMeshes[i].positions
                return stride(from: 0, to: positions.count - 2, by: 3).map { k -> Double in
                    let q = SIMD3(Double(positions[k]), Double(positions[k + 1]), Double(positions[k + 2])) - axis.origin
                    return simd_length(q - simd_dot(q, axis.direction) * axis.direction)
                }.max() ?? 0
            } ?? 0
            var h = handle("Angle", center, outward, rv.angle, unit: .angle, max: 2 * .pi)
            let clear = 10 * (dialView?.mmPerPoint ?? 0.25)  // the dot stands a little off the wall
            h.dial = DragHandle.Dial(side: simd_cross(axis.direction, outward), radius: max(edge, simd_length(radial)) + clear,
                                     reach: 2 * .pi, wraps: true)
            return h
        case .primitive(let pf):
            guard let frame = try? Regenerator.primitiveFrame(pf, result) else { return nil }
            switch pf.kind {
            case .box, .cylinder: return handle("Height", frame.origin, frame.normal, pf.height)
            case .sphere: return handle("Diameter", frame.origin, frame.normal, pf.diameter, per: 0.5)
            case .torus: return handle("Diameter", frame.origin, frame.xAxis, pf.diameter, per: 0.5)
            case .coil:
                guard let turns = try? params.value(of: pf.turns, kind: .none), turns > 0 else { return nil }
                return handle("Pitch", frame.origin, frame.normal, pf.pitch, per: turns)  // the arrow spans the coil
            }
        case .hole(let hf):
            guard let frame = try? Regenerator.holeFrame(hf, result, before: id) else { return nil }
            // Down into the material for the depth (unless the hole goes right through), and out along the face for
            // the diameter: the arrow spans the radius.
            if let depth = hf.depth, slot == 0 { return handle("Depth", frame.origin, -frame.normal, depth) }
            return handle("Diameter", frame.origin, frame.xAxis, hf.diameter, per: 0.5)
        case .thread(let tf):
            // Along the axis from the end the thread starts at (on the face as it was before).
            guard let length = tf.length, let body = result.featureInputs[id]?[tf.face.body],
                  let cyl = try? body.faceCylinder(tf.face.face, flipped: tf.flipped) else { return nil }
            return handle("Length", cyl.start, cyl.direction, length)
        case .pipe(let pf):
            guard let at = pathPoint(pf.path, result) else { return nil }
            return handle("Diameter", at.point, at.side, pf.diameter, per: 0.5)
        case .rib(let rf):
            guard let at = pathPoint(rf.path, result, middle: true) else { return nil }
            return handle("Thickness", at.point, at.normal, rf.thickness, per: 0.5)
        case .move(let mf):
            guard let middle = manipulatorMiddle(id, mf) else { return nil }
            let dir = Regenerator.direction(mf.arrow)
            if mf.rotating { return handle("Rotate \(mf.arrow.rawValue)", middle, dir, mf.turn(mf.arrow), unit: .angle, negative: true) }
            return handle("Move \(mf.arrow.rawValue)", middle, dir, mf.distance(mf.arrow), negative: true)
        case .rotate(let rf):
            guard let inputs = result.featureInputs[id], let center = Regenerator.center(of: Array(inputs.values)),
                  let box = inputs.values.first?.bounds else { return nil }
            let axis = Regenerator.direction(rf.axis)
            let radial: SIMD3<Double> = rf.axis == .z ? SIMD3(1, 0, 0) : rf.axis == .x ? SIMD3(0, 1, 0) : SIMD3(0, 0, 1)
            let r = max(simd_reduce_max(box.max - box.min) * 0.6, 1)
            var h = handle("Angle", center + r * radial, simd_cross(axis, radial), rf.angle, unit: .angle, per: r, max: 2 * .pi)
            h.allowsNegative = true
            return h
        case .scale(let sf):
            if !sf.bodies.isEmpty {
                // From the middle of the bodies along X: the arrow is half their size, times the factor.
                let bodies = Array((result.featureInputs[id] ?? [:]).values)
                let boxes = bodies.compactMap(\.bounds)
                guard let center = Regenerator.center(of: bodies), let first = boxes.first else { return nil }
                let lo = boxes.dropFirst().reduce(first.min) { simd_min($0, $1.min) }
                let hi = boxes.dropFirst().reduce(first.max) { simd_max($0, $1.max) }
                return handle("Scale", center, SIMD3(1, 0, 0), sf.factor, unit: .none, per: max(simd_reduce_max(hi - lo) / 2, 1))
            }
            // From the sketch's origin along its x axis: the arrow is as long as the sketch is wide, times the factor.
            guard let sk = result.sketchInputs[id]?[sf.sketches.first ?? ""], let box = sk.bounds else { return nil }
            let size = max(simd_reduce_max(box.max - box.min) / 2, 1)
            return handle("Scale", sk.frame.origin, sk.frame.xAxis, sf.factor, unit: .none, per: size)
        case .plane(let pf):
            // From where the plane is with no offset, along its normal. Worked out from the plane it
            // starts from (not from the plane as last built), so it holds still while being dragged.
            var unmoved = pf
            unmoved.offset = "0 mm"
            guard let start = try? Regenerator.plane(unmoved, result) else { return nil }
            return handle("Offset", start.origin, start.normal, pf.offset, negative: true)
        case .pattern(let pf) where pf.kind == .linear:
            // From the middle of the bodies to where the first copy's middle lands.
            let bodies = Array((result.featureInputs[id] ?? [:]).values)
            guard let center = Regenerator.center(of: bodies), let axis = try? Regenerator.line(pf.axis, result) else { return nil }
            return handle("Spacing", center, axis.direction, pf.spacing, negative: true)
        case .shell(let sf):
            // On the first flat open face (as it was before the shell), pointing into the wall.
            guard let body = result.featureInputs[id]?[sf.body] else { return nil }
            for face in sf.faces where face.body == sf.body {
                guard let frame = try? body.faceFrame(face.face), let center = try? body.faceCenter(face.face) else { continue }
                return handle("Thickness", center, frame.normal * (sf.inside ? -1 : 1), sf.thickness)
            }
            return nil
        case .draft(let df):
            // A dial where the first drafted face meets the plane it pivots about, swinging from the pull direction
            // (up the face) towards the inside of the body: a positive angle narrows the body, as it does in the field.
            guard let body = result.featureInputs[id]?[df.body], let fixed = df.fixed, fixed.body == df.body,
                  let plane = try? body.faceFrame(fixed.face) else { return nil }
            let pull = -plane.normal
            for face in df.faces where face.body == df.body {
                // Where the face is and which way it faces (square to the pull): a flat face at its centre, or a round
                // face at the point on its wall nearest the camera (nearest the far side, for a hole, whose wall is
                // seen through the opening), as a round face has no middle on its surface.
                var at: SIMD3<Double>, out: SIMD3<Double>
                if let frame = try? body.faceFrame(face.face), let center = try? body.faceCenter(face.face) {
                    at = center; out = frame.normal
                } else if let cyl = try? body.faceCylinder(face.face) {
                    var u = SIMD3<Double>(0, 0, 0)
                    if let view = dialView { u = (cyl.isHole ? 1 : -1) * view.forward }
                    u -= simd_dot(u, cyl.direction) * cyl.direction
                    if simd_length(u) < 1e-3 {
                        u = abs(cyl.direction.x) < 0.9 ? simd_cross(cyl.direction, SIMD3(1, 0, 0)) : simd_cross(cyl.direction, SIMD3(0, 1, 0))
                    }
                    u = simd_normalize(u)
                    at = cyl.start + u * cyl.radius
                    out = cyl.isHole ? -u : u
                } else { continue }
                out -= simd_dot(out, pull) * pull
                guard simd_length(out) > 1e-9 else { continue }
                out = simd_normalize(out)
                let pivot = at - simd_dot(at - plane.origin, pull) * pull
                var h = handle("Angle", pivot, pull, df.angle, unit: .angle, max: DragHandle.Dial.limit, negative: true)
                h.dial = DragHandle.Dial(side: -out, radius: 80 * (dialView?.mmPerPoint ?? 0.25))
                h.allowsZero = true
                return h
            }
            return nil
        case .project(let pf):
            // Out of the surface where the first profile landed. Dragged past zero it sinks in instead (a deboss).
            guard let landed = result.projectionHandles[id] else { return nil }
            return handle("Height", landed.origin, landed.normal, pf.signedHeight, negative: true)
        case .image(let imf):
            // Out along the picture's width from its middle: the arrow spans half the width; the height follows.
            guard let placed = result.images[id] else { return nil }
            return handle("Width", placed.frame.origin, placed.frame.xAxis, imf.width, per: 0.5)
        case .twistSweep(let tw):
            guard let sr = result.sketches[tw.sketch], let ref = tw.profiles.first, let region = Regenerator.region(ref, in: sr),
                  let slotIndex = sr.regions.firstIndex(where: { $0.index == region.index }),
                  let middle = Self.centroid(of: sr.regionMeshes[slotIndex]) else { return nil }
            let normal = sr.frame.normal
            let along = normal * (tw.flipped ? -1 : 1)
            let start = middle
            if slot == Self.taperSlot {
                // A dial round the turning line at the far end, where the profile's x axis points at an angle of nothing: the dot
                // stands where the end of the profile is, and swings round as the end angle grows.
                let length = (try? params.value(of: tw.distance, kind: .length)) ?? 0
                let slide = ((try? params.value(of: tw.shiftU, kind: .length)) ?? 0) * sr.frame.xAxis
                    + ((try? params.value(of: tw.shiftV, kind: .length)) ?? 0) * sr.frame.yAxis
                var turnsAbout = start
                if tw.pivotU != nil || tw.pivotV != nil {
                    let pu = (try? tw.pivotU.map { try params.value(of: $0, kind: .length) } ?? 0) ?? 0
                    let pv = (try? tw.pivotV.map { try params.value(of: $0, kind: .length) } ?? 0) ?? 0
                    turnsAbout = sr.frame.point(pu, pv)
                }
                let center = turnsAbout + along * length + slide
                let radial = Self.points(of: sr.regionMeshes[slotIndex]).map { q -> Double in
                    let d = q - turnsAbout
                    return simd_length(d - simd_dot(d, normal) * normal)
                }.max() ?? 10
                let clear = 10 * (dialView?.mmPerPoint ?? 0.25)
                var h = handle("End angle", center, sr.frame.xAxis, tw.endAngle, unit: .angle, max: 8 * .pi, negative: true)
                h.dial = DragHandle.Dial(side: sr.frame.yAxis, radius: max(radial, 2) + clear, reach: .pi)
                h.allowsZero = true
                return h
            }
            return handle("Length", start, along, tw.distance)
        case .sketch, .sweep, .loft, .combine, .split, .layOnFloor, .mirror, .pattern, .importBody:
            return nil
        }
    }

    /// The middle of a flat region's triangles (by area), in world coordinates.
    static func centroid(of mesh: Mesh) -> SIMD3<Double>? {
        var area = 0.0, sum = SIMD3<Double>(0, 0, 0)
        let pts = points(of: mesh), idx = mesh.indices
        for t in 0..<(idx.count / 3) {
            let a = pts[Int(idx[3 * t])], b = pts[Int(idx[3 * t + 1])], c = pts[Int(idx[3 * t + 2])]
            let size = simd_length(simd_cross(b - a, c - a)) / 2
            area += size
            sum += (a + b + c) / 3 * size
        }
        return area > 1e-12 ? sum / area : nil
    }

    /// A mesh's vertices, in world coordinates.
    static func points(of mesh: Mesh) -> [SIMD3<Double>] {
        stride(from: 0, to: mesh.positions.count - 2, by: 3).map {
            SIMD3(Double(mesh.positions[$0]), Double(mesh.positions[$0 + 1]), Double(mesh.positions[$0 + 2]))
        }
    }

    // MARK: moving a hole

    /// The selected hole, when its move dot shows (as with the drag handle: no sketch, no tool waiting).
    var selectedHole: (id: FeatureID, hole: HoleFeature)? {
        guard sketchSession == nil, pendingTool == nil, let id = selectedFeature,
              let f = document.features.first(where: { $0.id == id }), !f.suppressed, case .hole(let hole) = f.kind else { return nil }
        return (id, hole)
    }

    /// The plane of a hole's face; the hole's (u, v) are in it.
    func holeFace(_ id: FeatureID, _ hole: HoleFeature) -> Frame? {
        guard let result, let body = result.featureInputs[id]?[hole.face.body] ?? result.body(hole.face.body) else { return nil }
        return try? body.faceFrame(hole.face.face)
    }

    /// The middle of a hole's face outline (as it was before the hole), in the face's (u, v).
    func holeFaceCenter(_ id: FeatureID, _ hole: HoleFeature, on face: Frame) -> SIMD2<Double>? {
        guard let body = result?.featureInputs[id]?[hole.face.body], let c = try? body.faceOutlineCenter(hole.face.face) else { return nil }
        return Self.uv(of: c, on: face)
    }

    /// Where the selected hole's move dot is: the hole's centre, or where it's being dragged.
    var holeMoveDot: SIMD3<Double>? {
        guard let (id, hole) = selectedHole, let face = holeFace(id, hole) else { return nil }
        if let uv = holeMovePreview { return face.point(uv.x, uv.y) }
        guard let result, let frame = try? Regenerator.holeFrame(hole, result, before: id) else { return nil }
        return frame.origin
    }

    func beginHoleMove() {
        guard selectedHole != nil else { return }
        holeMoveStart = document
    }

    /// Slides the hole to where the mouse ray meets its face, in round steps of about 6 points
    /// (`pointsPerMM`: how long 1 mm on the face looks), and onto the face's centre lines when within
    /// 10 points of them. Previews the result.
    func moveHole(rayOrigin o: SIMD3<Double>, direction d: SIMD3<Double>, pointsPerMM: Double?) {
        guard let start = holeMoveStart, let (id, hole) = selectedHole, let face = holeFace(id, hole),
              let hit = Self.intersect(ray: (o, d), with: face) else { return }
        var uv = hit
        if let ppm = pointsPerMM, ppm > 1e-9 {
            let center = holeFaceCenter(id, hole, on: face)
            let c = center ?? .zero
            let step = GridSteps.niceStep(6 / ppm)
            uv = c + ((uv - c) / step).rounded(.toNearestOrAwayFromZero) * step
            if let center { uv = Self.snap(uv, to: center, tolerance: 10 / ppm) }
        }
        holeMovePreview = uv
        var preview = start
        Self.setHolePosition(uv, of: id, in: &preview)
        regenerate(preview: preview, previewFeature: id)
        overlayRevision += 1
    }

    func endHoleMove() {
        guard holeMoveStart != nil else { return }
        defer { holeMoveStart = nil; holeMovePreview = nil; overlayRevision += 1 }
        guard let (id, hole) = selectedHole, let uv = holeMovePreview else { return }
        if previewInvalid {
            // Dropped where the hole can't be made: go back to where it was.
            previewInvalid = false
            regenerate()
            return
        }
        if Self.isParametric(hole.u) || Self.isParametric(hole.v) {
            unlinkPrompt = UnlinkPrompt(featureID: id, label: "Position", unit: .length, expression: "\(hole.u), \(hole.v)",
                                        value: 0, holePosition: uv)
            return  // the preview stays on screen until the user answers
        }
        commitHoleMove(id, to: uv)
    }

    func commitHoleMove(_ id: FeatureID, to uv: SIMD2<Double>) {
        mutate("Move Hole") { Self.setHolePosition(uv, of: id, in: &$0) }
    }

    static func setHolePosition(_ uv: SIMD2<Double>, of id: FeatureID, in doc: inout CADDocument) {
        guard let i = doc.index(of: id), case .hole(var h) = doc.features[i].kind else { return }
        h.u = formatDimension(uv.x, kind: .length)
        h.v = formatDimension(uv.y, kind: .length)
        doc.features[i].kind = .hole(h)
    }

    /// Moves each coordinate onto the centre's when it's within `tolerance` of it: the point lands on
    /// the centre, or on one of the lines through it.
    static func snap(_ p: SIMD2<Double>, to center: SIMD2<Double>, tolerance: Double) -> SIMD2<Double> {
        SIMD2(abs(p.x - center.x) <= tolerance ? center.x : p.x, abs(p.y - center.y) <= tolerance ? center.y : p.y)
    }

    /// A point in a plane's (u, v).
    static func uv(of point: SIMD3<Double>, on frame: Frame) -> SIMD2<Double> {
        let p = point - frame.origin
        return SIMD2(simd_dot(p, frame.xAxis), simd_dot(p, frame.yAxis))
    }

    /// Where a ray meets a plane, in the plane's (u, v); nil when the ray runs along the plane.
    static func intersect(ray: (origin: SIMD3<Double>, direction: SIMD3<Double>), with frame: Frame) -> SIMD2<Double>? {
        let denom = simd_dot(ray.direction, frame.normal)
        guard abs(denom) > 1e-9 else { return nil }
        let t = simd_dot(frame.origin - ray.origin, frame.normal) / denom
        return uv(of: ray.origin + t * ray.direction, on: frame)
    }

    /// A move's distance along one axis, as stored.
    static func component(_ m: MoveFeature, _ a: Axis3) -> String {
        switch a {
        case .x: return m.dx
        case .y: return m.dy
        case .z: return m.dz
        }
    }

    /// A point on a path's first curve (its start, or its middle) with the in-plane direction
    /// square to the curve there and the sketch normal.
    private func pathPoint(_ ref: CurveRef, _ r: RegenResult, middle: Bool = false)
        -> (point: SIMD3<Double>, side: SIMD3<Double>, normal: SIMD3<Double>)? {
        guard let sk = r.sketches[ref.sketch], let first = ref.curves.first, let g = sk.solved.geometry(of: first) else { return nil }
        let t = middle ? 0.5 : 0.0
        let p = g.point(t), q = g.point(t + 1e-3)
        let d = q - p, len = (d.x * d.x + d.y * d.y).squareRoot()
        guard len > 1e-12 else { return nil }
        let side = SIMD2(-d.y, d.x) / len
        return (sk.frame.point(p.x, p.y), side.x * sk.frame.xAxis + side.y * sk.frame.yAxis, sk.frame.normal)
    }

    func beginHandleDrag(slot: Int = 0) {
        activeHandleSlot = slot
        guard let h = dragHandle else { return }
        if h.dial != nil { dialFieldOpen = h.featureID }  // the angle's field shows beside the dot from now on
        handleDragStart = document
        handleStartValue = h.featureValue(h.value)
    }

    /// The size when the drag or typing began, to notice an extrude turning round (Join ⇄ Cut).
    @ObservationIgnored private var handleStartValue: Double?

    /// Moves the handle to the point on its axis closest to the mouse ray, and previews the result.
    /// `pointsPerMM`: how long 1 mm along the arrow looks on screen. The size then goes in round
    /// steps (1, 2 or 5 × 10ⁿ mm or degrees) of about 6 points, not in whatever fraction the pointer lands on.
    /// A length step is never more than 1 mm, however far out the view is zoomed.
    func dragHandle(rayOrigin o: SIMD3<Double>, direction d: SIMD3<Double>, pointsPerMM: Double? = nil) {
        guard let start = handleDragStart, let h = dragHandle else { return }
        if let dial = h.dial {
            // The dot follows the mouse round the arc: the ray meets the arc's plane, and the angle is read off there.
            let pn = simd_cross(h.direction, dial.side)
            let facing = simd_dot(d, pn)
            guard abs(facing) > 0.05 else { return }  // the arc is edge-on
            let hit = o + d * (simd_dot(h.base - o, pn) / facing)
            let v = hit - h.base
            var angle = atan2(simd_dot(v, dial.side), simd_dot(v, h.direction))
            var low = -dial.reach
            if dial.wraps {
                // Round the whole circle: take the turn nearest the one the dot is on, so it never jumps back to the start.
                let turn = 2 * Double.pi
                angle += (((handlePreviewValue ?? h.value) - angle) / turn).rounded() * turn
                low = 1 * .pi / 180  // a turn of nothing is no turn
            }
            angle = min(max((angle * 180 / .pi).rounded() * .pi / 180, low), dial.reach)
            handlePreviewValue = angle
            var preview = start
            Self.set(expression: formatDimension(angle, kind: .angle), of: h.featureID, slot: h.slot, in: &preview)
            regenerate(preview: preview, previewFeature: h.featureID)
            overlayRevision += 1
            return
        }
        let a = h.direction, w = h.base - o
        let b = simd_dot(a, d)
        guard 1 - b * b > 1e-6 else { return }  // looking straight down the handle
        let s = (b * simd_dot(d, w) - simd_dot(a, w)) / (1 - b * b)
        var length = h.allowsNegative ? (abs(s) < 0.01 ? (s < 0 ? -0.01 : 0.01) : s) : max(s, 0.01)
        if let ppm = pointsPerMM, ppm > 1e-9, h.lengthPerUnit > 1e-12 {
            // In the feature's own units: mm, or degrees for angles (radians underneath).
            let degrees = h.unit == .angle ? 180 / Double.pi : 1
            let perPoint = degrees / (ppm * h.lengthPerUnit)
            var step = GridSteps.niceStep(6 * perPoint) / degrees
            if h.unit == .length { step = min(step, 1) }  // zoomed out, a step never jumps more than 1 mm
            let value = (length / h.lengthPerUnit / step).rounded() * step
            if value != 0 || h.allowsNegative == false { length = value * h.lengthPerUnit }
            if !h.allowsNegative { length = max(length, step * h.lengthPerUnit) }
        }
        if let m = h.maxValue { length = min(length, m * h.lengthPerUnit) }
        handlePreviewValue = length
        var preview = start
        Self.set(expression: formatDimension(h.featureValue(length), kind: h.unit), of: h.featureID, slot: h.slot, in: &preview)
        Self.turnRound(h.featureID, from: handleStartValue, to: h.featureValue(length), slot: h.slot, in: &preview)
        regenerate(preview: preview, previewFeature: h.featureID)
        overlayRevision += 1
    }

    func endHandleDrag() {
        guard handleDragStart != nil else { return }
        defer { handleDragStart = nil; handlePreviewValue = nil }
        guard let h = dragHandle, let length = handlePreviewValue else {
            // A click on the dial's dot without a drag: open its field for typing the angle.
            if dragHandle?.dial != nil { handleFocusSlot = activeHandleSlot; handleFocusRequest += 1 }
            return
        }
        if previewInvalid {
            // Dropped where the feature can't be built: go back to what was there.
            previewInvalid = false
            regenerate()
            return
        }
        let value = h.featureValue(length)
        if Self.isParametric(h.expression) {
            unlinkPrompt = UnlinkPrompt(featureID: h.featureID, label: h.label, unit: h.unit, expression: h.expression,
                                        value: value, startValue: handleStartValue, slot: h.slot)
            return  // the preview stays on screen until the user answers
        }
        commitHandle(h.featureID, h.label, formatDimension(value, kind: h.unit), slot: h.slot, from: handleStartValue, to: value)
    }

    // MARK: resizing a construction plane

    /// A construction plane's side being dragged: the plane, the side (see `PickID.planeEdge`), and the document before.
    private struct PlaneResize {
        var id: FeatureID
        var edge: Int
        var start: CADDocument
    }
    @ObservationIgnored private var planeResize: PlaneResize?

    /// The plane a plane-edge pick belongs to.
    func constructionPlane(ofEdge pick: PickID) -> FeatureID? {
        guard pick.kind == .planeEdge else { return nil }
        return planeFeatures[safe: pick.element]?.id
    }

    /// A side of a construction plane was grabbed: select the plane, and drag the side with `dragPlaneEdge`.
    func beginPlaneResize(_ pick: PickID) {
        guard let id = constructionPlane(ofEdge: pick) else { return }
        selection = []
        selectedFeature = id
        planeResize = PlaneResize(id: id, edge: pick.planeEdge, start: document)
    }

    /// Where the grabbed side is and which way it moves: the point at its middle, the unit direction it
    /// slides along (the plane's x axis for the left and right sides, its y axis for the others), and its
    /// coordinate along that direction.
    var planeResizeLine: (point: SIMD3<Double>, direction: SIMD3<Double>, coordinate: Double, extent: PlaneExtent)? {
        guard let drag = planeResize, let i = document.index(of: drag.id), case .plane(let pf) = document.features[i].kind,
              let frame = result?.planes[drag.id] else { return nil }
        let e = pf.extent ?? PlaneExtent(side: OriginPlane.displaySize(for: sceneBounds))
        let alongU = drag.edge == 1 || drag.edge == 3
        let current = [e.vMin, e.uMax, e.vMax, e.uMin][drag.edge]
        let middle = frame.point(alongU ? current : (e.uMin + e.uMax) / 2, alongU ? (e.vMin + e.vMax) / 2 : current)
        return (middle, alongU ? frame.xAxis : frame.yAxis, current, e)
    }

    /// Moves the grabbed side to the point on the line out from its middle that's closest to the mouse ray; the
    /// opposite side stays where it is. `pointsPerMM`: how long 1 mm looks on screen, for round steps.
    func dragPlaneEdge(rayOrigin o: SIMD3<Double>, direction d: SIMD3<Double>, pointsPerMM: Double?) {
        guard let drag = planeResize, let i = document.index(of: drag.id), case .plane(var pf) = document.features[i].kind,
              let line = planeResizeLine else { return }
        let a = line.direction, e = line.extent, current = line.coordinate
        let w = line.point - o, b = simd_dot(a, d)
        guard 1 - b * b > 1e-6 else { return }  // looking straight along the side's way
        var value = current + (b * simd_dot(d, w) - simd_dot(a, w)) / (1 - b * b)
        if let ppm = pointsPerMM, ppm > 1e-9 {
            let step = GridSteps.niceStep(6 / ppm)
            value = (value / step).rounded() * step
        }
        let smallest = 1.0, before = pf.extent
        switch drag.edge {
        case 0: pf.extent = PlaneExtent(uMin: e.uMin, uMax: e.uMax, vMin: min(value, e.vMax - smallest), vMax: e.vMax)
        case 1: pf.extent = PlaneExtent(uMin: e.uMin, uMax: max(value, e.uMin + smallest), vMin: e.vMin, vMax: e.vMax)
        case 2: pf.extent = PlaneExtent(uMin: e.uMin, uMax: e.uMax, vMin: e.vMin, vMax: max(value, e.vMin + smallest))
        default: pf.extent = PlaneExtent(uMin: min(value, e.uMax - smallest), uMax: e.uMax, vMin: e.vMin, vMax: e.vMax)
        }
        guard pf.extent != before else { return }
        document.features[i].kind = .plane(pf)  // shown at once; the undo step is made when the side is let go
        overlayRevision += 1
    }

    /// The side is let go: the new size becomes one undo step.
    func endPlaneResize() {
        guard let drag = planeResize else { return }
        planeResize = nil
        let resized = document
        guard resized != drag.start else { return }
        document = drag.start
        replace(with: resized, actionName: "Resize Plane")
    }

    /// Answer to the unlink prompt: use the dragged number, or keep the expression.
    func resolveUnlink(useValue: Bool) {
        guard let p = unlinkPrompt else { return }
        unlinkPrompt = nil
        if let t = p.transform {
            manipulatorLive = nil
            if useValue { commitTransform(p.featureID, t) } else { regenerate() }
        } else if useValue, let uv = p.holePosition {
            commitHoleMove(p.featureID, to: uv)
        } else if useValue {
            commitHandle(p.featureID, p.label, formatDimension(p.value, kind: p.unit), slot: p.slot, from: p.startValue, to: p.value)
        } else {
            regenerate()
        }
    }

    private func commitHandle(_ id: FeatureID, _ label: String, _ expression: String, slot: Int = 0, from old: Double? = nil,
                              to new: Double? = nil) {
        mutate("Change \(label)") { doc in
            Self.set(expression: expression, of: id, slot: slot, in: &doc)
            if let new { Self.turnRound(id, from: old, to: new, slot: slot, in: &doc) }
        }
    }

    /// An extrude dragged or typed through zero turns round: pulled back into the body it cuts,
    /// pushed out again it joins. Other operations are left as the user chose them.
    static func turnRound(_ id: FeatureID, from old: Double?, to new: Double, slot: Int = 0, in doc: inout CADDocument) {
        guard slot == 0, let old, let i = doc.index(of: id), case .extrude(var e) = doc.features[i].kind else { return }
        if old >= 0, new < 0, e.operation == .join { e.operation = .cut }
        else if old < 0, new >= 0, e.operation == .cut { e.operation = .join }
        else { return }
        doc.features[i].kind = .extrude(e)
    }

    // MARK: typing the handle's size

    /// Evaluates a typed size: positive, and a bare number read as millimetres (or degrees).
    private func handleSize(_ text: String, _ h: DragHandle) -> (expression: String, value: Double)? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard let v = try? parameterValues.value(of: t, kind: h.unit), h.allowsZero || (h.allowsNegative ? abs(v) > 1e-9 : v > 1e-9) else { return nil }
        if let m = h.maxValue, exceeds(v, m, h) { return nil }
        let bare = Double(t).map { h.unit == .angle ? $0 * .pi / 180 : $0 }
        return (bare.map { formatDimension($0, kind: h.unit) } ?? t, v)
    }

    /// Whether a value is past a handle's limit (a dial's reaches either way).
    private func exceeds(_ v: Double, _ limit: Double, _ h: DragHandle) -> Bool {
        (h.dial != nil ? abs(v) : v) > limit + 1e-9
    }

    /// Why a typed size can't be used: an unknown name, the wrong kind of value, or out of range.
    func handleSizeProblem(_ text: String, _ h: DragHandle) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return "Type a size" }
        let needed = h.unit == .angle ? "an angle" : h.unit == .none ? "a plain number" : "a length"
        do {
            let v = try parameterValues.value(of: t, kind: h.unit)
            if !h.allowsZero, h.allowsNegative ? abs(v) <= 1e-9 : v <= 1e-9 { return h.allowsNegative ? "It can't be zero" : "It must be more than zero" }
            if let m = h.maxValue, exceeds(v, m, h) {
                return (h.dial != nil ? "It can be at most \(h.unit.format(m)) either way" : "It can be at most \(h.unit.format(m))")
                    + (h.maxReason.map { ": \($0)" } ?? "")
            }
            return nil
        } catch {
            // The right expression with the wrong kind of value, e.g. a length parameter in an angle field.
            for other in [UnitKind.length, .angle, .none] where other != h.unit {
                if let v = try? parameterValues.value(of: t, kind: other) {
                    let got = other == .angle ? "an angle" : other == .length ? "a length" : "a plain number"
                    return "That's \(got) (\(other.format(v))), but this needs \(needed)"
                }
            }
            return "\(error)".prefix(1).uppercased() + "\(error)".dropFirst()
        }
    }

    /// Previews a size typed in the handle's field. Returns false if the text isn't a usable size.
    @discardableResult
    func previewHandle(_ text: String) -> Bool {
        guard let h = dragHandle, handleDragStart == nil else { return false }
        guard let size = handleSize(text, h) else {
            handleProblem = handleSizeProblem(text, h)
            return false
        }
        handleProblem = nil
        handleNote = nil
        handlePreviewValue = size.value * h.lengthPerUnit
        var preview = document
        Self.set(expression: size.expression, of: h.featureID, slot: h.slot, in: &preview)
        Self.turnRound(h.featureID, from: h.featureValue((try? parameterValues.value(of: h.expression, kind: h.unit)) ?? 0), to: size.value, slot: h.slot, in: &preview)
        regenerate(preview: preview, previewFeature: h.featureID)
        overlayRevision += 1
        return true
    }

    /// Return in the handle's field: stores the typed size (an expression may use parameters).
    /// `feature` is the feature the field was for, which may no longer be selected (OK, or a
    /// click elsewhere, closes the handle before the field hands over its text).
    @discardableResult
    func commitHandle(_ text: String, for feature: FeatureID? = nil, slot: Int? = nil) -> Bool {
        let slot = slot ?? activeHandleSlot
        guard let h = feature.flatMap({ handle(for: $0, slot: slot) }) ?? selectedHandle(slot) else { return false }
        guard let size = handleSize(text, h) else {
            handleProblem = handleSizeProblem(text, h)
            return false
        }
        handleProblem = nil
        handleNote = nil
        handleDraft = nil
        handlePreviewValue = nil
        let old = (try? parameterValues.value(of: h.expression, kind: h.unit)) ?? 0
        if size.expression == h.expression { regenerate() } else { commitHandle(h.featureID, h.label, size.expression, slot: h.slot, from: old, to: size.value) }
        overlayRevision += 1
        return true
    }

    /// Esc in the handle's field: drop the preview and show the stored size again.
    func cancelHandleEdit() {
        handleProblem = nil
        handleDraft = nil
        guard handleDragStart == nil, handlePreviewValue != nil || previewInvalid else { return }
        handlePreviewValue = nil
        previewInvalid = false
        regenerate()
        overlayRevision += 1
    }

    static func isParametric(_ expression: String) -> Bool {
        ((try? Expressions.parse(expression))?.references.isEmpty == false)
    }

    /// Writes the size a feature's drag handle controls.
    static func set(expression text: String, of id: FeatureID, slot: Int = 0, in doc: inout CADDocument) {
        guard let i = doc.index(of: id) else { return }
        switch doc.features[i].kind {
        case .extrude(var e):
            if slot == Self.taperSlot {
                e.taper = text
                doc.features[i].kind = .extrude(e)
                return
            }
            switch e.extent {
            case .distance: e.extent = .distance(text)
            case .symmetric: e.extent = .symmetric(text)
            case .twoSides(let first, let back): e.extent = slot == 1 ? .twoSides(first, back: text) : .twoSides(text, back: back)
            case .throughAll, .toFace: break
            }
            doc.features[i].kind = .extrude(e)
        case .fillet(var ef):
            ef.size = text
            doc.features[i].kind = .fillet(ef)
        case .chamfer(var ef):
            if slot == 1, ef.mode != .equalDistance { ef.second = text } else { ef.size = text }
            doc.features[i].kind = .chamfer(ef)
        case .revolve(var r):
            r.angle = text
            doc.features[i].kind = .revolve(r)
        case .primitive(var p):
            switch p.kind {
            case .box, .cylinder: p.height = text
            case .sphere, .torus: p.diameter = text
            case .coil: p.pitch = text
            }
            doc.features[i].kind = .primitive(p)
        case .hole(var h):
            if h.depth != nil, slot == 0 { h.depth = text } else { h.diameter = text }
            doc.features[i].kind = .hole(h)
        case .thread(var t):
            if t.length != nil { t.length = text }
            doc.features[i].kind = .thread(t)
        case .pipe(var p):
            p.diameter = text
            doc.features[i].kind = .pipe(p)
        case .rib(var r):
            r.thickness = text
            doc.features[i].kind = .rib(r)
        case .move(var m):
            switch (m.arrow, m.rotating) {
            case (.x, false): m.dx = text
            case (.y, false): m.dy = text
            case (.z, false): m.dz = text
            case (.x, true): m.rx = text
            case (.y, true): m.ry = text
            case (.z, true): m.rz = text
            }
            doc.features[i].kind = .move(m)
        case .scale(var s):
            s.factor = text
            doc.features[i].kind = .scale(s)
        case .rotate(var r):
            r.angle = text
            doc.features[i].kind = .rotate(r)
        case .plane(var p):
            p.offset = text
            doc.features[i].kind = .plane(p)
        case .pattern(var p):
            p.spacing = text
            doc.features[i].kind = .pattern(p)
        case .shell(var sf):
            sf.thickness = text
            doc.features[i].kind = .shell(sf)
        case .draft(var df):
            df.angle = text
            doc.features[i].kind = .draft(df)
        case .project(var pf):
            pf.setHeight(text)
            doc.features[i].kind = .project(pf)
        case .image(var im):
            im.width = text
            doc.features[i].kind = .image(im)
        case .twistSweep(var t):
            if slot == Self.taperSlot { t.endAngle = text } else { t.distance = text }
            doc.features[i].kind = .twistSweep(t)
        case .sketch, .sweep, .loft, .combine, .split, .layOnFloor, .mirror, .importBody:
            break
        }
    }

    /// Previews an uncommitted edit (e.g. while typing in the inspector) without an undo step.
    func preview(_ id: FeatureID, _ change: (inout Feature) -> Void) {
        var doc = document
        guard let i = doc.index(of: id) else { return }
        change(&doc.features[i])
        regenerate(preview: doc, previewFeature: id)
    }

    // MARK: files

    /// One import at a time: while a file is being read, reduced or built, says so (the others would be working on
    /// the same part and the same progress) and returns true, so the caller leaves the new import alone.
    func importInProgress() -> Bool {
        guard isImporting else { return false }
        alert = AlertInfo(title: "An import is already in progress",
                          message: "Wait for it to finish, then import the next file.")
        return true
    }

    #if os(macOS)
    /// Asks for a STEP file and adds it to the timeline as a body of its own.
    func importSTEP() {
        guard !importInProgress() else { return }
        guard let url = Self.chooseModel("Import", extensions: ["step", "stp"], message: "Choose a STEP file (.step or .stp).") else { return }
        Task { await importSTEP(from: url) }
    }
    #endif

    #if os(macOS)
    /// Asks for an STL file and adds it to the timeline as a body of its own.
    func importSTL() {
        guard !importInProgress() else { return }
        guard let url = Self.chooseModel("Import", extensions: ["stl"], message: "Choose an STL file. It must be watertight, and is read in millimetres.") else { return }
        Task { await importSTEP(from: url) }
    }
    #endif

    /// Reads a STEP or STL file and adds it as an Import feature, at the timeline marker, with the body
    /// named after the file. False if it can't be read (an alert says why).
    @discardableResult
    func importSTEP(from url: URL) async -> Bool {
        guard !importInProgress() else { return false }
        let id = IDs.make()
        guard let data = await loadSTEP(url, featureID: id) else { return false }
        if sketchSession != nil { finishSketch() }
        pendingTool = nil
        let feature = Feature(id: id, name: document.nextName("Import"),
                              .importBody(ImportFeature(fileName: url.lastPathComponent, data: data)))
        mutate("Import \(url.lastPathComponent)") { doc in
            doc.insertAtMarker(feature)
            doc.bodyNames[id] = url.deletingPathExtension().lastPathComponent
        }
        selection = []
        selectedFeature = id
        regenerate(fit: true)  // nothing left to build by then; it only brings the new body into view
        return true
    }

    #if os(macOS)
    /// Asks for a new version of an imported file. Its faces keep their names as long as the
    /// file lists them in the same order, so features after the import usually hold on.
    func replaceImport(_ id: FeatureID) {
        guard !importInProgress() else { return }
        guard let url = Self.chooseModel("Replace", extensions: ["step", "stp", "stl"],
                                         message: "Choose a STEP (.step, .stp) or STL (.stl) file.") else { return }
        Task { await replaceImport(id, from: url) }
    }
    #endif

    @discardableResult
    func replaceImport(_ id: FeatureID, from url: URL) async -> Bool {
        guard !importInProgress() else { return false }
        guard let data = await loadSTEP(url, featureID: id) else { return false }
        updateFeature(id, "Replace \(url.lastPathComponent)") { f in
            guard case .importBody(var i) = f.kind else { return }
            i.fileName = url.lastPathComponent
            i.data = data
            f.kind = .importBody(i)
        }
        return true
    }

    #if os(macOS)
    private static func chooseModel(_ prompt: String, extensions: [String], message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        panel.prompt = prompt
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }
    #endif

    /// STL meshes with more triangles than this are slow to import and to work with: the import offers to reduce them.
    static let comfortableSTLTriangles = 30_000
    /// The sizes a mesh can be reduced to, from finest to coarsest.
    static let reducedMeshSizes: [(name: String, triangles: Int)] = [("Fine", 60_000), ("Medium", 30_000), ("Coarse", 10_000)]

    /// A count with its thousands separated: 1,423,178.
    private static func grouped(_ n: Int) -> String {
        let number = NumberFormatter()
        number.numberStyle = .decimal
        return number.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// What to do with a big STL mesh.
    enum MeshReduction: Equatable {
        case reduce(to: Int)
        case importAsIs
        case cancel
    }

    /// The sizes offered for a mesh of `count` triangles, and the one chosen at first (the largest of 30 000 or fewer).
    static func meshReductionChoices(for count: Int) -> (sizes: [(name: String, triangles: Int)], first: Int) {
        let sizes = reducedMeshSizes.filter { $0.triangles < count }
        return (sizes, sizes.firstIndex { $0.triangles <= comfortableSTLTriangles } ?? 0)
    }

    #if os(macOS)
    /// Asks whether to reduce a big mesh before importing it. A mesh over the importer's limit can't go in as it is.
    private static func askAboutMeshReduction(fileName: String, count: Int) -> MeshReduction {
        let (sizes, first) = meshReductionChoices(for: count)
        guard !sizes.isEmpty else { return .importAsIs }
        let format = grouped
        let tooMany = count > KBody.maxSTLTriangles

        let alert = NSAlert()
        alert.messageText = "\(fileName) has \(format(count)) triangles"
        alert.informativeText = (tooMany
            ? "SimplMaker imports meshes of up to \(format(KBody.maxSTLTriangles)) triangles. "
            : "A mesh this size takes a while to import and is slow to work with. ")
            + "It can reduce the mesh first: flat faces and sharp edges stay as they are, and curved surfaces get a little coarser."
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: sizes.map { "\($0.name) · \(format($0.triangles)) triangles" })
        popup.selectItem(at: first)
        let label = NSTextField(labelWithString: "Reduce to")
        let row = NSStackView(views: [label, popup])
        row.spacing = 8
        row.frame = NSRect(origin: .zero, size: row.fittingSize)
        alert.accessoryView = row
        alert.addButton(withTitle: "Reduce and Import")
        if !tooMany { alert.addButton(withTitle: "Import As Is") }
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .reduce(to: sizes[popup.indexOfSelectedItem].triangles)
        case .alertSecondButtonReturn where !tooMany: return .importAsIs
        default: return .cancel
        }
    }
    #endif

    /// Reads a STEP or STL file and checks that the kernel can make a body of it, off the main thread. A big STL
    /// mesh is reduced first, if the user agrees; what comes back is then the reduced file. The body is kept for
    /// the rebuild that follows, so the file is read only once.
    private func loadSTEP(_ url: URL, featureID: FeatureID) async -> Data? {
        isImporting = true
        defer { isImporting = false; importProgress = nil }
        do {
            let (original, triangles) = try await Task.detached(priority: .userInitiated) { () -> (Data, Int?) in
                let data = try Data(contentsOf: url)
                return (data, KBody.looksLikeSTL(data) ? KBody.stlTriangleCount(data) : nil)
            }.value

            var reduceTo: Int?
            if let triangles, triangles > Self.comfortableSTLTriangles {
                switch meshReduction(url.lastPathComponent, triangles) {
                case .reduce(let n): reduceTo = n
                case .importAsIs: break
                case .cancel: return nil
                }
            }
            let name = url.lastPathComponent
            var data = original
            if let reduceTo, let triangles {
                importProgress = ImportProgress(title: "Reducing the mesh…", detail: "\(name)\n\(Self.grouped(triangles)) → \(Self.grouped(reduceTo)) triangles", fraction: 0)
                let reducing = Task.detached(priority: .userInitiated) { try KBody.simplifySTL(original, toTriangles: reduceTo) }
                let watching = Task { @MainActor in
                    while !Task.isCancelled {
                        importProgress?.fraction = KBody.simplifyProgress
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
                defer { watching.cancel() }
                data = try await reducing.value
            }
            if let triangles {  // a big mesh takes a while to turn into a solid, too
                importProgress = ImportProgress(title: "Building the solid…", detail: "\(name)\n\(Self.grouped(reduceTo ?? triangles)) triangles", fraction: nil)
            }
            let ready = data
            return try await Task.detached(priority: .userInitiated) { () -> Data in
                _ = try Regenerator.importedBody(ready, featureID: featureID)
                return ready
            }.value
        } catch {
            // Kernel errors read "STEP import: the file has no solids"; make that a sentence.
            var reason = error.localizedDescription
            if let e = error as? KernelError {
                let text = e.message.replacingOccurrences(of: "STEP import: ", with: "")
                    .replacingOccurrences(of: "STL import: ", with: "")
                reason = text.prefix(1).uppercased() + String(text.dropFirst()) + "."
            }
            alert = AlertInfo(title: "\(url.lastPathComponent) couldn't be imported", message: reason)
            return nil
        }
    }

    #if os(macOS)
    /// Asks for an SVG file and puts its shapes in a sketch.
    func importSVG() {
        guard !importInProgress() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.svg]
        panel.prompt = "Import"
        panel.message = "Choose an SVG file. Its shapes and paths become a sketch, in millimetres."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await importSVG(from: url) }
    }
    #endif

    #if os(macOS)
    /// Asks for a DXF file and puts its lines, arcs, circles and polylines in a sketch.
    func importDXF() {
        guard !importInProgress() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "dxf") ?? .data]
        panel.prompt = "Import"
        panel.message = "Choose a DXF file (text form). Its lines, arcs, circles and polylines become a sketch, in the file's units."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await importSVG(from: url) }
    }
    #endif

    #if os(macOS)
    /// Writes the sketch as a DXF file the user picks. Nothing in the part changes.
    func exportDXF(sketch id: FeatureID) {
        guard let solved = result?.sketches[id]?.solved else {
            alert = AlertInfo(title: "There's no sketch to export", message: "Fix the sketch's problems first, then export it.")
            return
        }
        guard solved.curves.contains(where: { !$0.construction }) else {
            alert = AlertInfo(title: "There's nothing to export", message: "\(featureName(id)) has no lines, arcs or curves. Construction lines are left out.")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "dxf") ?? .data]
        panel.nameFieldStringValue = "\(featureName(id)).dxf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try DXFExport.data(solved).write(to: url, options: .atomic) } catch {
            alert = AlertInfo(title: "The export failed", message: "\(error.localizedDescription)")
        }
    }
    #endif

    /// Reads an SVG or DXF file into the sketch being edited, or else into a new sketch on the selected flat
    /// face or plane (the XY plane when nothing is selected), with the drawing's middle on the sketch
    /// origin. False if it can't be read (an alert says why).
    @discardableResult
    func importSVG(from url: URL) async -> Bool {
        guard !importInProgress() else { return false }
        isImporting = true
        let outcome = await Task.detached(priority: .userInitiated) { () -> Swift.Result<SVGImport.Result, any Error> in
            Swift.Result {
                let data = try Data(contentsOf: url)
                return url.pathExtension.lowercased() == "dxf" ? try DXFImport.sketch(from: data) : try SVGImport.sketch(from: data)
            }
        }.value
        isImporting = false
        let imported: SVGImport.Result
        switch outcome {
        case .success(let r): imported = r
        case .failure(let error):
            var reason = (error as? SVGImportError).map { $0.message } ?? error.localizedDescription
            reason = (reason.prefix(1).uppercased() + reason.dropFirst()) + "."
            alert = AlertInfo(title: "\(url.lastPathComponent) couldn't be imported", message: reason)
            return false
        }
        if sketchSession != nil {
            sketchCommand { session in
                session.merge(imported.sketch)
                return "Import \(url.lastPathComponent)"
            }
        } else {
            let plane = selectedFacePlane ?? .xy
            let frame: Frame
            do {
                frame = try Regenerator.sketchFrame(SketchFeature(plane: plane, sketch: Sketch()), result ?? RegenResult())
            } catch {
                alert = AlertInfo(title: "You can't sketch on that face",
                                  message: "Choose a flat face or one of the origin planes. (\(error))")
                return false
            }
            pendingTool = nil
            isPickingSketchPlane = false
            let feature = Feature(name: document.nextName("Sketch"),
                                  .sketch(SketchFeature(plane: plane, sketch: imported.sketch)))
            mutate("Import \(url.lastPathComponent)") { doc in
                doc.insertAtMarker(feature)
                doc.hidden.remove(feature.id)
            }
            selection = []
            selectedFeature = feature.id
            let hw = imported.width / 2, hh = imported.height / 2
            let corners = [(-hw, -hh), (hw, hh)].map { u, v -> SIMD3<Float> in
                let p = frame.origin + frame.xAxis * u + frame.yAxis * v
                return SIMD3(Float(p.x), Float(p.y), Float(p.z))
            }
            let n = frame.normal
            send(.lookFit(min: simd_min(corners[0], corners[1]), max: simd_max(corners[0], corners[1]),
                          normal: SIMD3(Float(n.x), Float(n.y), Float(n.z))))
        }
        if !imported.skipped.isEmpty {
            alert = AlertInfo(title: "Some of \(url.lastPathComponent) wasn't imported",
                              message: "Sketches hold lines, arcs and curves, so \(imported.skipped.joined(separator: " and ")) in the file were left out."
                              + (url.pathExtension.lowercased() == "dxf" ? " Splines can be saved as polylines in most CAD programs."
                                 : " Convert them to outlines first (in Inkscape: Path ▸ Object to Path)."))
        }
        return true
    }

    #if os(macOS)
    /// Exports the bodies, or just the ones with these ids, to an STL, 3MF or STEP file the user picks. `name` is the
    /// file name offered when the ids are a group (a folder) rather than one body.
    func export(bodies ids: [FeatureID]? = nil, name: String? = nil, format: ExportFormat) {
        let wanted = result?.bodies.filter { ids?.contains($0.id) ?? true } ?? []
        guard !wanted.isEmpty else {
            alert = name.map { AlertInfo(title: "There's nothing to export", message: "\($0) has no bodies in it.") }
                ?? AlertInfo(title: "There's nothing to export", message: "Create a body first, for example by extruding a sketch.")
            return
        }
        let panel = NSSavePanel()
        let ext = format.fileExtension
        if let type = UTType(filenameExtension: ext) { panel.allowedContentTypes = [type] }
        let partName = fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        let base = name ?? (ids == nil ? partName
            : (wanted.count == 1 ? bodies.first { $0.id == wanted[0].id }?.name : nil) ?? partName)
        panel.nameFieldStringValue = "\(base).\(ext)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(wanted, format: format, to: url)
    }
    #endif

    #if os(macOS)
    /// Exports every body in a folder (and in the folders inside it) as one STL or STEP file.
    func export(folder id: String, format: ExportFormat) {
        guard let folder = document.folder(id) else { return }
        export(bodies: bodies(inFolder: id).map(\.id), name: folder.name, format: format)
    }
    #endif

    /// Writes bodies to a file, alerting if that fails. False if it did.
    @discardableResult
    func write(_ bodies: [BodyResult], format: ExportFormat, to url: URL) -> Bool {
        do {
            let kernel = bodies.map(\.body)
            switch format {
            case .stl: try KBody.exportSTL(kernel, to: url)
            case .step: try KBody.exportSTEP(kernel, to: url)
            case .threeMF:
                try ThreeMF.write(bodies.map { (name: $0.name, body: $0.body, color: document.bodyColors[$0.id]) }, to: url)
            }
            return true
        } catch {
            alert = AlertInfo(title: "The export failed", message: "\(error)")
            return false
        }
    }
}
