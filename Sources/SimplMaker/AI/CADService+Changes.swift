// How an AI assistant changes a part. Every change is an operation (see Operations/AIOperation.swift) run through one
// transaction: the edit is made on a copy of the document, the copy is rebuilt on the side to see that it builds, and only then
// does the real document get it, in one step. So a change either happens whole, as one entry in Undo, or not at all; a half-made
// model never exists. The document is changed only through `DocumentModel.mutate`, the same path the interface uses (license
// check, undo, rebuild). The functions here are the single-operation entry points; the operations themselves are in Operations/.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation

extension CADService {
    struct BoxRequest {
        var width: String, length: String, height: String
        var u: String?, v: String?
        var plane: String?
        var name: String?
        var id: String?
        var operation: BodyOperation = .newBody
        var target: FeatureID?
    }

    func createBox(documentID: String, expectedRevision: Int? = nil, _ box: BoxRequest) async throws -> ChangeResult {
        try await change(documentID: documentID, expectedRevision: expectedRevision, CreateBoxOperation(box: box))
    }

    func modifyFeature(documentID: String, featureID: FeatureID, settings: [String: JSONValue], unlink: Bool,
                       expectedRevision: Int? = nil) async throws -> ChangeResult {
        let name = (try? resolve(documentID).model.document.features.first { $0.id == featureID })?.name
        return try await change(documentID: documentID, expectedRevision: expectedRevision,
                                ModifyFeatureOperation(featureID: featureID, settings: settings, unlink: unlink, featureName: name))
    }

    func setParameter(documentID: String, name: String, value: JSONValue, unit: UnitKind?, comment: String?,
                      expectedRevision: Int? = nil) async throws -> ChangeResult {
        try await change(documentID: documentID, expectedRevision: expectedRevision,
                         SetParameterOperation(name: name, value: value, unit: unit, comment: comment))
    }

    /// One operation, as one transaction.
    func change(documentID: String, expectedRevision: Int?, _ operation: any AIOperation) async throws -> ChangeResult {
        let (id, model, outcomes) = try await run(documentID: documentID, expectedRevision: expectedRevision, operations: [operation])
        return changeResult(id, model, outcomes[0])
    }

    /// Several operations, as one transaction and one undo step.
    func batch(documentID: String, expectedRevision: Int?, label: String?, _ operations: [any AIOperation]) async throws -> BatchResult {
        let (id, model, outcomes) = try await run(documentID: documentID, expectedRevision: expectedRevision, label: label, operations: operations)
        return batchResult(id, model, operations, outcomes)
    }

    // MARK: undo and redo

    func undo(documentID: String, expectedRevision: Int? = nil) async throws -> HistoryResult {
        try await step(documentID: documentID, expectedRevision: expectedRevision, undoing: true)
    }

    func redo(documentID: String, expectedRevision: Int? = nil) async throws -> HistoryResult {
        try await step(documentID: documentID, expectedRevision: expectedRevision, undoing: false)
    }

    private func step(documentID: String, expectedRevision: Int?, undoing: Bool) async throws -> HistoryResult {
        let (id, model) = try resolve(documentID)
        try refuseIfBusy(model)
        await model.rebuilt()
        try checkRevision(expectedRevision, current: model.documentRevision)
        guard let manager = model.undoManager else {
            throw AIError(.undoUnavailable, "This part has no undo history available (its window is not ready).", reason: "Ask the user to click in the SimplMaker window and try again.")
        }
        guard undoing ? manager.canUndo : manager.canRedo else {
            throw AIError(undoing ? .nothingToUndo : .nothingToRedo, undoing ? "There is nothing to undo." : "There is nothing to redo.",
                          reason: undoing ? "The undo history of this part is empty." : "Redo only works right after an undo, before anything else is changed.")
        }
        let name = (undoing ? manager.undoActionName : manager.redoActionName)
        model.aiActivity = undoing ? "Undoing" : "Redoing"
        defer { model.aiActivity = nil }
        if undoing { manager.undo() } else { manager.redo() }
        await model.rebuilt()
        let label = name.isEmpty ? "the last change" : name
        return HistoryResult(documentId: id, revision: model.documentRevision,
                             message: (undoing ? "Undid " : "Redid ") + label + ".", step: name,
                             featureCount: model.document.features.count, bodies: bodies(of: model))
    }
}
