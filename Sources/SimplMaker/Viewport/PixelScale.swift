// The number of pixels to a point on the screen a view is on.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import MetalKit

extension MTKView {
    /// Pixels per point of the display the view is on (2 until it is in a window).
    var pixelScale: Float {
        #if os(macOS)
        Float(window?.backingScaleFactor ?? 2)
        #else
        Float(window?.screen.scale ?? traitCollection.displayScale)
        #endif
    }
}
