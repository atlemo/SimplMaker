// Automatic updates through Sparkle. The feed and the signing key are named in Info.plist
// (SUFeedURL, SUPublicEDKey); scripts/release.sh builds and signs the archives the feed points to.
// SPDX-License-Identifier: GPL-3.0-or-later
import Combine
import Foundation
import Sparkle

@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController?
    private var observation: AnyCancellable?

    /// False while a check is already running (the menu item is disabled then), and without a feed.
    @Published private(set) var canCheckForUpdates = false

    /// Whether this build can update itself. `swift run` has no bundle, so no feed: Sparkle stays off.
    var isAvailable: Bool { controller != nil }

    private init() {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else {
            controller = nil
            return
        }
        // Not started yet: AppDelegate starts it once the app has launched.
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    }

    func start() {
        guard let controller else { return }
        controller.startUpdater()
        observation = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            objectWillChange.send()
            controller?.updater.automaticallyChecksForUpdates = newValue
        }
    }
}
