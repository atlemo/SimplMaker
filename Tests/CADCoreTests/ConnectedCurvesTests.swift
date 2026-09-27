// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CADCore

/// Double-click selection in a sketch: every curve joined end to end.
@Suite struct ConnectedCurvesTests {
    @Test func aRectangleAndWhatTouchesIt() {
        var s = Sketch()
        let rect = s.addRectangle(0, 0, 40, 20)
        let tail = s.addLine(rect.corners[2], s.addPoint(60, 40))           // shares a corner
        let far = s.addPoint(80, 0), near = s.addPoint(60, 40)
        let tied = s.addLine(near, far)                                      // coincident with the tail's end
        if case .line(_, let end)? = s.curve(tail)?.geometry { s.constrain(.coincident(end, near)) }
        let alone = s.addLine(s.addPoint(0, 50), s.addPoint(10, 50))
        let diagonal = s.addLine(rect.corners[0], rect.corners[2], construction: true)

        let chain = s.connectedCurves(rect.lines[0])
        #expect(Set(chain) == Set(rect.lines + [tail, tied]) && chain.first == rect.lines[0])
        #expect(!chain.contains(alone) && !chain.contains(diagonal), "separate and construction curves stay out")
        #expect(s.connectedCurves(diagonal) == [diagonal], "construction only joins construction")
    }
}
