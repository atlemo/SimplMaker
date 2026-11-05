// The context menu items the model offers for what is under a finger (the Mac's right-click menu), as a UIMenu.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import UIKit

enum ContextMenuBuilder {
    static func menu(_ items: [ContextItem], after: @escaping () -> Void) -> UIMenu {
        // Items between separators form a group, drawn with a divider between groups.
        var groups: [[UIMenuElement]] = [[]]
        for item in items {
            switch item {
            case .separator:
                if !(groups.last?.isEmpty ?? true) { groups.append([]) }
            case .action(let title, let symbol, let enabled, let action):
                nonisolated(unsafe) let run = action
                nonisolated(unsafe) let finished = after
                let element = UIAction(title: title, image: symbol.flatMap { UIImage(systemName: $0) },
                                       attributes: enabled ? [] : .disabled) { _ in
                    MainActor.assumeIsolated { run(); finished() }
                }
                groups[groups.count - 1].append(element)
            case .submenu(let title, let children):
                groups[groups.count - 1].append(menu(children, after: after).withTitle(title))
            }
        }
        let children = groups.filter { !$0.isEmpty }.map { UIMenu(title: "", options: .displayInline, children: $0) }
        return UIMenu(title: "", children: children)
    }
}

private extension UIMenu {
    func withTitle(_ title: String) -> UIMenu { UIMenu(title: title, children: children) }
}
