// The first operations: a box, a change to a feature's settings, a named parameter. (Sketches, extrudes: their own files.)
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation

struct CreateBoxOperation: AIOperation {
    let box: CADService.BoxRequest
    var toolName: String { "create_box" }
    var label: String { "Create \(name ?? "Box")" }
    var activity: String { "Creating \(name ?? "a box")" }
    private var name: String? { box.name?.trimmingCharacters(in: .whitespaces).nonEmpty }

    func apply(to doc: inout CADDocument, context: OperationContext) throws -> OperationOutcome {
        try CADService.refuseRolledBack(doc)
        let values = context.values
        for (field, text) in [("width", box.width), ("length", box.length), ("height", box.height)] {
            _ = try AIValues.evaluate(text, kind: .length, field: field, positive: true, values: values)
        }
        for (field, text) in [("u", box.u), ("v", box.v)] {
            if let text { _ = try AIValues.evaluate(text, kind: .length, field: field, positive: false, values: values) }
        }
        let plane = try box.plane.map { try AIValues.plane($0, in: doc) } ?? .xy
        if let target = box.target {
            guard doc.features.contains(where: { $0.id == target && $0.createsBody }) else {
                throw AIError(.invalidArguments, "target \"\(target)\" is not a body.", reason: "Use the id of a body from get_document.")
            }
        }
        if box.operation != .newBody, !doc.features.contains(where: \.createsBody) {
            throw AIError(.invalidArguments, "operation \"\(box.operation.rawValue)\" needs a body to work on, and the part has none.",
                          reason: "Use operation \"new_body\" for the first body.")
        }
        let featureID = try AIValues.newFeatureID(box.id, in: doc)
        let featureName = name ?? doc.nextName("Box")
        let primitive = PrimitiveFeature(kind: .box, plane: plane, u: box.u ?? "0 mm", v: box.v ?? "0 mm", width: box.width,
                                         length: box.length, height: box.height, operation: box.operation, target: box.target)
        doc.addFeature(Feature(id: featureID, name: featureName, .primitive(primitive)))
        return OperationOutcome(featureID: featureID, message: "Created \(featureName): a \(box.width) × \(box.length) × \(box.height) box.")
    }
}

struct ModifyFeatureOperation: AIOperation {
    let featureID: FeatureID
    let settings: [String: JSONValue]
    let unlink: Bool
    /// The feature's name, for the status bar and Undo (the caller looked it up).
    var featureName: String?
    var toolName: String { "modify_feature" }
    var label: String { "Change \(featureName ?? "Feature")" }
    var activity: String { "Changing \(featureName ?? "a feature")" }

    func apply(to doc: inout CADDocument, context: OperationContext) throws -> OperationOutcome {
        guard !settings.isEmpty else {
            throw AIError(.invalidArguments, "parameters is empty: there is nothing to change.", reason: "Pass at least one setting, for example {\"width\": 120}.")
        }
        guard let index = doc.index(of: featureID) else {
            throw AIError(.featureNotFound, "There is no feature with the id \(featureID).", reason: "Call get_document for the features that exist.")
        }
        let feature = doc.features[index]
        let specs = FeatureFields.specs(for: feature.kind)
        guard !specs.isEmpty else {
            throw AIError(.unsupportedFeature, "\(feature.name) is a \(feature.typeName), which can be read but not yet changed by an assistant.",
                          reason: "Features that can be changed so far: \(FeatureFields.supportedTypes). Named parameters can always be changed with set_parameter.")
        }
        var kind = feature.kind
        var changes: [ChangeInfo] = []
        let describer = FeatureDescriber(values: context.values)
        for (name, raw) in settings.sorted(by: { $0.key < $1.key }) {
            guard let spec = specs.first(where: { $0.name == name }) else {
                throw AIError(.unknownField, "\(feature.name) (\(feature.typeName)) has no setting called \"\(name)\".",
                              reason: "Settings that can be changed: \(specs.map(\.name).joined(separator: ", ")).")
            }
            if spec.isText {
                guard let words = raw.string?.trimmingCharacters(in: .whitespacesAndNewlines), !words.isEmpty, words.count <= 200 else {
                    throw AIError(.invalidValue, "\(name) must be some text of 1 to 200 letters.")
                }
                let old = spec.read(kind) ?? ""
                guard old != words else { continue }
                changes.append(ChangeInfo(field: name, before: .text(old), after: .text(words)))
                spec.write(&kind, words)
                continue
            }
            let expression = try AIValues.expression(raw, kind: spec.unit, field: name)
            _ = try AIValues.evaluate(expression, kind: spec.unit, field: name, positive: spec.positive, values: context.values)
            let old = spec.read(kind) ?? ""
            // A size that follows a parameter isn't quietly turned into a fixed number.
            if DocumentModel.isParametric(old), !DocumentModel.isParametric(expression), !unlink {
                let names = ((try? Expressions.parse(old))?.references ?? []).sorted().joined(separator: ", ")
                throw AIError(.parameterLinked, "\(name) of \(feature.name) follows the expression \"\(old)\" (parameter: \(names)), so it was not replaced by the fixed value \(expression).",
                              reason: "Change the parameter with set_parameter so everything that uses it follows, or pass unlink: true to replace the link with the fixed value, or send an expression that keeps the link.")
            }
            guard old != expression else { continue }
            changes.append(ChangeInfo(field: name, before: Self.field(old, spec, describer), after: Self.field(expression, spec, describer)))
            spec.write(&kind, expression)
        }
        guard !changes.isEmpty else {
            throw AIError(.invalidValue, "Every value asked for is what \(feature.name) already has.", reason: "Nothing was changed.")
        }
        // A text that is made bigger or smaller keeps its middle where it was.
        if case .sketch(var after) = kind, case .sketch(let before) = feature.kind {
            SketchBuilder.keepTextCentres(from: before.sketch, in: &after.sketch, values: context.values)
            kind = .sketch(after)
        }
        doc.features[index].kind = kind
        let summary = changes.map { "\($0.field) \(Self.text($0.before)) → \(Self.text($0.after))" }.joined(separator: ", ")
        return OperationOutcome(featureID: featureID, changes: changes, message: "Changed \(feature.name): \(summary).")
    }

    static func field(_ expression: String, _ spec: FieldSpec, _ describer: FeatureDescriber) -> FeatureField {
        switch spec.unit {
        case .length: return describer.length(expression)
        case .angle: return describer.angle(expression)
        case .none: return describer.number(expression)
        }
    }

    static func text(_ f: FeatureField?) -> String {
        switch f {
        case .quantity(let expression, _, _)?: return expression
        case .text(let words)?: return "\"\(words)\""
        default: return "—"
        }
    }
}

struct SetParameterOperation: AIOperation {
    let name: String
    let value: JSONValue
    let unit: UnitKind?
    let comment: String?
    var toolName: String { "set_parameter" }
    var label: String { "Set \(name)" }
    var activity: String { "Setting \(name)" }

    func apply(to doc: inout CADDocument, context: OperationContext) throws -> OperationOutcome {
        guard ParameterEvaluator.isValidName(name) else {
            throw AIError(.invalidArguments, "\"\(name)\" is not a valid parameter name.",
                          reason: Expressions.isReserved(name) ? "It is already a unit, constant or function name."
                                                                : "A name starts with a letter or underscore and has only letters, digits and underscores.")
        }
        let existing = doc.parameters.first { $0.name == name }
        let kind = unit ?? existing?.unit ?? .length
        let expression = try AIValues.expression(value, kind: kind, field: "value")
        var trial = doc
        if existing != nil {
            trial.setParameterExpression(name, expression, values: context.values)
            if let unit, let i = trial.parameters.firstIndex(where: { $0.name == name }) { trial.parameters[i].unit = unit }
        } else {
            var p = Parameter(name, expression, unit: kind)
            p.comment = comment ?? ""
            trial.parameters.append(p)
            // An expression that is plainly a length or an angle makes the parameter one, as in the parameter list.
            trial.setParameterExpression(name, expression, values: ParameterEvaluator.evaluate(trial.parameters))
            if let unit, let i = trial.parameters.firstIndex(where: { $0.name == name }) { trial.parameters[i].unit = unit }
        }
        if let comment, existing != nil, let i = trial.parameters.firstIndex(where: { $0.name == name }) { trial.parameters[i].comment = comment }
        let after = ParameterEvaluator.evaluate(trial.parameters)
        if let problem = after.errors[name] {
            throw AIError(.invalidValue, "\"\(expression)\" is not a valid value for \(name): \(problem).",
                          reason: "Send a number, or an expression using other parameters and units such as mm, cm, in, deg.")
        }
        // A parameter that other parameters or features use can't be given a value they would choke on.
        if let broken = after.errors.first(where: { $0.key != name }) {
            throw AIError(.invalidValue, "Setting \(name) to \"\(expression)\" would leave the parameter \(broken.key) without a value: \(broken.value).")
        }
        doc = trial
        return OperationOutcome(parameter: name, message: existing != nil ? "Set \(name) to \(expression) (was \(existing!.expression))."
                                                                           : "Created the parameter \(name) = \(expression).")
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// Removes a feature from the timeline. Features built from it (an extrude of a sketch, a fillet of a body) would lose what they
/// stand on, so they are listed and the deletion refused, unless the caller says to remove them too.
struct DeleteFeatureOperation: AIOperation {
    let featureID: FeatureID
    let withChildren: Bool
    var featureName: String?
    var toolName: String { "delete_feature" }
    var label: String { "Delete \(featureName ?? "Feature")" }
    var activity: String { "Deleting \(featureName ?? "a feature")" }

    func apply(to doc: inout CADDocument, context: OperationContext) throws -> OperationOutcome {
        guard let feature = doc.features.first(where: { $0.id == featureID }) else {
            throw AIError(.featureNotFound, "There is no feature with the id \(featureID).", reason: "Call get_document for the features that exist.")
        }
        // Everything built from it, and from those, in timeline order.
        var doomed: Set<FeatureID> = [featureID]
        var grew = true
        while grew {
            grew = false
            for f in doc.features where !doomed.contains(f.id) && !f.references.isDisjoint(with: doomed) { doomed.insert(f.id); grew = true }
        }
        let dependents = doc.features.filter { doomed.contains($0.id) && $0.id != featureID }
        if !dependents.isEmpty, !withChildren {
            throw AIError(.hasDependents, "\(feature.name) cannot be deleted on its own: \(dependents.map(\.name).joined(separator: ", ")) \(dependents.count == 1 ? "is" : "are") built from it.",
                          reason: "Delete those first, or pass with_children: true to delete \(feature.name) and everything built from it.")
        }
        let removed = doc.features.filter { doomed.contains($0.id) }
        for f in removed {
            guard let i = doc.index(of: f.id) else { continue }
            doc.features.remove(at: i)
            if let r = doc.rollback, i < r { doc.rollback = r - 1 }  // the marker stays after the same features
        }
        if doc.rollback == doc.features.count { doc.rollback = nil }
        // Sketches that were hidden because what was deleted used them show again; the removed things lose their names, colours and materials.
        let stillUsed = Set(doc.features.flatMap(\.sketchesUsed))
        for f in removed {
            for sketch in f.sketchesUsed where !stillUsed.contains(sketch) { doc.hidden.remove(sketch) }
            doc.hidden.remove(f.id); doc.bodyNames[f.id] = nil; doc.bodyColors[f.id] = nil; doc.bodyMaterials[f.id] = nil
        }
        return OperationOutcome(message: "Deleted " + removed.map(\.name).joined(separator: ", ") + ".")
    }
}
