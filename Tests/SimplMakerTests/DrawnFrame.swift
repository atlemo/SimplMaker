// Reading back what a viewport drew, in the tests that look at pixels.
// Copyright © 2026 Atle Mo. All rights reserved.
import Metal
import MetalKit
@testable import SimplMaker

extension ViewportMTKView {
    /// The last frame drawn, once it is the size the view asks for. A new window's first frames come at half size (its layer
    /// takes the window's scale only on a later pass of the run loop), and when the tests run side by side two such frames
    /// can come in a row and look settled.
    var fullSizeTexture: MTLTexture? {
        let scale = window?.backingScaleFactor ?? 2
        let size = autoResizeDrawable ? CGSize(width: bounds.width * scale, height: bounds.height * scale) : drawableSize
        guard let texture = currentDrawable?.texture,
              texture.width == Int(size.width), texture.height == Int(size.height) else { return nil }
        return texture
    }
}
