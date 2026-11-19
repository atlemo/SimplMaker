// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import Testing
@testable import SimplMaker

/// The window's workspaces (Design and the Mold studio): which are offered, and what switching does to what is open.
@Suite(.serialized) @MainActor struct WorkspaceTests {
    /// Runs `body` with the Mold workspace switched on or off, and puts the preference back as it was.
    private func withMold(_ on: Bool, _ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let before = defaults.object(forKey: Preferences.moldWorkspace)
        defaults.set(on, forKey: Preferences.moldWorkspace)
        defer { if let before { defaults.set(before, forKey: Preferences.moldWorkspace) } else { defaults.removeObject(forKey: Preferences.moldWorkspace) } }
        try body()
    }

    @Test func anEmptyPartOpensOnTheStartPageAndOneWithFeaturesInDesign() {
        #expect(DocumentModel(document: CADDocument()).workspace == .start)
        var d = CADDocument()
        d.features = [Feature(id: "a", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "20", length: "20", height: "10")))]
        #expect(DocumentModel(document: d).workspace == .design)
    }

    @Test func moldIsOfferedOnlyWhenSwitchedOn() {
        withMold(false) { #expect(Workspace.available == [.start, .design, .render]) }
        withMold(true) { #expect(Workspace.available == [.start, .design, .mold, .render]) }
    }

    @Test func onlyDesignAndMoldHaveToolRows() {
        #expect(Workspace.allCases.filter(\.hasTools) == [.design, .mold])
    }

    @Test func aWorkspaceThatIsNotOfferedCannotBeEntered() {
        withMold(false) {
            let model = DocumentModel(document: CADDocument())
            model.setWorkspace(.design)
            model.setWorkspace(.mold)
            #expect(model.workspace == .design)
        }
    }

    @Test func switchingFinishesTheSketchBeingEdited() {
        withMold(true) {
            let model = DocumentModel(document: CADDocument())
            model.beginSketch(on: .xy)
            #expect(model.workspace == .design)
            #expect(model.sketchSession != nil)
            model.setWorkspace(.mold)
            #expect(model.workspace == .mold)
            #expect(model.sketchSession == nil)
        }
    }

    @Test func switchingDropsAToolWaitingForPicksAndAPlanePick() {
        withMold(true) {
            let model = DocumentModel(document: CADDocument())
            model.startSketch()
            #expect(model.isPickingSketchPlane)
            #expect(model.workspace == .design)  // the sketch button took the start page's place
            model.setWorkspace(.mold)
            #expect(!model.isPickingSketchPlane)
            model.setWorkspace(.design)
            model.run(.revolve)
            #expect(model.pendingTool == .revolve)
            model.setWorkspace(.mold)
            #expect(model.pendingTool == nil)
        }
    }

    @Test func switchingBackLeavesTheDocumentAlone() {
        withMold(true) {
            let model = DocumentModel(document: CADDocument())
            let before = model.document
            model.setWorkspace(.mold)
            model.setWorkspace(.design)
            #expect(model.workspace == .design)
            #expect(model.document == before)
        }
    }

    @Test func aDesignToolRunFromTheStartPageGoesToDesign() {
        let model = DocumentModel(document: CADDocument())
        #expect(model.workspace == .start)
        model.run(.revolve)
        #expect(model.workspace == .design)
        #expect(model.pendingTool == .revolve)
    }

    @Test func theRenderWorkspaceTurnsTheRenderViewOnAndOff() {
        let model = DocumentModel(document: CADDocument())
        model.setWorkspace(.design)
        model.setWorkspace(.render)
        #expect(model.renderView)
        model.setWorkspace(.design)
        #expect(!model.renderView)
        #expect(model.workspace == .design)
    }

    @Test func turningTheRenderViewOnFromAMenuMovesTheSelectorAndBackAgain() {
        let model = DocumentModel(document: CADDocument())
        model.setWorkspace(.design)
        model.setRenderView(true)
        #expect(model.workspace == .render)
        model.setRenderView(false)
        #expect(model.workspace == .design)
    }

    @Test func leavingRenderForStartTurnsTheViewOffToo() {
        let model = DocumentModel(document: CADDocument())
        model.setWorkspace(.render)
        model.setWorkspace(.start)
        #expect(!model.renderView)
        #expect(model.workspace == .start)
    }

    @Test func startingASketchLeavesTheRenderView() {
        let model = DocumentModel(document: CADDocument())
        model.setWorkspace(.render)
        model.startSketch()
        #expect(!model.renderView)
        #expect(model.workspace == .design)
    }

    @Test func pressingRenderAgainBringsItsOptionsBack() {
        let model = DocumentModel(document: CADDocument())
        model.setWorkspace(.render)
        model.showRenderOptions = false
        model.setWorkspace(.render)
        #expect(model.showRenderOptions)
        #expect(model.workspace == .render)
    }
}
