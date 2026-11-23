// The Mold workspace's model: the molds of a part (`CADDocument.molds`), their halves (worked out by MoldBuilder after each
// rebuild of the part, never saved) and what the viewport draws in the workspace: the body ghosted inside its two halves. See
// docs/MOLD-PLAN.md for the plan. The screens are in MoldViews.swift.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import simd

/// A click on the body the viewport is waiting for.
enum MoldPick: Equatable {
    /// An air vent goes in at the spot (and the next click makes another one).
    case vent
    /// The gate goes in at the spot.
    case gate
}

extension DocumentModel {
    // MARK: what is drawn

    var activeMold: MoldSetup? { document.molds.first { $0.id == activeMoldID } ?? document.molds.first }
    var activeMoldResult: MoldResult? { activeMold.flatMap { moldResults[$0.id] } }

    /// The scene of the Mold workspace: the body (ghosted), the two halves, and a marker at the gate and each vent. While a spot is being
    /// picked, or in the Check view, the halves are left out: only the body and the markers.
    var moldShownMeshes: [BodyMesh] {
        if choosingWorkspaceBody { return meshes.filter { !document.hidden.contains($0.id) } }  // every body, to click the one to mold
        guard let id = activeMold?.id else { return [] }
        // The halves are on their way: the body alone until they land.
        guard let set = moldMeshSets[id] else { return meshes.filter { $0.id == activeMold?.body }.map { BodyMesh(index: 0, id: $0.id, name: $0.name, mesh: $0.mesh) } }
        return moldPicking == nil && !moldCheckView ? set : set.filter { !MoldSetup.isPiece($0.id) }
    }

    /// The pieces are drawn in calm tints, so they can be told apart (and from the body): blues behind the parting plane, warm ones in
    /// front of it, the second piece of each half a shade over; the markers in strong ones.
    func moldTint(of id: FeatureID) -> BodyColor? {
        guard id.hasPrefix("mold~") else { return nil }
        if id.hasSuffix("~gate") { return BodyColor(red: 0.80, green: 0.14, blue: 0.16) }
        if id.contains("~vent") { return BodyColor(red: 0.45, green: 0.20, blue: 0.78) }
        let second = id.hasSuffix("~b")
        if id.contains("~behind") { return second ? BodyColor(red: 0.55, green: 0.84, blue: 0.82) : BodyColor(red: 0.62, green: 0.76, blue: 0.93) }
        return second ? BodyColor(red: 0.94, green: 0.66, blue: 0.68) : BodyColor(red: 0.96, green: 0.78, blue: 0.56)
    }

    /// A body that has a mold shows through it, as a ghost; while a spot on it is picked, or in the Check view, it is solid.
    func moldGhostOpacity(of id: FeatureID) -> Double? {
        guard !choosingWorkspaceBody, document.molds.contains(where: { $0.body == id }) else { return nil }
        return moldPicking == nil && !moldCheckView ? 0.3 : 1
    }

    /// How far the pieces are drawn apart: along the parting normal (and, in a four-piece mold, along the second plane's too), the body
    /// and the markers staying where they are.
    var moldOpenOffsets: [SIMD3<Float>] {
        guard moldOpenAmount > 0, let r = activeMoldResult, r.isBuilt else { return [] }
        let shown = moldShownMeshes
        guard shown.contains(where: { MoldSetup.isPiece($0.id) }) else { return [] }
        let n = SIMD3<Float>(r.partingNormal)
        let distance = Float(moldOpenAmount) * Float(abs(simd_dot(r.blockSize, r.partingNormal)))
        var across = SIMD3<Float>.zero, acrossDistance: Float = 0
        if let m = r.crossNormal {
            across = SIMD3<Float>(m)
            acrossDistance = Float(moldOpenAmount) * Float(abs(simd_dot(r.blockSize, m)))
        }
        let pieces = Dictionary(r.pieces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return shown.map { mesh in
            guard let piece = pieces[mesh.id] else { return .zero }
            return n * Float(piece.side) * distance / 2 + across * Float(piece.crossSide) * acrossDistance / 2
        }
    }

    /// The Check view's colours: for each face of the body, whether the halves can let go of it.
    func moldCheckLooks(for visible: [BodyMesh]) -> [[Int: Renderer.FaceLook]] {
        guard let analysis = activeMoldResult?.analysis else { return [] }
        return visible.map { m in
            guard m.id == activeMold?.body else { return [:] }
            var out: [Int: Renderer.FaceLook] = [:]
            for (index, name) in m.mesh.faceNames.enumerated() {
                guard let release = analysis.faces[name] else { continue }
                out[index] = Renderer.FaceLook(color: Self.releaseColor(release), material: 0, roughness: -1)
            }
            return out
        }
    }

    static func releaseColor(_ release: MoldAnalysis.Release) -> SIMD4<Float> {
        switch release {
        case .free: SIMD4(0.42, 0.76, 0.52, 1)
        case .noDraft: SIMD4(0.96, 0.76, 0.30, 1)
        case .undercut: SIMD4(0.89, 0.30, 0.27, 1)
        }
    }

    /// What the status bar says in the Mold workspace: what a click does while a spot is being picked, else where things stand.
    var moldStatusText: String {
        if choosingWorkspaceBody { return bodies.isEmpty ? "This part has no body yet" : "Click the body you want to make a mold of" }
        switch moldPicking {
        case .vent?: return "Click on the body where an air vent goes (the top of a pocket the air would be trapped in) · Esc when done"
        case .gate?: return "Click on the body where the silicone goes in · Esc to cancel"
        case nil: break
        }
        if let note = moldNote { return note }
        if moldCheckView, activeMoldResult?.analysis != nil {
            return "Green: lets go · amber: parallel to the pull · red: undercut"
        }
        guard let mold = activeMold else {
            return document.molds.isEmpty ? "Make a mold from a body on the left" : "Choose a mold on the left"
        }
        if moldBuilding { return "Building \(mold.name)…" }
        guard let r = moldResults[mold.id] else { return "" }
        if let error = r.error { return error }
        return "\(mold.name) · \(r.warnings.isEmpty ? "ready to print" : "\(r.warnings.count) \(r.warnings.count == 1 ? "warning" : "warnings")") · drag to orbit"
    }

    // MARK: building

    /// The workspace was entered or left.
    func moldWorkspaceChanged(entering: Bool) {
        moldPicking = nil
        moldCheckView = false
        moldNote = nil
        choosingWorkspaceBody = entering && document.molds.isEmpty  // nothing made yet: the bodies are there to click
        if entering {
            if activeMoldID == nil || !document.molds.contains(where: { $0.id == activeMoldID }) { activeMoldID = document.molds.first?.id }
            // The Mold workspace has no timeline: it goes while the workspace is on, and comes back after it (if it was open).
            timelineHiddenByMold = showTimeline
            showTimeline = false
            if moldsStale || moldResults.isEmpty { rebuildMolds(fit: true) } else { sceneRevision += 1; fitRevision += 1 }
        } else {
            if timelineHiddenByMold {
                if renderView { panelsHiddenByRender.timeline = true } else { showTimeline = true }  // Render keeps its panels away until it is left
            }
            timelineHiddenByMold = false
            sceneRevision += 1
            fitRevision += 1
        }
        overlayRevision += 1
    }

    /// The body (or anything before it) was rebuilt: the molds made around it follow.
    func moldBodyChanged() {
        moldsStale = true
        if workspace == .mold { rebuildMolds() }
    }

    /// A mold was changed, made, deleted, or an undo did one of those.
    func moldSettingsChanged() {
        moldsStale = true
        if let id = activeMoldID, !document.molds.contains(where: { $0.id == id }) { activeMoldID = document.molds.first?.id }
        if workspace == .mold, document.molds.isEmpty, !choosingWorkspaceBody {  // the last mold went (an undo, say): back to choosing
            choosingWorkspaceBody = true
            sceneRevision += 1; fitRevision += 1; overlayRevision += 1
        }
        if workspace == .mold { rebuildMolds() }
    }

    /// Works out every mold again, on a background thread, and shows them when they are done. A newer request makes an older one's
    /// answer unwanted.
    func rebuildMolds(fit: Bool = false) {
        moldsStale = false
        let setups = document.molds
        guard let r = result else { return }  // the part's first rebuild is on its way; it comes back here when it lands
        guard !setups.isEmpty else {
            moldResults = [:]; moldMeshSets = [:]; moldBuilding = false
            sceneRevision += 1; overlayRevision += 1
            return
        }
        moldGeneration += 1
        let gen = moldGeneration
        moldBuilding = true
        let parts = Dictionary(uniqueKeysWithValues: setups.map { ($0.id, r.body($0.body)) })
        Task.detached(priority: .userInitiated) {
            guard KernelActivity.shared.begin() else { return }  // the app is quitting
            defer { KernelActivity.shared.end() }
            var results: [String: MoldResult] = [:]
            var halfMeshes: [String: [Mesh]] = [:]
            var markerMeshes: [String: [(id: String, name: String, mesh: Mesh)]] = [:]
            for setup in setups {
                var built: MoldResult
                if let part = parts[setup.id] ?? nil {
                    built = MoldBuilder.build(setup, part: part, in: r)
                } else {
                    built = MoldResult(setup: setup, error: "The body this mold is made around is gone.")
                }
                results[setup.id] = built
                halfMeshes[setup.id] = built.halves.compactMap { try? $0.body.tessellate() }
                markerMeshes[setup.id] = Self.markers(of: built)
            }
            await self.finishMolds(results, halfMeshes, markerMeshes, setups: setups, generation: gen, fit: fit)
        }
    }

    /// Small balls at the gate and at each vent, drawn so they can be seen and checked.
    nonisolated private static func markers(of r: MoldResult) -> [(id: String, name: String, mesh: Mesh)] {
        var points: [(String, String, SIMD3<Double>, Double)] = []
        if let gate = r.gatePoint { points.append(("gate", "Gate", gate, max(2.5, r.gateDiameter * 0.6))) }
        for (i, v) in r.ventPoints.enumerated() { points.append(("vent\(i)", "Vent \(i + 1)", v, max(2.5, r.ventDiameter * 1.5))) }
        return points.compactMap { key, name, at, size in
            guard let ball = try? KBody.primitive(.sphere(diameter: size), on: Frame(origin: at, normal: SIMD3(0, 0, 1), xAxis: SIMD3(1, 0, 0)), featureID: "marker"),
                  let mesh = try? ball.tessellate(linearDeflection: 0.1) else { return nil }
            return ("mold~\(r.setup.id)~\(key)", name, mesh)
        }
    }

    private func finishMolds(_ results: [String: MoldResult], _ halfMeshes: [String: [Mesh]], _ markerMeshes: [String: [(id: String, name: String, mesh: Mesh)]],
                             setups: [MoldSetup], generation gen: Int, fit: Bool) {
        guard gen == moldGeneration else { return }  // a newer build is on its way
        moldBuilding = false
        moldResults = results
        var sets: [String: [BodyMesh]] = [:]
        for setup in setups {
            var set: [BodyMesh] = []
            if let ghost = meshes.first(where: { $0.id == setup.body }) {
                set.append(BodyMesh(index: 0, id: ghost.id, name: ghost.name, mesh: ghost.mesh))
            }
            // The pieces come after the body, in the order they were made (behind the plane first).
            if let built = results[setup.id], let meshesOfHalves = halfMeshes[setup.id], !meshesOfHalves.isEmpty, meshesOfHalves.count == built.pieces.count {
                for (half, mesh) in zip(built.halves, meshesOfHalves) { set.append(BodyMesh(index: set.count, id: half.id, name: half.name, mesh: mesh)) }
            }
            for marker in markerMeshes[setup.id] ?? [] {
                set.append(BodyMesh(index: set.count, id: marker.id, name: marker.name, mesh: marker.mesh))
            }
            sets[setup.id] = set
        }
        moldMeshSets = sets
        if activeMoldID == nil || !setups.contains(where: { $0.id == activeMoldID }) { activeMoldID = setups.first?.id }
        sceneRevision += 1
        overlayRevision += 1
        if fit || fitAfterWorkspaceBuild { fitRevision += 1 }
        fitAfterWorkspaceBuild = false
    }

    // MARK: changing molds

    /// Makes a mold around a body and goes to the Mold workspace. The parting plane starts across the axis that leaves the least
    /// undercut (the shortest side among equals) and the mold is poured from above.
    func makeMold(of bodyID: FeatureID) {
        guard let body = result?.body(bodyID) else { return }
        let ext = body.bounds.map { $0.max - $0.min } ?? SIMD3(1, 1, 1)
        var axis: MoldAxis = ext.x <= ext.y && ext.x <= ext.z ? .x : ext.y <= ext.z ? .y : .z
        if let mesh = meshes.first(where: { $0.id == bodyID })?.mesh, let bounds = body.bounds { axis = MoldAnalysis.bestAxis(mesh, bounds: bounds) }
        let name = bodies.first { $0.id == bodyID }?.name ?? "Body"
        let taken = Set(document.molds.map(\.name))
        var title = "\(name) mold", n = 2
        while taken.contains(title) { title = "\(name) mold \(n)"; n += 1 }
        let setup = MoldSetup(name: title, body: bodyID, parting: .middle(axis))
        choosingWorkspaceBody = false
        mutate("Make Mold") { $0.molds.append(setup) }
        activeMoldID = setup.id
        if workspace == .mold {
            sceneRevision += 1; overlayRevision += 1
            fitAfterWorkspaceBuild = true  // fitted once the mold is there
        } else {
            setWorkspace(.mold)
        }
    }

    /// Make a Mold… from the palette: with one body there is nothing to choose, so the mold is made; with more the Mold workspace opens
    /// on its list of bodies. A mold already made for the part is shown instead of making a second one by accident.
    func startMold() {
        if document.molds.isEmpty, bodies.count == 1, let only = bodies.first {
            makeMold(of: only.id)
        } else {
            setWorkspace(.mold)
        }
    }

    /// Changes one mold's settings, as one undo step.
    func updateMold(_ id: String, _ action: String = "Change Mold", _ change: (inout MoldSetup) -> Void) {
        guard let i = document.molds.firstIndex(where: { $0.id == id }) else { return }
        var next = document.molds[i]
        change(&next)
        guard next != document.molds[i] else { return }
        moldNote = nil
        mutate(action) { $0.molds[i] = next }
    }

    func deleteMold(_ id: String) {
        mutate("Delete Mold") { $0.molds.removeAll { $0.id == id } }
        moldResults[id] = nil
        moldMeshSets[id] = nil
        if activeMoldID == id { activeMoldID = document.molds.first?.id }
        if document.molds.isEmpty { choosingWorkspaceBody = true; fitRevision += 1 }
        sceneRevision += 1
        overlayRevision += 1
    }

    func selectMold(_ id: String) {
        guard document.molds.contains(where: { $0.id == id }), activeMoldID != id || choosingWorkspaceBody else { return }
        choosingWorkspaceBody = false
        activeMoldID = id
        moldPicking = nil
        sceneRevision += 1
        fitRevision += 1
        overlayRevision += 1
    }

    /// The viewport has the spot a vent or the gate waits for.
    func placeMoldPoint(_ point: SIMD3<Double>) {
        guard let id = activeMold?.id, let pick = moldPicking else { return }
        switch pick {
        case .vent:
            updateMold(id, "Add Vent") { $0.vents.append(MoldPoint(point)) }
        case .gate:
            updateMold(id, "Move Gate") { $0.gatePoint = MoldPoint(point) }
            moldPicking = nil
        }
    }

    /// The Mold and Split workspaces show every body again, to click the one to work on (the other molds and splits stay in their lists).
    func startChoosingWorkspaceBody() {
        guard workspace == .mold || workspace == .split else { return }
        choosingWorkspaceBody = true
        moldPicking = nil
        moldCheckView = false
        sceneRevision += 1; fitRevision += 1; overlayRevision += 1
    }

    /// A click in the viewport while a body is being chosen: the body under the ray gets a mold (or a split), or, if it has one, shows it.
    func chooseWorkspaceBody(origin: SIMD3<Double>, direction: SIMD3<Double>) {
        guard choosingWorkspaceBody, let hit = nearestHit(origin: origin, direction: direction) else { return }
        let id = hit.mesh.id
        if workspace == .mold {
            if let existing = document.molds.first(where: { $0.body == id }) { selectMold(existing.id) } else { makeMold(of: id) }
        } else if workspace == .split {
            if let existing = document.printSplits.first(where: { $0.body == id }) { selectSplit(existing.id) } else { makeSplit(of: id) }
        }
    }

    /// Starts or stops waiting for a click on the body.
    func toggleMoldPick(_ pick: MoldPick) {
        moldPicking = moldPicking == pick ? nil : pick
        sceneRevision += 1
        overlayRevision += 1
    }

    /// The Check view on or off.
    func toggleMoldCheck() {
        moldCheckView.toggle()
        moldPicking = nil
        moldNote = nil
        sceneRevision += 1
        overlayRevision += 1
    }

    /// Adds a vent at the top of each lobe of the body that the gate does not reach (see `MoldVents`), unless one is there already.
    func addAutomaticVents() {
        guard let mold = activeMold, let r = moldResults[mold.id], let gate = r.gatePoint,
              let ghost = meshes.first(where: { $0.id == mold.body }) else { return }
        let found = MoldVents.suggest(ghost.mesh, up: mold.up.vector, gate: gate, gateRadius: max(r.gateDiameter, 8) / 2)
        let fresh = found.filter { p in !mold.vents.contains { simd_length($0.vector - p) < 5 } }
        if fresh.isEmpty {
            moldNote = found.isEmpty ? "No trapped air found: the body has just one top, where the gate is." : "The vents are there already."
            overlayRevision += 1
            return
        }
        moldNote = nil
        updateMold(mold.id, "Add Vents") { $0.vents += fresh.map { MoldPoint($0) } }
    }

    /// The parting planes the mold can be set to besides "across an axis through the middle": the origin planes and the construction
    /// planes that lie square to an axis.
    var moldPartingChoices: [(title: String, parting: MoldParting)] {
        var out: [(String, MoldParting)] = [("Across X, through the middle", .middle(.x)), ("Across Y, through the middle", .middle(.y)),
                                            ("Across Z, through the middle", .middle(.z)),
                                            ("Origin plane XY", .plane(.xy)), ("Origin plane XZ", .plane(.xz)), ("Origin plane YZ", .plane(.yz))]
        for feature in planeFeatures where result?.planes[feature.id] != nil {
            out.append((feature.name, .plane(.plane(feature.id))))
        }
        return out
    }
}
