// The ground grid fades out as the view flattens toward the floor, and stays solid from above.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import simd
import Testing
@testable import SimplMaker

@MainActor struct GroundGridFadeTests {
    /// The view direction for a camera at `degrees` above the floor (looking down at it).
    private func forward(elevation degrees: Float) -> SIMD3<Float> {
        let a = degrees * .pi / 180
        return SIMD3(1, 0, 0) * cos(a) + SIMD3(0, 0, -sin(a))
    }

    @Test func theGridIsSolidFromAbove() {
        #expect(Renderer.groundGridOpacity(forward: forward(elevation: 90)) == 1)
        #expect(Renderer.groundGridOpacity(forward: forward(elevation: 31.5)) == 1, "the default view (pitch 0.55 rad) shows the grid as before")
        #expect(Renderer.groundGridOpacity(forward: forward(elevation: 27)) == 1)
    }

    @Test func theGridIsGoneWhenEdgeOn() {
        #expect(Renderer.groundGridOpacity(forward: forward(elevation: 0)) == 0)
        #expect(Renderer.groundGridOpacity(forward: forward(elevation: 4)) == 0)
    }

    @Test func theGridFadesSmoothlyInBetween() {
        var last: Float = -1
        for degrees in stride(from: Float(0), through: 30, by: 1) {
            let o = Renderer.groundGridOpacity(forward: forward(elevation: degrees))
            #expect(o >= 0 && o <= 1)
            #expect(o >= last, "the grid never gets fainter as the view rises (\(degrees)°)")
            last = o
        }
        let mid = Renderer.groundGridOpacity(forward: forward(elevation: 12))
        #expect(mid > 0.05 && mid < 0.95, "half-way: \(mid)")
    }
}
