// Quitting waits for a rebuild that is inside the geometry kernel, and no new one starts meanwhile.
// Copyright © 2026 Atle Mo. All rights reserved.
import Testing
@testable import SimplMaker

@Suite struct KernelActivityTests {
    @Test func idleQuitDoesNotWait() {
        #expect(!KernelActivity().beginQuit())
    }

    @Test func runningRebuildHoldsTheQuitUntilItEnds() {
        let activity = KernelActivity()
        #expect(activity.begin())
        #expect(activity.beginQuit())
        #expect(activity.isBusy)
        activity.end()
        #expect(!activity.isBusy)
    }

    @Test func noRebuildStartsWhileQuitting() {
        let activity = KernelActivity()
        _ = activity.beginQuit()
        #expect(!activity.begin())
        activity.cancelQuit()
        #expect(activity.begin())
    }
}
