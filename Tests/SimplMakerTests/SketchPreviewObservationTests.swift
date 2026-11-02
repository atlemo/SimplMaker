// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import Observation
import Testing
@testable import SimplMaker

/// The viewport asks for the rubber-band preview in every update, and the preview snaps. Snapping must not notify
/// observers when nothing changed, or each update starts the next and the viewport redraws without end (about 60 %
/// of a core on a trivial part while a tool waited for its second click, and a frozen window on a big one).
@Suite @MainActor struct SketchPreviewObservationTests {
    private func session() -> SketchSession {
        SketchSession(featureID: IDs.make(), frame: .xy, sketch: Sketch(), parameters: ParameterValues())
    }

    private func mouse(_ phase: SketchMouse.Phase, _ x: Double, _ y: Double) -> SketchMouse {
        SketchMouse(phase: phase, uv: SIMD2(x, y), pick: nil, tolerance: 0.5, gridStep: 1, snapping: true)
    }

    private func click(_ s: SketchSession, _ x: Double, _ y: Double) {
        _ = s.handle(mouse(.moved, x, y))
        _ = s.handle(mouse(.down, x, y))
        _ = s.handle(mouse(.up, x, y))
    }

    private final class Flag: @unchecked Sendable { var value = false }

    /// Whether `body` changes anything `read` looked at.
    private func notifies(reading read: @MainActor () -> Void, whenRunning body: @MainActor () -> Void) -> Bool {
        let fired = Flag()
        withObservationTracking({ read() }, onChange: { fired.value = true })
        body()
        return fired.value
    }

    @Test func repeatingThePreviewDoesNotNotifyObservers() {
        let s = session()
        s.setTool(.circle)
        click(s, 0, 0)
        _ = s.handle(mouse(.moved, 7, 3))
        _ = s.previewPolylines()  // the first call may record a new snap
        let again = notifies(reading: { _ = s.lastSnap }, whenRunning: { _ = s.previewPolylines() })
        #expect(!again, "the same cursor gives the same snap, so nobody should be told again")
        #expect(s.lastSnap?.kind == .grid)
    }

    @Test func aDifferentSnapStillNotifiesObservers() {
        let s = session()
        s.setTool(.circle)
        click(s, 0, 0)
        _ = s.handle(mouse(.moved, 7, 3))
        _ = s.previewPolylines()
        let moved = notifies(reading: { _ = s.lastSnap }, whenRunning: {
            _ = s.handle(mouse(.moved, 12, 5))
            _ = s.previewPolylines()
        })
        #expect(moved, "a new snap position must still reach the status bar and the marker")
    }
}
