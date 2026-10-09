// Which parameters a feature reads, so a rebuild's cache key moves only when one of those changes.
// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import Foundation

/// A feature's cache key used to cover the whole parameter table, so editing any parameter rebuilt the whole
/// timeline, threads and all. Now it covers the values of the parameters the feature's own text mentions, and
/// those they are built from.
///
/// This errs towards rebuilding: every word in the feature (ids and names too) counts as a possible parameter
/// name, so an extra match costs a rebuild and a missed one would show stale geometry. A feature that builds on
/// another one is covered by the key chain (it hashes the key of the feature before it).
final class ParameterDependencies: @unchecked Sendable {
    static let shared = ParameterDependencies()

    private let lock = NSLock()
    private var words: [Int: Set<String>] = [:]

    /// Every word in a feature, by the feature's hash.
    func words(of feature: Feature, hash: Int) -> Set<String> {
        lock.lock()
        if let hit = words[hash] { lock.unlock(); return hit }
        lock.unlock()
        let found = Self.scan(feature)
        lock.lock(); defer { lock.unlock() }
        if words.count >= 4096 { words.removeAll() }  // many edits in one session: start over
        words[hash] = found
        return found
    }

    /// The words in a piece of text (a parameter's expression).
    static func words(in text: String) -> Set<String> {
        var out: Set<String> = []
        add(words: Array(text.utf8), to: &out)
        return out
    }

    private static func scan(_ feature: Feature) -> Set<String> {
        // An imported file has no expressions, and its bytes would take long to scan.
        if case .importBody = feature.kind { return [] }
        guard let json = try? JSONEncoder().encode(feature) else { return ["\u{0}"] }  // can't tell: matches nothing, see below
        var out: Set<String> = []
        add(words: Array(json), to: &out)
        return out
    }

    /// Runs of letters, digits, underscores and non-ASCII bytes (part of a Unicode name). A run that starts with
    /// digits is also added without them, in case a number is written straight against a name.
    private static func add(words bytes: [UInt8], to out: inout Set<String>) {
        func isWord(_ b: UInt8) -> Bool {
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F || b >= 0x80
        }
        var i = 0
        while i < bytes.count {
            guard isWord(bytes[i]) else { i += 1; continue }
            var j = i
            while j < bytes.count, isWord(bytes[j]) { j += 1 }
            out.insert(String(decoding: bytes[i..<j], as: UTF8.self))
            var k = i
            while k < j, bytes[k] >= 0x30, bytes[k] <= 0x39 { k += 1 }
            if k > i, k < j { out.insert(String(decoding: bytes[k..<j], as: UTF8.self)) }
            i = j
        }
    }

    /// The parameter names a feature (given its words) reads, and the ones they are built from, sorted.
    /// `inputs` is each parameter's own words.
    static func closure(of words: Set<String>, inputs: [String: Set<String>]) -> [String] {
        var seen: Set<String> = []
        var pending = words.filter { inputs[$0] != nil }
        // A feature that couldn't be encoded depends on everything.
        if words.contains("\u{0}") { pending = Set(inputs.keys) }
        while let name = pending.popFirst() {
            guard seen.insert(name).inserted else { continue }
            for w in inputs[name] ?? [] where inputs[w] != nil && !seen.contains(w) { pending.insert(w) }
        }
        return seen.sorted()
    }
}
