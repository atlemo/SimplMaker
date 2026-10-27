// File ▸ Rename for document windows with a hidden title. macOS shows its own rename field attached to
// the window title, and with the title hidden it has nothing to attach to, so the stock item does nothing.
// This takes the item over and asks for the new name in a standard sheet instead.
// Copyright © 2026 Atle Mo. All rights reserved.
import AppKit

@MainActor
final class RenameDocument: NSObject, NSMenuItemValidation {
    static let shared = RenameDocument()

    /// Points the File menu's Rename item at the sheet. SwiftUI rebuilds menu items, so this runs each time a menu opens.
    func start() {
        NotificationCenter.default.addObserver(self, selector: #selector(menuOpened(_:)),
                                               name: NSMenu.didBeginTrackingNotification, object: nil)
    }

    @objc private func menuOpened(_ note: Notification) {
        guard let menu = note.object as? NSMenu else { return }
        for item in menu.items where item.action == NSSelectorFromString("renameDocument:") || item.action == NSSelectorFromString("rename:") {
            item.target = self
            item.action = #selector(rename(_:))
        }
    }

    private var document: NSDocument? { NSApp.keyWindow?.windowController?.document as? NSDocument }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        document?.fileURL != nil
    }

    @objc func rename(_ sender: Any?) {
        guard let document, let window = NSApp.keyWindow, let url = document.fileURL else { return }
        let alert = NSAlert()
        alert.messageText = "Rename"
        alert.informativeText = "Enter a new name for this document."
        let field = NSTextField(string: url.deletingPathExtension().lastPathComponent)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !name.contains("/"), !name.contains(":") else { return }
            let target = url.deletingLastPathComponent().appendingPathComponent(name).appendingPathExtension(url.pathExtension)
            guard target != url else { return }
            Task { @MainActor in
                document.move(to: target) { error in
                    if let error { NSAlert(error: error).beginSheetModal(for: window) }
                }
            }
        }
    }
}
