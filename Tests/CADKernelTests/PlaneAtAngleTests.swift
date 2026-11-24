// A construction plane turned by an angle about an axis or an edge.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import simd
import Testing
@testable import CADKernel

@Suite struct PlaneAtAngleTests {
    typealias T = NewFeatureTests

    static func frame(_ features: [Feature], parameters: [Parameter] = []) throws -> Frame {
        var doc = CADDocument()
        doc.features = features
        doc.parameters = parameters
        let r = Regenerator.regenerate(doc)
        #expect(r.errors.isEmpty, "\(r.errors)")
        return try #require(r.planes["pa"])
    }

    static func plane(_ base: PlaneRef = .xy, angle: String, _ turn: PlaneTurn, offset: String = "0 mm") -> Feature {
        Feature(id: "pa", name: "pa", .plane(PlaneFeature(base: base, turnedBy: angle, about: turn, offset: offset)))
    }

    static func near(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ tol: Double = 1e-9) -> Bool { simd_length(a - b) < tol }

    @Test func theFloorTurnedAboutTheXAxisLeansTowardsY() throws {
        let f = try Self.frame([Self.plane(angle: "30 deg", PlaneTurn(axis: .x))])
        let s = 0.5, c = 3.0.squareRoot() / 2
        // The normal (0, 0, 1) turns about +X by 30°: (0, -sin, cos).
        #expect(Self.near(f.normal, SIMD3(0, -s, c)), "\(f.normal)")
        #expect(Self.near(f.origin, .zero))
        #expect(abs(simd_dot(f.xAxis, f.normal)) < 1e-12, "x stays in the plane")
    }

    @Test func theAxisCanBeAnEdgeAwayFromTheOrigin() throws {
        // A 40 × 20 × 10 box on the floor: turn the floor about the box's top front edge (y = 0, z = 10, along X) by 90°.
        let box = T.box("bx", "40 mm", "20 mm", "10 mm")
        var doc = CADDocument()
        doc.features = [box]
        let built = Regenerator.regenerate(doc)
        let body = try #require(built.body("bx"))
        // Find a straight edge along X at the top: its line has direction ±X and z = 10.
        var edgeName: String?
        for name in body.edgeNames {
            guard let l = try? body.edgeLine(name) else { continue }
            if abs(abs(l.direction.x) - 1) < 1e-9, abs(l.origin.z - 10) < 1e-6, l.origin.y < 1 { edgeName = name; break }
        }
        let edge = try #require(edgeName)
        let f = try Self.frame([box, Self.plane(angle: "90 deg", PlaneTurn(axis: .edge(EdgeRef(body: "bx", edge: edge))))])
        // The floor (z = 0) swung 90° about the edge at z = 10: now a wall through y = 0 ± 10 (above or below, by the edge's direction).
        #expect(abs(f.normal.z) < 1e-9 && abs(abs(f.normal.y) - 1) < 1e-9, "\(f.normal)")
        #expect(abs(abs(f.origin.y) - 10) < 1e-6 || abs(abs(f.origin.z - 10) - 10) < 1e-6, "\(f.origin)")
    }

    @Test func directionOnlyProjectsTheAxisOntoTheBaseAndPivotsAboutTheBaseOrigin() throws {
        // The X axis lifted onto a plane 20 mm up: the axis' own line (through the origin) would swing the plane's origin round it,
        // but with the direction alone the plane pivots about a point of the base (its origin), so it stays at z = 20.
        let up = Feature(id: "up", name: "up", .plane(PlaneFeature(base: .xy, offset: "20 mm")))
        let whole = try Self.frame([up, Self.plane(.plane("up"), angle: "90 deg", PlaneTurn(axis: .x))])
        #expect(abs(whole.origin.y + 20) < 1e-9 && abs(whole.origin.z) < 1e-9, "turned about the real X axis: \(whole.origin)")
        let only = try Self.frame([up, Self.plane(.plane("up"), angle: "90 deg", PlaneTurn(axis: .x, directionOnly: true))])
        #expect(Self.near(only.origin, SIMD3(0, 0, 20)), "pivots about the base origin: \(only.origin)")
        #expect(abs(abs(only.normal.y) - 1) < 1e-9, "\(only.normal)")
    }

    @Test func aPivotPointOnTheBaseMovesTheTurn() throws {
        // Pivot at (u, v) = (0, 10) on the floor, about the X direction: the plane's origin (0, 0) swings round that point.
        let f = try Self.frame([Self.plane(angle: "90 deg", PlaneTurn(axis: .x, directionOnly: true, pivotU: "0 mm", pivotV: "10 mm"))])
        #expect(Self.near(f.origin, SIMD3(0, 10, -10)) || Self.near(f.origin, SIMD3(0, 10, 10)), "\(f.origin)")
        #expect(abs(abs(f.normal.y) - 1) < 1e-9)
    }

    @Test func anAxisSquareToTheBaseHasNoDirectionAlongItWhenOnlyTheDirectionCounts() throws {
        var doc = CADDocument()
        doc.features = [Self.plane(angle: "20 deg", PlaneTurn(axis: .z, directionOnly: true))]
        let r = Regenerator.regenerate(doc)
        #expect(r.errors["pa"]?.contains("square to the base") == true, "\(r.errors)")
        // Without that option the same turn is fine: a spin about its own normal.
        doc.features = [Self.plane(angle: "20 deg", PlaneTurn(axis: .z))]
        #expect(Regenerator.regenerate(doc).errors.isEmpty)
    }

    @Test func angleOffsetAndPivotFollowParameters() throws {
        let f = try Self.frame([Self.plane(angle: "tilt", PlaneTurn(axis: .y, directionOnly: true, pivotU: "px", pivotV: "0 mm"), offset: "lift")],
                               parameters: [Parameter("tilt", "90 deg", unit: .angle), Parameter("px", "5 mm"), Parameter("lift", "3 mm")])
        // The floor tipped up 90° about the Y direction through x = 5 (its origin swings to (5, 0, 5)), then 3 mm along its new normal, +X.
        #expect(Self.near(f.origin, SIMD3(8, 0, 5)), "\(f.origin)")
        #expect(abs(abs(f.normal.x) - 1) < 1e-9, "\(f.normal)")
    }

    @Test func oldAndNewFilesBothDecode() throws {
        let old = #"{"base":{"xy":{}},"offset":"10 mm","angle":"0 deg","axis":"Horizontal"}"#
        #expect(try JSONDecoder().decode(PlaneFeature.self, from: Data(old.utf8)).turn == nil)
        let mine = PlaneFeature(base: .xz, turnedBy: "30 deg", about: PlaneTurn(axis: .y, directionOnly: true, pivotU: "1 mm", pivotV: "2 mm"))
        #expect(try JSONDecoder().decode(PlaneFeature.self, from: JSONEncoder().encode(mine)) == mine)
    }

    @Test func aSketchOnTheTurnedPlaneWorks() throws {
        // A sloped sketch for an angled bracket: a plate on a plane tipped 45° about the X axis, extruded.
        let plate = T.sketch("sk", on: .plane("pa")) { s in T.rect(&s, 0, 0, 20, 10, ids: ["A", "B", "C", "D"]) }
        let ex = Feature(id: "ex", name: "ex", .extrude(ExtrudeFeature(sketch: "sk", profiles: [ProfileRef(curves: ["A", "B", "C", "D"])],
                                                                     extent: .distance("3 mm"))))
        let r = try T.regen([Self.plane(angle: "45 deg", PlaneTurn(axis: .x)), plate, ex])
        let body = try #require(r.body("ex"))
        #expect(body.isValid && T.close(body.volume, 20 * 10 * 3, 1e-6), "\(body.volume)")
    }
}
