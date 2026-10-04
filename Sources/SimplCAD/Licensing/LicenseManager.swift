// The app's single license state: reads the stored data, applies the rules, talks to the server, and
// tells the UI. Licensing is only enforced when the bundle names a Polar organization (the release
// build does; `swift run`, Xcode debug builds and the tests do not).
// Copyright © 2026 Atle Mo. All rights reserved.
import AppKit
import Foundation

struct LicenseConfiguration: Equatable {
    var organizationID: String
    /// The page where the app is bought (a Polar checkout link).
    var buyURL: URL
    /// The major version this build sells licenses for (1 for SimplCAD 1.x). Each has its own trial and its own keys.
    var generation = 1
    /// The Polar product (license-key benefit) of this major version; keys of other products are rejected.
    var benefitID: String?
    /// Polar's sandbox API for testing (https://sandbox-api.polar.sh); nil means the real one.
    var apiBase: URL?

    /// From Info.plist (SCPolarOrganizationID, SCBuyURL, SCLicenseGeneration, SCPolarBenefitID, SCPolarAPIBase, written by scripts/bundle-app.sh from Packaging/licensing.conf).
    static func fromBundle(_ bundle: Bundle = .main) -> LicenseConfiguration? {
        guard let id = bundle.object(forInfoDictionaryKey: "SCPolarOrganizationID") as? String, !id.isEmpty,
              let buy = (bundle.object(forInfoDictionaryKey: "SCBuyURL") as? String).flatMap(URL.init(string:))
        else { return nil }
        let base = (bundle.object(forInfoDictionaryKey: "SCPolarAPIBase") as? String).flatMap(URL.init(string:))
        let generation = (bundle.object(forInfoDictionaryKey: "SCLicenseGeneration") as? String).flatMap(Int.init) ?? 1
        let benefit = (bundle.object(forInfoDictionaryKey: "SCPolarBenefitID") as? String).flatMap { $0.isEmpty ? nil : $0 }
        return LicenseConfiguration(organizationID: id, buyURL: buy, generation: generation, benefitID: benefit, apiBase: base)
    }
}

@MainActor
@Observable
final class LicenseManager {
    static var shared: LicenseManager = {
        guard let configuration = LicenseConfiguration.fromBundle() else { return LicenseManager(configuration: nil) }
        var server = PolarLicenseServer(organizationID: configuration.organizationID, benefitID: configuration.benefitID)
        if let base = configuration.apiBase { server.baseURL = base.appendingPathComponent("v1/customer-portal/license-keys") }
        return LicenseManager(configuration: configuration, store: KeychainLicenseStore(generation: configuration.generation), server: server)
    }()

    let configuration: LicenseConfiguration?
    private(set) var status: LicenseStatus
    private(set) var isBusy = false
    /// The last problem activating, for the License window.
    private(set) var errorMessage: String?

    @ObservationIgnored private let store: LicenseStore
    @ObservationIgnored private let server: LicenseServer?
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var timer: Timer?

    /// Whether this build asks for a license at all.
    var isEnforced: Bool { configuration != nil }
    /// Whether documents may be changed. Always true in builds without licensing.
    var allowsEditing: Bool { !isEnforced || status.allowsEditing }
    var isLicensed: Bool { if case .licensed = status { true } else { false } }

    init(configuration: LicenseConfiguration?, store: LicenseStore = InMemoryLicenseStore(),
         server: LicenseServer? = nil, clock: @escaping () -> Date = Date.init) {
        self.configuration = configuration
        self.store = store
        self.server = server
        self.clock = clock
        // Builds without licensing never read or write the stored data.
        status = configuration == nil ? .licensed(displayKey: "") : .trial(daysLeft: LicensePolicy.trialDays)
        if configuration != nil { refresh() }
    }

    /// Call at launch: re-evaluates now, asks the server if it has been a while, then re-checks daily.
    func start() {
        guard isEnforced else { return }
        refresh()
        Task { await revalidateIfDue() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
                await self?.revalidateIfDue()
            }
        }
    }

    /// Applies the rules to the stored data at the current time.
    func refresh() {
        guard isEnforced else { return }
        let (newStatus, data) = LicensePolicy.evaluate(store.load() ?? LicenseData(lastSeen: clock()), now: clock())
        store.save(data)
        if newStatus != status { status = newStatus }
    }

    func activate(key rawKey: String) async {
        guard let server, !isBusy else { return }
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { errorMessage = "Enter the license key from your purchase email."; return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let license = try await server.activate(key: key, label: Host.current().localizedName ?? "Mac", now: clock())
            var data = store.load() ?? LicenseData(lastSeen: clock())
            data.license = license
            store.save(data)
            refresh()
        } catch let error as LicenseError {
            errorMessage = error.message
        } catch {
            errorMessage = LicenseError.offline.message
        }
    }

    /// Frees this Mac's activation, so the key can be used on another one. The trial is not given back.
    func deactivate() async {
        guard let server, !isBusy, var data = store.load(), let license = data.license else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await server.deactivate(license)
            data.license = nil
            store.save(data)
            refresh()
        } catch let error as LicenseError {
            errorMessage = error.message
        } catch {
            errorMessage = LicenseError.offline.message
        }
    }

    /// Asks the server about the key if it has not been confirmed for a week. Offline is fine for a month.
    func revalidateIfDue() async {
        guard let server, var data = store.load(), var license = data.license,
              LicensePolicy.needsRevalidation(data, now: clock()) else { return }
        do {
            switch try await server.validate(license, now: clock()) {
            case .valid(let expiresAt):
                license.lastValidated = clock()
                license.expiresAt = expiresAt
                data.license = license
            case .invalid:
                data.license = nil  // revoked, refunded or expired for good
            }
            store.save(data)
            refresh()
        } catch {
            // Not reachable or a server error: keep going on the grace period.
        }
    }

    func buy() {
        guard let url = configuration?.buyURL else { return }
        NSWorkspace.shared.open(url)
    }
}
