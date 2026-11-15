// Renders an SVG to a PNG at 2x with WebKit-free AppKit: swift render.swift in.svg out.png
import AppKit
let a = CommandLine.arguments
guard a.count == 3, let img = NSImage(contentsOf: URL(fileURLWithPath: a[1])) else { print("usage: render.swift in.svg out.png"); exit(1) }
let scale: CGFloat = 2
let w = Int(img.size.width * scale), h = Int(img.size.height * scale)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
img.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
print("\(w) x \(h)")
