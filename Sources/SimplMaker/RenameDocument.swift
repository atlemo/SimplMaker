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
        center.addObserver(self, selector: #selector(hideStockItem), name: NSApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(hideNow), name: NSMenu.didAddItemNotification, object: nil)
        for delay in [0.5, 2.0] {  // the menu is built just after launch
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.hideStockItem() }
        }
    }

    /// The File menu lists the stock Rename… first and ours (SimplMakerCommands) after it; the stock one's action
    /// isn't one we can match, so hide every Rename… but the last.
    @objc private func hideStockItem() {
        hideNow()
        for delay in [0.05, 0.3] {  // SwiftUI rebuilds the menu just after a window changes
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.hideNow() }
        }
    }

    @objc private func hideNow() {
        guard let file = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "File" })?.submenu else { return }
        let renames = file.items.filter { $0.title.hasPrefix("Rename") }
        for item in renames.dropLast() { item.isHidden = true }
    }

    private var document: NSDocument? { NSDocumentController.shared.currentDocument }

    func rename() {
        guard let document, let url = document.fileURL,
              let window = document.windowControllers.first?.window ?? NSApp.keyWindow else { return NSSound.beep() }
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
