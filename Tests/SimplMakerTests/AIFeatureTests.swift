// The build-time switch for the AI mode: every build has it unless the bundle says no, and without it nothing starts or is written.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SimplMaker

@Suite @MainActor struct AIFeatureTests {
    @Test func everyBuildHasTheModeUnlessTheBundleSaysNo() {
        #expect(AIFeature.resolve(plistValue: true))
        #expect(!AIFeature.resolve(plistValue: false))
        for on in ["true", "TRUE", "yes", "1", " true "] { #expect(AIFeature.resolve(plistValue: on), "\(on)") }
        for off in ["false", "FALSE", "no", "0", " false "] { #expect(!AIFeature.resolve(plistValue: off), "\(off)") }
        #expect(AIFeature.resolve(plistValue: NSNumber(value: 1)))
        #expect(!AIFeature.resolve(plistValue: NSNumber(value: 0)))
        // No key, or something unreadable: the mode is there (it is still off until the user turns it on).
        #expect(AIFeature.resolve(plistValue: nil))
        #expect(AIFeature.resolve(plistValue: ""))
        #expect(AIFeature.resolve(plistValue: "maybe"))
        #expect(AIFeature.resolve(plistValue: ["x"]))
    }

    @Test func aBuildWithoutTheModeNeverListensWritesOrAcceptsTheSwitch() async throws {
        let s = AIConnectionTests.Setup(); defer { s.cleanUp() }
        s.defaults.set(true, forKey: AIConnection.enabledKey)  // as if a user's preferences already say yes
        let ai = AIConnection(defaults: s.defaults, file: s.file, service: CADService(registry: s.rig.registry),
                              version: "t", available: false)
        #expect(!ai.isAvailable && !ai.isEnabled, "it reads as off whatever the preferences say")
        await ai.refresh()
        ai.startIfEnabled()
        ai.setEnabled(true)
        await ai.refresh()
        #expect(ai.status == .off && ai.endpoint == nil && ai.port == nil)
        #expect(!ai.isEnabled)
        ai.stop()
        #expect(!FileManager.default.fileExists(atPath: s.file.url.path), "no connection file, ever")
        #expect(!FileManager.default.fileExists(atPath: s.directory.path))
    }

    @Test func withoutABundleKeyTheModeIsAvailableButOffUntilTheUserTurnsItOn() {
        // `swift test` runs without an app bundle.
        #expect(Bundle.main.object(forInfoDictionaryKey: AIFeature.infoKey) == nil)
        #expect(AIFeature.isAvailable)
        let s = AIConnectionTests.Setup(); defer { s.cleanUp() }
        let ai = AIConnection(defaults: s.defaults, file: s.file, service: CADService(registry: s.rig.registry),
                              version: "t", available: AIFeature.isAvailable)
        #expect(ai.isAvailable && !ai.isEnabled, "off by default")
    }
}
