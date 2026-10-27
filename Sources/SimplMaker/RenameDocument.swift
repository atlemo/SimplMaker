// File ▸ Rename for document windows with a hidden title. macOS shows its own rename field attached to
// the window title, and with the title hidden it has nothing to attach to, so the stock item does nothing.
// This takes the item over and asks for the new name in a standard sheet instead.
// Copyright © 2026 Atle Mo. All rights reserved.
import AppKit

@MainActor
final class RenameDocument: NSObject {
    static let shared = RenameDocument()

    /// Hides the stock Rename item, which does nothing here; File ▸ Rename… in SimplMakerCommands replaces it.
    /// SwiftUI rebuilds menu items, so this runs whenever a menu opens or a window comes forward. The tracking
    /// notification names the menu bar, not the File submenu, so it searches them all.
    func start() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(hideStockItem), name: NSMenu.didBeginTrackingNotification, object: nil)
        center.addObserver(self, selector: #selector(hideStockItem), name: NSWindow.didBecomeKeyNotification, object: nil)
    }

    @objc private func hideStockItem() {
        if let menu = NSApp.mainMenu { hideRename(in: menu) }
    }

    private func hideRename(in menu: NSMenu) {
        for item in menu.items {
            if item.action == NSSelectorFromString("renameDocument:") || item.action == NSSelectorFromString("rename:") {
                item.isHidden = true
            }
            if let submenu = item.submenu { hideRename(in: submenu) }
        }
    }

    private var document: NSDocument? { NSApp.keyWindow?.windowController?.document as? NSDocument }

    func rename() {
        guard let document, let window = NSApp.keyWindow, let url = document.fileURL else { return NSSound.beep() }
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
