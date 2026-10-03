// Auto-complete for the words in an expression: parameter names, functions and constants.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A word that can be typed in an expression field.
public struct CompletionCandidate: Equatable, Sendable {
    public enum Kind: Sendable { case parameter, function, constant }

    public var name: String
    /// What it is worth or takes, shown beside the name ("40 mm", "sin(angle)").
    public var detail: String
    public var kind: Kind

    public init(name: String, detail: String = "", kind: Kind = .parameter) {
        self.name = name; self.detail = detail; self.kind = kind
    }

    /// What typing it puts in the field: a function opens its parenthesis.
    public var insertion: String { kind == .function ? name + "(" : name }
}

public enum ExpressionCompletion {
    /// The word being typed, and where it sits in the text (UTF-16 offsets, as an NSTextView counts).
    public struct Word: Equatable, Sendable {
        public var prefix: String
        public var range: Range<Int>
    }

    public static let maxSuggestions = 8

    /// The functions and constants an expression can use, after the user's parameters.
    public static let builtins: [CompletionCandidate] = [
        CompletionCandidate(name: "pi", detail: "3.14159", kind: .constant),
        CompletionCandidate(name: "e", detail: "2.71828", kind: .constant),
        CompletionCandidate(name: "sin", detail: "sin(angle)", kind: .function),
        CompletionCandidate(name: "cos", detail: "cos(angle)", kind: .function),
        CompletionCandidate(name: "tan", detail: "tan(angle)", kind: .function),
        CompletionCandidate(name: "asin", detail: "asin(ratio)", kind: .function),
        CompletionCandidate(name: "acos", detail: "acos(ratio)", kind: .function),
        CompletionCandidate(name: "atan", detail: "atan(ratio)", kind: .function),
        CompletionCandidate(name: "sqrt", detail: "sqrt(value)", kind: .function),
        CompletionCandidate(name: "abs", detail: "abs(value)", kind: .function),
        CompletionCandidate(name: "min", detail: "min(a, b)", kind: .function),
        CompletionCandidate(name: "max", detail: "max(a, b)", kind: .function),
        CompletionCandidate(name: "round", detail: "round(value)", kind: .function),
        CompletionCandidate(name: "floor", detail: "floor(value)", kind: .function),
        CompletionCandidate(name: "ceil", detail: "ceil(value)", kind: .function),
    ]

    /// The word just before the caret, if a name belongs there: the caret ends a word that starts with a
    /// letter, and what comes before it asks for a value (the start, an operator, "(" or ",").
    /// After a number a word can only be a unit ("3 mm"), which is not completed.
    public static func word(in text: String, caret: Int) -> Word? {
        guard caret >= 0, caret <= text.utf16.count else { return nil }
        let end = String.Index(utf16Offset: caret, in: text)
        func isNameCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        if end < text.endIndex, isNameCharacter(text[end]) { return nil }  // in the middle of a word
        var start = end
        while start > text.startIndex {
            let before = text.index(before: start)
            guard isNameCharacter(text[before]) else { break }
            start = before
        }
        guard let first = text[start..<end].first, first.isLetter || first == "_" else { return nil }
        var i = start
        while i > text.startIndex {
            i = text.index(before: i)
            let c = text[i]
            if c.isWhitespace { continue }
            guard "+-*/^(,".contains(c) else { return nil }
            break
        }
        return Word(prefix: String(text[start..<end]), range: start.utf16Offset(in: text)..<end.utf16Offset(in: text))
    }

    /// The names that fit what is typed: those starting with it first (the user's parameters before the
    /// built-in words), then, for two letters or more, those containing it. Nothing is offered when the word
    /// is already complete and nothing else fits.
    public static func suggestions(for prefix: String, parameters: [CompletionCandidate]) -> [CompletionCandidate] {
        guard !prefix.isEmpty else { return [] }
        let all = parameters + builtins.filter { b in !parameters.contains { $0.name == b.name } }
        let key = prefix.lowercased()
        var starting: [CompletionCandidate] = [], containing: [CompletionCandidate] = []
        for c in all {
            let name = c.name.lowercased()
            if name.hasPrefix(key) { starting.append(c) } else if key.count >= 2, name.contains(key) { containing.append(c) }
        }
        let found = starting + containing
        if found.count == 1, found[0].name == prefix { return [] }
        return Array(found.prefix(maxSuggestions))
    }

    /// The suggestions for the word at the caret.
    public static func suggestions(in text: String, caret: Int, parameters: [CompletionCandidate]) -> (word: Word, items: [CompletionCandidate])? {
        guard let word = word(in: text, caret: caret) else { return nil }
        let items = suggestions(for: word.prefix, parameters: parameters)
        return items.isEmpty ? nil : (word, items)
    }

    /// `text` with the word replaced by the chosen candidate, and where the caret goes.
    public static func applying(_ candidate: CompletionCandidate, to text: String, replacing range: Range<Int>) -> (text: String, caret: Int) {
        let lo = String.Index(utf16Offset: range.lowerBound, in: text), hi = String.Index(utf16Offset: range.upperBound, in: text)
        var out = text
        out.replaceSubrange(lo..<hi, with: candidate.insertion)
        return (out, range.lowerBound + candidate.insertion.utf16.count)
    }
}
