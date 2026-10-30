// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation
import Testing
@testable import CADCore

/// Naming the constraints and dimensions that fight each other, or repeat each other.
@Suite struct SketchDiagnosisTests {
    /// A line from the origin to (30, 0), horizontal.
    private func line() -> (sketch: Sketch, line: EntityID, end: EntityID) {
        var s = Sketch()
        let end = s.addPoint(30, 0)
        let l = s.addLine("origin", end)
        s.constrain(.horizontal(l))
        return (s, l, end)
    }

    @Test func aSketchThatIsFineHasNothingToReport() {
        var (s, l, _) = line()
        s.dimension(.length(l), "40", id: "len")
        #expect(SketchSolver.diagnose(s, dimensionValues: ["len": 40]).isEmpty)
        #expect(SketchSolver.diagnose(Sketch(), dimensionValues: [:]).isEmpty)
    }

    @Test func twoDimensionsThatDisagreeAreNamedAndTheHorizontalIsLeftOut() throws {
        var (s, l, end) = line()
        s.dimension(.length(l), "40", id: "len")
        s.dimension(.horizontalDistance("origin", end), "50", id: "across")
        let values: [EntityID: Double] = ["len": 40, "across": 50]
        var solved = s
        #expect(SketchSolver.solve(&solved, dimensionValues: values).status == .failed, "they really cannot both hold")
        let d = SketchSolver.diagnose(s, dimensionValues: values)
        #expect(Set(d.conflicting) == ["len", "across"], "\(d)")
        #expect(d.redundant.isEmpty)
        let text = try #require(s.conflictText(d.conflicting))
        #expect(text.contains("Length") && text.contains("= 40") && text.contains("= 50"), Comment(rawValue: text))
    }

    @Test func aDimensionThatSaysWhatTheOthersSayIsRedundantNotAConflict() {
        var (s, l, end) = line()
        s.dimension(.length(l), "40", id: "len")
        s.dimension(.horizontalDistance("origin", end), "40", id: "across")
        let d = SketchSolver.diagnose(s, dimensionValues: ["len": 40, "across": 40])
        #expect(d.conflicting.isEmpty && d.redundant == ["across"], "the later one repeats the earlier: \(d)")
    }

    @Test func aRectangleWithEveryRightAngleAlsoStatedIsRedundant() {
        var s = Sketch()
        let a = s.addPoint(0, 0), b = s.addPoint(40, 0), c = s.addPoint(40, 20), e = s.addPoint(0, 20)
        let l1 = s.addLine(a, b), l2 = s.addLine(b, c), l3 = s.addLine(c, e), l4 = s.addLine(e, a)
        for k in [SketchConstraint.Kind.horizontal(l1), .vertical(l2), .horizontal(l3), .vertical(l4)] { s.constrain(k) }
        #expect(SketchSolver.diagnose(s, dimensionValues: [:]).isEmpty)
        s.constrain(.perpendicular(l1, l2))
        let d = SketchSolver.diagnose(s, dimensionValues: [:])
        #expect(d.conflicting.isEmpty && d.redundant.count == 1, "\(d)")
        #expect(s.describeRule(d.redundant[0]) == "Perpendicular")
    }

    @Test func addingARuleThatFightsTellsWhatItFightsWith() throws {
        var (s, l, end) = line()
        s.dimension(.length(l), "40", id: "len")
        let result = s.diagnosis(adding: [.vertical(l)], values: ["len": 40])
        #expect(result.diagnosis.conflicting.count >= 2, "\(result.diagnosis)")
        let others = try #require(s.conflictText(result.diagnosis.conflicting, excluding: result.added))
        #expect(others.contains("Horizontal") || others.contains("Length"), Comment(rawValue: others))
        _ = end
    }

    @Test func tooManyRulesAreNotAnalysedAndNothingCrashes() {
        var s = Sketch()
        for i in 0..<(SketchSolver.diagnoseLimit + 5) { s.addPoint(Double(i), 0) }
        s.constrain(.coincident("origin", s.points[1].id))
        #expect(SketchSolver.diagnose(s, dimensionValues: [:]).isEmpty)
        var t = Sketch()
        t.constrain(.horizontal("nope"))
        t.dimension(.length("nope"), "1", id: "d")
        _ = SketchSolver.diagnose(t, dimensionValues: ["d": 1])
    }
}
