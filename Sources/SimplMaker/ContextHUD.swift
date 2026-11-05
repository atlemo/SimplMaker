// The floating messages and buttons over the viewport while a feature is being made (Mac). The model side is in ContextActions.swift,
// which the iPad app shares.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import SwiftUI

extension View {
    /// A message that wraps at `width` and reports its wrapped height to a hosting view's
    /// `fittingSize`. A `maxWidth` frame doesn't: the fitting size then counts one line, and the
    /// panel around the text comes out too short. Short messages keep their natural width.
    @ViewBuilder fileprivate func errorWrap(_ text: String, width: CGFloat) -> some View {
        if text.count > 40 {
            fixedSize(horizontal: false, vertical: true).frame(width: width, alignment: .leading)
        } else {
            fixedSize()
        }
    }
}

/// The options panel under a feature's size field: how it combines with the body, flip, and
/// OK / Cancel — the choices that matter while sizing it, next to where you're looking.
struct FeatureHUD: View {
    let model: DocumentModel

    var body: some View {
        if let id = model.dragHandle?.featureID {
            VStack(alignment: .leading, spacing: DS.Spacing.space2) {
                // Why the typed size can't be used, right where the user is looking.
                if let problem = model.handleProblem ?? model.errorText(of: id) {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .errorWrap(problem, width: 320)
                }
                if let note = model.handleNote, note.feature == id, model.handleProblem == nil {
                    Text(note.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .errorWrap(note.text, width: 320)
                }
                controls(id)
            }
            .touchControls()
            .padding(DS.Spacing.space3)
            .panelGlass(in: .rect(cornerRadius: DS.Radius.xl2))
            .fixedSize()
        }
    }

    private func controls(_ id: FeatureID) -> some View {
        HStack(spacing: DS.Spacing.space3) {
            if let op = model.operation(of: id) {
                Picker("Operation", selection: Binding(get: { op }, set: { model.setOperation($0, of: id) })) {
                    ForEach(BodyOperation.allCases, id: \.self) { o in
                        Text(o == .newBody ? "New" : o.rawValue).tag(o)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Join adds to the body, Cut removes from it, New makes a separate body, Intersect keeps the overlap")
            }
            if model.isMoveFeature(id) {
                Picker("Type", selection: Binding(get: { model.isRotating(id) }, set: { model.setRotating($0, of: id) })) {
                    Text("Move").tag(false)
                    Text("Rotate").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("What the typed value sets: a distance to move, or an angle to turn")
            }
            if let axis = model.transformAxis(id) {
                Picker("Axis", selection: Binding(get: { axis }, set: { model.setTransformAxis($0, of: id) })) {
                    ForEach(Axis3.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("The axis to move along or turn about")
            }
            if let flipped = model.isFlipped(id) {
                Toggle(isOn: Binding(get: { flipped }, set: { _ in model.toggleFlip(id) })) {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .toggleStyle(.button)
                .help("Flip the direction")
            }
            if model.canStartOnFace(id) {
                let start = model.startFace(of: id)
                Menu {
                    Button("Start from the Selected Face") {
                        if let face = model.selectedFlatFace { model.setStartFace(face, of: id) }
                    }
                    .disabled(model.selectedFlatFace == nil)
                    Button("Start on the Profile's Plane") { model.setStartFace(nil, of: id) }
                        .disabled(start == nil)
                } label: {
                    Label(start == nil ? "Start" : "From Face", systemImage: "arrow.up.to.line")
                }
                .menuStyle(.button)
                .fixedSize()
                .help("Extrude from a face of a body instead of from the profile's own plane: select a flat face parallel to the sketch, then choose it here")
            }
            if model.newFeature == id {
                Button("Cancel") { model.cancelNewFeature() }
                    .help("Remove this new feature (Esc in the field only undoes the typing)")
            }
            // No default-button shortcut: it would take Return from the size field before the
            // field could store what was typed. Return in the field already means OK.
            Button("OK") { model.finishFeatureEdit() }
                .help("Done (Return)")
        }
    }
}

/// The Pattern tool's options, under its fields: rectangular or circular, what is wrong with the
/// settings, and OK / Cancel.
struct SketchPatternHUD: View {
    let model: DocumentModel

    var body: some View {
        if let session = model.sketchSession, session.isOffsetting {
            VStack(alignment: .leading, spacing: DS.Spacing.space2) {
                if let problem = session.message ?? session.offsetProblem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .errorWrap(problem, width: 280)
                }
                HStack(spacing: DS.Spacing.space3) {
                    Text("Offset").font(.caption.weight(.semibold))
                    Button("Cancel") {
                        session.cancelOffset()
                        model.overlayRevision += 1
                    }
                    .help("Take the offset back (Esc)")
                    Button("OK") { model.commitSketchTyped() }
                        .help("Keep the offset (Return)")
                }
            }
            .touchControls()
            .padding(DS.Spacing.space3)
            .panelGlass(in: .rect(cornerRadius: DS.Radius.xl2))
            .fixedSize()
        } else if let session = model.sketchSession, let setup = session.patternSetup {
            VStack(alignment: .leading, spacing: DS.Spacing.space2) {
                if let problem = session.message ?? session.patternProblem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .errorWrap(problem, width: 280)
                }
                HStack(spacing: DS.Spacing.space3) {
                    Picker("Pattern", selection: Binding(get: { setup.kind }, set: { kind in
                        session.setPatternKind(kind)
                        model.overlayRevision += 1
                    })) {
                        ForEach(SketchPatternDef.Kind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Copy in a grid, or around a point")
                    if !session.patternIsNew {
                        Button("Delete") { model.commitSketch(session.deletePattern()) }
                            .help("Remove the pattern's copies (⌫)")
                    }
                    Button("Cancel") {
                        session.cancelPattern()
                        model.overlayRevision += 1
                    }
                    Button("OK") { model.commitSketchTyped() }
                        .help("Keep the pattern (Return)")
                }
            }
            .touchControls()
            .padding(DS.Spacing.space3)
            .panelGlass(in: .rect(cornerRadius: DS.Radius.xl2))
            .fixedSize()
        }
    }
}

/// The sketch Mirror tool's choices: the line is clicked in the sketch, or an axis is chosen here.
struct SketchMirrorBar: View {
    let model: DocumentModel

    var body: some View {
        if let session = model.sketchSession, let setup = session.mirrorSetup {
            HStack(spacing: DS.Spacing.space3) {
                if let problem = session.message {
                    Text(problem)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .errorWrap(problem, width: 320)
                } else {
                    Text(session.mirrorLineName.map { "Mirror across \($0)" } ?? "Click the line to mirror across")
                        .font(.callout.weight(.medium))
                }
                axisButton("X Axis", SketchMirrorDef.xAxis, setup, session, help: "Mirror across the sketch's x axis (up and down swap)")
                axisButton("Y Axis", SketchMirrorDef.yAxis, setup, session, help: "Mirror across the sketch's y axis (left and right swap)")
                if !session.mirrorIsNew {
                    Button("Delete") { model.commitSketch(session.deleteMirror()); model.overlayRevision += 1 }
                        .help("Remove the mirror image (⌫)")
                }
                Button("Cancel") {
                    session.cancelMirror()
                    model.overlayRevision += 1
                }
                .help("Take the mirror back (Esc)")
                Button("OK") { model.commitSketchTyped() }
                    .disabled(setup.line == "")
                    .help("Keep the mirror (Return)")
            }
            .touchControls()
            .padding(.horizontal, DS.Spacing.space4)
            .padding(.vertical, DS.Spacing.space2)
            .panelGlass(in: Capsule())
            .fixedSize()
            .transition(.opacity)
        }
    }

    private func axisButton(_ title: String, _ axis: EntityID, _ setup: SketchMirrorDef, _ session: SketchSession, help: String) -> some View {
        Button(title) {
            session.setMirrorLine(axis)
            model.overlayRevision += 1
        }
        .buttonStyle(.bordered)
        .tint(setup.line == axis ? .accentColor : nil)
        .help(help)
    }
}

/// OK and Cancel for a feature with no drag handle to carry them (see DocumentModel.featureWithoutHandle).
struct FeatureDoneBar: View {
    let model: DocumentModel

    var body: some View {
        if let id = model.featureWithoutHandle {
            HStack(spacing: DS.Spacing.space3) {
                if let problem = model.errorText(of: id) {
                    Text(problem)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .errorWrap(problem, width: 420)
                } else {
                    Text(model.featureName(id))
                        .font(.callout.weight(.medium))
                    Text("Set it up in the inspector")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if model.newFeature == id {
                    Button("Cancel") { model.cancelNewFeature() }
                        .help("Remove this new feature")
                }
                Button("OK") { model.finishFeatureEdit() }
                    .help("Done (Return)")
            }
            .touchControls()
            .padding(.horizontal, DS.Spacing.space4)
            .padding(.vertical, DS.Spacing.space2)
            .panelGlass(in: .capsule)
            .fixedSize()
            .transition(.opacity)
        }
    }
}
