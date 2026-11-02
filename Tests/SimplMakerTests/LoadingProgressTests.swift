// A part that takes a while to build reports how far it has got, and stops once it is done.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import Testing
@testable import SimplMaker

@Suite @MainActor struct LoadingProgressTests {
    @Test func aSlowPartReportsProgressWhileItOpensAndNoneAfter() async throws {
        let model = DocumentModel(document: .manifoldDemo())
        var seen: [RegenProgress] = []
        for _ in 0..<4000 where model.isRegenerating || model.result == nil {
            if let p = model.regenProgress, seen.last != p { seen.append(p) }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.result != nil)
        #expect(!seen.isEmpty, "a build of several seconds shows its progress")
        #expect(seen.allSatisfy { $0.done < $0.total })
        #expect(seen.map(\.done) == seen.map(\.done).sorted())
        #expect(model.regenProgress == nil)
    }

    @Test func aQuickPartNeverShowsProgress() async throws {
        let model = DocumentModel(document: .demo())
        var shown = false
        for _ in 0..<1000 where model.isRegenerating || model.result == nil {
            if model.regenProgress != nil { shown = true }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(model.result != nil)
        #expect(!shown)
    }
}
