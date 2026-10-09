// The Shortcuts pane in Settings: every command with its shortcut, and a field that records a new one.
// Copyright © 2026 Atle Mo. All rights reserved.
import AppKit
import SwiftUI

struct ShortcutsPane: View {
    @StateObject private var store = ShortcutStore.shared
    /// What the last change did to another command ("Fillet lost F"), until the next change.
    @State private var notice: String?
    /// The titles of the categories that are folded up.
    @State private var collapsed: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            Form {
                ForEach(ShortcutCommand.sections) { section in
                    Section {
                        if !collapsed.contains(section.title) {
                            ForEach(section.commands) { command in
                                ShortcutRow(command: command, store: store, notice: $notice)
                            }
                        }
                    } header: {
                        sectionHeader(section.title)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Text(notice ?? "Click a shortcut, then press the new keys. ⌫ removes it, Esc cancels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Restore Defaults") { store.resetAll(); notice = nil }
                    .disabled(!store.hasCustomShortcuts)
            }
            .padding(DS.Spacing.space3)
        }
    }

    /// A category's title with its chevron on the right; the whole row folds the category up or opens it.
    private func sectionHeader(_ title: String) -> some View {
        let open = !collapsed.contains(title)
        return Button {
            withAnimation(.easeInOut(duration: DS.Duration.base)) {
                if open { collapsed.insert(title) } else { collapsed.remove(title) }
            }
        } label: {
            HStack {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open ? 0 : -90))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, open ? 0 : DS.Spacing.space4)  // a folded category has no rows to keep the next title apart
        .accessibilityValue(open ? "expanded" : "collapsed")
    }
}

private struct ShortcutRow: View {
    let command: ShortcutCommand
    @ObservedObject var store: ShortcutStore
    @Binding var notice: String?

    var body: some View {
        let custom = Shortcuts.isCustomized(command)
        LabeledContent {
            HStack(spacing: DS.Spacing.space2) {
                Button {
                    store.reset(command)
                    notice = nil
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help("Back to the default (\(command.defaultChord?.label ?? "none"))")
                .opacity(custom ? 1 : 0)
                .disabled(!custom)
                .accessibilityLabel("Reset \(command.title)")
                ShortcutRecorder(command: command, store: store, notice: $notice)
            }
        } label: {
            Text(command.title)
        }
    }
}

/// A button that shows a command's shortcut and, once clicked, takes the next key press as the new one.
private struct ShortcutRecorder: View {
    let command: ShortcutCommand
    @ObservedObject var store: ShortcutStore
    @Binding var notice: String?
    @State private var recording = false
    @State private var monitor: Any?
    @Environment(\.accent) private var accent

    var body: some View {
        let chord = Shortcuts.chord(command)
        Button { start() } label: {
            Text(recording ? "Press keys…" : chord?.label ?? "None")
                .foregroundStyle(recording ? accent : chord == nil ? .secondary : .primary)
                .frame(width: 96)
        }
        .buttonStyle(.bordered)
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
            .strokeBorder(accent, lineWidth: recording ? 2 : 0))
        .accessibilityLabel("\(command.title) shortcut")
        .accessibilityValue(chord?.label ?? "None")
        .onDisappear { stop() }
    }

    private func start() {
        guard monitor == nil else { return }
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { event in
            // Any click (outside, or on this button again) ends the recording.
            if event.type == .leftMouseDown { MainActor.assumeIsolated { stop() }; return event }
            let consumed = MainActor.assumeIsolated { handle(event) }
            return consumed ? nil : event
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }

    /// Esc cancels, ⌫ removes the shortcut, anything else is tried as the new one. Every key is taken
    /// while recording, so ⌘Q and the like do not run.
    private func handle(_ event: NSEvent) -> Bool {
        let plain = event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        if plain, event.keyCode == 53 { stop(); return true }
        if plain, event.keyCode == 51 || event.keyCode == 117 {  // ⌫ ⌦
            store.assign(nil, to: command)
            notice = nil
            stop()
            return true
        }
        guard let chord = KeyChord(event: event) else { NSSound.beep(); return true }
        if let problem = Shortcuts.problem(chord, for: command) {
            notice = problem
            NSSound.beep()
            return true
        }
        if let displaced = store.assign(chord, to: command) {
            notice = "\(chord.label) was \(displaced.title)'s. \(displaced.title) has no shortcut now."
        } else {
            notice = nil
        }
        stop()
        return true
    }
}
