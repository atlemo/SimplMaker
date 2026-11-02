// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import Testing
@testable import CADKernel

/// A sketch that stops being solvable says which of its constraints and dimensions can't all hold.
@Suite struct SketchConflictErrorTests {
    @Test func theErrorNamesTheRulesThatFight() throws {
        var s = Sketch()
        let end = s.addPoint(30, 0)
        let l = s.addLine("origin", end)
        s.constrain(.horizontal(l))
        s.dimension(.length(l), "width", id: "len")
        s.dimension(.horizontalDistance("origin", end), "50", id: "across")
        var d = CADDocument()
        d.parameters = [Parameter("width", "40")]
        d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s)))]
        let result = Regenerator.regenerate(d)
        let message = try #require(result.errors["sk"])
        #expect(message.contains("cannot all hold") && message.contains("Length") && message.contains("= width") && message.contains("= 50"),
                Comment(rawValue: message))
    }
}
