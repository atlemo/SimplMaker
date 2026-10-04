// The rules: a 14-day trial, then a license key. Pure functions over stored data and a date, so the
// rules can be tested with any clock. Nothing here touches the keychain, the network or the UI.
// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation

/// A license key that was activated on this Mac.
struct ActivatedLicense: Codable, Equatable {
    var key: String
    /// The key as the seller shows it (partly hidden), for the License window.
    var displayKey: String
    /// The server's id for this Mac's activation; needed to validate or deactivate it.
    var activationID: String
    /// When the server last confirmed the key was valid. Offline use is allowed for `LicensePolicy.offlineGrace` after this.
    var lastValidated: Date
    /// When the key stops working, if it expires (a key can be sold with a time limit).
    var expiresAt: Date?
}

/// Everything remembered between launches (kept in the keychain).
struct LicenseData: Codable, Equatable {
    /// The first time the app ran. Never reset: deactivating a license does not give a new trial.
    var trialStart: Date?
    /// The latest time the app has seen. A clock set back cannot give the trial more days.
    var lastSeen: Date
    var license: ActivatedLicense?
}

enum LicenseStatus: Equatable {
    case trial(daysLeft: Int)
    case trialEnded
    case licensed(displayKey: String)
    /// A key that stopped working: past its expiry date.
    case licenseExpired
    /// A key the server has not been able to confirm for longer than the offline grace.
    case needsConnection

    /// Whether the user may change documents. Otherwise the app opens, shows and exports them only.
    var allowsEditing: Bool {
        switch self {
        case .trial, .licensed: true
        case .trialEnded, .licenseExpired, .needsConnection: false
        }
    }
}

enum LicensePolicy {
    static let trialDays = 14
    /// The app asks the server again when it last did this long ago.
    static let revalidateAfter: TimeInterval = 7 * 86_400
    /// A key keeps working this long without the server confirming it (a Mac that is offline for a while).
    static let offlineGrace: TimeInterval = 30 * 86_400

    /// The status at `now`, and the data to remember. Starts the trial the first time it is called.
    static func evaluate(_ data: LicenseData, now: Date) -> (status: LicenseStatus, data: LicenseData) {
        var data = data
        let now = max(now, data.lastSeen)  // a clock set back counts as no time passing
        data.lastSeen = now
        if data.trialStart == nil { data.trialStart = now }

        if let license = data.license {
            if let expires = license.expiresAt, now >= expires { return (.licenseExpired, data) }
            if now.timeIntervalSince(license.lastValidated) > offlineGrace { return (.needsConnection, data) }
            return (.licensed(displayKey: license.displayKey), data)
        }

        let left = Double(trialDays) * 86_400 - now.timeIntervalSince(data.trialStart ?? now)
        if left <= 0 { return (.trialEnded, data) }
        return (.trial(daysLeft: Int((left / 86_400).rounded(.up))), data)
    }

    /// Whether the app should ask the server about the key now.
    static func needsRevalidation(_ data: LicenseData, now: Date) -> Bool {
        guard let license = data.license else { return false }
        return now.timeIntervalSince(license.lastValidated) > revalidateAfter
    }
}
