// One segmented control for the whole app: a quiet track with the chosen segment as a white pill (the system's own look is grey in a dark window).
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// A row of segments, one selected: the tabs and the presets. A segment without an action ("Custom") only shows where the
/// settings are, and is not something to click.
struct SegmentedRow: View {
    struct Item {
        var title: String
        var selected: Bool
        var action: (() -> Void)?
    }
    let items: [Item]
    /// Segments take the width they need (a control that sits in a toolbar) instead of sharing what is offered.
    var compact = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in segment(item) }
        }
        .padding(2)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: DS.Radius.lg))
        .overlay { RoundedRectangle(cornerRadius: DS.Radius.lg).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1) }
    }

    private func segment(_ item: Item) -> some View {
        Text(item.title)
            .lineLimit(1)
            .foregroundStyle(item.selected ? Color.black : item.action == nil ? Color.secondary.opacity(0.6) : Color.primary.opacity(0.85))
            .padding(.horizontal, compact ? 10 : 0)
            .frame(maxWidth: compact ? nil : .infinity, minHeight: DS.ControlHeight.large)
            .background {
                if item.selected {
                    RoundedRectangle(cornerRadius: DS.Radius.md).fill(Color.white)
                        .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { item.action?() }
            .accessibilityAddTraits(item.selected ? .isSelected : [])
    }
}

/// Stands in for a `Picker` with the segmented style: the same choices, with the white chosen segment.
struct SegmentedPicker<Value: Hashable>: View {
    let options: [Value]
    let title: (Value) -> String
    @Binding var selection: Value
    var compact = false

    init(selection: Binding<Value>, options: [Value], compact: Bool = false, title: @escaping (Value) -> String) {
        self._selection = selection
        self.options = options
        self.compact = compact
        self.title = title
    }

    var body: some View {
        SegmentedRow(items: options.map { option in
            SegmentedRow.Item(title: title(option), selected: option == selection) { selection = option }
        }, compact: compact)
    }
}

extension SegmentedPicker where Value: CaseIterable {
    init(selection: Binding<Value>, compact: Bool = false, title: @escaping (Value) -> String) {
        self.init(selection: selection, options: Array(Value.allCases), compact: compact, title: title)
    }
}
