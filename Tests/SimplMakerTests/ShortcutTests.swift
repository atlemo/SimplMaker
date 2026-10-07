// Customizable keyboard shortcuts: the stored form, conflicts, and the defaults.
// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation
import Testing
@testable import SimplMaker

@MainActor
@Suite struct ShortcutTests {
    /// A store on its own defaults, so the user's real shortcuts stay out of it.
    private func makeStore() -> (ShortcutStore, UserDefaults) {
        let name = "ShortcutTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (ShortcutStore(defaults: defaults), defaults)
    }

    @Test func chordsSurviveTheStoredForm() {
        let chords = [KeyChord("e"), KeyChord("g", [.command, .option]), KeyChord("1", [.command, .shift]),
                      KeyChord("'", .command), KeyChord("+", [.command]), KeyChord("+"), KeyChord("s", [.command, .control, .option, .shift])]
        for chord in chords { #expect(KeyChord(stored: chord.stored) == chord, "\(chord.stored)") }
        #expect(KeyChord(stored: "") == nil)
        #expect(KeyChord(stored: "hyper+x") == nil)
        #expect(KeyChord(stored: "cmdx") == nil)
    }

    @Test func labelsReadLikeTheMenus() {
        #expect(KeyChord("e").label == "E")
        #expect(KeyChord("g", [.command, .option]).label == "⌥⌘G")
        #expect(KeyChord("s", [.command, .control]).label == "⌃⌘S")
        #expect(KeyChord("1", [.command, .shift]).label == "⇧⌘1")
    }

    @Test func everyCommandStartsWithADistinctShortcutPerScope() {
        for scope in [ShortcutCommand.Scope.app, .sketch] {
            let chords = ShortcutCommand.all.filter { $0.scope == scope }.compactMap(\.defaultChord)
            let count = ShortcutCommand.all.filter { $0.scope == scope }.count
            #expect(chords.count == count, "a command has no default")
            #expect(Set(chords).count == count, "two commands share a default in \(scope)")
        }
        #expect(Set(ShortcutCommand.all.map(\.id)).count == ShortcutCommand.all.count, "ids are unique")
        #expect(ShortcutCommand.all.allSatisfy { Shortcuts.problem($0.defaultChord!, for: $0) == nil }, "a default is not allowed")
    }

    @Test func everyDesignToolAndSketchToolFamilyIsListed() {
        let tools = ShortcutCommand.all.compactMap { c -> DesignTool? in if case .tool(let t) = c { return t } else { return nil } }
        #expect(Set(tools) == Set(DesignTool.allCases) && tools.count == DesignTool.allCases.count)
        let sketch = ShortcutCommand.all.compactMap { c -> SketchTool? in if case .sketch(let t) = c { return t } else { return nil } }
        #expect(Set(sketch.flatMap(\.family)) == Set(SketchTool.allCases), "a sketch tool cannot be set")
    }

    @Test func changesAreStoredAsChangesOnly() {
        let (store, defaults) = makeStore()
        let fillet = ShortcutCommand.tool(.fillet)
        #expect(Shortcuts.chord(fillet, defaults: defaults) == KeyChord("f"))
        #expect(!Shortcuts.isCustomized(fillet, defaults: defaults))

        store.assign(KeyChord("f", .shift), to: fillet)
        #expect(Shortcuts.chord(fillet, defaults: defaults) == KeyChord("f", .shift))
        #expect(Shortcuts.isCustomized(fillet, defaults: defaults))

        store.assign(nil, to: fillet)  // removed
        #expect(Shortcuts.chord(fillet, defaults: defaults) == nil)

        store.assign(KeyChord("f"), to: fillet)  // back to the default: nothing to remember
        #expect(!Shortcuts.isCustomized(fillet, defaults: defaults))
        #expect(!store.hasCustomShortcuts)
    }

    @Test func takingAShortcutTakesItFromItsOwner() {
        let (store, defaults) = makeStore()
        let displaced = store.assign(KeyChord("e"), to: .tool(.fillet))  // E is Extrude's
        #expect(displaced == .tool(.extrude))
        #expect(Shortcuts.chord(.tool(.fillet), defaults: defaults) == KeyChord("e"))
        #expect(Shortcuts.chord(.tool(.extrude), defaults: defaults) == nil)

        // Putting Extrude's own E back takes it from Fillet in turn.
        store.reset(.tool(.extrude))
        #expect(Shortcuts.chord(.tool(.extrude), defaults: defaults) == KeyChord("e"))
        #expect(Shortcuts.chord(.tool(.fillet), defaults: defaults) == nil)

        store.resetAll()
        #expect(Shortcuts.chord(.tool(.fillet), defaults: defaults) == KeyChord("f"))
    }

    @Test func sketchKeysAreSeparateFromMenuShortcuts() {
        let (store, defaults) = makeStore()
        // The same letter is Extrude's in the menus and Extend's in a sketch; that is by design.
        #expect(Shortcuts.chord(.tool(.extrude), defaults: defaults) == Shortcuts.chord(.sketch(.extend), defaults: defaults))
        #expect(store.assign(KeyChord("e"), to: .sketch(.line)) == .sketch(.extend))
        #expect(Shortcuts.chord(.tool(.extrude), defaults: defaults) == KeyChord("e"), "the menu keeps its own")
    }

    @Test func someChordsAreRefused() {
        #expect(Shortcuts.problem(KeyChord("q", .command), for: .tool(.fillet)) != nil, "Quit")
        #expect(Shortcuts.problem(KeyChord("c", .command), for: .fitAll) != nil, "Copy")
        #expect(Shortcuts.problem(KeyChord("q", [.command, .option]), for: .fitAll) == nil)
        #expect(Shortcuts.problem(KeyChord("5"), for: .sketch(.line)) != nil, "digits type sizes while sketching")
        #expect(Shortcuts.problem(KeyChord("l", .command), for: .sketch(.line)) != nil, "sketch keys take no modifiers")
        #expect(Shortcuts.problem(KeyChord("5"), for: .tool(.fillet)) == nil)
    }

    @Test func tooltipsFollowTheShortcut() {
        // Uses the real defaults, which the tests never change.
        #expect(DesignTool.fillet.help.hasPrefix("Fillet (F): "))
        #expect(SketchTool.circle2Point.help.contains("C again for center"))
    }

    @Test func aSketchFamilyIsListedOnceUnderItsFirstTool() {
        #expect(ShortcutCommand.sketch(.rectangle).title == "Rectangle")
        #expect(!ShortcutCommand.all.contains(.sketch(.centerRectangle)))
    }
}
