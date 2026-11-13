// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import SimplMaker

/// The tools the Spacebar panel shows while sketching: the stored choice and the search.
@Suite struct SketchShortcutListTests {
    @Test func nothingStoredShowsTheDefaults() {
        #expect(SketchShortcutList.decode("") == SketchShortcutList.defaults)
        #expect(!SketchShortcutList.defaults.isEmpty)
    }

    @Test func aChoiceSurvivesStoringAndKeepsItsOrder() {
        let chosen: [SketchTool] = [.circle2Point, .line, .trim]
        #expect(SketchShortcutList.decode(SketchShortcutList.encode(chosen)) == chosen)
    }

    @Test func removingEverythingIsNotTheSameAsNeverCustomizing() {
        #expect(SketchShortcutList.decode(SketchShortcutList.encode([])).isEmpty)
    }

    @Test func unknownAndRepeatedNamesAreDropped() {
        #expect(SketchShortcutList.decode("v1:Line,Nonsense,Line,Trim") == [.line, .trim])
    }

    @Test func searchFindsEveryToolByAnyWordOfItsName() {
        #expect(SketchShortcutList.search("").isEmpty)
        let tangent = SketchShortcutList.search("tangent")
        #expect(tangent.contains(.tangentArc) && tangent.contains(.circle2Tangent) && tangent.contains(.circle3Tangent))
        #expect(SketchShortcutList.search("fit spline") == [.bezier])
        #expect(SketchShortcutList.search("zzz").isEmpty)
    }
}
