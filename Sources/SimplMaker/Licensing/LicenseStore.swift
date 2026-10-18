// Where the license data is kept between launches. The keychain survives deleting the app (so the trial
// cannot be restarted by trashing it); a copy in UserDefaults covers a keychain that cannot be read.
// Builds without a Team ID (ad-hoc signed development builds) never touch the keychain item: macOS ties its
// "Always Allow" to the signing identity, and each such build would overwrite the release app's approval.
// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation
import Security

protocol LicenseStore {
    func load() -> LicenseData?
    func save(_ data: LicenseData)
}

/// For tests, and for builds without licensing.
final class InMemoryLicenseStore: LicenseStore {
    var data: LicenseData?
    init(_ data: LicenseData? = nil) { self.data = data }
    func load() -> LicenseData? { data }
    func save(_ data: LicenseData) { self.data = data }
}

/// One record per major version: SimplMaker 2 has its own trial and its own license, apart from SimplMaker 1's.
struct KeychainLicenseStore: LicenseStore {
    var service = "com.simplmaker.SimplMaker.license"
    var account: String
    var defaults = UserDefaults.standard
    var defaultsKey: String
    /// False for builds that are not signed with a Team ID; they keep the license in `defaults` only.
    var usesKeychain: Bool

    init(generation: Int = 1, usesKeychain: Bool = Self.processHasTeamID) {
        self.usesKeychain = usesKeychain
        account = "state-v\(generation)"
        defaultsKey = "licenseStateBackup-v\(generation)"
    }

    /// Whether this process is signed with a Team ID (Developer ID or Apple Development), as the release app is.
    static let processHasTeamID: Bool = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return false }
        return dict[kSecCodeInfoTeamIdentifier as String] is String
    }()

    func load() -> LicenseData? {
        merged(keychain: usesKeychain ? readKeychain() : nil, backup: readBackup())
    }

    func save(_ data: LicenseData) {
        guard let encoded = try? JSONEncoder.license.encode(data) else { return }
        if usesKeychain {
            let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData: encoded] as CFDictionary)
            if status == errSecItemNotFound {
                SecItemAdd(query.merging([kSecValueData: encoded]) { $1 } as CFDictionary, nil)
            }
        }
        defaults.set(encoded, forKey: defaultsKey)
    }

    /// When both copies exist the trial start is the earlier one and `lastSeen` the later one, so that
    /// removing one copy does not help; the license comes from the keychain, else from the backup.
    func merged(keychain: LicenseData?, backup: LicenseData?) -> LicenseData? {
        switch (keychain, backup) {
        case (nil, nil): return nil
        case let (a?, nil): return a
        case let (nil, b?): return b
        case let (a?, b?):
            var out = a
            out.trialStart = [a.trialStart, b.trialStart].compactMap { $0 }.min()
            out.lastSeen = max(a.lastSeen, b.lastSeen)
            out.license = a.license ?? b.license
            return out
        }
    }

    private func readKeychain() -> LicenseData? {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                      kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder.license.decode(LicenseData.self, from: data)
    }

    private func readBackup() -> LicenseData? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder.license.decode(LicenseData.self, from: data)
    }
}

extension JSONEncoder {
    static var license: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}

extension JSONDecoder {
    static var license: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
