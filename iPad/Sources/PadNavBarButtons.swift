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

    private var content: some View {
        PadTopButtons(model: model, guide: guide, undoManager: undoManager)
            .modifier(AccentScope(sketching: model.sketchSession != nil))
    }

    func makeUIView(context: Context) -> Anchor {
        let anchor = Anchor()
        anchor.isUserInteractionEnabled = false
        anchor.host = UIHostingController(rootView: AnyView(content))
        anchor.host?.view.backgroundColor = .clear
        return anchor
    }

    func updateUIView(_ anchor: Anchor, context: Context) {
        anchor.host?.rootView = AnyView(content)
        anchor.attach()
    }

    static func dismantleUIView(_ anchor: Anchor, coordinator: ()) { anchor.detach() }

    /// An invisible view in the document's hierarchy: through it the navigation bar above is found.
    final class Anchor: UIView {
        var host: UIHostingController<AnyView>?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { DispatchQueue.main.async { [weak self] in self?.attach() } } else { detach() }
        }

        func attach() {
            guard let host, let bar = navigationBar() else { return }
            if host.view.superview === bar { return }
            host.view.removeFromSuperview()
            bar.addSubview(host.view)
            host.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                host.view.trailingAnchor.constraint(equalTo: bar.safeAreaLayoutGuide.trailingAnchor, constant: -14),
                host.view.centerYAnchor.constraint(equalTo: bar.safeAreaLayoutGuide.centerYAnchor),
            ])
            if let controller = owningController(of: bar), host.parent == nil { controller.addChild(host); host.didMove(toParent: controller) }
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
