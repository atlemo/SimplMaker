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

    static let size = CGSize(width: 136, height: 132)
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

    private var center: CGPoint { CGPoint(x: Self.size.width / 2 + 4, y: Self.size.height / 2 - 6) }

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
                    .position(x: 16, y: Self.size.height - 14)
                HStack(spacing: 4) {
                    Button { state.turn?(1) } label: { Image(systemName: "arrow.counterclockwise").frame(width: 28, height: 28) }
                    Button { state.turn?(-1) } label: { Image(systemName: "arrow.clockwise").frame(width: 28, height: 28) }
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 14))
                .position(x: Self.size.width - 36, y: 14)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .accessibilityLabel("View cube")
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
