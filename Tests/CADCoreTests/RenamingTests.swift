// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CADCore

/// Renaming a parameter rewrites every expression that uses it, and nothing else.
@Suite struct RenamingTests {
    @Test func onlyWholeNamesChange() {
        #expect(Expressions.renaming("p1*2 + p10 - p1", "p1", to: "width") == "width*2 + p10 - width")
        #expect(Expressions.renaming("2e3 + e", "e", to: "k") == "2e3 + k", "a number's exponent isn't a name")
        #expect(Expressions.renaming("max(p1, 3 mm)", "p1", to: "w") == "max(w, 3 mm)")
    }

    @Test func everyUseFollowsTheNewName() throws {
        var s = Sketch()
        let a = s.addPoint(0, 0), b = s.addPoint(10, 0)
        let line = s.addLine(a, b)
        s.dimension(.length(line), "p1 * 2")
        s.texts = [SketchText(text: "Hi", position: a, height: "p1")]
        var d = CADDocument(parameters: [Parameter("p1", "5 mm"), Parameter("p2", "p1 + 1 mm")])
        d.features = [
            Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s))),
            Feature(id: "f", name: "Fillet1", .fillet(EdgeFeature(edges: [], size: "p1"))),
            Feature(id: "b", name: "p1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, height: "p1 + p2"))),
        ]
        #expect(d.features(using: "p1").map(\.id) == ["sk", "f", "b"])
        try d.renameParameter("p1", to: "wall")
        #expect(d.parameters.map(\.name) == ["wall", "p2"] && d.parameters[1].expression == "wall + 1 mm")
        guard case .sketch(let sf) = d.features[0].kind, case .fillet(let ef) = d.features[1].kind,
              case .primitive(let pf) = d.features[2].kind else { Issue.record("kinds changed"); return }
        #expect(sf.sketch.dimensions[0].expression == "wall * 2" && sf.sketch.texts[0].height == "wall")
        #expect(ef.size == "wall" && pf.height == "wall + p2")
        #expect(d.features[2].name == "p1", "a feature's own name is not an expression")
        #expect(ParameterEvaluator.evaluate(d.parameters).values["p2"]?.value == 6)
    }

    @Test func badNamesAreRefused() {
        var d = CADDocument(parameters: [Parameter("p1", "5 mm"), Parameter("p2", "1 mm")])
        #expect(throws: RenameError.self) { try d.renameParameter("p1", to: "p2") }
        #expect(throws: RenameError.self) { try d.renameParameter("p1", to: "mm") }
        #expect(throws: RenameError.self) { try d.renameParameter("p1", to: "2wide") }
        #expect(d.parameters[0].name == "p1")
    }
}
