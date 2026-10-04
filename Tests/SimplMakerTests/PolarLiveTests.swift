// Copyright © 2026 Atle Mo. All rights reserved.
// Talks to the real Polar API with a real license key, so it only runs when you give it one:
//   POLAR_LIVE_KEY=SIMPL-… POLAR_LIVE_ORG=<organization uuid> POLAR_LIVE_BENEFIT=<benefit uuid> \
//   [POLAR_LIVE_BASE=https://sandbox-api.polar.sh] swift test --filter PolarLive
// It activates the key on this Mac, validates it, and deactivates it again, so the key's activation slot is freed.
// The tests run one at a time: they share the key, whose activations are limited.
import Foundation
import Testing
@testable import SimplMaker

private let env = ProcessInfo.processInfo.environment

@Suite(.serialized, .enabled(if: env["POLAR_LIVE_KEY"] != nil && env["POLAR_LIVE_ORG"] != nil && env["POLAR_LIVE_BENEFIT"] != nil))
struct PolarLiveTests {
    private func server(benefit: String? = env["POLAR_LIVE_BENEFIT"]) -> PolarLicenseServer {
        var server = PolarLicenseServer(organizationID: env["POLAR_LIVE_ORG"] ?? "", benefitID: benefit)
        if let base = env["POLAR_LIVE_BASE"].flatMap(URL.init(string:)) {
            server.baseURL = base.appendingPathComponent("v1/customer-portal/license-keys")
        }
        return server
    }

    @Test func aRealKeyActivatesValidatesAndDeactivates() async throws {
        let key = env["POLAR_LIVE_KEY"] ?? ""
        let live = server()
        let license = try await live.activate(key: key, label: "SimplMaker live test", now: Date())
        defer { Task { try? await live.deactivate(license) } }
        #expect(license.benefitID == env["POLAR_LIVE_BENEFIT"])
        #expect(!license.activationID.isEmpty)
        #expect(try await live.validate(license, now: Date()) == .valid(expiresAt: license.expiresAt))
        try await live.deactivate(license)
        #expect(try await live.validate(license, now: Date()) == .invalid)  // the activation is gone
    }

    @Test func aKeyOfAnotherProductIsTurnedAwayAndNothingStaysActivated() async throws {
        let key = env["POLAR_LIVE_KEY"] ?? ""
        await #expect(throws: LicenseError.wrongVersion) {
            try await server(benefit: "00000000-0000-4000-8000-000000000000").activate(key: key, label: "SimplMaker live test", now: Date())
        }
    }

    @Test func aMadeUpKeyIsNotRecognised() async {
        await #expect(throws: LicenseError.invalidKey) {
            try await server().activate(key: "SIMPL-00000000-0000-0000-0000-000000000000", label: "SimplMaker live test", now: Date())
        }
    }
}
