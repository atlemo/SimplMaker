// The iPad app's first screen: a part rebuilt by the real kernel, drawn by the shared Metal renderer.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import SwiftUI

struct PadRootView: View {
    @State private var scene = PadScene()

    var body: some View {
        ZStack(alignment: .topLeading) {
            PadViewport(scene: scene).ignoresSafeArea()
            Text(scene.status)
                .font(.system(.footnote, design: .monospaced))
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding()
                .accessibilityIdentifier("status")
        }
        .task { await scene.load() }
    }
}
