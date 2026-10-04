// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation
import Testing
@testable import CADCore

@Suite struct ExpressionCompletionTests {
    let params = [
        CompletionCandidate(name: "width", detail: "40 mm"),
        CompletionCandidate(name: "wall", detail: "2 mm"),
        CompletionCandidate(name: "side_wall", detail: "3 mm"),
        CompletionCandidate(name: "height", detail: "10 mm"),
    ]

    private func names(_ text: String, caret: Int? = nil) -> [String] {
        ExpressionCompletion.suggestions(in: text, caret: caret ?? text.utf16.count, parameters: params)?.items.map(\.name) ?? []
    }

    @Test func offersParametersThatStartWithTheWord() {
        #expect(names("w") == ["width", "wall"], "one letter: only names that start with it")
        #expect(names("wa") == ["wall", "side_wall"], "two letters: names starting with it, then those containing it")
        #expect(names("wi") == ["width"])
        #expect(names("WID") == ["width"], "case doesn't matter")
        #expect(names("h") == ["height"])
    }

    @Test func parametersComeBeforeBuiltIns() {
        #expect(names("s") == ["side_wall", "sin", "sqrt"])
        let withSin = params + [CompletionCandidate(name: "sides", detail: "6", kind: .parameter)]
        let items = ExpressionCompletion.suggestions(for: "si", parameters: withSin).map(\.name)
        #expect(items == ["side_wall", "sides", "sin", "asin"], "the user's names, then built-in ones; containing matches last")
        #expect(items.firstIndex(of: "sides")! < items.firstIndex(of: "sin")!)
    }

    @Test func aCompleteWordIsLeftAlone() {
        #expect(names("width").isEmpty)
        #expect(names("height").isEmpty)
        #expect(names("wall") == ["wall", "side_wall"], "still offered when a longer name contains it")
    }

    @Test func completesAfterOperatorsAndBrackets() {
        #expect(names("2 * wi") == ["width"])
        #expect(names("(wi") == ["width"])
        #expect(names("max(1, he") == ["height"])
        #expect(names("10 mm + wi") == ["width"])
        #expect(names("-wi") == ["width"])
    }

    @Test func staysQuietWhereOnlyAUnitCanGo() {
        #expect(names("3 w").isEmpty)
        #expect(names("3m").isEmpty)
        #expect(names("(2 + 1) w").isEmpty)
        #expect(names("12").isEmpty)
        #expect(names("1e").isEmpty, "the exponent of a number")
        #expect(names("").isEmpty)
        #expect(names("width wi").isEmpty)
    }

    @Test func staysQuietInTheMiddleOfAWord() {
        #expect(names("width", caret: 2).isEmpty)
        #expect(names("wi + 2", caret: 2) == ["width"])
    }

    @Test func letterOutsideTheBasicAlphabet() {
        let p = [CompletionCandidate(name: "åpning", detail: "5 mm")]
        #expect(ExpressionCompletion.suggestions(for: "å", parameters: p).map(\.name) == ["åpning"])
        #expect(ExpressionCompletion.word(in: "2 * åp", caret: 6)?.prefix == "åp")
    }

    @Test func wordRangeIsInUTF16Offsets() throws {
        let w = try #require(ExpressionCompletion.word(in: "2 * wid", caret: 7))
        #expect(w.prefix == "wid")
        #expect(w.range == 4..<7)
    }

    @Test func applyingReplacesTheWordAndPlacesTheCaret() throws {
        let width = params[0]
        let r = ExpressionCompletion.applying(width, to: "2 * wi + 1", replacing: 4..<6)
        #expect(r.text == "2 * width + 1")
        #expect(r.caret == 9)
        let sin = try #require(ExpressionCompletion.builtins.first { $0.name == "sin" })
        let f = ExpressionCompletion.applying(sin, to: "si", replacing: 0..<2)
        #expect(f.text == "sin(")
        #expect(f.caret == 4)
    }

    @Test func limitsTheList() {
        let many = (0..<30).map { CompletionCandidate(name: "p\($0)") }
        #expect(ExpressionCompletion.suggestions(for: "p", parameters: many).count == ExpressionCompletion.maxSuggestions)
    }

    @Test func everyBuiltInIsReallyUsable() throws {
        for b in ExpressionCompletion.builtins {
            #expect(Expressions.isReserved(b.name), "\(b.name) is a word the parser knows")
        }
    }
}
