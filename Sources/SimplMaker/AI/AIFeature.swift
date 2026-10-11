// The switch for the whole AI mode: the interface that lets an AI assistant read and change parts. With it off the
// Settings tab is gone, no server is ever started, no connection file is written, no document is registered for it, and the
// relay program isn't put in the app. It is decided when the app is built, not by the user:
//
//   - a bundle can say so: Info.plist `SCAIEnabled` (written by scripts/bundle-app.sh, which turns it on for debug builds
//     and for release builds only when given --with-ai);
//   - without that key (Xcode, `swift run`) a debug build has it on and a release build has it off.
//
// A signed, notarized app can't have its Info.plist edited without breaking the signature, so a release build that
// leaves it out can't be turned on by whoever has the app.
// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation

enum AIFeature {
    static let infoKey = "SCAIEnabled"

    /// What the plist value (a boolean, or the text "true"/"yes"/"1" a script may write) and the build type come to.
    static func resolve(plistValue: Any?, debugBuild: Bool) -> Bool {
        switch plistValue {
        case let value as Bool: return value
        case let text as String:
            switch text.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0", "": return false
            default: return debugBuild
            }
        case let number as NSNumber: return number.boolValue
        default: return debugBuild
        }
    }

    #if DEBUG
    static let isDebugBuild = true
    #else
    static let isDebugBuild = false
    #endif

    /// Whether this build has the AI mode.
    static let isAvailable = resolve(plistValue: Bundle.main.object(forInfoDictionaryKey: infoKey), debugBuild: isDebugBuild)
}
