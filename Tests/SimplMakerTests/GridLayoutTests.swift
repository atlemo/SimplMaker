// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CADCore
import SwiftUI
import Testing
@testable import SimplMaker

/// The UI follows one grid: buttons share columns from panel to panel, and spacing is a step of the design system's
/// scale. These tests measure the drawn views, so a symbol that is wider than its frame (the cause of the padlock and
/// eye once nearly touching) or a row that drifts off its header's columns fails here instead of in a screenshot.
@Suite(.serialized) @MainActor struct GridLayoutTests {
    /// The horizontal runs of ink (in points from the view's left edge) of a view drawn on a transparent background,
    /// looking only at the rows `bandTop..<bandBottom` (points from the top), left to right.
    private func inkRuns<V: View>(of view: V, size: CGSize = CGSize(width: 120, height: 40), band: Range<CGFloat>? = nil,
                                  settle: Duration? = nil) async throws -> [ClosedRange<CGFloat>] {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.appearance = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .trailing)
            .environment(\.colorScheme, .light).foregroundStyle(.black))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        if let settle { try await Task.sleep(for: settle); host.layoutSubtreeIfNeeded() }
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        let band = band ?? 0..<size.height
        let rows = Int(band.lowerBound * scale)..<Int(band.upperBound * scale)
        var runs: [ClosedRange<CGFloat>] = []
        var start: Int?
        for x in 0..<rep.pixelsWide {
            let inked = rows.contains { (rep.colorAt(x: x, y: $0)?.alphaComponent ?? 0) > 0.25 }
            if inked, start == nil { start = x }
            if !inked, let s = start { runs.append(CGFloat(s) / scale ... CGFloat(x) / scale); start = nil }
        }
        if let s = start { runs.append(CGFloat(s) / scale ... CGFloat(rep.pixelsWide) / scale) }
        return runs
    }

    private func centre(_ r: ClosedRange<CGFloat>) -> CGFloat { (r.lowerBound + r.upperBound) / 2 }

    private func browserModel() async throws -> DocumentModel {
        var s = Sketch()
        s.addRectangle(0, 0, 40, 20)
        var d = CADDocument()
        d.features = [
            Feature(id: "a", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "20", length: "20", height: "10"))),
            Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s))),
        ]
        let m = DocumentModel(document: d)
        for _ in 0..<400 where m.isRegenerating || m.result == nil { try await Task.sleep(for: .milliseconds(5)) }
        return m
    }

    /// The columns of a panel: the eye sits under the collapse arrow and the padlock under the add button, row after
    /// row, because they share the header's button cells. Measured on the real Browser panel, drawn.
    @Test func browserRowsLineUpWithTheHeaderButtons() async throws {
        let model = try await browserModel()
        let panel = SidebarPanel(title: "Browser", open: .constant(true), accessory: {
            HeaderIconButton(systemImage: "folder.badge.plus", help: "Add a folder") {}
        }) { BrowserList(model: model) }
        let size = CGSize(width: 260, height: 300)
        let head = try await inkRuns(of: panel, size: size, band: 0..<PanelTouch.headerHeight, settle: .milliseconds(300))
        // Below the header: the Bodies and Sketches folders and their rows (the rows' own text is further left).
        let rows = try await inkRuns(of: panel, size: size, band: (PanelTouch.headerHeight + 6)..<200, settle: .milliseconds(300))
        let arrow = centre(try #require(head.last)), add = centre(try #require(head.dropLast().last))
        let eye = centre(try #require(rows.last)), lock = centre(try #require(rows.dropLast().last))
        // The add button's badge makes its drawing lopsided inside its cell, hence a point and a half.
        #expect(abs(eye - arrow) <= 1.5, "the eye is at \(eye) pt, the header's collapse arrow at \(arrow)")
        #expect(abs(lock - add) <= 1.5, "the padlock is at \(lock) pt, the header's add button at \(add)")
    }

    /// The Appearance panel's eye is in the same column as the Browser's: under the header's collapse arrow.
    @Test func appearanceEyeLinesUpWithTheHeaderArrow() async throws {
        let model = try await browserModel()
        model.setHidden(["a"], true)  // a hidden body's eye is always shown
        let panel = SidebarPanel(title: "Appearance", open: .constant(true), accessory: { EmptyView() }) { AppearancePanel(model: model) }
        let size = CGSize(width: 260, height: 520)
        let head = try await inkRuns(of: panel, size: size, band: 0..<PanelTouch.headerHeight, settle: .milliseconds(300))
        let rows = try await inkRuns(of: panel, size: size, band: 396..<520, settle: .milliseconds(300))
        let arrow = centre(try #require(head.last)), eye = centre(try #require(rows.last))
        #expect(abs(eye - arrow) <= 1.5, "the Appearance eye is at \(eye) pt, the header's collapse arrow at \(arrow)")
    }

    /// On the tinted sketch toolbar the panel buttons are one pill, as the glass group is in Design: the pill's fill
    /// also covers the seam between two buttons, where separate round buttons would leave a gap.
    @Test func sketchToolbarButtonsAreOnePill() throws {
        let group = HStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { _ in PanelToggle(title: "t", systemImage: "camera", ink: .black, help: "") {} }
        }
        .toolbarGlass(ink: .black)
        let size = CGSize(width: 130, height: 50)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: true)
        window.appearance = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: group.frame(width: size.width, height: size.height, alignment: .leading))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / size.width
        func alpha(_ x: CGFloat, _ y: CGFloat) -> CGFloat { rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.alphaComponent ?? 0 }
        let top = (size.height - 34) / 2 + 3  // just inside the pill's top edge
        #expect(alpha(4 + 34, top) > 0.1, "no fill between the first two buttons: separate circles, not one pill")
        #expect(alpha(4 + 68, top) > 0.1, "no fill between the last two buttons")
        #expect(alpha(1, (size.height - 34) / 2 + 1) < 0.05, "the pill's corner is square, not round")
    }

    /// Padlock and eye never come closer than a label gap, whichever symbols they show, and the eye does not move
    /// with the state of the padlock or of itself.
    @Test func padlockAndEyeKeepApartAndTheEyeStaysPut() async throws {
        var eyeCentres: Set<CGFloat> = []
        for locked in [false, true] {
            for hidden in [false, true] {
                let runs = try await inkRuns(of: RowEndButtons(locked: locked, toggleLock: {}, hidden: hidden, toggleHidden: {}))
                try #require(runs.count == 2, "locked \(locked), hidden \(hidden): expected two shapes, got \(runs)")
                let gap = runs[1].lowerBound - runs[0].upperBound
                #expect(gap >= DS.Spacing.labelGap, "locked \(locked), hidden \(hidden): drawn gap \(gap) pt")
                eyeCentres.insert(centre(runs[1]))
            }
        }
        #expect(eyeCentres.count == 1, "the eye moves with a state: \(eyeCentres.sorted())")
    }

    /// Spacing and padding written as a bare number must be a step of `DS.Spacing.scale` (or use the DS names).
    /// The views that predate this check keep their off-grid numbers, listed here with how many each has: the list
    /// may only shrink. A new off-grid number fails the test; move a view onto the grid and lower its count.
    @Test func spacingAndPaddingLiteralsAreOnTheGrid() throws {
        let known: [String: Int] = [
            "WelcomeView.swift": 7, "DocumentPanels.swift": 2, "AppearancePanel.swift": 2, "ContentView.swift": 3,
            "CommandPalette.swift": 1, "TutorialCard.swift": 1, "TutorialSpotlight.swift": 1, "AISettingsPane.swift": 1,
        ]
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/SimplMaker")
        let patterns = [#"\bspacing:\s*(-?\d+(?:\.\d+)?)\s*[,)]"#,
                        #"\.padding\((?:\.[A-Za-z]+,\s*|\[[^\]]*\],\s*)?(-?\d+(?:\.\d+)?)\)"#]
            .map { try! NSRegularExpression(pattern: $0) }
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var found: [String: [String]] = [:]
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (n, line) in text.components(separatedBy: "\n").enumerated() {
                let code = String(line.components(separatedBy: "//")[0])
                let range = NSRange(code.startIndex..., in: code)
                var seen = Set<Int>()
                for regex in patterns {
                    for m in regex.matches(in: code, range: range) where seen.insert(m.range.location).inserted {
                        let value = Double(code[Range(m.range(at: 1), in: code)!])!
                        if !DS.Spacing.scale.contains(CGFloat(value)) {
                            found[url.lastPathComponent, default: []].append("line \(n + 1): \(value)")
                        }
                    }
                }
            }
        }
        for (file, hits) in found.sorted(by: { $0.key < $1.key }) {
            #expect(hits.count <= known[file, default: 0],
                    "\(file) has \(hits.count) off-grid spacing/padding numbers (allowed \(known[file, default: 0])): \(hits.joined(separator: ", ")). Use DS.Spacing steps \(DS.Spacing.scale.map { Int($0) }).")
        }
        for (file, allowed) in known where (found[file]?.count ?? 0) < allowed {
            Issue.record("\(file) is down to \(found[file]?.count ?? 0) off-grid numbers: lower its count in the list (was \(allowed))")
        }
    }
}
