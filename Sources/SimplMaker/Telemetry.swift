// Anonymous usage statistics through TelemetryDeck (telemetrydeck.com): how many people use the app,
// on which macOS and app version, and which features get used. No part contents, file names or
// personal data are sent, and TelemetryDeck hashes the user identifier. Off with one switch in
// Settings ▸ General; the privacy page on simplmaker.com (website/src/pages/privacy) has the wording users see.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if os(macOS)
import TelemetryDeck
#endif

#if os(macOS)
@MainActor
enum Telemetry {
    private static let appID = "8B60A0C4-139C-49FE-83AD-F72B32D9500D"
    /// The organization namespace shown next to the app ID in TelemetryDeck; without it the SDK posts to the default
    /// namespace and the signals never reach this account's dashboard.
    private static let namespace = "simpl.shot"
    private static var isStarted = false

    /// Whether this is an official SimplMaker build (scripts/bundle-app.sh --official writes `SCOfficialBuild` into
    /// Info.plist). A build made from the source never sends statistics to this dashboard, nor checks this project's update feed.
    static let isOfficialBuild = Bundle.main.object(forInfoDictionaryKey: "SCOfficialBuild") as? Bool == true

    /// Whether usage statistics are sent (on by default).
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: Preferences.sendUsageStatistics) as? Bool ?? true }

    /// Starts the SDK once the app has launched. Does nothing when the user has turned statistics off.
    static func start() {
        guard isOfficialBuild, isEnabled, !isStarted else { return }
        isStarted = true
        TelemetryDeck.initialize(config: .init(appID: appID, namespace: namespace))
    }

    /// Sends a named event. Cheap to call anywhere; ignored when statistics are off or not started.
    static func signal(_ name: String, _ parameters: [String: String] = [:]) {
        guard isEnabled, isStarted else { return }
        TelemetryDeck.signal(name, parameters: parameters)
    }
}
#else
/// The iPad app sends no usage statistics.
@MainActor
enum Telemetry {
    static var isEnabled: Bool { false }
    static func start() {}
    static func signal(_ name: String, _ parameters: [String: String] = [:]) {}
}
#endif
