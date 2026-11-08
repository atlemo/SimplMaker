// A calculator-style number pad that takes the place of the system keyboard while a size is typed on the iPad.
//
// Every size field is marked by `numericEntry()` (its text field has the numbers-and-punctuation keyboard type). When such a field
// starts editing, its keyboard is replaced by nothing and this pad floats up instead: the keys type into the field as the keyboard
// would, so the field's own behaviour (the live preview, completing a parameter's name, Return to finish) is unchanged. It takes
// less room than the keyboard, and the Inspector is opened beside it so every size the feature needs is in view.

import SwiftUI
import UIKit

@MainActor @Observable
final class PadNumpad {
    static let shared = PadNumpad()

    /// The field being typed into, while the pad is up for it.
    private(set) var field: UITextField?
    /// What the field is for ("Depth", "Diameter"), from its accessibility label or placeholder.
    private(set) var label = ""
    /// The user asked for the letters (a parameter's name): the system keyboard takes over for this field.
    private(set) var usesSystemKeyboard = false

    var isActive: Bool { field != nil && !usesSystemKeyboard }

    static let width: CGFloat = 300
    static let height: CGFloat = 352
    /// The room the pad takes above the bottom of the screen (the timeline below it included): the fields that are typed in keep above it.
    var reserve: CGFloat { isActive ? Self.height + 70 : 0 }

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: UITextField.textDidBeginEditingNotification, object: nil, queue: .main) { note in
            nonisolated(unsafe) let note = note
            MainActor.assumeIsolated {
                guard let field = note.object as? UITextField else { return }
                PadNumpad.shared.began(field)
            }
        }
        center.addObserver(forName: UITextField.textDidEndEditingNotification, object: nil, queue: .main) { note in
            nonisolated(unsafe) let note = note
            MainActor.assumeIsolated {
                guard let ended = note.object as? UITextField else { return }
                // Moving from one field to the next ends one and begins the other: only let go if no other began meanwhile.
                DispatchQueue.main.async { if PadNumpad.shared.field === ended { PadNumpad.shared.field = nil } }
            }
        }
    }

    private func began(_ field: UITextField) {
        guard field.keyboardType == .numbersAndPunctuation, !Self.isInPresentedController(field) else { return }
        self.field = field
        usesSystemKeyboard = false
        let named = field.accessibilityLabel ?? field.placeholder ?? ""
        label = named == "expression" ? "Value" : named  // a field with no name of its own says what any of them does
        field.inputView = UIView(frame: .zero)  // nothing: the pad is the keyboard
        field.inputAssistantItem.leadingBarButtonGroups = []
        field.inputAssistantItem.trailingBarButtonGroups = []
        field.reloadInputViews()
    }

    /// A field in a popover or sheet sits over the app: the pad would be out of reach under it, so it keeps the system keyboard.
    private static func isInPresentedController(_ view: UIView) -> Bool {
        var responder: UIResponder? = view
        while let next = responder?.next {
            if let controller = next as? UIViewController, controller.presentingViewController != nil { return true }
            responder = next
        }
        return false
    }

    // MARK: keys

    func type(_ text: String, isOperator: Bool = false) {
        guard let field else { return }
        // A field starts with its text selected, so a number typed replaces it; an operator goes after it instead.
        if isOperator, let range = field.selectedTextRange, !range.isEmpty { field.selectedTextRange = field.textRange(from: field.endOfDocument, to: field.endOfDocument) }
        field.insertText(text)
    }

    func backspace() { field?.deleteBackward() }

    func clear() {
        guard let field else { return }
        field.selectAll(nil)
        field.deleteBackward()
    }

    func negate() {
        guard let field else { return }
        let start = field.beginningOfDocument
        if (field.text ?? "").hasPrefix("-"), let after = field.position(from: start, offset: 1) {
            field.selectedTextRange = field.textRange(from: start, to: after)
            field.deleteBackward()
        } else {
            field.selectedTextRange = field.textRange(from: start, to: start)
            field.insertText("-")
        }
        field.selectedTextRange = field.textRange(from: field.endOfDocument, to: field.endOfDocument)
    }

    /// Return in the field: what the keyboard's own Return did.
    func done() {
        guard let field else { return }
        _ = field.delegate?.textFieldShouldReturn?(field)
        field.resignFirstResponder()
    }

    /// The next size field on the screen (the Inspector's, or the ones by the arrows), round to the first again.
    func next() {
        guard let field, let window = field.window else { return }
        var fields: [UITextField] = []
        func collect(_ view: UIView) {
            if let f = view as? UITextField, f.keyboardType == .numbersAndPunctuation, !f.isHidden, f.alpha > 0.01, f.window != nil,
               !Self.isInPresentedController(f) { fields.append(f) }
            view.subviews.forEach(collect)
        }
        collect(window)
        guard fields.count > 1, let index = fields.firstIndex(of: field) else { return }
        fields[(index + 1) % fields.count].becomeFirstResponder()
    }

    /// The letters, for a parameter's name: the system keyboard for this field only.
    func useSystemKeyboard() {
        guard let field else { return }
        usesSystemKeyboard = true
        field.inputView = nil
        field.reloadInputViews()
    }
}

// MARK: the pad

struct PadNumpadPanel: View {
    let model: DocumentModel
    @State private var numpad = PadNumpad.shared
    @State private var offset = CGSize.zero
    @State private var dragStart = CGSize.zero

    var body: some View {
        if numpad.isActive {
            VStack(spacing: 8) {
                header
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow {
                        key("C") { numpad.clear() }
                        key("(") { numpad.type("(", isOperator: true) }
                        key(")") { numpad.type(")", isOperator: true) }
                        key(systemImage: "delete.left") { numpad.backspace() }
                    }
                    GridRow {
                        digit("7"); digit("8"); digit("9")
                        key("÷", emphasis: true) { numpad.type("/", isOperator: true) }
                    }
                    GridRow {
                        digit("4"); digit("5"); digit("6")
                        key("×", emphasis: true) { numpad.type("*", isOperator: true) }
                    }
                    GridRow {
                        digit("1"); digit("2"); digit("3")
                        key("−", emphasis: true) { numpad.type("-", isOperator: true) }
                    }
                    GridRow {
                        digit("0")
                        key(".") { numpad.type(".") }
                        key("±") { numpad.negate() }
                        key("+", emphasis: true) { numpad.type("+", isOperator: true) }
                    }
                    GridRow {
                        parametersMenu
                        unitsMenu
                        key(systemImage: "arrow.right.to.line") { numpad.next() }
                            .accessibilityLabel("Next size")
                        Button { numpad.done() } label: {
                            Text("OK").font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel("Done typing")
                    }
                }
            }
            .padding(12)
            .frame(width: PadNumpad.width)
            .panelGlass(in: RoundedRectangle(cornerRadius: DS.Radius.window, style: .continuous))
            .offset(offset)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Number pad")
        }
    }

    /// What is being typed, and the way to the letters. Dragging the header moves the pad out of the way.
    private var header: some View {
        HStack {
            Text(numpad.label.isEmpty ? "Size" : numpad.label).font(.headline).lineLimit(1)
            Spacer(minLength: 8)
            Button { numpad.useSystemKeyboard() } label: {
                Text("abc").font(.subheadline.weight(.semibold)).padding(.horizontal, 10).frame(minHeight: 32)
                    .background(Color.primary.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show the letter keyboard")
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(coordinateSpace: .global)  // not the pad's own space: it moves with the pad, which made the drag jitter
            .onChanged { offset = CGSize(width: dragStart.width + $0.translation.width, height: dragStart.height + $0.translation.height) }
            .onEnded { _ in dragStart = offset })
    }

    private func digit(_ d: String) -> some View { key(d) { numpad.type(d) } }

    private func key(_ title: String, emphasis: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.title3.weight(emphasis ? .semibold : .regular)).frame(maxWidth: .infinity, minHeight: 44)
                .background(Color.primary.opacity(emphasis ? 0.14 : 0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .foregroundStyle(Color.primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func key(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.title3).frame(maxWidth: .infinity, minHeight: 44)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .foregroundStyle(Color.primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var parametersMenu: some View {
        Menu {
            ForEach(model.document.parameters, id: \.name) { p in
                Button(p.name) { numpad.type(p.name) }
            }
        } label: {
            Text("param").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .foregroundStyle(Color.primary)
        }
        .disabled(model.document.parameters.isEmpty)
        .accessibilityLabel("Insert a parameter")
    }

    private var unitsMenu: some View {
        Menu {
            ForEach(["mm", "cm", "in", "deg"], id: \.self) { u in Button(u) { numpad.type(" " + u) } }
        } label: {
            Text("unit").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .foregroundStyle(Color.primary)
        }
        .accessibilityLabel("Insert a unit")
    }
}
