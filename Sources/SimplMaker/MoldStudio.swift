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

    /// The scene of the Mold workspace: the body (ghosted), then the two halves. While a spot is being picked, only the body.
    var moldShownMeshes: [BodyMesh] {
        guard let id = activeMold?.id, let set = moldMeshSets[id] else { return [] }
        return moldPicking == nil ? set : Array(set.prefix(1))
    }

    /// The halves are drawn in two calm tints, so they can be told apart (and from the body).
    func moldTint(of id: FeatureID) -> BodyColor? {
        guard id.hasPrefix("mold~") else { return nil }
        return id.hasSuffix("~behind") ? BodyColor(red: 0.62, green: 0.76, blue: 0.93) : BodyColor(red: 0.96, green: 0.78, blue: 0.56)
    }

    /// A body that has a mold shows through it, as a ghost; while a spot on it is picked it is solid.
    func moldGhostOpacity(of id: FeatureID) -> Double? {
        guard document.molds.contains(where: { $0.body == id }) else { return nil }
        return moldPicking == nil ? 0.3 : 1
    }

    /// How far the halves are drawn apart: along the parting normal, the body staying where it is.
    var moldOpenOffsets: [SIMD3<Float>] {
        guard moldOpenAmount > 0, let r = activeMoldResult, r.isBuilt, moldShownMeshes.count == 3 else { return [] }
        let n = SIMD3<Float>(r.partingNormal)
        let distance = Float(moldOpenAmount) * Float(abs(simd_dot(r.blockSize, r.partingNormal)))
        return [.zero, -n * distance / 2, n * distance / 2]
    }

    /// What the status bar says in the Mold workspace: what a click does while a spot is being picked, else where things stand.
    var moldStatusText: String {
        switch moldPicking {
        case .vent?: return "Click on the body where an air vent goes (the top of a pocket the air would be trapped in) · Esc when done"
        case .gate?: return "Click on the body where the silicone goes in · Esc to cancel"
        case nil: break
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
        if entering {
            if activeMoldID == nil || !document.molds.contains(where: { $0.id == activeMoldID }) { activeMoldID = document.molds.first?.id }
            // The Mold workspace has no timeline: it goes while the workspace is on, and comes back after it (if it was open).
            timelineHiddenByMold = showTimeline
            showTimeline = false
            if moldsStale || moldResults.isEmpty { rebuildMolds(fit: true) } else { sceneRevision += 1; fitRevision += 1 }
        } else {
            if timelineHiddenByMold { showTimeline = true }
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
            for setup in setups {
                var built: MoldResult
                if let part = parts[setup.id] ?? nil {
                    built = MoldBuilder.build(setup, part: part, in: r)
                } else {
                    built = MoldResult(setup: setup, error: "The body this mold is made around is gone.")
                }
                results[setup.id] = built
                halfMeshes[setup.id] = built.halves.compactMap { try? $0.body.tessellate() }
            }
            await self.finishMolds(results, halfMeshes, setups: setups, generation: gen, fit: fit)
        }
    }

    private func finishMolds(_ results: [String: MoldResult], _ halfMeshes: [String: [Mesh]], setups: [MoldSetup], generation gen: Int, fit: Bool) {
        guard gen == moldGeneration else { return }  // a newer build is on its way
        moldBuilding = false
        moldResults = results
        var sets: [String: [BodyMesh]] = [:]
        for setup in setups {
            var set: [BodyMesh] = []
            if let ghost = meshes.first(where: { $0.id == setup.body }) {
                set.append(BodyMesh(index: 0, id: ghost.id, name: ghost.name, mesh: ghost.mesh))
            }
            // The halves come after the body, in the order they were made (behind, then in front).
            if let built = results[setup.id], let meshesOfHalves = halfMeshes[setup.id], meshesOfHalves.count == 2 {
                for (half, mesh) in zip(built.halves, meshesOfHalves) { set.append(BodyMesh(index: set.count, id: half.id, name: half.name, mesh: mesh)) }
            }
            sets[setup.id] = set
        }
        moldMeshSets = sets
        if activeMoldID == nil || !setups.contains(where: { $0.id == activeMoldID }) { activeMoldID = setups.first?.id }
        sceneRevision += 1
        overlayRevision += 1
        if fit { fitRevision += 1 }
    }

    // MARK: changing molds

    /// Makes a mold around a body and goes to the Mold workspace. The parting plane starts across the body's shortest side (so the
    /// halves meet over its biggest outline) and the mold is poured from above.
    func makeMold(of bodyID: FeatureID) {
        guard let body = result?.body(bodyID) else { return }
        let ext = body.bounds.map { $0.max - $0.min } ?? SIMD3(1, 1, 1)
        let axis: MoldAxis = ext.x <= ext.y && ext.x <= ext.z ? .x : ext.y <= ext.z ? .y : .z
        let name = bodies.first { $0.id == bodyID }?.name ?? "Body"
        let taken = Set(document.molds.map(\.name))
        var title = "\(name) mold", n = 2
        while taken.contains(title) { title = "\(name) mold \(n)"; n += 1 }
        let setup = MoldSetup(name: title, body: bodyID, parting: .middle(axis))
        mutate("Make Mold") { $0.molds.append(setup) }
        activeMoldID = setup.id
        if workspace == .mold {
            fitRevision += 1
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
        mutate(action) { $0.molds[i] = next }
    }

    func deleteMold(_ id: String) {
        mutate("Delete Mold") { $0.molds.removeAll { $0.id == id } }
        moldResults[id] = nil
        moldMeshSets[id] = nil
        if activeMoldID == id { activeMoldID = document.molds.first?.id }
        sceneRevision += 1
    }

    func selectMold(_ id: String) {
        guard activeMoldID != id, document.molds.contains(where: { $0.id == id }) else { return }
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

    /// Starts or stops waiting for a click on the body.
    func toggleMoldPick(_ pick: MoldPick) {
        moldPicking = moldPicking == pick ? nil : pick
        sceneRevision += 1
        overlayRevision += 1
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
