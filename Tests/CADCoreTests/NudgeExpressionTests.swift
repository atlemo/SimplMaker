// Copyright © 2026 Atle Mo. All rights reserved.
import Testing
@testable import CADCore

@Suite struct NudgeExpressionTests {
    @Test func plainNumbersMoveAndKeepTheirUnit() {
        #expect(nudgedExpression("68", by: -1) == "67")
        #expect(nudgedExpression("12.5 mm", by: 1) == "13.5 mm")
        #expect(nudgedExpression("30 deg", by: 10) == "40 deg")
        #expect(nudgedExpression(" 0.3 ", by: 0.1) == "0.4")
        #expect(nudgedExpression("0", by: -1) == "-1")
        #expect(nudgedExpression("1", by: -1) == "0")
    }

    @Test func expressionsAreLeftAlone() {
        #expect(nudgedExpression("wall * 2", by: 1) == nil)
        #expect(nudgedExpression("width", by: 1) == nil)
        #expect(nudgedExpression("2 + 3", by: 1) == nil)
        #expect(nudgedExpression("", by: 1) == nil)
    }
}
