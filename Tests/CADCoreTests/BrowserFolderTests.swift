// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation
import Testing
@testable import CADCore

@Suite struct BrowserFolderTests {
    @Test func foldersNestAndHoldItems() {
        var d = CADDocument()
        let a = d.addFolder(named: "Lid")
        let b = d.addFolder(named: "Hinge", in: a)
        d.move(["x", "y"], toFolder: a)
        d.move(["z"], toFolder: b)
        #expect(d.subfolders(of: nil).map(\.name) == ["Lid"] && d.subfolders(of: a).map(\.name) == ["Hinge"])
        #expect(d.depth(of: a) == 0 && d.depth(of: b) == 1)
        #expect(d.items(inTree: a) == ["x", "y", "z"], "a folder's items include those in its folders")
        #expect(d.items(inTree: b) == ["z"])
        #expect(d.folder(of: "z") == b)
    }

    @Test func aFolderCannotGoInsideItself() {
        var d = CADDocument()
        let a = d.addFolder(), b = d.addFolder(in: a), c = d.addFolder(in: b)
        let intoSelf = d.moveFolder(a, into: a)
        let intoChild = d.moveFolder(a, into: c)
        let out = d.moveFolder(c, into: nil)
        #expect(!intoSelf)
        #expect(!intoChild, "nor inside a folder of its own")
        #expect(out && d.folder(c)?.parent == nil)
        #expect(d.nextFolderName() == "Folder 4")
    }

    @Test func deletingAFolderKeepsWhatWasInIt() {
        var d = CADDocument()
        let a = d.addFolder(named: "A"), b = d.addFolder(named: "B", in: a)
        d.move(["in-a"], toFolder: a)
        d.move(["in-b"], toFolder: b)
        d.removeFolder(b)
        #expect(d.folder(of: "in-b") == a, "moves up into the folder it was in")
        d.removeFolder(a)
        #expect(d.folder(of: "in-a") == nil && d.folderOf.isEmpty && d.folders.isEmpty)
    }

    @Test func foldersSurviveSavingAndChangeNothingToRebuild() throws {
        var d = CADDocument()
        let before = d.ignoringPresentation
        let a = d.addFolder(named: "Lid")
        d.move(["x"], toFolder: a)
        #expect(d.ignoringPresentation == before, "folders are presentation only")
        let back = try CADDocument.decode(try d.encoded())
        #expect(back.folders == d.folders && back.folderOf == ["x": a])
        #expect(try CADDocument.decode(try CADDocument().encoded()).folders.isEmpty, "older files have none")
    }

    @Test func anItemInAFolderThatIsGoneIsLoose() {
        var d = CADDocument()
        d.folderOf["x"] = "gone"
        #expect(d.folder(of: "x") == nil)
    }
}
