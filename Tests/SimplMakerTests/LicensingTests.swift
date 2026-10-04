// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import Foundation
import Testing
@testable import SimplMaker

private let day: TimeInterval = 86_400
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func license(validated: Date = t0, expires: Date? = nil) -> ActivatedLicense {
    ActivatedLicense(key: "SIMPL-KEY", displayKey: "****-1234", activationID: "act-1", lastValidated: validated, expiresAt: expires)
}

@Suite struct LicensePolicyTests {
    @Test func theTrialStartsOnFirstUseAndCountsDown() {
        let (status, data) = LicensePolicy.evaluate(LicenseData(lastSeen: t0), now: t0)
        #expect(status == .trial(daysLeft: 14))
        #expect(data.trialStart == t0)
        #expect(LicensePolicy.evaluate(data, now: t0 + 13 * day).status == .trial(daysLeft: 1))
        #expect(LicensePolicy.evaluate(data, now: t0 + 13.5 * day).status == .trial(daysLeft: 1))
    }

    @Test func theTrialEndsAfterFourteenDays() {
        let (_, data) = LicensePolicy.evaluate(LicenseData(lastSeen: t0), now: t0)
        #expect(LicensePolicy.evaluate(data, now: t0 + 14 * day).status == .trialEnded)
        #expect(LicensePolicy.evaluate(data, now: t0 + 400 * day).status == .trialEnded)
        #expect(!LicenseStatus.trialEnded.allowsEditing)
        #expect(LicenseStatus.trial(daysLeft: 3).allowsEditing)
    }

    @Test func aClockSetBackDoesNotGiveMoreTrial() {
        let (_, data) = LicensePolicy.evaluate(LicenseData(lastSeen: t0), now: t0)
        let (late, remembered) = LicensePolicy.evaluate(data, now: t0 + 15 * day)
        #expect(late == .trialEnded)
        // The user sets the clock back to day 1: the app remembers it saw day 15.
        #expect(LicensePolicy.evaluate(remembered, now: t0 + 1 * day).status == .trialEnded)
    }

    @Test func aLicenseIsGoodUntilItExpires() {
        let data = LicenseData(trialStart: t0 - 100 * day, lastSeen: t0, license: license(expires: t0 + 10 * day))
        #expect(LicensePolicy.evaluate(data, now: t0 + 5 * day).status == .licensed(displayKey: "****-1234"))
        #expect(LicensePolicy.evaluate(data, now: t0 + 11 * day).status == .licenseExpired)
        #expect(!LicenseStatus.licenseExpired.allowsEditing)
    }

    @Test func aLicenseWorksOfflineForAMonth() {
        let data = LicenseData(trialStart: t0, lastSeen: t0, license: license(validated: t0))
        #expect(LicensePolicy.evaluate(data, now: t0 + 29 * day).status == .licensed(displayKey: "****-1234"))
        #expect(LicensePolicy.evaluate(data, now: t0 + 31 * day).status == .needsConnection)
        #expect(!LicenseStatus.needsConnection.allowsEditing)
    }

    @Test func theServerIsAskedAgainAfterAWeek() {
        let data = LicenseData(trialStart: t0, lastSeen: t0, license: license(validated: t0))
        #expect(!LicensePolicy.needsRevalidation(data, now: t0 + 6 * day))
        #expect(LicensePolicy.needsRevalidation(data, now: t0 + 8 * day))
        #expect(!LicensePolicy.needsRevalidation(LicenseData(lastSeen: t0), now: t0 + 99 * day))  // no key, nothing to ask
    }
}

@Suite struct KeychainMergeTests {
    @Test func eachMajorVersionKeepsItsOwnRecord() {
        let one = KeychainLicenseStore(generation: 1), two = KeychainLicenseStore(generation: 2)
        #expect(one.account != two.account)
        #expect(one.defaultsKey != two.defaultsKey)
        #expect(two.account == "state-v2")
    }

    @Test func theEarlierTrialStartAndLaterLastSeenWin() {
        let a = LicenseData(trialStart: t0 + 5 * day, lastSeen: t0 + 6 * day)
        let b = LicenseData(trialStart: t0, lastSeen: t0 + 9 * day, license: license())
        let merged = KeychainLicenseStore().merged(keychain: a, backup: b)
        #expect(merged?.trialStart == t0)
        #expect(merged?.lastSeen == t0 + 9 * day)
        #expect(merged?.license != nil)
        #expect(KeychainLicenseStore().merged(keychain: nil, backup: nil) == nil)
        #expect(KeychainLicenseStore().merged(keychain: nil, backup: b) == b)
    }
}

@Suite struct PolarServerTests {
    /// Records requests and answers with canned responses.
    final class Fake: @unchecked Sendable {
        var requests: [URLRequest] = []
        var status = 200
        var body = Data()
        var fail = false
        /// Make this many "deactivate" calls fail before one succeeds.
        var failDeactivations = 0
        var transport: HTTPTransport {
            { [self] request in
                requests.append(request)
                if fail { throw LicenseError.offline }
                if request.url?.lastPathComponent == "deactivate", failDeactivations > 0 {
                    failDeactivations -= 1
                    throw LicenseError.offline
                }
                return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
        }
        func json(_ object: [String: Any]) { body = try! JSONSerialization.data(withJSONObject: object) }
        func sent() -> [String: String] {
            (try? JSONSerialization.jsonObject(with: requests.last?.httpBody ?? Data()) as? [String: String]) ?? [:]
        }
    }

    private func server(_ fake: Fake) -> PolarLicenseServer {
        PolarLicenseServer(organizationID: "org-1", transport: fake.transport)
    }

    @Test func activateSendsKeyOrganizationAndLabel() async throws {
        let fake = Fake()
        fake.json(["id": "act-9", "license_key": ["display_key": "****-ABCD", "expires_at": "2027-01-01T00:00:00.123456Z"]])
        let result = try await server(fake).activate(key: "K-1", label: "Atle's Mac", now: t0)
        #expect(fake.requests.last?.url?.absoluteString == "https://api.polar.sh/v1/customer-portal/license-keys/activate")
        #expect(fake.requests.last?.httpMethod == "POST")
        #expect(fake.sent() == ["key": "K-1", "organization_id": "org-1", "label": "Atle's Mac"])
        #expect(result.activationID == "act-9")
        #expect(result.displayKey == "****-ABCD")
        #expect(result.lastValidated == t0)
        #expect(result.expiresAt == Date(timeIntervalSince1970: 1_798_761_600.123))
    }

    @Test func activateMapsErrors() async {
        let fake = Fake()
        for (code, expected) in [(404, LicenseError.invalidKey), (422, .invalidKey), (403, .rejected), (500, .server(500))] {
            fake.status = code
            await #expect(throws: expected) { try await server(fake).activate(key: "K", label: "L", now: t0) }
        }
        fake.fail = true
        await #expect(throws: LicenseError.offline) { try await server(fake).activate(key: "K", label: "L", now: t0) }
    }

    @Test func validateSendsTheActivationAndReadsTheExpiry() async throws {
        let fake = Fake()
        fake.json(["expires_at": NSNull()])
        #expect(try await server(fake).validate(license(), now: t0) == .valid(expiresAt: nil))
        #expect(fake.sent() == ["key": "SIMPL-KEY", "organization_id": "org-1", "activation_id": "act-1"])
        fake.status = 404
        #expect(try await server(fake).validate(license(), now: t0) == .invalid)
        fake.status = 503
        await #expect(throws: LicenseError.server(503)) { try await server(fake).validate(license(), now: t0) }
    }

    @Test func deactivateTreatsAnAlreadyRemovedActivationAsDone() async throws {
        let fake = Fake()
        fake.status = 204
        try await server(fake).deactivate(license())
        #expect(fake.requests.last?.url?.lastPathComponent == "deactivate")
        fake.status = 404
        try await server(fake).deactivate(license())
        fake.status = 500
        await #expect(throws: LicenseError.server(500)) { try await server(fake).deactivate(license()) }
    }

    @Test func aKeyForAnotherMajorVersionIsTurnedAwayAndItsActivationFreed() async throws {
        let fake = Fake()
        fake.json(["id": "act-7", "license_key": ["display_key": "****-V1", "benefit_id": "benefit-v1"]])
        var v2 = server(fake)
        v2.benefitID = "benefit-v2"
        await #expect(throws: LicenseError.wrongVersion) { try await v2.activate(key: "K", label: "L", now: t0) }
        // It asked Polar to remove the activation it had just made, so the key's slot is not used up.
        #expect(fake.requests.map { $0.url?.lastPathComponent } == ["activate", "deactivate"])
        #expect(fake.sent()["activation_id"] == "act-7")

        var v1 = server(Fake())
        let fake1 = Fake()
        fake1.json(["id": "act-8", "license_key": ["display_key": "****-V1", "benefit_id": "benefit-v1"]])
        v1 = server(fake1)
        v1.benefitID = "benefit-v1"
        let ok = try await v1.activate(key: "K", label: "L", now: t0)
        #expect(ok.benefitID == "benefit-v1")
        #expect(fake1.requests.count == 1)
    }

    @Test func aFailedAttemptToFreeTheWrongVersionActivationIsRetried() async {
        let fake = Fake()
        fake.json(["id": "act-5", "license_key": ["display_key": "****", "benefit_id": "benefit-v1"]])
        fake.failDeactivations = 2
        var v2 = server(fake)
        v2.benefitID = "benefit-v2"
        v2.retryDelay = .milliseconds(1)
        await #expect(throws: LicenseError.wrongVersion) { try await v2.activate(key: "K", label: "L", now: t0) }
        #expect(fake.requests.map { $0.url?.lastPathComponent } == ["activate", "deactivate", "deactivate", "deactivate"])
    }

    @Test func aKeyWithNoProductIsTurnedAwayWhenTheBuildNamesOne() async {
        let fake = Fake()
        fake.json(["id": "act-1", "license_key": ["display_key": "****"]])
        var v1 = server(fake)
        v1.benefitID = "benefit-v1"
        await #expect(throws: LicenseError.wrongVersion) { try await v1.activate(key: "K", label: "L", now: t0) }
    }

    @Test func validateAsksAboutTheProductOfThisVersion() async throws {
        let fake = Fake()
        fake.json(["expires_at": NSNull()])
        var v1 = server(fake)
        v1.benefitID = "benefit-v1"
        _ = try await v1.validate(license(), now: t0)
        #expect(fake.sent()["benefit_id"] == "benefit-v1")
        #expect(fake.sent()["activation_id"] == "act-1")
    }

    @Test func polarTimestampsWithMicrosecondsParse() {
        #expect(PolarLicenseServer.date("2026-01-01T00:00:00.000000Z") == Date(timeIntervalSince1970: 1_767_225_600))
        #expect(PolarLicenseServer.date("2026-01-01T00:00:00Z") == Date(timeIntervalSince1970: 1_767_225_600))
        #expect(PolarLicenseServer.date("garbage") == nil)
    }
}

/// A server whose answers the test sets.
actor FakeServer: LicenseServer {
    var activation: Result<ActivatedLicense, LicenseError> = .failure(.offline)
    var validation: Result<ValidationResult, LicenseError> = .failure(.offline)
    var deactivation: Result<Void, LicenseError> = .success(())
    func set(activation: Result<ActivatedLicense, LicenseError>? = nil, validation: Result<ValidationResult, LicenseError>? = nil,
             deactivation: Result<Void, LicenseError>? = nil) {
        if let activation { self.activation = activation }
        if let validation { self.validation = validation }
        if let deactivation { self.deactivation = deactivation }
    }
    func activate(key: String, label: String, now: Date) async throws -> ActivatedLicense { try activation.get() }
    func validate(_ license: ActivatedLicense, now: Date) async throws -> ValidationResult { try validation.get() }
    func deactivate(_ license: ActivatedLicense) async throws { try deactivation.get() }
}

@MainActor @Suite struct LicenseManagerTests {
    private let configuration = LicenseConfiguration(organizationID: "org-1", buyURL: URL(string: "https://example.com/buy")!)

    private func manager(store: InMemoryLicenseStore = InMemoryLicenseStore(), server: FakeServer = FakeServer(),
                         now: @escaping () -> Date) -> LicenseManager {
        LicenseManager(configuration: configuration, store: store, server: server, clock: now)
    }

    @Test func aBuildWithoutLicensingAlwaysAllowsEditing() {
        let m = LicenseManager(configuration: nil)
        #expect(!m.isEnforced)
        #expect(m.allowsEditing)
    }

    @Test func aFreshInstallIsOnTheTrialAndItEnds() {
        var now = t0
        let store = InMemoryLicenseStore()
        let m = manager(store: store, now: { now })
        #expect(m.status == .trial(daysLeft: 14))
        #expect(m.allowsEditing)
        now = t0 + 15 * day
        m.refresh()
        #expect(m.status == .trialEnded)
        #expect(!m.allowsEditing)
    }

    @Test func activatingAKeyUnlocksEditing() async {
        let now = t0 + 20 * day
        let store = InMemoryLicenseStore(LicenseData(trialStart: t0, lastSeen: t0))
        let server = FakeServer()
        await server.set(activation: .success(license(validated: now)))
        let m = manager(store: store, server: server, now: { now })
        #expect(m.status == .trialEnded)
        await m.activate(key: "  SIMPL-KEY \n")
        #expect(m.status == .licensed(displayKey: "****-1234"))
        #expect(m.allowsEditing)
        #expect(m.errorMessage == nil)
        #expect(store.data?.license?.key == "SIMPL-KEY")
    }

    @Test func aRejectedKeyShowsTheReason() async {
        let server = FakeServer()
        await server.set(activation: .failure(.rejected))
        let m = manager(server: server, now: { t0 })
        await m.activate(key: "K")
        #expect(m.errorMessage == LicenseError.rejected.message)
        #expect(m.status == .trial(daysLeft: 14))
        await m.activate(key: "   ")
        #expect(m.errorMessage?.contains("Enter the license key") == true)
    }

    @Test func deactivatingKeepsTheTrialOver() async {
        let now = t0 + 30 * day
        let store = InMemoryLicenseStore(LicenseData(trialStart: t0, lastSeen: t0, license: license(validated: now)))
        let m = manager(store: store, now: { now })
        #expect(m.isLicensed)
        await m.deactivate()
        #expect(store.data?.license == nil)
        #expect(m.status == .trialEnded)  // the trial is not given back
    }

    @Test func aFailedDeactivationKeepsTheLicense() async {
        let server = FakeServer()
        await server.set(deactivation: .failure(.offline))
        let store = InMemoryLicenseStore(LicenseData(trialStart: t0, lastSeen: t0, license: license()))
        let m = manager(store: store, server: server, now: { t0 })
        await m.deactivate()
        #expect(m.isLicensed)
        #expect(m.errorMessage == LicenseError.offline.message)
    }

    @Test func aWeeklyCheckRefreshesOrRemovesTheKey() async {
        var now = t0 + 8 * day
        let store = InMemoryLicenseStore(LicenseData(trialStart: t0 - 99 * day, lastSeen: t0, license: license(validated: t0)))
        let server = FakeServer()
        let m = manager(store: store, server: server, now: { now })

        await server.set(validation: .failure(.offline))  // offline: nothing changes, the grace period carries on
        await m.revalidateIfDue()
        #expect(m.isLicensed)
        #expect(store.data?.license?.lastValidated == t0)

        await server.set(validation: .success(.valid(expiresAt: nil)))
        await m.revalidateIfDue()
        #expect(store.data?.license?.lastValidated == now)

        now += 8 * day
        await server.set(validation: .success(.invalid))  // refunded or revoked
        await m.revalidateIfDue()
        #expect(store.data?.license == nil)
        #expect(!m.allowsEditing)
    }
}

@MainActor @Suite struct EditingLockTests {
    @Test func aLockedAppDoesNotChangeTheDocument() {
        let saved = LicenseManager.shared
        defer { LicenseManager.shared = saved }
        let model = DocumentModel()
        let before = model.document

        let locked = LicenseManager(configuration: LicenseConfiguration(organizationID: "o", buyURL: URL(string: "https://x.test")!),
                                    store: InMemoryLicenseStore(LicenseData(trialStart: t0, lastSeen: t0)),
                                    clock: { t0 + 30 * day })
        #expect(locked.status == .trialEnded)
        LicenseManager.shared = locked
        model.mutate("Add parameter") { $0.parameters.append(Parameter("width", "10")) }
        #expect(model.document == before)
        #expect(model.alert?.title == "Editing is turned off")

        LicenseManager.shared = LicenseManager(configuration: nil)
        model.alert = nil
        model.mutate("Add parameter") { $0.parameters.append(Parameter("width", "10")) }
        #expect(model.document != before)
    }
}
