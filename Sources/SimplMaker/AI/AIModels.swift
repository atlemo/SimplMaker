// What the AI interface returns. Plain data, encoded to JSON by whoever carries it (keys in snake_case).
// Everything is in the document's units: millimetres and degrees. Expressions are kept as typed, next to
// the value they come to, so the AI can tell a size that follows a parameter ("wall") from a fixed one ("2 mm").
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation

/// One setting of a feature.
enum FeatureField: Encodable, Equatable {
    /// A number with an expression: `value` is nil if the expression doesn't evaluate. `unit` is "mm", "deg" or "".
    case quantity(expression: String, value: Double?, unit: String)
    case text(String)
    case flag(Bool)
    case list([String])

    private enum Keys: String, CodingKey { case expression, value, unit }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .quantity(let expression, let value, let unit):
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(expression, forKey: .expression)
            try c.encodeIfPresent(value, forKey: .value)
            if !unit.isEmpty { try c.encode(unit, forKey: .unit) }
        case .text(let s): var c = encoder.singleValueContainer(); try c.encode(s)
        case .flag(let b): var c = encoder.singleValueContainer(); try c.encode(b)
        case .list(let l): var c = encoder.singleValueContainer(); try c.encode(l)
        }
    }
}

struct DocumentSummary: Encodable, Equatable {
    var id: String
    var name: String
    /// Where the file is, nil for a part that hasn't been saved.
    var path: String?
    /// The document in the front window.
    var isActive: Bool
    var featureCount: Int
}

struct DocumentList: Encodable, Equatable {
    var documents: [DocumentSummary]
}

struct ParameterInfo: Encodable, Equatable {
    var name: String
    var expression: String
    /// "mm", "deg" or "" (a plain number).
    var unit: String
    var value: Double?
    var comment: String?
    /// Why it has no value (a bad expression, a circle of parameters).
    var error: String?
    /// The features that use it, in timeline order.
    var usedBy: [FeatureID]
}

struct BodyInfo: Encodable, Equatable {
    /// The id of the feature that made it; use it wherever a body is asked for.
    var id: FeatureID
    var name: String
    var visible: Bool
    var volume: Double
    var boundsMin: [Double]
    var boundsMax: [Double]
    var faceCount: Int
    var edgeCount: Int
    var isValid: Bool
}

struct DimensionInfo: Encodable, Equatable {
    var id: EntityID
    var kind: String
    /// The points or curves it measures.
    var refs: [EntityID]
    var field: FeatureField
}

struct ProfileInfo: Encodable, Equatable {
    /// Use this where a profile is asked for (extrude, revolve…).
    var id: String
    var area: Double
    /// A point inside it, in the sketch's own coordinates; {"at": inside} picks this profile too.
    var inside: [Double]
    /// Its extent in the sketch's own coordinates: [min u, min v, max u, max v]. How wide a text came out, for example.
    var bounds: [Double]
    /// Set when this profile lies inside another one: it is what fills a hole in that one (the disc inside a ring, the inside of an
    /// o). Extrude it only to fill the hole; for the shape itself, leave it out.
    var insideProfile: String?
}

struct TextInfo: Encodable, Equatable {
    /// The shape id; its settings are "<id>.text", "<id>.height", "<id>.x" and "<id>.y".
    var id: String
    var text: String
    var height: FeatureField
    var font: String
}

struct SketchInfo: Encodable, Equatable {
    var points: Int
    var curves: Int
    var constraints: Int
    var texts: [TextInfo]
    var dimensions: [DimensionInfo]
    var profiles: [ProfileInfo]
    /// Free-moving parts left in the sketch (0 = fully constrained); nil if it hasn't been solved.
    var degreesOfFreedom: Int?
}

struct FeatureInfo: Encodable, Equatable {
    var id: FeatureID
    /// "Sketch", "Extrude", "Box", "Fillet"…
    var type: String
    var name: String
    var index: Int
    var suppressed: Bool
    /// "ok", "error", "suppressed" or "rolled_back" (after the timeline marker, so not built now).
    var status: String
    var error: String?
    /// Whether it makes a new body; that body's id is then this feature's id.
    var createsBody: Bool
    var parameters: [String: FeatureField]
    /// The features it is built from.
    var dependencies: [FeatureID]
    /// The features built from it.
    var children: [FeatureID]
}

struct FeatureDescription: Encodable, Equatable {
    var documentId: String
    var revision: Int
    var feature: FeatureInfo
    /// The settings modify_feature can change on this feature (empty: it can be read but not changed yet).
    var editable: [String]
    /// For a sketch.
    var sketch: SketchInfo?
}

struct DocumentDescription: Encodable, Equatable {
    var documentId: String
    var name: String
    var path: String?
    /// Always "mm": lengths in millimetres, angles in degrees. A length can be written with a unit ("2 in").
    var units: String
    /// Changes whenever the document does. A later request can pass the one it read to be refused if the user has
    /// changed the part in between.
    var revision: Int
    /// Features after the timeline marker are not built; nil when the marker is at the end.
    var timelineMarker: Int?
    var parameters: [ParameterInfo]
    var features: [FeatureInfo]
    var bodies: [BodyInfo]
}

struct SelectedEntity: Encodable, Equatable {
    var id: String
    /// "body", "face", "edge", "profile", "curve" or "plane".
    var type: String
    /// The feature the entity belongs to: the one that made the body, sketch or plane.
    var featureId: FeatureID?
}

struct SelectionDescription: Encodable, Equatable {
    var documentId: String
    var revision: Int
    var entities: [SelectedEntity]
    /// A feature selected in the browser or the timeline, apart from anything picked in the viewport.
    var selectedFeature: FeatureID?
}

/// One setting a change made: what it was and what it is now.
struct ChangeInfo: Encodable, Equatable {
    var field: String
    var before: FeatureField?
    var after: FeatureField
}

/// What a successful change returns: the part as it is now, so the caller can check it without asking again.
struct ChangeResult: Encodable, Equatable {
    var success = true
    var documentId: String
    /// The revision after the change; pass it as expected_revision to the next one to be sure nothing came in between.
    var revision: Int
    var message: String
    var feature: FeatureInfo?
    var parameter: ParameterInfo?
    var changes: [ChangeInfo]
    /// What was made, when that is more than a feature (a sketch's new shapes and their ids).
    var created: JSONValue?
    /// For a change to a sketch: the sketch as it is now, with its profiles.
    var sketch: SketchInfo?
    var bodies: [BodyInfo]
}

/// One step of a batch.
struct BatchStep: Encodable, Equatable {
    var step: Int
    var tool: String
    var message: String
    var feature: FeatureInfo?
    var parameter: ParameterInfo?
    var changes: [ChangeInfo]
    var created: JSONValue?
    var sketch: SketchInfo?
}

/// What a batch of changes returns: every step, and the part as it is now.
struct BatchResult: Encodable, Equatable {
    var success = true
    var documentId: String
    var revision: Int
    var message: String
    var steps: [BatchStep]
    var bodies: [BodyInfo]
}

/// What undo and redo return.
struct HistoryResult: Encodable, Equatable {
    var success = true
    var documentId: String
    var revision: Int
    var message: String
    /// The name of the step that was undone or redone, as the Edit menu shows it.
    var step: String
    var featureCount: Int
    var bodies: [BodyInfo]
}
