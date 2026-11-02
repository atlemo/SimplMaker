// The navigation cube in the viewport's corner: it turns with the camera, and clicking a face, an
// edge or a corner turns the view to look from there; dragging it orbits, and the house goes home.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import simd

final class ViewCubeView: NSView {
    /// The camera to follow, and what clicks and drags do with it.
    var camera: () -> Camera? = { nil }
    var lookAlong: (SIMD3<Float>) -> Void = { _ in }
    var orbit: (_ dx: Float, _ dy: Float) -> Void = { _, _ in }
    var home: () -> Void = {}
    /// A quarter turn of the picture, +1 counter-clockwise and −1 clockwise (sketching or modelling).
    var turn: (_ quarterTurns: Int) -> Void = { _ in }
    var offersTurning = false {
        didSet {
            guard offersTurning != oldValue else { return }
            turnButtons.forEach { $0.isHidden = !offersTurning }
            if !offersTurning { hoveredArrow = nil }
        }
    }
    /// The colour of the hovered part (the accent, which while sketching is the system's).
    var accent: () -> NSColor = { .controlAccentColor }

    static let size = NSSize(width: 136, height: 132)
    private let scale: CGFloat = 30  // half the cube's side, in points
    private var center: CGPoint { CGPoint(x: bounds.midX + 4, y: bounds.midY - 8) }

    /// The part under the pointer: a direction whose components are −1, 0 or 1 (one nonzero: a
    /// face; two: an edge; three: a corner).
    private var hovered: SIMD3<Int32>? { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var dragFrom: NSPoint?
    private var dragged = false
    private var homeButton: NSButton!
    private(set) var turnButtons: [NSButton] = []
    /// The turn arrow under the pointer (0: counter-clockwise, 1: clockwise).
    private var hoveredArrow: Int? { didSet { if hoveredArrow != oldValue { showArrowStates() } } }

    /// A face: its outward normal and the directions that are right and up when you look at it.
    private struct Face {
        let name: String
        let normal: SIMD3<Int32>, right: SIMD3<Int32>, up: SIMD3<Int32>
    }
    private static let faces = [
        Face(name: "FRONT", normal: [0, -1, 0], right: [1, 0, 0], up: [0, 0, 1]),
        Face(name: "BACK", normal: [0, 1, 0], right: [-1, 0, 0], up: [0, 0, 1]),
        Face(name: "RIGHT", normal: [1, 0, 0], right: [0, 1, 0], up: [0, 0, 1]),
        Face(name: "LEFT", normal: [-1, 0, 0], right: [0, -1, 0], up: [0, 0, 1]),
        Face(name: "TOP", normal: [0, 0, 1], right: [1, 0, 0], up: [0, 1, 0]),
        Face(name: "BOTTOM", normal: [0, 0, -1], right: [1, 0, 0], up: [0, -1, 0]),
    ]
    /// Where a face's edge and corner bands begin, in face coordinates (−1…1).
    private let band: CGFloat = 0.6

    override init(frame: NSRect) {
        super.init(frame: frame)
        let button = NSButton(image: NSImage(systemSymbolName: "house", accessibilityDescription: "Home view")!,
                              target: self, action: #selector(goHome))
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = "Home view (fits the model)"
        button.frame = NSRect(x: 2, y: Self.size.height - 24, width: 22, height: 22)
        addSubview(button)
        homeButton = button
        // Curved arrows by the cube's top edge: the view turns a quarter about the line of sight, the way they point.
        // They sit on a ring round the cube's top-right: counter-clockwise on top, clockwise down its right side.
        let ring = [CGPoint(x: Self.size.width / 2 + 4 + 27, y: Self.size.height / 2 - 8 + 51),
                    CGPoint(x: Self.size.width / 2 + 4 + 50, y: Self.size.height / 2 - 8 + 29)]
        for (i, spec) in [(counterClockwise: true, tip: "Turn the view a quarter counter-clockwise", action: #selector(turnCounterClockwise)),
                          (counterClockwise: false, tip: "Turn the view a quarter clockwise", action: #selector(turnClockwise))].enumerated() {
            let image = Self.turnArrow(counterClockwise: spec.counterClockwise)
            image.accessibilityDescription = spec.tip
            let b = NSButton(image: image, target: self, action: spec.action)
            b.isBordered = false
            b.imagePosition = .imageOnly
            b.imageScaling = .scaleNone
            b.toolTip = spec.tip
            b.isHidden = true
            b.frame = NSRect(x: ring[i].x - image.size.width / 2, y: ring[i].y - image.size.height / 2,
                             width: image.size.width, height: image.size.height)
            addSubview(b)
            turnButtons.append(b)
        }
        setAccessibilityLabel("View cube")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// A turn arrow, drawn like a cube face (tinted with the accent while hovered): the same fill and outline, in the light or dark scheme at the time it is drawn.
    /// The outlines are the designer's SVG paths (35×20 pointing left, 20×35 pointing down), scaled down.
    private static func turnArrow(counterClockwise: Bool, hoveredWith accent: NSColor? = nil) -> NSImage {
        let k: CGFloat = 0.9
        let natural = counterClockwise ? CGSize(width: 35, height: 20) : CGSize(width: 20, height: 35)
        let image = NSImage(size: CGSize(width: natural.width * k, height: natural.height * k), flipped: true) { _ in
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let path = NSBezierPath()
            func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * k, y: y * k) }
            if counterClockwise {
                path.move(to: p(9.35358, 5.06644))
                path.curve(to: p(33.6353, 12.905), controlPoint1: p(18.8143, 5.29578), controlPoint2: p(27.5061, 8.14745))
                path.curve(to: p(33.774, 14.2995), controlPoint1: p(34.0716, 13.2436), controlPoint2: p(34.1275, 13.8752))
                path.line(to: p(29.9332, 18.9085))
                path.curve(to: p(28.5101, 19.0558), controlPoint1: p(29.5797, 19.3328), controlPoint2: p(28.9508, 19.3887))
                path.curve(to: p(9.35358, 13.0684), controlPoint1: p(23.9932, 15.6441), controlPoint2: p(17.1978, 13.2916))
                path.line(to: p(9.35358, 18.6035))
                path.line(to: p(0.353577, 9.60355))
                path.line(to: p(9.35358, 0.603546))
            } else {
                path.move(to: p(14.6148, 24.8312))
                path.curve(to: p(6.57961, 0.613773), controlPoint1: p(14.3088, 15.3726), controlPoint2: p(11.3867, 6.70421))
                path.curve(to: p(5.18402, 0.486473), controlPoint1: p(6.23744, 0.180258), controlPoint2: p(5.60542, 0.129489))
                path.line(to: p(0.606275, 4.36447))
                path.curve(to: p(0.470559, 5.78877), controlPoint1: p(0.184871, 4.72147), controlPoint2: p(0.134124, 5.35078))
                path.curve(to: p(6.61315, 24.8961), controlPoint1: p(3.91875, 10.2778), controlPoint2: p(6.32632, 17.0539))
                path.line(to: p(1.07817, 24.941))
                path.line(to: p(10.1509, 33.8677))
                path.line(to: p(19.0776, 24.795))
            }
            path.close()
            NSColor(white: dark ? 0.4 : 0.89, alpha: 1).setFill()
            path.fill()
            if let accent {  // the hovered part of the cube is tinted the same way
                accent.withAlphaComponent(0.45).setFill()
                path.fill()
            }
            NSColor(white: dark ? 0.6 : 0.63, alpha: 1).setStroke()
            path.lineWidth = 0.75
            path.stroke()
            return true
        }
        return image
    }

    private func showArrowStates() {
        for (i, b) in turnButtons.enumerated() {
            let image = Self.turnArrow(counterClockwise: i == 0, hoveredWith: hoveredArrow == i ? accent() : nil)
            image.accessibilityDescription = b.toolTip
            b.image = image
        }
    }

    @objc private func goHome() { home() }
    @objc private func turnCounterClockwise() { turn(1) }
    @objc private func turnClockwise() { turn(-1) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp],
                                       owner: self))
    }

    // MARK: projection

    private func axes(_ cam: Camera) -> (right: SIMD3<Float>, up: SIMD3<Float>, eye: SIMD3<Float>) {
        (cam.right, cam.up, -cam.forward)
    }

    private func project(_ p: SIMD3<Float>, _ cam: Camera) -> CGPoint {
        let a = axes(cam)
        return CGPoint(x: center.x + CGFloat(simd_dot(p, a.right)) * scale, y: center.y + CGFloat(simd_dot(p, a.up)) * scale)
    }

    private func f(_ v: SIMD3<Int32>) -> SIMD3<Float> { SIMD3(Float(v.x), Float(v.y), Float(v.z)) }

    /// A visible face's centre and the screen vectors of its right and up half-sides.
    private func frame(of face: Face, _ cam: Camera) -> (c: CGPoint, a: CGVector, b: CGVector)? {
        guard simd_dot(f(face.normal), axes(cam).eye) > 1e-3 else { return nil }
        let c = project(f(face.normal), cam)
        let r = project(f(face.normal) + f(face.right), cam), u = project(f(face.normal) + f(face.up), cam)
        return (c, CGVector(dx: r.x - c.x, dy: r.y - c.y), CGVector(dx: u.x - c.x, dy: u.y - c.y))
    }

    private func point(_ fr: (c: CGPoint, a: CGVector, b: CGVector), _ s: CGFloat, _ t: CGFloat) -> CGPoint {
        CGPoint(x: fr.c.x + s * fr.a.dx + t * fr.b.dx, y: fr.c.y + s * fr.a.dy + t * fr.b.dy)
    }

    /// The region (face, edge or corner direction) under a point, if it's on the cube.
    private func region(at p: CGPoint) -> SIMD3<Int32>? {
        guard let cam = camera() else { return nil }
        for face in Self.faces {
            guard let fr = frame(of: face, cam) else { continue }
            let det = fr.a.dx * fr.b.dy - fr.a.dy * fr.b.dx
            guard abs(det) > 1e-6 else { continue }
            let dx = p.x - fr.c.x, dy = p.y - fr.c.y
            let s = (dx * fr.b.dy - dy * fr.b.dx) / det, t = (fr.a.dx * dy - fr.a.dy * dx) / det
            guard abs(s) <= 1, abs(t) <= 1 else { continue }
            let i: Int32 = s < -band ? -1 : s > band ? 1 : 0, j: Int32 = t < -band ? -1 : t > band ? 1 : 0
            return face.normal &+ i &* face.right &+ j &* face.up
        }
        return nil
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let cam = camera(), let ctx = NSGraphicsContext.current?.cgContext else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let eye = axes(cam).eye

        // Axes from the front-left-bottom corner; drawn again on top where their edge faces us.
        let origin = SIMD3<Float>(-1, -1, -1)
        let triad: [(SIMD3<Float>, NSColor, String, [SIMD3<Int32>])] = [
            ([1, 0, 0], .systemRed, "X", [[0, -1, 0], [0, 0, -1]]),
            ([0, 1, 0], .systemGreen, "Y", [[-1, 0, 0], [0, 0, -1]]),
            ([0, 0, 1], .systemBlue, "Z", [[-1, 0, 0], [0, -1, 0]]),
        ]
        func drawAxis(_ axis: (SIMD3<Float>, NSColor, String, [SIMD3<Int32>])) {
            let a = project(origin, cam), b = project(origin + axis.0 * 2.7, cam)
            ctx.setStrokeColor(axis.1.cgColor)
            ctx.setLineWidth(2)
            ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
            let label = NSAttributedString(string: axis.2, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .bold),
                                                                        .foregroundColor: axis.1])
            let size = label.size()
            let tip = project(origin + axis.0 * 3.0, cam)
            label.draw(at: CGPoint(x: tip.x - size.width / 2, y: tip.y - size.height / 2))
        }
        func edgeFacesUs(_ axis: (SIMD3<Float>, NSColor, String, [SIMD3<Int32>])) -> Bool {
            axis.3.contains { simd_dot(f($0), eye) > 1e-3 }
        }
        for axis in triad where !edgeFacesUs(axis) { drawAxis(axis) }

        // Faces, shaded a little by how squarely they face the camera, with their names.
        let base: CGFloat = dark ? 0.34 : 0.9
        for face in Self.faces {
            guard let fr = frame(of: face, cam) else { continue }
            let facing = CGFloat(simd_dot(f(face.normal), eye))
            let quad = [point(fr, -1, -1), point(fr, 1, -1), point(fr, 1, 1), point(fr, -1, 1)]
            ctx.addLines(between: quad); ctx.closePath()
            ctx.setFillColor(NSColor(white: base + 0.06 * facing - 0.03, alpha: 0.96).cgColor)
            ctx.fillPath()

            // The hovered face, edge or corner, on every face it touches.
            if let h = hovered {
                for i in Int32(-1)...1 {
                    for j in Int32(-1)...1 where face.normal &+ i &* face.right &+ j &* face.up == h {
                        let s0 = [-1, -band, band][Int(i + 1)], s1 = [-band, band, 1][Int(i + 1)]
                        let t0 = [-1, -band, band][Int(j + 1)], t1 = [-band, band, 1][Int(j + 1)]
                        ctx.addLines(between: [point(fr, s0, t0), point(fr, s1, t0), point(fr, s1, t1), point(fr, s0, t1)])
                        ctx.closePath()
                        ctx.setFillColor(accent().withAlphaComponent(0.45).cgColor)
                        ctx.fillPath()
                    }
                }
            }
            ctx.addLines(between: quad); ctx.closePath()
            ctx.setStrokeColor(NSColor(white: dark ? 0.55 : 0.55, alpha: 1).cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()

            // The name, laid on the face: face coordinates −1…1 map to ±40 text units.
            ctx.saveGState()
            ctx.concatenate(CGAffineTransform(a: fr.a.dx / 40, b: fr.a.dy / 40, c: fr.b.dx / 40, d: fr.b.dy / 40,
                                              tx: fr.c.x, ty: fr.c.y))
            let name = NSAttributedString(string: face.name, attributes: [
                .font: NSFont.systemFont(ofSize: face.name.count > 5 ? 14 : 16, weight: .heavy),
                .foregroundColor: NSColor(white: dark ? 0.85 : 0.35, alpha: 1),
            ])
            let size = name.size()
            name.draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2))
            ctx.restoreGState()
        }
        for axis in triad where edgeFacesUs(axis) { drawAxis(axis) }
    }

    // MARK: mouse

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hoveredArrow = offersTurning ? turnButtons.firstIndex { $0.frame.contains(p) } : nil
        hovered = hoveredArrow == nil ? region(at: p) : nil
    }
    override func mouseExited(with event: NSEvent) { hovered = nil; hoveredArrow = nil }

    override func mouseDown(with event: NSEvent) {
        dragFrom = convert(event.locationInWindow, from: nil)
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let from = dragFrom else { return }
        let dx = Float(p.x - from.x), dy = Float(p.y - from.y)  // up is positive, as the viewport's orbit expects
        if !dragged, abs(dx) + abs(dy) < 3 { return }
        dragged = true
        dragFrom = p
        hovered = nil
        orbit(dx, dy)
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragFrom = nil }
        guard !dragged, let r = region(at: convert(event.locationInWindow, from: nil)) else { return }
        lookAlong(simd_normalize(f(r)))  // look from that face, edge or corner toward the model
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only the cube and the house take clicks; the rest of the square is the viewport's.
        let local = convert(point, from: superview)
        if homeButton.frame.contains(local) { return homeButton }
        if offersTurning, let b = turnButtons.first(where: { $0.frame.contains(local) }) { return b }
        return region(at: local) != nil ? self : nil
    }
}
