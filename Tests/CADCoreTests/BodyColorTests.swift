// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CADCore

@Suite struct BodyColorTests {
    @Test func hexRoundTrips() throws {
        let c = try #require(BodyColor(hex: "#3a78D0"))
        #expect(c.red == 0x3A && c.green == 0x78 && c.blue == 0xD0)
        #expect(c.hex == "#3A78D0")
        #expect(BodyColor(hex: "0A0B0C")?.hex == "#0A0B0C", "the # is optional, and small values keep two digits")
        for bad in ["", "#12345", "#1234567", "#GG0000", "+12345"] {
            #expect(BodyColor(hex: bad) == nil, "\(bad) isn't a colour")
        }
        let clamped = BodyColor(red: 1.5, green: -1, blue: 0.5)
        #expect(clamped.hex == "#FF0080")
    }

    @Test func colorsAreSavedAndNeedNoRebuild() throws {
        var doc = CADDocument.demo()
        let before = doc.ignoringPresentation
        doc.bodyColors["plate"] = BodyColor(hex: "#C07A4F")
        #expect(doc.ignoringPresentation == before, "a colour is presentation only")

        let data = try doc.encoded()
        #expect(String(decoding: data, as: UTF8.self).contains("\"#C07A4F\""), "saved as readable hex")
        let back = try CADDocument.decode(data)
        #expect(back.bodyColors == ["plate": BodyColor(hex: "#C07A4F")!])

        // Files from before colours existed still open, with none.
        let plain = try CADDocument.decode(try CADDocument.demo().encoded())
        #expect(plain.bodyColors.isEmpty)
        #expect(!String(decoding: try CADDocument.demo().encoded(), as: UTF8.self).contains("bodyColors"))
    }
}
