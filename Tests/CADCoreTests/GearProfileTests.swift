// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CADCore

/// Spur gear outlines: closed loops of arcs, lines and Béziers on the involute.
@Suite struct GearProfileTests {
    private let specs = [
        GearSpec(teeth: 8, module: 2), GearSpec(teeth: 12, module: 1.5), GearSpec(teeth: 17, module: 1),
        GearSpec(teeth: 20, module: 2), GearSpec(teeth: 40, module: 1, backlash: 0.1), GearSpec(teeth: 100, module: 0.5),
    ]

    @Test func theOutlineIsAClosedLoop() throws {
        for spec in specs {
            let pieces = try GearProfile.outline(spec)
            for (i, p) in pieces.enumerated() {
                let next = pieces[(i + 1) % pieces.count]
                #expect(vlen(p.end - next.start) < 1e-9, "\(spec.teeth) teeth, piece \(i)")
            }
        }
    }

    @Test func tipsAndRootsSitOnTheirCircles() throws {
        let spec = GearSpec(teeth: 20, module: 2)
        let pieces = try GearProfile.outline(spec)
        var arcs = 0
        for case .arc(let a, let b) in pieces {
            arcs += 1
            let r = vlen(a)
            #expect(abs(r - vlen(b)) < 1e-9)
            #expect(abs(r - spec.tipRadius) < 1e-9 || abs(r - spec.rootRadius) < 1e-9)
        }
        #expect(arcs == 40)  // a tip and a root per tooth
    }

    @Test func theFittedFlanksStayCloseToTheTrueInvolute() throws {
        for spec in specs {
            let e = try GearProfile.flankError(spec)
            #expect(e < GearProfile.flankTolerance * 1.5, "\(spec.teeth) teeth: \(e) mm")
        }
    }

    @Test func smallGearsStartTheFlankWithARadialLineToTheRoot() throws {
        // At 20°, 12 teeth: the root circle (1.25 m below pitch) is inside the base circle.
        let spec = GearSpec(teeth: 12, module: 1.5)
        #expect(spec.rootRadius < spec.baseRadius)
        let lines = try GearProfile.outline(spec).filter { if case .line = $0 { return true } else { return false } }
        #expect(lines.count == 24)
        // A big gear has none, and a 40-tooth one only just misses (its root is moved up to the base circle).
        let big = try GearProfile.outline(GearSpec(teeth: 60, module: 1)).filter { if case .line = $0 { return true } else { return false } }
        #expect(big.isEmpty)
        let nearly = try GearProfile.outline(GearSpec(teeth: 40, module: 1)).filter { if case .line = $0 { return true } else { return false } }
        #expect(nearly.isEmpty)
    }

    @Test func backlashThinsTheTeeth() throws {
        // The tip arc spans the tooth's angle at the tip: less with backlash.
        func tipSpan(_ s: GearSpec) throws -> Double {
            for case .arc(let a, let b) in try GearProfile.outline(s) where abs(vlen(a) - s.tipRadius) < 1e-9 {
                return atan2(b.y, b.x) - atan2(a.y, a.x)
            }
            return 0
        }
        let plain = try tipSpan(GearSpec(teeth: 20, module: 2))
        let loose = try tipSpan(GearSpec(teeth: 20, module: 2, backlash: 0.2))
        #expect(loose < plain)
    }

    private let none = ParameterValues()

    private func generated(_ s: Sketch) -> (points: [SketchPoint], curves: [SketchCurve]) {
        (s.points.filter { Sketch.isGenerated($0.id) }, s.curves.filter { Sketch.isGenerated($0.id) })
    }

    @Test func aGearIsGeneratedFromItsDefinitionAroundItsCentre() throws {
        var s = Sketch()
        let centre = s.addPoint(10, 5)
        let def = try s.addGear(SketchGearDef(center: centre, teeth: "20", module: "2 mm", bore: "8 mm"))
        #expect(s.gears == [def])
        let g = generated(s)
        #expect(g.points.allSatisfy { $0.fixed }, "no free points: nothing for the solver to move or the user to trip over")
        #expect(g.points.allSatisfy { $0.id.hasPrefix(def.id + "~") })
        #expect(g.curves.filter { if case .circle = $0.geometry { return true } else { return false } }.count == 1)
        // The outline's ends sit on the right circles about the centre.
        let tips = g.curves.compactMap { c -> Double? in
            guard case .arc(let m, let a, _) = c.geometry, m == centre, let p = s.point(a) else { return nil }
            return vlen(p.position - SIMD2(10, 5))
        }
        #expect(tips.count == 40 && tips.allSatisfy { abs($0 - 22) < 1e-9 || abs($0 - 17.5) < 1e-9 })
        // Every curve end refers to a real point.
        for c in g.curves {
            switch c.geometry {
            case .line(let a, let b), .arc(_, let a, let b), .bezier(let a, _, _, let b): #expect(s.point(a) != nil && s.point(b) != nil)
            case .circle, .ellipse: break
            }
        }
    }

    @Test func refreshingMakesTheSameOutlineAgainAndFollowsChanges() throws {
        var s = Sketch()
        let centre = s.addPoint(0, 0)
        try s.addGear(SketchGearDef(id: "g", center: centre, teeth: "20", module: "2 mm"))
        let before = generated(s)
        #expect(s.refreshGenerated(none).isEmpty)
        #expect(generated(s).points == before.points && generated(s).curves == before.curves, "same ids, same places")
        s.gears[0].teeth = "12"
        s.refreshGenerated(none)
        #expect(generated(s).curves.count < before.curves.count)
        s.points[s.points.firstIndex { $0.id == centre }!].x = 30  // the centre is dragged
        s.refreshGenerated(none)
        let xs = generated(s).points.map(\.position.x)
        let right = xs.max() ?? 0
        #expect(right > 30 + 13.5 && right < 30 + 14 + 1e-9, "the outline went with it (tip radius 14)")
    }

    @Test func expressionsAndParametersDriveTheGear() throws {
        var s = Sketch()
        let centre = s.addPoint(0, 0)
        try s.addGear(SketchGearDef(id: "g", center: centre, teeth: "n", module: "mod + 0.5 mm"),
                      ParameterEvaluator.evaluate([Parameter("n", "16", unit: .none), Parameter("mod", "1 mm")]))
        let teethFor = { (p: ParameterValues) -> GearSpec? in try? s.gears[0].spec(p) }
        #expect(teethFor(ParameterEvaluator.evaluate([Parameter("n", "24", unit: .none), Parameter("mod", "2 mm")])) == GearSpec(teeth: 24, module: 2.5))
        let params = ParameterEvaluator.evaluate([Parameter("n", "10", unit: .none), Parameter("mod", "1 mm")])
        s.refreshGenerated(params)
        #expect(generated(s).curves.filter { if case .arc = $0.geometry { return true } else { return false } }.count == 20)
    }

    @Test func aGearThatCantBeMadeMakesNothingAndSaysWhy() throws {
        var s = Sketch()
        let centre = s.addPoint(0, 0)
        #expect(throws: GearError.self) { try s.addGear(SketchGearDef(center: centre, teeth: "12.5")) }
        #expect(s.gears.isEmpty && generated(s).curves.isEmpty)
        try s.addGear(SketchGearDef(id: "g", center: centre))
        s.gears[0].bore = "90 mm"
        let problems = s.refreshGenerated(none)
        #expect(problems["g"]?.contains("hole") == true && generated(s).curves.isEmpty)
    }

    @Test func removingAGearTakesItsOutlineAndItsOwnCentre() throws {
        var s = Sketch()
        let centre = s.addPoint(5, 5)
        try s.addGear(SketchGearDef(id: "g", center: centre, ownsCenter: true))
        s.removeGear("g")
        #expect(s.gears.isEmpty && generated(s).curves.isEmpty && s.point(centre) == nil)
        // A centre that was there first stays.
        let mine = s.addPoint(1, 1)
        try s.addGear(SketchGearDef(id: "h", center: mine))
        s.removeGear("h")
        #expect(s.point(mine) != nil)
    }

    @Test func aGearWhoseCentreIsGoneIsDropped() throws {
        var s = Sketch()
        let centre = s.addPoint(5, 5)
        try s.addGear(SketchGearDef(id: "g", center: centre))
        s.points.removeAll { $0.id == centre }
        s.refreshGenerated(none)
        #expect(s.gears.isEmpty && generated(s).curves.isEmpty)
    }

    /// Chaining a gear's 160 curves into a closed shape took 0.3 s on every mouse move of every drawing tool.
    @Test func shapeCentersLeaveGeneratedCurvesOut() throws {
        var s = Sketch()
        try s.addGear(SketchGearDef(center: s.addPoint(0, 0), teeth: "40"))
        #expect(s.shapeCenters().isEmpty)
        let (_, corners) = s.addRectangle(100, 0, 110, 10)
        #expect(s.shapeCenters().count == 1 && corners.count == 4, "ordinary shapes still have theirs")
    }

    @Test func theSolverLeavesTheGearAlone() throws {
        var s = Sketch()
        let centre = s.addPoint(3, 4)
        try s.addGear(SketchGearDef(id: "g", center: centre))
        let before = generated(s)
        #expect(SketchSolver.solve(&s, dimensionValues: [:]).status == .solved)
        #expect(generated(s).points == before.points)
    }

    @Test func aSavedGearComesBack() throws {
        var s = Sketch()
        let centre = s.addPoint(0, 0)
        try s.addGear(SketchGearDef(id: "g", center: centre, ownsCenter: true, teeth: "18", module: "2 mm", pressureAngle: "25 deg", backlash: "0.1 mm", bore: "5 mm"))
        // Only the definition is stored in a file's worth of data; the outline is made again on load.
        var stored = s
        _ = stored.takeGenerated()
        let back = try JSONDecoder().decode(Sketch.self, from: JSONEncoder().encode(stored))
        #expect(back.gears == s.gears)
        var loaded = back
        loaded.refreshGenerated(none)
        #expect(generated(loaded).points == generated(s).points)
        let old = try JSONDecoder().decode(Sketch.self, from: JSONEncoder().encode(Sketch()))
        #expect(old.gears.isEmpty, "files from before gears")
    }

    @Test func badSpecsAreRefused() {
        #expect(throws: GearError.self) { try GearProfile.outline(GearSpec(teeth: 3, module: 1)) }
        #expect(throws: GearError.self) { try GearProfile.outline(GearSpec(teeth: 20, module: 0)) }
        #expect(throws: GearError.self) { try GearProfile.outline(GearSpec(teeth: 20, module: 2, boreDiameter: 40)) }
        #expect(throws: GearError.self) { try GearProfile.outline(GearSpec(teeth: 20, module: 2, backlash: 3)) }
    }
}
