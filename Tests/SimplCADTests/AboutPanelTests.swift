// SPDX-License-Identifier: GPL-3.0-or-later
import CADKernel
import Testing
@testable import SimplCAD

/// The About panel's credits: hard-wrapped licence texts reflow to fit its narrow text view.
@Suite @MainActor struct AboutPanelTests {
    @Test func reflowJoinsWrappedLinesAndKeepsParagraphsAndItems() {
        let text = """
            Copyright (c) 1993 The Regents.
            All rights reserved.

              Redistribution and use are
              permitted provided that:

            1. Redistributions of source code
            must retain the notice.
            2. Redistributions in binary form
            must reproduce it.
            """
        #expect(AboutPanel.reflowed(text) == """
            Copyright (c) 1993 The Regents. All rights reserved.
            Redistribution and use are permitted provided that:
            1. Redistributions of source code must retain the notice.
            2. Redistributions in binary form must reproduce it.
            """)
    }

    @Test func occtVersionComesFromTheKernel() {
        #expect(occtVersion.split(separator: ".").count >= 3)
    }
}
