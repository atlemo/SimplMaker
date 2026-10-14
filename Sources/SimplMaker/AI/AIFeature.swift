// The switch for the whole AI mode: the interface that lets an AI assistant read and change parts. Every build has it, and
// it is off until the user turns it on in Settings ▸ AI: with it off no server is started, no connection file is written and
// no document is registered for it. A build can still be made without it (scripts/bundle-app.sh --without-ai), which also leaves
// out the relay program and removes the Settings tab. That is decided when the app is built, not by the user, through the
// Info.plist key `SCAIEnabled`: an explicit false turns the mode off, and a missing or unreadable value leaves it on.
// A signed, notarized app can't have its Info.plist edited without breaking the signature.
// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation

enum AIFeature {
    static let infoKey = "SCAIEnabled"

    /// What the plist value (a boolean, or the text "true"/"yes"/"1" a script may write) comes to. Only an explicit "off" turns
    /// the mode off.
    static func resolve(plistValue: Any?) -> Bool {
        switch plistValue {
        case let value as Bool: return value
        case let text as String:
            switch text.trimmingCharacters(in: .whitespaces).lowercased() {
            case "false", "no", "0": return false
            default: return true
            }
        case let number as NSNumber: return number.boolValue
        default: return true
        }
    }

    /// Whether this build has the AI mode.
    static let isAvailable = resolve(plistValue: Bundle.main.object(forInfoDictionaryKey: infoKey))
}
