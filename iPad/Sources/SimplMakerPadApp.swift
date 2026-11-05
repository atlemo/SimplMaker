// The iPad app's entry point (first launch spike: build a part and draw it).
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

@main
struct SimplMakerPadApp: App {
    var body: some Scene {
        WindowGroup { PadRootView() }
    }
}
