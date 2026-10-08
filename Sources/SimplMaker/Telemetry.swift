// Anonymous usage statistics through TelemetryDeck (telemetrydeck.com): how many people use the app,
// on which macOS and app version, and which features get used. No part contents, file names or
// personal data are sent, and TelemetryDeck hashes the user identifier. Off with one switch in
// Settings ▸ General; see legal/PRIVACY.md for the wording users see.
// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation
import TelemetryDeck

@MainActor
enum Telemetry {
    private static let appID = "8B60A0C4-139C-49FE-83AD-F72B32D9500D"
    private static var isStarted = false

    /// Whether usage statistics are sent (on by default).
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: Preferences.sendUsageStatistics) as? Bool ?? true }

    /// Starts the SDK once the app has launched. Does nothing when the user has turned statistics off.
    static func start() {
        guard isEnabled, !isStarted else { return }
        isStarted = true
        TelemetryDeck.initialize(config: .init(appID: appID))
    }

    /// Sends a named event. Cheap to call anywhere; ignored when statistics are off or not started.
    static func signal(_ name: String, _ parameters: [String: String] = [:]) {
        guard isEnabled, isStarted else { return }
        TelemetryDeck.signal(name, parameters: parameters)
    }
}
