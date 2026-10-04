// Polar (polar.sh) is the merchant of record and issues the license keys. Its customer-portal license
// endpoints are public: they take the key and the organization id and need no secret, so they are safe
// to call from the app. Docs: https://polar.sh/docs/api-reference/customer-portal/license-keys/activate
// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation

enum LicenseError: Error, Equatable {
    /// No such key, or it was revoked.
    case invalidKey
    /// A real key, but for another major version of SimplCAD.
    case wrongVersion
    /// The key cannot be activated: disabled, expired, or already on as many Macs as it allows.
    case rejected
    /// The server could not be reached.
    case offline
    case server(Int)

    var message: String {
        switch self {
        case .invalidKey: "That license key was not recognised. Check it for typing mistakes."
        case .wrongVersion: "This key was bought for a different major version of SimplCAD. A key works with the version it was bought for (SimplCAD 1 keys with SimplCAD 1); buy the upgrade for this version."
        case .rejected: "This key cannot be activated. It may have expired, been revoked, or already be in use on the most Macs it allows. Deactivate it on another Mac first, or contact support."
        case .offline: "SimplCAD could not reach the license server. Check your internet connection and try again."
        case .server(let code): "The license server answered with an error (\(code)). Try again later."
        }
    }
}

/// What the server says about a key it was asked to validate.
enum ValidationResult: Equatable {
    case valid(expiresAt: Date?)
    case invalid
}

protocol LicenseServer: Sendable {
    func activate(key: String, label: String, now: Date) async throws -> ActivatedLicense
    func validate(_ license: ActivatedLicense, now: Date) async throws -> ValidationResult
    func deactivate(_ license: ActivatedLicense) async throws
}

/// Sends a request and returns the answer; URLSession in the app, a fake in tests.
typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

struct PolarLicenseServer: LicenseServer {
    var organizationID: String
    /// The product (license-key benefit) of this major version. Keys of other products are turned away.
    var benefitID: String? = nil
    var baseURL = URL(string: "https://api.polar.sh/v1/customer-portal/license-keys")!
    var transport: HTTPTransport = PolarLicenseServer.urlSession

    static let urlSession: HTTPTransport = { request in
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw LicenseError.offline }
            return (data, http)
        } catch is URLError {
            throw LicenseError.offline
        }
    }

    func activate(key: String, label: String, now: Date) async throws -> ActivatedLicense {
        let (data, response) = try await post("activate", ["key": key, "organization_id": organizationID, "label": label])
        switch response.statusCode {
        case 200:
            guard let body = try? JSONDecoder().decode(ActivationBody.self, from: data) else { throw LicenseError.server(200) }
            let activated = ActivatedLicense(key: key, displayKey: body.license_key.display_key, activationID: body.id,
                                             lastValidated: now, expiresAt: body.license_key.expires_at.flatMap(Self.date),
                                             benefitID: body.license_key.benefit_id)
            if let want = benefitID, activated.benefitID != want {
                try? await deactivate(activated)  // do not use up one of the key's activations on the wrong version
                throw LicenseError.wrongVersion
            }
            return activated
        case 404, 422: throw LicenseError.invalidKey
        case 403: throw LicenseError.rejected
        default: throw LicenseError.server(response.statusCode)
        }
    }

    func validate(_ license: ActivatedLicense, now: Date) async throws -> ValidationResult {
        var body = ["key": license.key, "organization_id": organizationID, "activation_id": license.activationID]
        if let benefitID { body["benefit_id"] = benefitID }
        let (data, response) = try await post("validate", body)
        switch response.statusCode {
        case 200:
            let expires = (try? JSONDecoder().decode(ValidationBody.self, from: data))?.expires_at.flatMap(Self.date)
            return .valid(expiresAt: expires)
        case 404: return .invalid  // not found, revoked, disabled, expired, or this activation was removed
        default: throw LicenseError.server(response.statusCode)
        }
    }

    func deactivate(_ license: ActivatedLicense) async throws {
        let (_, response) = try await post("deactivate", ["key": license.key, "organization_id": organizationID,
                                                          "activation_id": license.activationID])
        switch response.statusCode {
        case 200...299, 404: return  // already gone is fine
        default: throw LicenseError.server(response.statusCode)
        }
    }

    private func post(_ path: String, _ body: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await transport(request)
    }

    private struct ActivationBody: Decodable {
        struct Key: Decodable { var display_key: String; var expires_at: String?; var benefit_id: String? }
        var id: String
        var license_key: Key
    }

    private struct ValidationBody: Decodable { var expires_at: String? }

    /// Polar's timestamps carry microseconds ("2026-01-01T00:00:00.000000Z"); ISO8601DateFormatter wants milliseconds at most.
    static func date(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let trimmed = string.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        return withFraction.date(from: trimmed) ?? plain.date(from: trimmed)
    }
}
