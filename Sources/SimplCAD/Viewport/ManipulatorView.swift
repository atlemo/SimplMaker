// Draws the Move/Rotate manipulator over the viewport. It never takes the mouse: the viewport
// asks the layout what a click hits (see ManipulatorLayout.hit).
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CADCore

@MainActor
final class ManipulatorView: NSView {
    var layout: ManipulatorLayout? { didSet { needsDisplay = true } }
    /// The part under the pointer, and the one the typed field is for.
    var hover: ManipulatorPart? { didSet { if hover != oldValue { needsDisplay = true } } }
    var active: ManipulatorPart? { didSet { if active != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private let body = NSColor(white: 0.88, alpha: 1)
    private let lit = NSColor(calibratedRed: 0.35, green: 0.72, blue: 1, alpha: 1)
    private let outline = NSColor.black

    private func fill(for part: ManipulatorPart) -> NSColor { part == hover || part == active ? lit : body }

    /// The rotation rings take the axes' colours, as in the view cube: X red, Y green, Z blue.
    static func color(of axis: Axis3) -> NSColor {
        switch axis {
        case .x: return NSColor(calibratedRed: 0.92, green: 0.24, blue: 0.24, alpha: 1)
        case .y: return NSColor(calibratedRed: 0.22, green: 0.68, blue: 0.30, alpha: 1)
        case .z: return NSColor(calibratedRed: 0.24, green: 0.48, blue: 0.95, alpha: 1)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let layout, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)

        // Rings first, so everything else sits on top of them.
        for ring in layout.rings {
            let part = ManipulatorPart.ring(ring.axis)
            let path = CGMutablePath()
            path.addLines(between: ring.outline)
            path.closeSubpath()
            ctx.addPath(path)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
            ctx.setLineWidth(4)
            ctx.strokePath()
            ctx.addPath(path)
            let strong = part == hover || part == active
            ctx.setStrokeColor(Self.color(of: ring.axis).withAlphaComponent(strong ? 1 : 0.85).cgColor)
            ctx.setLineWidth(strong ? 3.2 : 1.8)
            ctx.strokePath()
        }
        for square in layout.squares {
            shape(ctx, square.corners, fill: fill(for: .plane(square.normal)))
        }
        for arrow in layout.arrows {
            shape(ctx, arrow.polygon, fill: fill(for: .axis(arrow.axis)))
        }
        disc(ctx, layout.center, ManipulatorLayout.dotRadius, fill: fill(for: .center), dot: false)
        for ring in layout.rings {
            let part = ManipulatorPart.ring(ring.axis), color = Self.color(of: ring.axis)
            // Lit, the handle fills with a light wash of its own colour.
            let lit = part == hover || part == active
            disc(ctx, ring.handle, ManipulatorLayout.handleRadius, fill: lit ? color.blended(withFraction: 0.55, of: .white) ?? color : body,
                 dot: true, dotColor: color)
        }
    }

    private func shape(_ ctx: CGContext, _ points: [CGPoint], fill: NSColor) {
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(fill.cgColor)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(outline.cgColor)
        ctx.setLineWidth(2)
        ctx.strokePath()
    }

    private func disc(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, fill: NSColor, dot: Bool, dotColor: NSColor? = nil) {
        let rect = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        ctx.setFillColor(fill.cgColor)
        ctx.fillEllipse(in: rect)
        ctx.setStrokeColor(outline.cgColor)
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: rect)
        if dot {
            ctx.setFillColor((dotColor ?? outline).cgColor)
            ctx.fillEllipse(in: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6))
        }
    }
}
