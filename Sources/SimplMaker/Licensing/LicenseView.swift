// The License window (and Settings tab), the notice in the welcome window, and the banner over a part
// that can no longer be edited.
// Copyright © 2026 Atle Mo. All rights reserved.
import SwiftUI

extension LicenseStatus {
    /// One sentence for the License window.
    var summary: String {
        switch self {
        case .trial(let days): "Free trial: \(days) \(days == 1 ? "day" : "days") left."
        case .trialEnded: "Your free trial has ended. You can still open your parts and export them; buy a license to edit and save."
        case .licensed(let key): key.isEmpty ? "Licensed." : "Licensed. Key \(key)."
        case .licenseExpired: "This license has expired. You can still open and export your parts."
        case .needsConnection: "SimplMaker has not been able to confirm your license for over a month. Connect to the internet and it will check again."
        }
    }

    /// Whether a key is stored (working or not), so the window offers Deactivate rather than a key field.
    var hasKey: Bool {
        switch self {
        case .licensed, .licenseExpired, .needsConnection: true
        case .trial, .trialEnded: false
        }
    }
}

struct LicenseView: View {
    let license: LicenseManager
    @State private var key = ""

    var body: some View {
        Form {
            Section {
                Text(license.status.summary)
                if license.status.hasKey {
                    Button("Deactivate This Mac") { Task { await license.deactivate() } }
                        .disabled(license.isBusy)
                    Text("Deactivating frees the key so you can use it on another Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    TextField("License key", text: $key)
                        .textFieldStyle(.roundedBorder)
                        .disabled(license.isBusy)
                        .onSubmit { activate() }
                    HStack {
                        Button("Activate") { activate() }
                            .disabled(license.isBusy || key.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Buy SimplMaker…") { license.buy() }
                        if license.isBusy { ProgressView().controlSize(.small) }
                    }
                }
                if let message = license.errorMessage {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func activate() { Task { await license.activate(key: key) } }
}

/// The License window opened from the SimplMaker menu and the banners.
struct LicenseWindow: View {
    var body: some View {
        LicenseView(license: .shared)
            .frame(width: 460)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A line in the welcome window while the trial runs (or after it ended).
struct LicenseNotice: View {
    let license: LicenseManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if license.isEnforced, !license.isLicensed {
            HStack(spacing: 6) {
                Text(license.status.summary).foregroundStyle(.secondary)
                Button("Buy…") { license.buy() }.buttonStyle(.link)
                Button("Enter License…") { openWindow(id: AppWindows.licenseID) }.buttonStyle(.link)
            }
            .font(.callout)
        }
    }
}

/// Over a part that cannot be edited because the trial or the license has ended.
struct LockedBanner: View {
    let license: LicenseManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if !license.allowsEditing {
            HStack(spacing: 10) {
                Image(systemName: "lock.fill")
                Text("Editing is off: \(license.status.summary)")
                    .lineLimit(2)
                Button("Buy…") { license.buy() }
                Button("Enter License…") { openWindow(id: AppWindows.licenseID) }
            }
            .font(.callout)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
            .transition(.opacity)
        }
    }
}
