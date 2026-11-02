// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SimplMaker

/// The ground grid reaches as far as the view does, at any zoom.
@Suite @MainActor struct WorldGridTests {
    private let view = CGSize(width: 900, height: 600)

    @Test func coversTheWholeViewWhenZoomedFarOut() throws {
        let renderer = try #require(Renderer())
        renderer.camera.setStandard(.top)
        renderer.camera.target = .zero
        renderer.camera.distance = 20_000  // a 14 km view: far past the old 200 mm grid
        let key = renderer.worldGridKey(viewSize: view)
        let half = Double(renderer.camera.halfHeight)
        #expect(key.x.lowerBound <= -half * 1.5 && key.x.upperBound >= half * 1.5)
        #expect(key.y.lowerBound <= -half && key.y.upperBound >= half)
    }

    @Test func followsThePanAndKeepsLinesALegibleDistanceApart() throws {
        let renderer = try #require(Renderer())
        renderer.camera.setStandard(.top)
        renderer.camera.distance = 300
        renderer.camera.target = SIMD3(5000, -3000, 0)
        let key = renderer.worldGridKey(viewSize: view)
        #expect(key.x.contains(5000) && key.y.contains(-3000))
        let mmPerPoint = Double(2 * renderer.camera.halfHeight) / Double(view.height)
        #expect(key.minor >= 12 * mmPerPoint, "lines at least 12 points apart")
        // Only what's in view, plus a little: not a grid out to the old limits.
        #expect(key.x.upperBound - key.x.lowerBound < 4 * 2 * Double(renderer.camera.halfHeight) * Double(view.width / view.height))
    }

    @Test func aGroundSeenAlmostEdgeOnStaysWithinAReasonableNumberOfLines() throws {
        let renderer = try #require(Renderer())
        renderer.camera.pitch = 0.02  // looking nearly along the ground: the far rays never meet it
        renderer.camera.orthographic = false
        renderer.camera.distance = 500
        let key = renderer.worldGridKey(viewSize: view)
        #expect(key.i1 - key.i0 <= 1300 && key.j1 - key.j0 <= 1300)
    }

    @Test func thePerspectiveHorizonDoesNotMakeItInfinite() throws {
        let renderer = try #require(Renderer())
        renderer.camera.pitch = 0.3
        renderer.camera.orthographic = false
        renderer.camera.distance = 500  // the top of the view looks above the horizon
        let key = renderer.worldGridKey(viewSize: view)
        #expect(key.x.upperBound.isFinite && key.i1 - key.i0 <= 1300)
    }
}
