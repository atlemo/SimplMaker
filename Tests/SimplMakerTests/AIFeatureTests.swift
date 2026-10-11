// The build-time switch for the AI mode: what turns it on, and that without it nothing starts or is written.
// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation
import Testing
@testable import SimplMaker

@Suite @MainActor struct AIFeatureTests {
    @Test func theBundleDecidesAndWithoutAnAnswerTheBuildTypeDoes() {
        // A key in the bundle wins, in either direction.
        #expect(AIFeature.resolve(plistValue: true, debugBuild: false))
        #expect(!AIFeature.resolve(plistValue: false, debugBuild: true))
        for on in ["true", "TRUE", "yes", "1", " true "] { #expect(AIFeature.resolve(plistValue: on, debugBuild: false), "\(on)") }
        for off in ["false", "no", "0", ""] { #expect(!AIFeature.resolve(plistValue: off, debugBuild: true), "\(off)") }
        #expect(AIFeature.resolve(plistValue: NSNumber(value: 1), debugBuild: false))
        #expect(!AIFeature.resolve(plistValue: NSNumber(value: 0), debugBuild: true))
        // No key: debug builds have it, release builds don't.
        #expect(AIFeature.resolve(plistValue: nil, debugBuild: true))
        #expect(!AIFeature.resolve(plistValue: nil, debugBuild: false))
        // Something unreadable is not an answer.
        #expect(AIFeature.resolve(plistValue: "maybe", debugBuild: true))
        #expect(!AIFeature.resolve(plistValue: "maybe", debugBuild: false))
        #expect(!AIFeature.resolve(plistValue: ["x"], debugBuild: false))
    }

    @Test func aBuildWithoutTheModeNeverListensWritesOrAcceptsTheSwitch() async throws {
        let s = AIConnectionTests.Setup(); defer { s.cleanUp() }
        s.defaults.set(true, forKey: AIConnection.enabledKey)  // as if a user's preferences already say yes
        let ai = AIConnection(defaults: s.defaults, file: s.file, service: CADService(registry: s.rig.registry, licensed: { true }),
                              licensed: { true }, version: "t", available: false)
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

    @Test func withoutABundleKeyTheBuildTypeDecides() {
        // `swift test` runs without an app bundle, so the mode follows the build type (on in debug builds).
        #expect(Bundle.main.object(forInfoDictionaryKey: AIFeature.infoKey) == nil)
        #expect(AIFeature.isAvailable == AIFeature.isDebugBuild)
    }
}
