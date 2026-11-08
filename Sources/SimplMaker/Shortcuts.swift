// Customizable keyboard shortcuts: the commands that have one, their defaults, and the user's changes.
//
// A shortcut is a key plus modifiers. Most of SimplMaker's are a bare letter (E extrude, F fillet), which
// is why this is not built on a global-hotkey library. Only the changes are stored (UserDefaults, under
// `Shortcuts.defaultsKey`, as {command id: "cmd+opt+g"}, or "" for no shortcut), so a default that
// changes in a later version reaches everyone who never touched it.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
#if os(macOS)
import AppKit
#endif
import SwiftUI

/// A key and the modifiers held with it. The key is one lowercase character, as the key is labelled with
/// no modifier held (⌥⌘G is "g", ⇧⌘1 is "1").
struct KeyChord: Hashable, Sendable {
    var key: Character
    var modifiers: Modifiers

    struct Modifiers: OptionSet, Hashable, Sendable {
        let rawValue: Int
        static let control = Modifiers(rawValue: 1)
        static let option = Modifiers(rawValue: 2)
        static let shift = Modifiers(rawValue: 4)
        static let command = Modifiers(rawValue: 8)

        /// The names used in the stored form, in the order they are written.
        fileprivate static let names: [(Modifiers, String)] = [(.control, "ctrl"), (.option, "opt"), (.shift, "shift"), (.command, "cmd")]

        var eventModifiers: EventModifiers {
            var m: EventModifiers = []
            if contains(.control) { m.insert(.control) }
            if contains(.option) { m.insert(.option) }
            if contains(.shift) { m.insert(.shift) }
            if contains(.command) { m.insert(.command) }
            return m
        }
    }

    init(_ key: Character, _ modifiers: Modifiers = []) {
        self.key = Character(key.lowercased())
        self.modifiers = modifiers
    }

    #if os(macOS)
    /// The chord of a key press; nil for keys that are not a plain character (arrows, F-keys, Return, Esc...).
    init?(event: NSEvent) {
        guard event.type == .keyDown, event.specialKey == nil,
              let char = event.characters(byApplyingModifiers: [])?.first,
              let scalar = char.unicodeScalars.first, scalar.value > 0x20, scalar.value != 0x7F,
              !(0xF700...0xF8FF).contains(scalar.value)
        else { return nil }
        var m: Modifiers = []
        let flags = event.modifierFlags
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.command) { m.insert(.command) }
        self.init(char, m)
    }
    #else
    /// The chord of a hardware key press; nil for keys that are not a plain character (arrows, F-keys, Return, Esc...).
    @MainActor init?(key: UIKey) {
        guard let char = key.charactersIgnoringModifiers.first, key.charactersIgnoringModifiers.count == 1,
              let scalar = char.unicodeScalars.first, scalar.value > 0x20, scalar.value != 0x7F,
              !(0xF700...0xF8FF).contains(scalar.value)
        else { return nil }
        var m: Modifiers = []
        let flags = key.modifierFlags
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.alternate) { m.insert(.option) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.command) { m.insert(.command) }
        self.init(char, m)
    }
    #endif

    /// The stored form: "e", "cmd+opt+g", "cmd++" (⌘ and the plus key).
    var stored: String {
        let mods = Modifiers.names.filter { modifiers.contains($0.0) }.map(\.1)
        return (mods + [String(key)]).joined(separator: "+")
    }

    init?(stored: String) {
        guard let key = stored.last else { return nil }
        var rest = stored.dropLast()
        if rest.last == "+" { rest = rest.dropLast() } else if !rest.isEmpty { return nil }
        var m: Modifiers = []
        for name in rest.split(separator: "+") {
            guard let found = Modifiers.names.first(where: { $0.1 == name }) else { return nil }
            m.insert(found.0)
        }
        self.init(key, m)
    }

    /// As shown in menus and tooltips: ⌥⌘G, E.
    var label: String {
        let symbols = Modifiers.names.filter { modifiers.contains($0.0) }.map { name -> String in
            switch name.0 {
            case .control: return "⌃"
            case .option: return "⌥"
            case .shift: return "⇧"
            default: return "⌘"
            }
        }
        return symbols.joined() + String(key).uppercased()
    }

    var keyboardShortcut: KeyboardShortcut { KeyboardShortcut(KeyEquivalent(key), modifiers: modifiers.eventModifiers) }

    /// A bare key (shift allowed): it types a character, so a text field being edited must get it, not the menu.
    var isPlainKey: Bool { modifiers.subtracting(.shift).isEmpty }
}

/// Everything that has a shortcut the user can change.
enum ShortcutCommand: Hashable, Identifiable, Sendable {
    case tool(DesignTool)
    /// A sketch tool; always the first of its family (rectangle, circle and arc share a key).
    case sketch(SketchTool)
    case view(StandardView)
    case fitAll, orthographic, showGrid, showAxes, snapToGrid
    case appearance, browser, timeline, inspector, hideUI
    case rebuild, importSTEP, welcome, exampleParts, palette

    /// Menu shortcuts work anywhere in the app; sketch shortcuts are single keys the viewport reads while sketching.
    enum Scope: Sendable { case app, sketch }
    var scope: Scope { if case .sketch = self { return .sketch } else { return .app } }

    var id: String {
        switch self {
        case .tool(let t): return "tool.\(t.rawValue)"
        case .sketch(let t): return "sketch.\(t.rawValue)"
        case .view(let v): return "view.\(v.rawValue)"
        case .fitAll: return "fitAll"
        case .orthographic: return "orthographic"
        case .showGrid: return "showGrid"
        case .showAxes: return "showAxes"
        case .snapToGrid: return "snapToGrid"
        case .appearance: return "appearance"
        case .browser: return "browser"
        case .timeline: return "timeline"
        case .inspector: return "inspector"
        case .hideUI: return "hideUI"
        case .rebuild: return "rebuild"
        case .importSTEP: return "importSTEP"
        case .welcome: return "welcome"
        case .exampleParts: return "exampleParts"
        case .palette: return "palette"
        }
    }

    var title: String {
        switch self {
        case .tool(let t): return t.rawValue
        case .sketch(let t): return t.shortTitle
        case .view(let v): return v.title
        case .fitAll: return "Fit All"
        case .orthographic: return "Orthographic Projection"
        case .showGrid: return "Show Grid"
        case .showAxes: return "Show Axes"
        case .snapToGrid: return "Snap to Grid"
        case .appearance: return "Appearance"
        case .browser: return "Show or Hide Browser"
        case .timeline: return "Show or Hide Timeline"
        case .inspector: return "Show or Hide Inspector"
        case .hideUI: return "Show or Hide UI"
        case .rebuild: return "Rebuild"
        case .importSTEP: return "Import STEP"
        case .welcome: return "Welcome Window"
        case .exampleParts: return "Open Example Part"
        case .palette: return "Command Palette"
        }
    }

    var defaultChord: KeyChord? {
        switch self {
        case .tool(let t): return KeyChord(t.defaultKey, t.defaultModifiers)
        case .sketch(let t): return KeyChord(t.defaultKey)
        case .view(let v):
            switch v {
            case .top: return KeyChord("1", .command)
            case .front: return KeyChord("2", .command)
            case .right: return KeyChord("3", .command)
            case .home: return KeyChord("4", .command)
            }
        case .fitAll: return KeyChord("0", .command)
        case .orthographic: return KeyChord("o", [.command, .option])
        case .showGrid: return KeyChord("g", [.command, .option])
        case .showAxes: return KeyChord("a", [.command, .option])
        case .snapToGrid: return KeyChord("'", .command)
        case .appearance: return KeyChord("a")
        case .browser: return KeyChord("s", [.command, .control])
        case .timeline: return KeyChord("t", [.command, .option])
        case .inspector: return KeyChord("i", [.command, .option])
        case .hideUI: return KeyChord("@", .command)
        case .rebuild: return KeyChord("r", .command)
        case .importSTEP: return KeyChord("i", [.command, .shift])
        case .welcome: return KeyChord("1", [.command, .shift])
        case .exampleParts: return KeyChord("n", [.command, .option])
        case .palette: return KeyChord("k", .command)
        }
    }

    /// What the Shortcuts settings list, in sections.
    struct Section: Identifiable {
        let title: String
        let commands: [ShortcutCommand]
        var id: String { title }
    }

    static let sections: [Section] = [
        Section(title: "Create", commands: (DesignTool.shapes + DesignTool.primitives + [.plane, .canvas]).map { .tool($0) }),
        Section(title: "Modify", commands: (DesignTool.modifiers + [.mirror, .pattern]).map { .tool($0) }),
        Section(title: "Inspect", commands: DesignTool.inspect.map { .tool($0) }),
        Section(title: "View", commands: StandardView.allCases.map { .view($0) } + [
            .fitAll, .orthographic, .showGrid, .showAxes, .snapToGrid, .appearance, .browser, .timeline, .inspector, .hideUI]),
        Section(title: "Model", commands: [.palette, .rebuild, .importSTEP, .welcome, .exampleParts]),
        Section(title: "While Sketching", commands: SketchTool.allCases.filter { $0.family[0] == $0 }.map { .sketch($0) }),
    ]

    static let all: [ShortcutCommand] = sections.flatMap(\.commands)
}

enum Shortcuts {
    static let defaultsKey = "shortcuts"

    private static func overrides(_ defaults: UserDefaults) -> [String: String] {
        defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }

    /// The shortcut a command has now: the user's, or the default. Nil when the user removed it.
    static func chord(_ command: ShortcutCommand, defaults: UserDefaults = .standard) -> KeyChord? {
        guard let stored = overrides(defaults)[command.id] else { return command.defaultChord }
        return KeyChord(stored: stored)  // "" (removed) and anything unreadable: none
    }

    static func isCustomized(_ command: ShortcutCommand, defaults: UserDefaults = .standard) -> Bool {
        overrides(defaults)[command.id] != nil
    }

    /// The label for menus and tooltips: "⌥⌘G", or nil.
    static func label(_ command: ShortcutCommand) -> String? { chord(command)?.label }

    /// For `.keyboardShortcut(_:)` on a menu item.
    static func keyboardShortcut(_ command: ShortcutCommand) -> KeyboardShortcut? { chord(command)?.keyboardShortcut }

    #if os(macOS)
    /// Whether a key press is this command's shortcut.
    static func matches(_ command: ShortcutCommand, _ event: NSEvent, defaults: UserDefaults = .standard) -> Bool {
        guard let chord = chord(command, defaults: defaults), let pressed = KeyChord(event: event) else { return false }
        return pressed == chord
    }
    #endif

    /// Combinations macOS and the standard menus already use (Quit, Save, Copy...).
    static func isReserved(_ chord: KeyChord) -> Bool {
        guard chord.modifiers.contains(.command), chord.modifiers.subtracting([.command, .shift]).isEmpty else { return false }
        return "nowsqzxcvahmp,`".contains(chord.key)
    }

    /// Why a chord cannot go to a command, or nil when it can.
    static func problem(_ chord: KeyChord, for command: ShortcutCommand) -> String? {
        switch command.scope {
        case .sketch:
            if !chord.modifiers.isEmpty { return "Sketch tools use a single key, with no modifiers." }
            if "0123456789.-".contains(chord.key) { return "Digits and . - are for typing sizes while you sketch." }
        case .app:
            if isReserved(chord) { return "\(chord.label) is used by a standard macOS command." }
        }
        return nil
    }

    /// The command that already has this chord, in the same scope.
    static func owner(of chord: KeyChord, besides command: ShortcutCommand, defaults: UserDefaults = .standard) -> ShortcutCommand? {
        ShortcutCommand.all.first { $0 != command && $0.scope == command.scope && Shortcuts.chord($0, defaults: defaults) == chord }
    }
}

/// The settings side: changing shortcuts, and telling the menus and tooltips that they changed.
@MainActor
final class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()
    private let defaults: UserDefaults

    /// Changes whenever a shortcut does; views that show one watch it.
    @Published private(set) var revision = 0

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func write(_ id: String, _ value: String?) {
        var all = defaults.dictionary(forKey: Shortcuts.defaultsKey) as? [String: String] ?? [:]
        all[id] = value
        defaults.set(all, forKey: Shortcuts.defaultsKey)
        revision += 1
    }

    /// Sets (nil: removes) a command's shortcut. A command in the same scope that had the chord loses it;
    /// that command is returned.
    @discardableResult
    func assign(_ chord: KeyChord?, to command: ShortcutCommand) -> ShortcutCommand? {
        var displaced: ShortcutCommand?
        if let chord, let other = Shortcuts.owner(of: chord, besides: command, defaults: defaults) {
            displaced = other
            write(other.id, "")
        }
        if chord == command.defaultChord { write(command.id, nil) } else { write(command.id, chord?.stored ?? "") }
        return displaced
    }

    func reset(_ command: ShortcutCommand) {
        // Putting the default back takes it from whoever has it now.
        if let chord = command.defaultChord, let other = Shortcuts.owner(of: chord, besides: command, defaults: defaults) {
            write(other.id, "")
        }
        write(command.id, nil)
    }

    func resetAll() {
        defaults.removeObject(forKey: Shortcuts.defaultsKey)
        revision += 1
    }

    var hasCustomShortcuts: Bool { !(defaults.dictionary(forKey: Shortcuts.defaultsKey) ?? [:]).isEmpty }
}

extension View {
    /// The command's current shortcut on a menu item (none when the user removed it).
    func shortcut(_ command: ShortcutCommand) -> some View {
        keyboardShortcut(Shortcuts.keyboardShortcut(command))
    }
}
