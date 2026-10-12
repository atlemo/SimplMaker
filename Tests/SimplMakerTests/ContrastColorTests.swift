// Copyright © 2026 Atle Mo. All rights reserved.
import AppKit
import Testing
@testable import SimplMaker

/// The toolbar's symbols and titles take black or white by contrast with whatever colour the toolbar is.
@Suite @MainActor struct ContrastColorTests {
    private let aqua = NSAppearance(named: .aqua)!

    private func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }

    @Test func ratioMatchesWCAGEndpoints() {
        #expect(abs(ContrastColor.ratio(ContrastColor.white, ContrastColor.black) - 21) < 0.01)
        #expect(abs(ContrastColor.ratio(ContrastColor.white, ContrastColor.white) - 1) < 0.01)
    }

    @Test func deepColoursTakeWhiteAndPaleOnesTakeBlack() {
        #expect(ContrastColor.prefersWhite(on: srgb(0.16, 0.46, 0.33), in: aqua))      // Soft green's deep shade
        #expect(ContrastColor.prefersWhite(on: srgb(0.04, 0.52, 1), in: aqua))         // the system blue: white, though black scores a little higher
        #expect(!ContrastColor.prefersWhite(on: srgb(1, 0.58, 0), in: aqua))           // an orange accent colour
        #expect(!ContrastColor.prefersWhite(on: srgb(1, 0.8, 0), in: aqua))            // a yellow accent colour
        #expect(!ContrastColor.prefersWhite(on: srgb(0.78, 0.87, 0.96), in: aqua))     // pale paper
    }

    @Test func everyAccentColourGetsAReadableForeground() {
        // Sweep the colour cube: whichever of black and white is picked always clears the graphics bar.
        let steps: [CGFloat] = [0, 0.25, 0.5, 0.75, 1]
        for r in steps { for g in steps { for b in steps {
            let bg = srgb(r, g, b)
            let fg = ContrastColor.foreground(on: bg, in: aqua)
            #expect(ContrastColor.ratio(fg, bg) >= ContrastColor.graphicRatio)
        } } }
    }

    @Test func everySketchToolbarTintGetsAReadableForeground() {
        for paper in Preferences.SketchPaper.allCases {
            let bg = ContrastColor.resolve(paper.toolbarNSColor, in: aqua)!
            #expect(ContrastColor.ratio(ContrastColor.foreground(on: bg, in: aqua), bg) >= ContrastColor.graphicRatio)
        }
    }

    @Test func softenedTextStaysAboveTheTextBar() {
        for bg in [srgb(0.16, 0.46, 0.33), srgb(1, 0.8, 0), srgb(0.55, 0.47, 0.27), srgb(0.5, 0.5, 0.5)] {
            let fg = ContrastColor.foreground(on: bg, alpha: 0.75, in: aqua)
            let opaque = fg.withAlphaComponent(1)
            // Blend by hand: the soft colour over the background.
            let a = fg.alphaComponent
            let f = opaque.usingColorSpace(.sRGB)!
            let mixed = srgb(f.redComponent * a + bg.redComponent * (1 - a), f.greenComponent * a + bg.greenComponent * (1 - a),
                             f.blueComponent * a + bg.blueComponent * (1 - a))
            // Either it passes the text bar, or it fell back to the opaque colour (which is the best of black and white).
            #expect(ContrastColor.ratio(mixed, bg) >= ContrastColor.textRatio || a == 1)
        }
    }
}
