// A change an AI assistant can ask for, as a value that can be run on its own or together with others as one transaction.
// An operation edits a copy of the document and says what it did; it never touches the real document, the interface or the
// kernel. The runner (CADService.run) applies a list of them in order, rebuilding the copy on the side after each one so the next
// can look at what was built (a sketch's profiles, a body's faces), refuses the whole list if any step fails or leaves anything
// unbuildable, and gives the real document the result in a single undo step.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation

/// What an operation can look at while it works.
struct OperationContext {
    /// The part's parameters as the document stands before this operation.
    var values: ParameterValues
    /// The part built as it stands before this operation: bodies, solved sketches, errors.
    var built: RegenResult
}

/// What an operation did.
struct OperationOutcome {
    var featureID: FeatureID?
    var parameter: String?
    var changes: [ChangeInfo] = []
    var message = ""
    /// Something worth telling about what was made (the ids of a sketch's new shapes).
    var created: JSONValue?
}

@MainActor
protocol AIOperation: Sendable {
    /// The tool it belongs to, as the AI knows it.
    var toolName: String { get }
    /// The step's name in Undo ("Create Box1").
    var label: String { get }
    /// What the status bar says while it runs ("Creating Box1").
    var activity: String { get }
    func apply(to doc: inout CADDocument, context: OperationContext) throws -> OperationOutcome
}

extension CADService {
    // MARK: the runner

    /// Applies the operations in order to a copy of the document, and gives the document the result as one undo step.
    /// Nothing changes if the user is busy, the part has moved on since `expectedRevision`, any operation refuses, or
    /// anything that built before would no longer build.
    func run(documentID: String, expectedRevision: Int?, label: String? = nil, operations: [any AIOperation]) async throws
        -> (id: String, model: DocumentModel, outcomes: [OperationOutcome]) {
        guard !operations.isEmpty else {
            throw AIError(.invalidArguments, "There is nothing to do: the list of operations is empty.")
        }
        let (id, model) = try resolve(documentID)
        try refuseIfBusy(model)
        model.aiActivity = operations.count == 1 ? operations[0].activity : "Making \(operations.count) changes"
        defer { model.aiActivity = nil }
        await model.rebuilt()
        let revision = model.documentRevision
        try checkRevision(expectedRevision, current: revision)

        let before = model.result?.errors ?? [:]
        var doc = model.document
        var built = model.result ?? Regenerator.regenerate(doc)
        var outcomes: [OperationOutcome] = []
        for (index, operation) in operations.enumerated() {
            do {
                let context = OperationContext(values: ParameterEvaluator.evaluate(doc.parameters), built: built)
                outcomes.append(try operation.apply(to: &doc, context: context))
                // Build what it made on the side: the next step looks at it, and a failure stops everything here.
                let snapshot = doc
                built = await Task.detached(priority: .userInitiated) { Regenerator.regenerate(snapshot) }.value
                if let failure = Self.newFailure(in: built, comparedTo: before, document: doc) { throw failure }
            } catch var error as AIError {
                if operations.count > 1 {
                    error.message = "Step \(index + 1) of \(operations.count) (\(operation.toolName)): " + error.message
                    error.reason = (error.reason.map { $0 + " " } ?? "") + "None of the steps was applied."
                }
                throw error
            }
        }
        guard doc != model.document else {
            throw AIError(.invalidValue, "The change would leave the part exactly as it is.", reason: "Nothing was changed.")
        }

        // The user may have gone on working while that was built.
        try refuseIfBusy(model)
        guard model.documentRevision == revision else {
            throw AIError(.staleRevision, "The part was changed by the user while this change was being checked, so it was not applied.",
                          reason: "Read the part again with get_document and repeat the change if it still makes sense.")
        }
        model.mutate("AI: \(label ?? operations[0].label)") { $0 = doc }
        await model.rebuilt()
        return (id, model, outcomes)
    }

    func refuseIfBusy(_ model: DocumentModel) throws {
        if let activity = model.userActivity {
            throw AIError(.userBusy, "The user is in the middle of something in SimplMaker (\(activity)), so the part was not changed.",
                          reason: "Wait a moment and try again, or ask the user to finish or press Esc. Nothing of theirs was interrupted.")
        }
    }

    func checkRevision(_ expected: Int?, current: Int) throws {
        if let expected, expected != current {
            throw AIError(.staleRevision, "The part has changed since you read it (you had revision \(expected), it is at \(current)), so nothing was changed.",
                          reason: "The user probably edited it. Read it again with get_document, then decide whether the change still makes sense.")
        }
    }

    /// A feature that fails now and did not before: the change is refused, naming it and why.
    static func newFailure(in result: RegenResult, comparedTo before: [FeatureID: String], document doc: CADDocument) -> AIError? {
        let broken = doc.features.filter { result.errors[$0.id] != nil && before[$0.id] == nil && !$0.suppressed }
        guard let first = broken.first, let raw = result.errors[first.id] else { return nil }
        let reason = reasonText(raw, feature: first)
        let others = broken.dropFirst().map(\.name)
        return AIError(.rebuildFailed,
                       "The change was not applied: \(first.name) (\(first.typeName)) could not be built" + (others.isEmpty ? "." : ", and neither could \(others.joined(separator: ", "))."),
                       reason: reason + " The part is unchanged. Try a smaller or different value, or change the feature that fails.")
    }

    /// The kernel says "fillet: fillet failed (…)": drop the repeated name.
    static func reasonText(_ error: String, feature: Feature) -> String {
        let parts = error.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let text = parts.count == 2 && parts[0].lowercased() == feature.typeName.lowercased() ? parts[1] : error
        return text.prefix(1).uppercased() + text.dropFirst() + (text.hasSuffix(".") ? "" : ".")
    }

    static func refuseRolledBack(_ doc: CADDocument) throws {
        if let marker = doc.rollback, marker < doc.features.count {
            throw AIError(.timelineRolledBack, "The user has rolled the timeline back to position \(marker): a new feature would be inserted there and the features after it are not built.",
                          reason: "Ask the user to move the timeline marker to the end (or do so in SimplMaker), then try again.")
        }
    }

    // MARK: answers

    /// The answer for one change that went through.
    func changeResult(_ id: String, _ model: DocumentModel, _ outcome: OperationOutcome) -> ChangeResult {
        let describer = FeatureDescriber(values: model.parameterValues)
        let feature = outcome.featureID.flatMap { model.document.index(of: $0) }.map { featureInfo(at: $0, in: model, describer: describer) }
        let parameter = outcome.parameter.flatMap { name in parameters(of: model).first { $0.name == name } }
        let sketch = outcome.featureID.flatMap { sketchInfo($0, in: model, describer: describer) }
        return ChangeResult(documentId: id, revision: model.documentRevision, message: outcome.message, feature: feature,
                            parameter: parameter, changes: outcome.changes, created: outcome.created, sketch: sketch, bodies: bodies(of: model))
    }

    /// The answer for a list of changes.
    func batchResult(_ id: String, _ model: DocumentModel, _ operations: [any AIOperation], _ outcomes: [OperationOutcome]) -> BatchResult {
        let describer = FeatureDescriber(values: model.parameterValues)
        let steps = zip(operations, outcomes).enumerated().map { index, pair in
            BatchStep(step: index + 1, tool: pair.0.toolName, message: pair.1.message,
                      feature: pair.1.featureID.flatMap { model.document.index(of: $0) }.map { featureInfo(at: $0, in: model, describer: describer) },
                      parameter: pair.1.parameter.flatMap { name in parameters(of: model).first { $0.name == name } },
                      changes: pair.1.changes, created: pair.1.created,
                      sketch: pair.1.featureID.flatMap { sketchInfo($0, in: model, describer: describer) })
        }
        return BatchResult(documentId: id, revision: model.documentRevision,
                           message: "Made \(operations.count) changes as one undo step.", steps: steps, bodies: bodies(of: model))
    }
}
