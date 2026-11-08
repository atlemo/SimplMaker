// The navigation cube in the corner of the view: it turns with the camera; a tap on a face, an edge or a corner turns the view to look from
// there, a drag orbits, the house goes home, and the arrows turn the picture a quarter about the line of sight.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import simd

struct PadViewCube: View {
    let model: DocumentModel
    let state: PadViewState
    @Environment(\.accent) private var accent
    @State private var lastDrag: CGSize?
    @State private var flash: SIMD3<Int32>?

    static let size = CGSize(width: 150, height: 144)
    private let scale: CGFloat = 32
    private let band: CGFloat = 0.6

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

    private var center: CGPoint { CGPoint(x: 72, y: 72) }

    /// A model direction on the cube's picture.
    private func point(_ v: SIMD3<Float>, _ camera: Camera) -> CGPoint {
        CGPoint(x: center.x + scale * CGFloat(simd_dot(v, camera.right)), y: center.y - scale * CGFloat(simd_dot(v, camera.up)))
    }

    private func f(_ v: SIMD3<Int32>) -> SIMD3<Float> { SIMD3(Float(v.x), Float(v.y), Float(v.z)) }

    var body: some View {
        let _ = state.revision
        ZStack(alignment: .topLeading) {
            if let camera = state.renderer?.camera {
                Canvas { ctx, _ in draw(&ctx, camera) }
                    .frame(width: Self.size.width, height: Self.size.height)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            if let last = lastDrag {
                                if hypot(g.translation.width, g.translation.height) > 6 {
                                    state.orbit?(Float(g.translation.width - last.width), Float(-(g.translation.height - last.height)))
                                }
                            }
                            lastDrag = g.translation
                        }
                        .onEnded { g in
                            lastDrag = nil
                            if hypot(g.translation.width, g.translation.height) <= 6 { tapped(at: g.startLocation, camera) }
                        })
                Button { model.show(.home) } label: { Image(systemName: "house").font(.system(size: 15)).frame(width: 30, height: 30) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Home view")
                    // Where the desktop has it: the cube area's top left corner.
                    .position(x: 15, y: 15)
                // Turning a quarter only makes sense looking straight along an axis (Front, Right, Top…), so the arrows show only there.
                if Self.looksAlongAxis(camera) {
                // The desktop's curved arrows on a ring round the cube's top right: counter-clockwise on top, clockwise down its right side.
                Button { state.turn?(1) } label: { PadTurnArrow(counterClockwise: true).padding(10) }
                    .buttonStyle(.plain).accessibilityLabel("Turn the view a quarter counter-clockwise")
                    .position(x: center.x + 22, y: center.y - 61)
                Button { state.turn?(-1) } label: { PadTurnArrow(counterClockwise: false).padding(10) }
                    .buttonStyle(.plain).accessibilityLabel("Turn the view a quarter clockwise")
                    .position(x: center.x + 60, y: center.y - 35)
                }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .accessibilityLabel("View cube")
    }

    /// Whether the view looks straight along one of the three axes (a flat view).
    private static func looksAlongAxis(_ camera: Camera) -> Bool {
        let f = camera.forward
        return [abs(f.x), abs(f.y), abs(f.z)].filter { $0 > 0.999 }.count == 1
    }

    private func draw(_ ctx: inout GraphicsContext, _ camera: Camera) {
        let forward = camera.forward
        for face in Self.faces {
            let n = f(face.normal), r = f(face.right), u = f(face.up)
            guard simd_dot(n, forward) < -0.01 else { continue }
            let corners = [n - r + u, n + r + u, n + r - u, n - r - u].map { point($0, camera) }
            var path = Path(); path.addLines(corners); path.closeSubpath()
            let lit = flash.map { $0 == face.normal } ?? false
            ctx.fill(path, with: .color(lit ? accent.opacity(0.55) : Color(white: 0.5, opacity: 0.22 + 0.2 * Double(-simd_dot(n, forward)))))
            ctx.stroke(path, with: .color(.secondary), lineWidth: 1)
            let facing = Double(-simd_dot(n, forward))
            if facing > 0.4 {
                ctx.draw(Text(face.name).font(.system(size: 9, weight: .semibold)).foregroundStyle(.primary), at: point(n, camera))
            }
        }
    }

    /// What a tap on the cube chose: a face, an edge or a corner, as the direction to look from.
    private func tapped(at p: CGPoint, _ camera: Camera) {
        let forward = camera.forward
        for face in Self.faces where simd_dot(f(face.normal), forward) < -0.01 {
            let n = f(face.normal), r = f(face.right), u = f(face.up)
            let c = point(n, camera), pr = point(n + r, camera), pu = point(n + u, camera)
            // The tap in the face's own (right, up) coordinates.
            let ex = CGVector(dx: pr.x - c.x, dy: pr.y - c.y), ey = CGVector(dx: pu.x - c.x, dy: pu.y - c.y)
            let det = ex.dx * ey.dy - ex.dy * ey.dx
            guard abs(det) > 1e-6 else { continue }
            let d = CGVector(dx: p.x - c.x, dy: p.y - c.y)
            let a = (d.dx * ey.dy - d.dy * ey.dx) / det, b = (ex.dx * d.dy - ex.dy * d.dx) / det
            guard abs(a) <= 1, abs(b) <= 1 else { continue }
            var direction = face.normal
            if abs(a) > band { direction &+= face.right &* Int32(a > 0 ? 1 : -1) }
            if abs(b) > band { direction &+= face.up &* Int32(b > 0 ? 1 : -1) }
            flash = direction
            Task { @MainActor in try? await Task.sleep(for: .milliseconds(250)); flash = nil }
            state.lookAlong?(simd_normalize(f(direction)))
            return
        }
    }
}

/// A turn arrow as on the desktop cube: the designer's outline (35×20 pointing left, 20×35 pointing down) scaled by 0.9, filled and outlined like a cube face.
struct PadTurnArrow: View {
    let counterClockwise: Bool
    @Environment(\.colorScheme) private var scheme
    private static let k: CGFloat = 0.9

    static func size(_ counterClockwise: Bool) -> CGSize {
        counterClockwise ? CGSize(width: 35 * k, height: 20 * k) : CGSize(width: 20 * k, height: 35 * k)
    }

    private var outline: Path {
        let k = Self.k
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: y * k) }
        var path = Path()
        if counterClockwise {
            path.move(to: p(9.35358, 5.06644))
            path.addCurve(to: p(33.6353, 12.905), control1: p(18.8143, 5.29578), control2: p(27.5061, 8.14745))
            path.addCurve(to: p(33.774, 14.2995), control1: p(34.0716, 13.2436), control2: p(34.1275, 13.8752))
            path.addLine(to: p(29.9332, 18.9085))
            path.addCurve(to: p(28.5101, 19.0558), control1: p(29.5797, 19.3328), control2: p(28.9508, 19.3887))
            path.addCurve(to: p(9.35358, 13.0684), control1: p(23.9932, 15.6441), control2: p(17.1978, 13.2916))
            path.addLine(to: p(9.35358, 18.6035))
            path.addLine(to: p(0.353577, 9.60355))
            path.addLine(to: p(9.35358, 0.603546))
        } else {
            path.move(to: p(14.6148, 24.8312))
            path.addCurve(to: p(6.57961, 0.613773), control1: p(14.3088, 15.3726), control2: p(11.3867, 6.70421))
            path.addCurve(to: p(5.18402, 0.486473), control1: p(6.23744, 0.180258), control2: p(5.60542, 0.129489))
            path.addLine(to: p(0.606275, 4.36447))
            path.addCurve(to: p(0.470559, 5.78877), control1: p(0.184871, 4.72147), control2: p(0.134124, 5.35078))
            path.addCurve(to: p(6.61315, 24.8961), control1: p(3.91875, 10.2778), control2: p(6.32632, 17.0539))
            path.addLine(to: p(1.07817, 24.941))
            path.addLine(to: p(10.1509, 33.8677))
            path.addLine(to: p(19.0776, 24.795))
        }
        path.closeSubpath()
        return path
    }

    var body: some View {
        let dark = scheme == .dark
        outline.fill(Color(white: dark ? 0.4 : 0.89))
            .overlay(outline.stroke(Color(white: dark ? 0.6 : 0.63), lineWidth: 0.75))
            .frame(width: Self.size(counterClockwise).width, height: Self.size(counterClockwise).height)
    }
}
