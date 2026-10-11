// Errors the AI-facing API returns. Written for a language model to read: a stable code to branch on, a sentence
// saying what happened, and (where there is one) the reason and whether trying again differently can work.
// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation

struct AIError: Error, Equatable, Encodable, CustomStringConvertible {
    enum Code: String, Encodable, Sendable {
        case licenseRequired = "LICENSE_REQUIRED"
        case documentNotFound = "DOCUMENT_NOT_FOUND"
        case noActiveDocument = "NO_ACTIVE_DOCUMENT"
        case featureNotFound = "FEATURE_NOT_FOUND"
        case invalidArguments = "INVALID_ARGUMENTS"
        case internalError = "INTERNAL_ERROR"
        /// The user is in the middle of something in the window; try again shortly.
        case userBusy = "USER_BUSY"
        /// The part changed since the revision the caller read.
        case staleRevision = "STALE_REVISION"
        case timelineRolledBack = "TIMELINE_ROLLED_BACK"
        case invalidValue = "INVALID_VALUE"
        case unknownField = "UNKNOWN_FIELD"
        case unsupportedFeature = "UNSUPPORTED_FEATURE_TYPE"
        case parameterLinked = "PARAMETER_LINKED"
        /// The change was refused because something in the part would no longer build.
        case rebuildFailed = "REBUILD_FAILED"
        case nothingToUndo = "NOTHING_TO_UNDO"
        case nothingToRedo = "NOTHING_TO_REDO"
        case undoUnavailable = "UNDO_UNAVAILABLE"
        /// Other features are built from the one to delete.
        case hasDependents = "HAS_DEPENDENTS"
    }

    var code: Code
    var message: String
    /// Why it happened, when that helps the next attempt.
    var reason: String?
    /// Whether the same request, changed, can work.
    var recoverable: Bool

    init(_ code: Code, _ message: String, reason: String? = nil, recoverable: Bool = true) {
        self.code = code; self.message = message; self.reason = reason; self.recoverable = recoverable
    }

    var description: String { "\(code.rawValue): \(message)" }

    /// The AI interface needs a valid licence or a running trial (the same rule as editing).
    static let licenseRequired = AIError(
        .licenseRequired, "SimplMaker's AI interface needs a valid license or a running trial.",
        reason: "The trial has ended or the license is not valid. The user can buy or enter a license under SimplMaker ▸ License…",
        recoverable: false)
}

extension AIError {
    /// What a failed tool call reads like to the AI.
    var json: JSONValue {
        var error: [String: JSONValue] = ["code": .string(code.rawValue), "message": .string(message), "recoverable": .bool(recoverable)]
        if let reason { error["reason"] = .string(reason) }
        return ["success": false, "error": .object(error)]
    }

    static func describing(_ error: Error) -> JSONValue {
        if let ai = error as? AIError { return ai.json }
        return AIError(.internalError, "SimplMaker could not complete the request.", reason: "\(error)", recoverable: false).json
    }
}
