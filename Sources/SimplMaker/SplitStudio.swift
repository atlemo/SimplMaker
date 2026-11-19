// The Split workspace's model: the splits of a part (`CADDocument.printSplits`), their pieces (worked out by PrintSplitBuilder after
// each rebuild of the part, never saved) and what the viewport draws in the workspace: the pieces, each in a tint of its own, that
// can be drawn apart. The screens are in SplitViews.swift. It follows the Mold workspace's pattern (MoldStudio.swift).
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import simd

extension DocumentModel {
    // MARK: what is drawn

    var activeSplit: PrintSplit? { document.printSplits.first { $0.id == activeSplitID } ?? document.printSplits.first }
    var activeSplitResult: PrintSplitResult? { activeSplit.flatMap { splitResults[$0.id] } }

    /// The scene of the Split workspace: the pieces of the active split, side by side as they were cut.
    var splitShownMeshes: [BodyMesh] {
        if choosingWorkspaceBody { return meshes.filter { !document.hidden.contains($0.id) } }  // every body, to click the one to split
        guard let id = activeSplit?.id else { return [] }
        // The pieces are on their way: the body alone until they land.
        guard let set = splitMeshSets[id] else { return meshes.filter { $0.id == activeSplit?.body }.map { BodyMesh(index: 0, id: $0.id, name: $0.name, mesh: $0.mesh) } }
        return set
    }

    /// A calm set of tints, so neighbouring pieces can be told apart; a piece that does not fit the printer is red.
    private static let pieceTints: [BodyColor] = [
        BodyColor(red: 0.62, green: 0.76, blue: 0.93), BodyColor(red: 0.96, green: 0.78, blue: 0.56), BodyColor(red: 0.66, green: 0.85, blue: 0.68),
        BodyColor(red: 0.85, green: 0.71, blue: 0.90), BodyColor(red: 0.95, green: 0.86, blue: 0.55), BodyColor(red: 0.60, green: 0.84, blue: 0.84),
    ]
    static let pieceTooBig = BodyColor(red: 0.86, green: 0.30, blue: 0.27)

    /// The tint of a piece, by its place among the pieces (a checkerboard of the cells, so neighbours differ).
    func splitTint(of id: FeatureID) -> BodyColor? {
        guard id.hasPrefix("split~"), let r = activeSplitResult, let piece = r.pieces.first(where: { $0.id == id }) else { return nil }
        if !piece.fits { return Self.pieceTooBig }
        let parity = piece.cell.reduce(0, +)
        let slot = (parity + (piece.cell[2] * 2)) % Self.pieceTints.count
        return Self.pieceTints[slot]
    }

    /// How far each piece is drawn from where it was cut: away from the middle of the body along the grid, the pieces at the ends the most.
    var splitOpenOffsets: [SIMD3<Float>] {
        guard splitOpenAmount > 0, !choosingWorkspaceBody, let r = activeSplitResult, r.isBuilt else { return [] }
        return splitShownMeshes.map { shown in
            guard let piece = r.pieces.first(where: { $0.id == shown.id }) else { return .zero }
            var shift = SIMD3<Float>.zero
            for axis in 0..<3 {
                let n = Double(r.counts[axis])
                guard n > 1 else { continue }
                let each = r.bodySize[axis] / n
                shift[axis] = Float((Double(piece.cell[axis]) - (n - 1) / 2) * each * 0.6 * splitOpenAmount)
            }
            return shift
        }
    }

    /// What the status bar says in the Split workspace.
    var splitStatusText: String {
        if choosingWorkspaceBody { return bodies.isEmpty ? "This part has no body yet" : "Click the body you want to split" }
        if let note = splitNote { return note }
        guard let split = activeSplit else {
            return document.printSplits.isEmpty ? "Make a split from a body on the left" : "Choose a split on the left"
        }
        if splitBuilding { return "Cutting \(split.name)…" }
        guard let r = splitResults[split.id] else { return "" }
        if let error = r.error { return error }
        let pieces = "\(r.pieces.count) \(r.pieces.count == 1 ? "piece" : "pieces")"
        let state = r.allFit ? "all fit \(split.printerTitle)" : "\(r.pieces.filter { !$0.fits }.count) too big for \(split.printerTitle)"
        return "\(split.name) · \(pieces), \(state) · drag to orbit"
    }

    // MARK: building

    /// The workspace was entered or left.
    func splitWorkspaceChanged(entering: Bool) {
        splitNote = nil
        choosingWorkspaceBody = entering && document.printSplits.isEmpty  // nothing made yet: the bodies are there to click
        if entering {
            if activeSplitID == nil || !document.printSplits.contains(where: { $0.id == activeSplitID }) { activeSplitID = document.printSplits.first?.id }
            // The Split workspace has no timeline: it goes while the workspace is on, and comes back after it (if it was open).
            timelineHiddenBySplit = showTimeline
            showTimeline = false
            if splitsStale || splitResults.isEmpty { rebuildSplits(fit: true) } else { sceneRevision += 1; fitRevision += 1 }
        } else {
            if timelineHiddenBySplit {
                if renderView { panelsHiddenByRender.timeline = true } else { showTimeline = true }  // Render keeps its panels away until it is left
            }
            timelineHiddenBySplit = false
            sceneRevision += 1
            fitRevision += 1
        }
        overlayRevision += 1
    }

    /// The body (or anything before it) was rebuilt: the splits made of it follow.
    func splitBodyChanged() {
        splitsStale = true
        if workspace == .split { rebuildSplits() }
    }

    /// A split was changed, made, deleted, or an undo did one of those.
    func splitSettingsChanged() {
        splitsStale = true
        if let id = activeSplitID, !document.printSplits.contains(where: { $0.id == id }) { activeSplitID = document.printSplits.first?.id }
        if workspace == .split, document.printSplits.isEmpty, !choosingWorkspaceBody {  // the last split went (an undo, say): back to choosing
            choosingWorkspaceBody = true
            sceneRevision += 1; fitRevision += 1; overlayRevision += 1
        }
        if workspace == .split { rebuildSplits() }
    }

    /// Works out every split again, on a background thread, and shows them when they are done. A newer request makes an older one's
    /// answer unwanted.
    func rebuildSplits(fit: Bool = false) {
        splitsStale = false
        let setups = document.printSplits
        guard let r = result else { return }  // the part's first rebuild is on its way; it comes back here when it lands
        guard !setups.isEmpty else {
            splitResults = [:]; splitMeshSets = [:]; splitBuilding = false
            sceneRevision += 1; overlayRevision += 1
            return
        }
        splitGeneration += 1
        let gen = splitGeneration
        splitBuilding = true
        let parts = Dictionary(uniqueKeysWithValues: setups.map { ($0.id, r.body($0.body)) })
        Task.detached(priority: .userInitiated) {
            guard KernelActivity.shared.begin() else { return }  // the app is quitting
            defer { KernelActivity.shared.end() }
            var results: [String: PrintSplitResult] = [:]
            var meshes: [String: [(piece: PrintSplitPiece, mesh: Mesh)]] = [:]
            for setup in setups {
                var built: PrintSplitResult
                if let part = parts[setup.id] ?? nil {
                    built = PrintSplitBuilder.build(setup, part: part, in: r)
                } else {
                    built = PrintSplitResult(setup: setup, error: "The body this split is made of is gone.")
                }
                results[setup.id] = built
                meshes[setup.id] = built.pieces.compactMap { piece in (try? piece.body.tessellate()).map { (piece, $0) } }
            }
            await self.finishSplits(results, meshes, setups: setups, generation: gen, fit: fit)
        }
    }

    private func finishSplits(_ results: [String: PrintSplitResult], _ meshes: [String: [(piece: PrintSplitPiece, mesh: Mesh)]],
                              setups: [PrintSplit], generation gen: Int, fit: Bool) {
        guard gen == splitGeneration else { return }  // a newer build is on its way
        splitBuilding = false
        splitResults = results
        var sets: [String: [BodyMesh]] = [:]
        for setup in setups {
            var set: [BodyMesh] = []
            for (piece, mesh) in meshes[setup.id] ?? [] { set.append(BodyMesh(index: set.count, id: piece.id, name: piece.name, mesh: mesh)) }
            sets[setup.id] = set
        }
        splitMeshSets = sets
        if activeSplitID == nil || !setups.contains(where: { $0.id == activeSplitID }) { activeSplitID = setups.first?.id }
        sceneRevision += 1
        overlayRevision += 1
        if fit { fitRevision += 1 }
    }

    // MARK: changing splits

    /// Makes a split of a body and goes to the Split workspace.
    func makeSplit(of bodyID: FeatureID) {
        guard result?.body(bodyID) != nil else { return }
        let name = bodies.first { $0.id == bodyID }?.name ?? "Body"
        let taken = Set(document.printSplits.map(\.name))
        var title = "\(name) split", n = 2
        while taken.contains(title) { title = "\(name) split \(n)"; n += 1 }
        let setup = PrintSplit(name: title, body: bodyID)
        choosingWorkspaceBody = false
        mutate("Make Split") { $0.printSplits.append(setup) }
        activeSplitID = setup.id
        if workspace == .split {
            sceneRevision += 1; fitRevision += 1; overlayRevision += 1
        } else {
            setWorkspace(.split)
        }
    }

    /// Split to Print… from the palette: with one body there is nothing to choose, so the split is made; with more the Split workspace opens
    /// on its list of bodies. A split already made for the part is shown instead of making a second one by accident.
    func startSplit() {
        if document.printSplits.isEmpty, bodies.count == 1, let only = bodies.first {
            makeSplit(of: only.id)
        } else {
            setWorkspace(.split)
        }
    }

    /// Changes one split's settings, as one undo step.
    func updateSplit(_ id: String, _ action: String = "Change Split", _ change: (inout PrintSplit) -> Void) {
        guard let i = document.printSplits.firstIndex(where: { $0.id == id }) else { return }
        var next = document.printSplits[i]
        change(&next)
        guard next != document.printSplits[i] else { return }
        splitNote = nil
        mutate(action) { $0.printSplits[i] = next }
    }

    func deleteSplit(_ id: String) {
        mutate("Delete Split") { $0.printSplits.removeAll { $0.id == id } }
        splitResults[id] = nil
        splitMeshSets[id] = nil
        if activeSplitID == id { activeSplitID = document.printSplits.first?.id }
        if document.printSplits.isEmpty { choosingWorkspaceBody = true; fitRevision += 1 }
        sceneRevision += 1
        overlayRevision += 1
    }

    func selectSplit(_ id: String) {
        guard document.printSplits.contains(where: { $0.id == id }), activeSplitID != id || choosingWorkspaceBody else { return }
        choosingWorkspaceBody = false
        activeSplitID = id
        sceneRevision += 1
        fitRevision += 1
        overlayRevision += 1
    }

    /// Takes the cuts out of automatic hands: the split keeps the cuts it has now, as a list to edit. And back again.
    func setSplitCutsByHand(_ id: String, _ byHand: Bool) {
        guard let split = document.printSplits.first(where: { $0.id == id }) else { return }
        if byHand, let r = splitResults[id], r.isBuilt {
            updateSplit(id, "Cut by Hand") { $0.cuts = r.cuts }
        } else if byHand {
            updateSplit(id, "Cut by Hand") { $0.cuts = split.cuts ?? [] }
        } else {
            updateSplit(id, "Cut Automatically") { $0.cuts = nil }
        }
    }
}
