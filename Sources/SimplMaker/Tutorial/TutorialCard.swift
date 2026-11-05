// The card that walks the user through the tutorial: the step's title and text, what to do next
// right now, a way to have it done, and a way out. It floats at the top of the viewport and can be
// dragged aside or folded down to a line.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
#if os(macOS)
import AppKit
#endif
import SwiftUI

struct TutorialCard: View {
    @Environment(\.accent) private var accent
    let model: DocumentModel
    let guide: TutorialGuide
    @State private var drag = CGSize.zero
    @State private var dragStart: CGSize?

    static let width: CGFloat = 380

    var body: some View {
        // Reading `current` here ties the card to every change in the part that a step looks at.
        let step = guide.isActive ? guide.current(in: model) : nil
        ZStack {
            if let step {
                card(step)
                    .id(step.id)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .animation(.easeOut(duration: DS.Duration.base), value: step?.id)
        .animation(.easeOut(duration: DS.Duration.base), value: guide.isCollapsed)
        .onChange(of: step?.id, initial: true) { _, id in
            guard let step, step.id == id else { return }
            step.enter?(model)
            AccessibilityNotification.Announcement("\(step.title). \(step.text)").post()
        }
        .onChange(of: step.map { $0.spotlight(model) } ?? [], initial: true) { _, spots in
            if guide.spotlight != spots { guide.spotlight = spots }
        }
    }

    // MARK: card

    private func card(_ step: TutorialStep) -> some View {
        let hint = step.hint(model)
        let position = guide.position(of: step)
        return VStack(alignment: .leading, spacing: DS.Spacing.space5) {
            header(step, position: position)
            if guide.isCollapsed {
                Text(hint.map { markdown($0.text) } ?? markdown(step.title))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: DS.Spacing.space3) {
                    Text(step.title).font(.title3.weight(.semibold))
                    Text(markdown(step.text))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let hint { HintRow(hint: hint) }
                buttons(step)
            }
        }
        .padding(DS.Spacing.space6)
        .frame(width: Self.width)
        .panelGlass(in: .rect(cornerRadius: DS.Radius.window))
        .offset(drag)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tutorial, step \(position.index + 1) of \(position.count)")
    }

    /// The chapter, the progress, and the card's own controls. Dragging this strip moves the card.
    private func header(_ step: TutorialStep, position: (index: Int, count: Int)) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space3) {
            HStack(spacing: DS.Spacing.space3) {
                Text(step.chapter.title.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(accent)
                Text("Step \(position.index + 1) of \(position.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if guide.isAssisting { ProgressView().controlSize(.small) }
                CardButton(systemImage: guide.isCollapsed ? "chevron.down" : "chevron.up",
                           help: guide.isCollapsed ? "Show the whole step" : "Fold the card down to a line") {
                    guide.isCollapsed.toggle()
                }
                CardButton(systemImage: "xmark", help: "Close the tutorial. Help ▸ Tutorial brings it back.") { guide.stop() }
            }
            ProgressStrip(index: position.index, count: position.count)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { value in
                    let start = dragStart ?? drag
                    dragStart = start
                    drag = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
                }
                .onEnded { _ in dragStart = nil }
        )
    }

    @ViewBuilder
    private func buttons(_ step: TutorialStep) -> some View {
        HStack(spacing: DS.Spacing.space4) {
            if guide.previous(of: step) != nil {
                Button { Task { await guide.goBack(from: step, in: model) } } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.bordered)
                .disabled(guide.isAssisting)
                .help("Go back a step. What you did in it is undone.")
                .accessibilityLabel("Back")
            }
            switch step.kind {
            case .read(let title):
                Button(step.id == TutorialScript.welcome.id ? "Not now" : "Leave tutorial") { guide.stop() }
                    .buttonStyle(.bordered)
                Spacer(minLength: 0)
                #if os(macOS)
                if step.id == TutorialScript.done.id {
                    Button("Save…") { NSApp.sendAction(#selector(NSDocument.save(_:)), to: nil, from: nil) }
                }
                #endif
                Button(title) { guide.acknowledge(step) }
                    .buttonStyle(.borderedProminent)
            case .task:
                Button("Leave tutorial") { guide.stop() }
                    .buttonStyle(.bordered)
                Spacer(minLength: 0)
                Button("Do it for me") { Task { await guide.assist(step, in: model) } }
                    .disabled(guide.isAssisting || step.assist == nil)
                    .help("SimplMaker does this step for you, and the guide moves on")
            }
        }
        .controlSize(.regular)
        .font(.callout)
    }

    private func markdown(_ text: String) -> AttributedString { tutorialMarkdown(text, accent: accent) }
}

/// Inline Markdown in a step's text. What the user types or clicks stands out from the explanation around it:
/// `code` (a parameter name, a value) is bright on an accent-tinted chip, **bold** (a tool, a key) is bright.
func tutorialMarkdown(_ text: String, accent: Color) -> AttributedString {
    guard let parsed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    else { return AttributedString(text) }
    var out = AttributedString()
    for run in parsed.runs {
        var piece = AttributedString(parsed[run.range])
        let intent = run.inlinePresentationIntent ?? []
        if intent.contains(.code) {
            // Thin spaces inside the chip, so the background has some air around the letters.
            piece = AttributedString("\u{2009}") + piece + AttributedString("\u{2009}")
            piece.foregroundColor = Color.primary
            piece.backgroundColor = accent.opacity(0.32)
        } else if intent.contains(.stronglyEmphasized) {
            piece.foregroundColor = Color.primary
        }
        out += piece
    }
    return out
}

/// What to do next, set apart from the explanation above it.
private struct HintRow: View {
    @Environment(\.accent) private var accent
    let hint: TutorialHint

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.space4) {
            Image(systemName: hint.isProblem ? "exclamationmark.triangle.fill" : "arrow.right.circle.fill")
                .foregroundStyle(hint.isProblem ? Color.orange : accent)
            Text(tutorialMarkdown(hint.text, accent: accent))
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.space5)
        .padding(.vertical, DS.Spacing.space4)
        .background((hint.isProblem ? Color.orange : accent).opacity(0.14),
                    in: RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// One capsule per step: done, the current one, and what's left.
private struct ProgressStrip: View {
    @Environment(\.accent) private var accent
    let index: Int
    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i <= index ? accent : Color.primary.opacity(0.14))
                    .opacity(i < index ? 0.55 : 1)
                    .frame(height: 3)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A small icon button in the card's header.
private struct CardButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 20, height: 20)
                .foregroundStyle(.secondary)
                .background(hovering ? Color.primary.opacity(0.1) : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
