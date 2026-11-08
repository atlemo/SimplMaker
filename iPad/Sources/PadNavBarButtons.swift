// The part's action buttons (undo, redo, render, view, help, settings, export) in the navigation bar, as a view of our own.
//
// As items of the system bar (`.toolbar`) they kept disappearing: after another app had been in front, or a dialog had been
// open. That took the way out of the Render view with it. A view added to the bar itself is not something the bar can drop.

import SwiftUI
import UIKit

struct PadNavBarButtons: UIViewRepresentable {
    let model: DocumentModel
    let guide: TutorialGuide
    let undoManager: UndoManager?
    /// Where the buttons are, in window coordinates: the glass behind them is drawn with the rest of the glass, not here.
    @Binding var frame: CGRect

    private var content: some View {
        PadTopButtons(model: model, guide: guide, undoManager: undoManager)
            .modifier(AccentScope(sketching: model.sketchSession != nil))
    }

    func makeUIView(context: Context) -> Anchor {
        let anchor = Anchor()
        anchor.isUserInteractionEnabled = false
        anchor.onFrame = { new in if new != frame { frame = new } }
        anchor.host = UIHostingController(rootView: AnyView(content))
        anchor.host?.view.backgroundColor = .clear
        return anchor
    }

    func updateUIView(_ anchor: Anchor, context: Context) {
        anchor.host?.rootView = AnyView(content)
        anchor.onFrame = { new in if new != frame { frame = new } }
        anchor.attach()
    }

    static func dismantleUIView(_ anchor: Anchor, coordinator: ()) { anchor.detach() }

    /// An invisible view in the document's hierarchy: through it the navigation bar above is found.
    final class Anchor: UIView {
        var host: UIHostingController<AnyView>?
        var onFrame: (CGRect) -> Void = { _ in }

        override func layoutSubviews() {
            super.layoutSubviews()
            DispatchQueue.main.async { [weak self] in self?.report() }
        }

        func report() {
            guard let view = host?.view, view.window != nil else { return }
            view.layoutIfNeeded()
            onFrame(view.convert(view.bounds, to: nil))
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { DispatchQueue.main.async { [weak self] in self?.attach() } } else { detach() }
        }

        func attach() {
            guard let host, let bar = navigationBar() else { return }
            // The bar has no backdrop of its own: the view shows through, and the glass is all that is on it.
            let clear = UINavigationBarAppearance()
            clear.configureWithTransparentBackground()
            bar.standardAppearance = clear; bar.scrollEdgeAppearance = clear; bar.compactAppearance = clear; bar.compactScrollEdgeAppearance = clear
            if host.view.superview === bar { return }
            host.view.removeFromSuperview()
            bar.addSubview(host.view)
            host.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                host.view.trailingAnchor.constraint(equalTo: bar.safeAreaLayoutGuide.trailingAnchor, constant: -14),
                host.view.centerYAnchor.constraint(equalTo: bar.safeAreaLayoutGuide.centerYAnchor),
            ])
            if let controller = owningController(of: bar), host.parent == nil { controller.addChild(host); host.didMove(toParent: controller) }
            DispatchQueue.main.async { [weak self] in self?.report() }
        }

        func detach() {
            host?.willMove(toParent: nil)
            host?.view.removeFromSuperview()
            host?.removeFromParent()
        }

        /// The bar of the navigation controller this view's controller sits in.
        private func navigationBar() -> UINavigationBar? {
            var responder: UIResponder? = self
            while let next = responder?.next {
                if let controller = next as? UIViewController, let bar = controller.navigationController?.navigationBar { return bar }
                responder = next
            }
            return nil
        }

        private func owningController(of bar: UINavigationBar) -> UIViewController? {
            var responder: UIResponder? = bar
            while let next = responder?.next {
                if let controller = next as? UIViewController { return controller }
                responder = next
            }
            return nil
        }
    }
}
