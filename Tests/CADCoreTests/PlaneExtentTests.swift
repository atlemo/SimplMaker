// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CADCore

@Suite struct PlaneExtentTests {
    @Test func aDraggedSizeIsSavedAndNeedsNoRebuild() throws {
        var doc = CADDocument.demo()
        doc.features.append(Feature(id: "p1", name: "Plane1", .plane(PlaneFeature(base: .xy))))
        let before = doc.ignoringPresentation

        doc.features[doc.features.count - 1].kind = .plane(PlaneFeature(base: .xy, extent: PlaneExtent(uMin: -5, uMax: 40, vMin: -10, vMax: 12)))
        #expect(doc.ignoringPresentation == before, "the size a plane is drawn at is presentation only")

        let back = try CADDocument.decode(try doc.encoded())
        guard case .plane(let f)? = back.features.last?.kind else { Issue.record("plane lost"); return }
        #expect(f.extent == PlaneExtent(uMin: -5, uMax: 40, vMin: -10, vMax: 12))
    }

    @Test func aPlaneSavedBeforeSizesExistedOpensWithNone() throws {
        let now = try JSONEncoder().encode(PlaneFeature(base: .xy, extent: PlaneExtent(side: 20)))
        var json = try #require(try JSONSerialization.jsonObject(with: now) as? [String: Any])
        #expect(json.removeValue(forKey: "extent") != nil)
        let old = try JSONSerialization.data(withJSONObject: json)
        #expect(try JSONDecoder().decode(PlaneFeature.self, from: old).extent == nil)
    }
}
