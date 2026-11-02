// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import Testing
@testable import CADKernel

/// A shell that can't be built says why.
@Suite struct ShellReasonTests {
    private func document(rounded: Bool = false, thickness: String) -> CADDocument {
        var d = CADDocument()
        d.features = [Feature(id: "b", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "20 mm", length: "20 mm", height: "20 mm")))]
        if rounded {
            d.features.append(Feature(id: "f", name: "Fillet1", .fillet(EdgeFeature(edges: [], faces: [FaceRef(body: "b", face: "b.top")], size: "1 mm"))))
        }
        d.features.append(Feature(id: "s", name: "Shell1", .shell(ShellFeature(body: "b", faces: [FaceRef(body: "b", face: "b.bottom")], thickness: thickness))))
        return d
    }

    @Test func aPlainBoxShellsAndKeepsItsInputForTheHandle() throws {
        let r = Regenerator.regenerate(document(thickness: "2 mm"))
        #expect(r.errors.isEmpty, "\(r.errors)")
        #expect(r.featureInputs["s"]?["b"] != nil)
        let volume = try #require(r.body("b")).volume
        #expect(abs(volume - (8000 - 16 * 16 * 18)) < 1e-3, "\(volume)")
    }

    @Test func aWallThatDoesntFitSaysSo() {
        let r = Regenerator.regenerate(document(thickness: "11 mm"))
        let message = r.errors["s"] ?? ""
        #expect(message.contains("at most 10 mm"), "\(message)")
        #expect(message.contains("11 mm"))
    }

    @Test func zeroThicknessSaysSo() {
        let r = Regenerator.regenerate(document(thickness: "0 mm"))
        #expect(r.errors["s"]?.contains("more than zero") == true, "\(r.errors)")
    }

    @Test func aMissingBodyAsksToPickAgain() {
        var d = document(thickness: "2 mm")
        d.features.removeFirst()
        let r = Regenerator.regenerate(d)
        #expect(r.errors["s"]?.contains("Pick the faces") == true, "\(r.errors)")
    }

    @Test func aTightRoundedEdgeIsNamedWhenTheShellFails() {
        // 1 mm fillets under 2 mm walls: if the kernel can't do it, the reason names the fillet.
        let r = Regenerator.regenerate(document(rounded: true, thickness: "2 mm"))
        if let message = r.errors["s"] {
            #expect(message.contains("Fillet1") && message.contains("1 mm"), "\(message)")
        }
    }

    @Test func noFailureIsLeftWithoutAMessage() {
        for t in ["0.3 mm", "1 mm", "2 mm", "5 mm", "9.9 mm"] {
            for rounded in [false, true] {
                let r = Regenerator.regenerate(document(rounded: rounded, thickness: t))
                if let message = r.errors["s"] { #expect(message.count > 20 && message != "kernel: ", "\(t) \(rounded): \(message)") }
            }
        }
    }
}
