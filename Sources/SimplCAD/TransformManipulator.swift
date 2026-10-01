// The Move/Rotate manipulator's side of the model: which feature it is on, where it sits, and what
// dragging one of its parts does to the feature (a live preview, then one undo step).
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import simd

/// The six numbers of a Move feature, by index: distances along X, Y, Z, then turns about X, Y, Z.
enum TransformKey: Int, CaseIterable {
    case dx, dy, dz, rx, ry, rz

    var label: String { ["X", "Y", "Z", "Rotate X", "Rotate Y", "Rotate Z"][rawValue] }
    var isTurn: Bool { rawValue >= 3 }

    func expression(in m: MoveFeature) -> String {
        switch self {
        case .dx: return m.dx
        case .dy: return m.dy
        case .dz: return m.dz
        case .rx: return m.rx
        case .ry: return m.ry
        case .rz: return m.rz
        }
    }

    func set(_ text: String, in m: inout MoveFeature) {
        switch self {
        case .dx: m.dx = text
        case .dy: m.dy = text
        case .dz: m.dz = text
        case .rx: m.rx = text
        case .ry: m.ry = text
        case .rz: m.rz = text
        }
    }

    func value(in v: TransformValues) -> Double { isTurn ? v.turn[rawValue - 3] : v.move[rawValue] }
}

extension DocumentModel {
    /// The selected Move feature, while nothing else is going on: the manipulator is shown on it.
    var manipulatedFeature: (id: FeatureID, move: MoveFeature)? {
        guard sketchSession == nil, pendingTool == nil, holeMoveStart == nil, result != nil, let id = selectedFeature,
              let f = document.features.first(where: { $0.id == id }), !f.suppressed, case .move(let m) = f.kind else { return nil }
        return (id, m)
    }

    func transformValues(_ m: MoveFeature) -> TransformValues {
        let p = parameterValues
        var v = TransformValues()
        for key in TransformKey.allCases {
            let x = (try? p.value(of: key.expression(in: m), kind: key.isTurn ? .angle : .length)) ?? 0
            if key.isTurn { v.turn[key.rawValue - 3] = x } else { v.move[key.rawValue] = x }
        }
        return v
    }

    /// What the manipulator shows: the values being dragged, or the stored ones.
    var manipulatorValues: TransformValues? {
        if let live = manipulatorLive { return live }
        return manipulatedFeature.map { transformValues($0.move) }
    }

    /// Where the manipulator sits: the middle of what the feature moves, as it was before, carried along
    /// by the move. Turns are about that middle before the move.
    func manipulatorMiddle(_ id: FeatureID, _ m: MoveFeature) -> SIMD3<Double>? {
        guard let result else { return nil }
        let bodies = Array((result.featureInputs[id] ?? [:]).values), sketches = Array((result.sketchInputs[id] ?? [:]).values)
        guard let c = Regenerator.center(of: bodies, sketches: sketches) else { return nil }
        return c + (manipulatorLive ?? transformValues(m)).move
    }

    var manipulatorMiddle: SIMD3<Double>? { manipulatedFeature.flatMap { manipulatorMiddle($0.id, $0.move) } }

    /// Where the manipulator is drawn and how it is laid out: on the selected Move feature, or, in a
    /// sketch, on what the Move or Rotate tool works on, in the sketch's plane.
    var manipulatorPlacement: (middle: SIMD3<Double>, turn: SIMD3<Double>, frame: ManipulatorFrame)? {
        if let session = sketchSession {
            guard let m = session.manipulatorMiddle else { return nil }
            if let setup = session.patternSetup {
                return (session.frame.point(m.x, m.y), session.patternValues?.turn ?? .zero,
                        ManipulatorFrame(pattern: setup.kind == .circular, sketch: session.frame))
            }
            return (session.frame.point(m.x, m.y), session.manipulatorValues.turn, ManipulatorFrame(sketch: session.frame))
        }
        guard let middle = manipulatorMiddle, let values = manipulatorValues else { return nil }
        return (middle, values.turn, .world)
    }

    /// What dragging starts from: a Move feature's stored values, or nothing yet for a sketch.
    var manipulatorDragStart: TransformValues? {
        if let session = sketchSession { return session.patternValues ?? (session.manipulating == nil ? nil : TransformValues()) }
        return manipulatedFeature.map { transformValues($0.move) }
    }

    /// The part the typed field is for.
    var manipulatorActivePart: ManipulatorPart? {
        if let session = sketchSession { return session.manipulating == .rotate ? .ring(.z) : nil }
        return manipulatedFeature.map { $0.move.rotating ? .ring($0.move.arrow) : .axis($0.move.arrow) }
    }

    /// Makes an arrow or ring the one the field types into. Not an undo step, and nothing to rebuild.
    func activateManipulatorPart(_ part: ManipulatorPart) {
        guard let (id, m) = manipulatedFeature else { return }
        var next = m
        switch part {
        case .axis(let a): next.arrow = a; next.rotating = false
        case .ring(let a): next.arrow = a; next.rotating = true
        case .plane, .center: return
        }
        guard next != m else { return }
        storeTypedSize()  // what was typed for the last one stays with it
        setPresentation(id) { $0.kind = .move(next) }
    }

    /// The mouse went down on a part. Returns the values to drag from.
    @discardableResult
    func beginManipulatorDrag(_ part: ManipulatorPart) -> TransformValues? {
        if let session = sketchSession { return session.beginManipulatorDrag(part) ? (session.patternValues ?? TransformValues()) : nil }
        guard let (_, m) = manipulatedFeature else { return nil }
        activateManipulatorPart(part)
        let v = transformValues(m)
        manipulatorStart = document
        manipulatorBase = v
        manipulatorLive = v
        return v
    }

    /// Shows the feature with the dragged values, without storing them.
    func previewManipulator(_ v: TransformValues) {
        if let session = sketchSession {
            session.previewManipulator(v)
            overlayRevision += 1
            return
        }
        guard let start = manipulatorStart, let base = manipulatorBase, let id = selectedFeature else { return }
        manipulatorLive = v
        var doc = start
        Self.write(changes(from: base, to: v), of: id, in: &doc)
        regenerate(preview: doc, previewFeature: id)
        overlayRevision += 1
    }

    /// The values that differ, by key.
    private func changes(from base: TransformValues, to v: TransformValues) -> [Int: Double] {
        var out: [Int: Double] = [:]
        for key in TransformKey.allCases where abs(key.value(in: v) - key.value(in: base)) > 1e-9 { out[key.rawValue] = key.value(in: v) }
        return out
    }

    static func write(_ values: [Int: Double], of id: FeatureID, in doc: inout CADDocument) {
        guard let i = doc.index(of: id), case .move(var m) = doc.features[i].kind else { return }
        for (k, v) in values {
            guard let key = TransformKey(rawValue: k) else { continue }
            key.set(formatDimension(v, kind: key.isTurn ? .angle : .length), in: &m)
        }
        doc.features[i].kind = .move(m)
    }

    /// The mouse came up: keep what was dragged (one undo step), or go back if it can't be built. A
    /// value that comes from a parameter asks before it is replaced by a number.
    func endManipulatorDrag() {
        if let session = sketchSession {
            if session.isPatterning { overlayRevision += 1; return }  // the copies stay open for more changes
            sketchCommand { $0.endManipulatorDrag() }
            return
        }
        guard manipulatorStart != nil else { return }
        let base = manipulatorBase, live = manipulatorLive
        manipulatorStart = nil
        manipulatorBase = nil
        guard let base, let live, let (id, m) = manipulatedFeature ?? selectedFeature.flatMap({ sel in
            document.features.first(where: { $0.id == sel }).flatMap { f in if case .move(let mm) = f.kind { return (sel, mm) } else { return nil } }
        }) else { manipulatorLive = nil; return }
        let changed = changes(from: base, to: live)
        if changed.isEmpty || previewInvalid {
            previewInvalid = false
            manipulatorLive = nil
            regenerate()  // nothing moved, or dropped where it can't be built: back to what was there
            overlayRevision += 1
            return
        }
        if let key = changed.keys.sorted().compactMap(TransformKey.init(rawValue:)).first(where: { Self.isParametric($0.expression(in: m)) }) {
            unlinkPrompt = UnlinkPrompt(featureID: id, label: key.label, unit: key.isTurn ? .angle : .length,
                                        expression: key.expression(in: m), value: key.value(in: live), transform: changed)
            return  // the preview stays on screen until the user answers
        }
        manipulatorLive = nil
        commitTransform(id, changed)
    }

    func commitTransform(_ id: FeatureID, _ changes: [Int: Double]) {
        let turns = changes.keys.contains { $0 >= 3 }, moves = changes.keys.contains { $0 < 3 }
        mutate(turns && moves ? "Move and Rotate" : turns ? "Rotate" : "Move") { Self.write(changes, of: id, in: &$0) }
        overlayRevision += 1
    }

    /// Whether a Move feature is turning (rather than sliding) what its typed field sets.
    func isRotating(_ id: FeatureID) -> Bool {
        if case .move(let m)? = document.features.first(where: { $0.id == id })?.kind { return m.rotating }
        return false
    }
}
