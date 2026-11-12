// A calculator-style number pad that takes the place of the system keyboard while a size is typed on the iPad.
//
// Every size field is marked by `numericEntry()` (its text field has the numbers-and-punctuation keyboard type). When such a field
// starts editing, its keyboard is replaced by nothing and this pad floats up instead: the keys type into the field as the keyboard
// would, so the field's own behaviour (the live preview, completing a parameter's name, Return to finish) is unchanged. It takes
// less room than the keyboard, and the Inspector is opened beside it so every size the feature needs is in view.
//
// A field in a popover or sheet (a dimension's value, the Transform sizes, the parameter sheet) sits over the app, where a pad in the
// document window would be hidden under it, and a tap beside the popover would close it: there the same pad floats in a layer of its
// own on top of the app window, and taps on it leave the popover alone.

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
    /// The field is in a popover or sheet: the pad floats in a window above it, not in the document window.
    private(set) var inOverlayWindow = false
    /// For the parameters menu on the keys; the document window sets it.
    weak var model: DocumentModel?
    private var overlayLayer: PadNumpadLayer?
    private var overlayHost: UIViewController?
    /// Where the field being typed in is on the screen.
    var fieldFrame: CGRect { field.map { $0.convert($0.bounds, to: nil) } ?? .zero }
    /// Where the pad (or the 123 key) is on the screen while it floats in its window: the only place that window takes touches.
    var overlayFrame = CGRect.zero

    var isActive: Bool { field != nil && !usesSystemKeyboard }
    /// The touch now on the viewport began while a size was being typed: it ends the typing and must not also draw or pick.
    var touchFoundPadUp = false

    static let width: CGFloat = 300
    static let height: CGFloat = 352
    /// The room the pad takes above the bottom of the screen (the timeline below it included): the fields that are typed in keep above it.
    /// Measured from the bottom of the screen: the pad stands above the timeline and status bar (its own padding and the keys' frame included).
    var reserve: CGFloat {
        isActive && !inOverlayWindow ? Self.height + 24 + 8 + Panel.bottomInset(timeline: model?.showTimeline ?? true) + 12 : 0
    }

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
                DispatchQueue.main.async { if PadNumpad.shared.field === ended { PadNumpad.shared.release() } }
            }
        }
    }

    private func began(_ field: UITextField) {
        guard field.keyboardType == .numbersAndPunctuation else { return }
        self.field = field
        usesSystemKeyboard = false
        let named = field.accessibilityLabel ?? field.placeholder ?? ""
        label = named == "expression" ? "Value" : named  // a field with no name of its own says what any of them does
        inOverlayWindow = Self.presentedController(of: field) != nil
        field.inputView = UIView(frame: .zero)  // nothing: the pad is the keyboard
        field.inputAssistantItem.leadingBarButtonGroups = []
        field.inputAssistantItem.trailingBarButtonGroups = []
        field.reloadInputViews()
        updateWindow()
    }

    /// The field is done: the pad goes (and its window, if it had one).
    func release() {
        field = nil
        inOverlayWindow = false
        updateWindow()
    }

    /// The pad over a popover or sheet: a transparent layer on top of the app's own window (not a window of its own: a touch in another
    /// window is not the popover's own, and a popover is dismissed by those), where only the pad itself takes touches.
    private func updateWindow() {
        guard inOverlayWindow, field != nil, let model, let window = field?.window else {
            overlayLayer?.isHidden = true
            overlayFrame = .zero
            if !inOverlayWindow { overlayLayer?.removeFromSuperview(); overlayLayer = nil; overlayHost = nil }
            return
        }
        if overlayLayer?.window !== window { overlayLayer?.removeFromSuperview(); overlayLayer = nil; overlayHost = nil }
        if overlayLayer == nil {
            let layer = PadNumpadLayer(frame: window.bounds)
            layer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            layer.backgroundColor = .clear
            let host = UIHostingController(rootView: PadNumpadOverlay(model: model))
            host.view.backgroundColor = .clear
            host.view.frame = layer.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            if let root = window.rootViewController {
                root.addChild(host)
                layer.addSubview(host.view)
                host.didMove(toParent: root)
            } else {
                layer.addSubview(host.view)
            }
            window.addSubview(layer)
            overlayLayer = layer
            overlayHost = host
        }
        overlayLayer?.isHidden = false
        if let layer = overlayLayer { window.bringSubviewToFront(layer) }  // a popover that came up since is under it
    }

    /// The popover or sheet a field sits in (nil: the document window itself).
    private static func presentedController(of view: UIView) -> UIViewController? {
        var responder: UIResponder? = view
        while let next = responder?.next {
            if let controller = next as? UIViewController, controller.presentingViewController != nil { return controller }
            responder = next
        }
        return nil
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
        // A SwiftUI field in a popover or sheet takes its Return (onSubmit) from the control's own action, which the delegate call alone
        // does not fire.
        if inOverlayWindow { field.sendActions(for: .primaryActionTriggered) }
        field.resignFirstResponder()
    }

    /// The next size field on the screen (the Inspector's, or the ones by the arrows), round to the first again.
    func next() {
        guard let field, let window = field.window else { return }
        var fields: [UITextField] = []
        let here = Self.presentedController(of: field)  // the next size in the same popover or sheet, or in the window itself
        func collect(_ view: UIView) {
            if let f = view as? UITextField, f.keyboardType == .numbersAndPunctuation, !f.isHidden, f.alpha > 0.01, f.window != nil,
               Self.presentedController(of: f) === here { fields.append(f) }
            view.subviews.forEach(collect)
        }
        collect(window)
        guard fields.count > 1, let index = fields.firstIndex(of: field) else { return }
        fields[(index + 1) % fields.count].becomeFirstResponder()
    }

    /// Back to the pad after the letters: the field's keyboard is nothing again.
    func useNumpad() {
        guard let field else { return }
        usesSystemKeyboard = false
        field.inputView = UIView(frame: .zero)
        field.reloadInputViews()
        updateWindow()
    }

    /// The letters, for a parameter's name or an expression: the system keyboard for this field only.
    func useSystemKeyboard() {
        guard let field else { return }
        usesSystemKeyboard = true
        field.inputView = nil
        field.reloadInputViews()
        updateWindow()
    }
}

// MARK: the pad

struct PadNumpadPanel: View {
    let model: DocumentModel
    /// True for the pad in the window of its own over a popover or sheet; false for the one in the document window.
    var inWindow = false
    @State private var numpad = PadNumpad.shared
    @State private var offset = CGSize.zero
    @State private var dragStart = CGSize.zero

    var body: some View {
        if numpad.isActive, numpad.inOverlayWindow == inWindow {
            keys
                .padding(12)
                .frame(width: PadNumpad.width)
                .panelGlass(in: RoundedRectangle(cornerRadius: DS.Radius.window, style: .continuous))
                .offset(offset)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Number pad")
                .reportsFrame(if: inWindow)
        }
    }

    private var keys: some View {
        Group {
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

/// The pad in its own window: at the bottom of the screen, above a popover or sheet. While the letters are up (an expression, a
/// parameter's name) a small "123" key under the field goes back to the pad.
struct PadNumpadOverlay: View {
    let model: DocumentModel
    @State private var numpad = PadNumpad.shared

    var body: some View {
        ZStack {
            PadNumpadPanel(model: model, inWindow: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 24)
            if numpad.field != nil, numpad.usesSystemKeyboard {
                let box = numpad.fieldFrame
                Button { numpad.useNumpad() } label: {
                    Text("123").font(.headline).padding(.horizontal, 18).frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .panelGlass(in: Capsule())
                .reportsFrame(if: true)
                .accessibilityLabel("Show the number pad")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, box.maxX + 130)  // beside the popover: under it the keyboard would cover it
                .padding(.top, max(box.minY - 8, 8))
            }
        }
    }
}

private extension View {
    /// Tells the pad's window where this view is on the screen, so the window takes touches only there.
    @ViewBuilder func reportsFrame(if on: Bool) -> some View {
        if on {
            onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { PadNumpad.shared.overlayFrame = $0 }
        } else {
            self
        }
    }
}

/// A layer over the whole window that passes every touch not on the pad through to what is under it. (SwiftUI's buttons are not views of
/// their own: the hosting view is the hit view for all of them, so what is on the pad is told by its frame.)
final class PadNumpadLayer: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        PadNumpad.shared.overlayFrame.contains(point) ? super.hitTest(point, with: event) : nil
    }
}
