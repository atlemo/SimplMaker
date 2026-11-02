// The pulsing ring the tutorial puts round what to use next: a toolbar button, the parameter list,
// the inspector. Views opt in with `tutorialSpot`; the ring shows while the step asks for that id.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

extension EnvironmentValues {
    /// The ids the tutorial is pointing at right now.
    @Entry var tutorialSpotlight: Set<String> = []
}

extension View {
    /// Rings this view while the tutorial points at `id`.
    func tutorialSpot(_ id: String, cornerRadius: CGFloat = DS.Radius.md, outset: CGFloat = 2, filled: Bool = true) -> some View {
        tutorialSpot(anyOf: [id], cornerRadius: cornerRadius, outset: outset, filled: filled)
    }

    /// Rings this view while the tutorial points at any of `ids`.
    /// `filled: false` draws the ring only, for something as big as a panel.
    func tutorialSpot(anyOf ids: [String], cornerRadius: CGFloat = DS.Radius.md, outset: CGFloat = 2, filled: Bool = true) -> some View {
        modifier(TutorialSpot(ids: ids, cornerRadius: cornerRadius, outset: outset, filled: filled))
    }
}

private struct TutorialSpot: ViewModifier {
    let ids: [String]
    let cornerRadius: CGFloat
    let outset: CGFloat
    let filled: Bool
    @Environment(\.tutorialSpotlight) private var spotlight

    func body(content: Content) -> some View {
        content.overlay {
            if ids.contains(where: spotlight.contains) {
                SpotRing(cornerRadius: cornerRadius, filled: filled)
                    .padding(-outset)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
        }
    }
}

/// An orange ring that breathes, white inside so it reads on the tinted toolbar of Sketch mode too.
private struct SpotRing: View {
    let cornerRadius: CGFloat
    let filled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lit = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(Color.orange.opacity(filled ? (lit ? 0.14 : 0.05) : 0))
            .overlay { shape.strokeBorder(Color.orange, lineWidth: 2.5) }
            .overlay { shape.strokeBorder(Color.white.opacity(0.85), lineWidth: 1).padding(2.5) }
            .shadow(color: Color.orange.opacity(lit ? 0.85 : 0.3), radius: lit ? 7 : 2)
            .onAppear {
                if reduceMotion { lit = true; return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { lit = true }
            }
    }
}
