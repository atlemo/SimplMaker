// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import Foundation
import Testing
@testable import SimplMaker

/// A sketch that is asked to take a constraint it can't says what the constraint fights.
@Suite @MainActor struct ConflictMessageTests {
    private func session(_ sketch: Sketch) -> SketchSession {
        SketchSession(featureID: IDs.make(), frame: .xy, sketch: sketch, parameters: ParameterEvaluator.evaluate([]))
    }

    /// A horizontal line from the origin, 40 long.
    private func horizontalLine() -> (sketch: Sketch, line: EntityID) {
        var s = Sketch()
        let end = s.addPoint(40, 0)
        let l = s.addLine("origin", end)
        s.constrain(.horizontal(l))
        s.dimension(.length(l), "40", id: "len")
        return (s, l)
    }

    @Test func aVerticalOnAHorizontalLineNamesWhatItFights() throws {
        let (sketch, line) = horizontalLine()
        let s = session(sketch)
        s.select(line, additive: false)
        #expect(s.apply(.vertical) == nil)
        let message = try #require(s.message)
        #expect(message.hasPrefix("Vertical would over-constrain the sketch: it fights "), Comment(rawValue: message))
        #expect(message.contains("Horizontal") || message.contains("Length"), Comment(rawValue: message))
    }

    @Test func aSecondDimensionThatDisagreesNamesTheFirst() throws {
        let (sketch, line) = horizontalLine()
        let s = session(sketch)
        s.select(line, additive: false)
        // A horizontal distance of 50 between the same two points cannot hold with a length of 40.
        guard case .line(let a, let b) = try #require(sketch.curve(line)).geometry else { return }
        #expect(s.addDimension(.horizontalDistance(a, b), value: 50) == nil)
        let message = try #require(s.message)
        #expect(message.contains("fights") && message.contains("Length"), Comment(rawValue: message))
    }

    @Test func aRepeatedStatementIsCountedAsRedundantInTheStatusLine() throws {
        var (sketch, line) = horizontalLine()
        guard case .line(let a, let b) = try #require(sketch.curve(line)).geometry else { return }
        sketch.dimension(.horizontalDistance(a, b), "40", id: "across")
        let s = session(sketch)
        #expect(s.diagnosis.redundant == ["across"], "\(s.diagnosis)")
        #expect(s.statusText.contains("1 redundant"), Comment(rawValue: s.statusText))
    }
}
