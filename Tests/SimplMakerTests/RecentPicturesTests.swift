// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CADCore
import Foundation
import Testing
@testable import SimplMaker

/// The recent parts' pictures: the one drawn at the last open is shown, also for a file that has no picture of its own.
@Suite(.serialized) @MainActor struct RecentPicturesTests {
    private func png(_ side: Int) -> Data {
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus(); NSColor.orange.setFill(); NSRect(x: 0, y: 0, width: side, height: side).fill(); image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }

    @Test func aPictureDrawnAtOpenIsShownForAFileWithNone() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recent-\(UUID().uuidString).simplmaker")
        try CADDocument().encoded().write(to: url)  // saved without a picture, as an older version did
        defer { try? FileManager.default.removeItem(at: url); RecentPictures.store(nil, for: url) }
        #expect(await RecentPictures.image(for: url) == nil)
        RecentPictures.store(png(64), for: url)
        let drawn = await RecentPictures.image(for: url)
        #expect(drawn != nil)
        RecentPictures.store(nil, for: url)  // an empty part: no picture
        #expect(await RecentPictures.image(for: url) == nil)
    }
}
