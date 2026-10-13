// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation
import Testing
@testable import CADCore

/// Mirror images of sketch geometry across a line, an axis or a projected edge.
@Suite struct SketchMirrorTests {
    private let none = ParameterValues()

    /// A triangle to the right of the y axis, and a vertical drawn line at x = 0 ("mirror").
    private func sample() -> (Sketch, tri: [EntityID], mirror: EntityID) {
        var s = Sketch()
        let a = s.addPoint(10, 0), b = s.addPoint(20, 0), c = s.addPoint(10, 5)
        let tri = [s.addLine(a, b), s.addLine(b, c), s.addLine(c, a)]
        let m0 = s.addPoint(0, -10), m1 = s.addPoint(0, 10)
        let mirror = s.addLine(m0, m1)
        return (s, tri, mirror)
    }

    private func images(_ s: Sketch) -> [SketchPoint] { s.points.filter { Sketch.isGenerated($0.id) } }

    @Test func mirrorsAcrossADrawnLineAndKeepsTheOriginal() throws {
        var (s, tri, mirror) = sample()
        s.mirrors = [SketchMirrorDef(id: "m", sources: tri, line: mirror)]
        #expect(s.refreshGenerated(none).isEmpty)
        let made = images(s)
        #expect(made.count == 3 && made.allSatisfy(\.fixed), "fixed points the solver leaves alone")
        #expect(s.curves.filter { Sketch.isGenerated($0.id) }.count == 3)
        #expect(made.contains { vlen($0.position - SIMD2(-20, 0)) < 1e-9 })
        #expect(made.contains { vlen($0.position - SIMD2(-10, 5)) < 1e-9 })
        #expect(s.points.contains { vlen($0.position - SIMD2(20, 0)) < 1e-9 }, "the original stays")
    }

    @Test func mirrorsAcrossATiltedLine() throws {
        var s = Sketch()
        let p = s.addPoint(4, 0)
        let l0 = s.addPoint(0, 0), l1 = s.addPoint(10, 10)
        let diagonal = s.addLine(l0, l1)
        let dot = s.addPoint(4, 0)
        _ = p
        s.mirrors = [SketchMirrorDef(id: "m", sources: [dot], line: diagonal)]
        s.refreshGenerated(none)
        #expect(images(s).contains { vlen($0.position - SIMD2(0, 4)) < 1e-9 }, "(4, 0) across y = x lands on (0, 4)")
    }

    @Test func theAxesWorkAsLines() throws {
        var (s, tri, _) = sample()
        s.mirrors = [SketchMirrorDef(id: "x", sources: tri, line: SketchMirrorDef.xAxis)]
        s.refreshGenerated(none)
        #expect(images(s).contains { vlen($0.position - SIMD2(10, -5)) < 1e-9 }, "across the x axis, y flips")
        s.mirrors = [SketchMirrorDef(id: "y", sources: tri, line: SketchMirrorDef.yAxis)]
        s.refreshGenerated(none)
        #expect(images(s).contains { vlen($0.position - SIMD2(-10, 5)) < 1e-9 } && images(s).count == 3, "the old images are replaced")
    }

    @Test func anArcKeepsRunningCounterClockwise() throws {
        var s = Sketch()
        let c = s.addPoint(10, 0), a = s.addPoint(15, 0), b = s.addPoint(10, 5)
        let arc = s.addArc(center: c, start: a, end: b)  // the quarter from east to north
        s.mirrors = [SketchMirrorDef(id: "m", sources: [arc], line: SketchMirrorDef.yAxis)]
        s.refreshGenerated(none)
        guard case .arc(let m, let start, let end)? = s.curve("m~\(arc)")?.geometry else { Issue.record("no mirrored arc"); return }
        #expect(s.position(m) == SIMD2(-10, 0))
        // Counter-clockwise from (-10, 5) (north) round to (-15, 0) (west): the ends swapped.
        #expect(s.position(start) == SIMD2(-10, 5) && s.position(end) == SIMD2(-15, 0))
    }

    @Test func imagesFollowTheOriginalsAndTheLine() throws {
        var (s, tri, mirror) = sample()
        s.mirrors = [SketchMirrorDef(id: "m", sources: tri, line: mirror)]
        s.refreshGenerated(none)
        let k = s.points.firstIndex { $0.position == SIMD2(20, 0) }!
        s.points[k].x = 30
        s.refreshGenerated(none)
        #expect(images(s).contains { vlen($0.position - SIMD2(-30, 0)) < 1e-9 }, "the image moved with its original")
        // Move the mirror line to x = 5: an image of x = 30 lands at -20.
        for i in s.points.indices where s.points[i].x == 0 && s.points[i].id != "origin" { s.points[i].x = 5 }
        s.refreshGenerated(none)
        #expect(images(s).contains { vlen($0.position - SIMD2(-20, 0)) < 1e-9 })
    }

    @Test func theLineItselfIsNotCopiedWhenTheWholeSketchIsMirrored() throws {
        var (s, tri, mirror) = sample()
        s.mirrors = [SketchMirrorDef(id: "m", sources: tri + [mirror], line: mirror)]
        s.refreshGenerated(none)
        #expect(s.curve("m~\(mirror)") == nil && s.curves.filter { Sketch.isGenerated($0.id) }.count == 3)
    }

    @Test func aMirrorWithoutALineMakesNothing() throws {
        var (s, tri, _) = sample()
        s.mirrors = [SketchMirrorDef(id: "m", sources: tri)]
        #expect(s.refreshGenerated(none).isEmpty && images(s).isEmpty)
        #expect(s.mirrors.count == 1, "kept: the line is still to be chosen")
    }

    @Test func deletingTheLineOrTheOriginalsRemovesTheMirror() throws {
        var (s, tri, mirror) = sample()
        s.mirrors = [SketchMirrorDef(id: "m", sources: tri, line: mirror)]
        var gone = s
        gone.delete([mirror])
        gone.refreshGenerated(none)
        #expect(gone.mirrors.isEmpty && images(gone).isEmpty && gone.curves.count == 3)
        s.delete(Set(tri))
        s.refreshGenerated(none)
        #expect(s.mirrors.isEmpty && images(s).isEmpty)
    }

    @Test func aDegenerateLineIsReportedNotUsed() throws {
        var s = Sketch()
        let p = s.addPoint(1, 1), q = s.addPoint(1, 1)
        let line = s.addLine(p, q)
        let dot = s.addPoint(5, 5)
        s.mirrors = [SketchMirrorDef(id: "m", sources: [dot], line: line)]
        #expect(s.refreshGenerated(none)["m"] != nil && images(s).isEmpty)
    }

    @Test func savesAndLoadsAndOlderFilesHaveNone() throws {
        var (s, tri, mirror) = sample()
        s.mirrors = [SketchMirrorDef(id: "m", sources: tri, line: mirror)]
        let back = try JSONDecoder().decode(Sketch.self, from: JSONEncoder().encode(s))
        #expect(back.mirrors == s.mirrors)
        var plain = sample().0
        plain.mirrors = []
        let text = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        #expect(!text.contains("mirrors"), "a sketch without a mirror is saved as before")
    }
}

/// Offsetting a selection that includes the image of a mirror.
@Suite struct SketchMirrorOffsetTests {
    private let none = ParameterValues()

    /// A trapezoid of three lines (and a construction base) over y = 0, mirrored across the base line.
    private func mirrored() -> (Sketch, all: [EntityID]) {
        var s = Sketch()
        let a = s.addPoint(0, 0), b = s.addPoint(10, 0), c = s.addPoint(8, 5), d = s.addPoint(2, 5)
        let base = s.addLine(a, b, construction: true)
        let right = s.addLine(b, c), top = s.addLine(c, d), left = s.addLine(d, a)
        s.mirrors = [SketchMirrorDef(id: "m", sources: [right, top, left], line: base)]
        s.refreshGenerated(none)
        let images = s.curves.map(\.id).filter(Sketch.isGenerated)
        return (s, [right, top, left] + images)
    }

    @Test func theOffsetOfAnImageSolvesAndLeavesTheOriginalsAlone() throws {
        var (s, all) = mirrored()
        let before = s.points.count
        let made = s.offset(all, distance: 1, expression: "1 mm")
        #expect(!made.isEmpty)
        let result = SketchSolver.solve(&s, dimensionValues: s.dimensionValues(none))
        #expect(result.status == .solved)
        // And with the images taken out for solving, as the session does, the sketch still solves.
        var solving = s
        let generated = solving.takeGenerated()
        let r2 = SketchSolver.solve(&solving, dimensionValues: solving.dimensionValues(none))
        #expect(r2.status == .solved, "constraints may not refer to the images")
        solving.restoreGenerated(generated)
        solving.refreshGenerated(none)
        #expect(solving.points.count > before)
        // No constraint or dimension of the offset names an entity that exists only while the images do.
        let names = Set(solving.points.map(\.id) + solving.curves.map(\.id))
        for c in solving.constraints { #expect(Sketch.references(c.kind).allSatisfy(names.contains)) }
        for c in solving.constraints { #expect(!Sketch.references(c.kind).contains(where: Sketch.isGenerated)) }
        for d in solving.dimensions { #expect(!Sketch.references(d.kind).contains(where: Sketch.isGenerated)) }
    }

    @Test func theOffsetOfAnImageIsAMillimetreAwayAndFollowsNothing() throws {
        var (s, all) = mirrored()
        let images = all.filter(Sketch.isGenerated)
        let made = s.offset(images, distance: 1, expression: "1 mm")
        #expect(made.count == 3)
        let lowest = made.compactMap { s.curve($0) }.flatMap { s.pointIDs(of: $0) }.compactMap { s.position($0) }.map(\.y).min() ?? 0
        #expect(abs(abs(lowest + 5) - 1) < 1e-6, "the image reaches y = -5; its offset is a mm further or nearer (got \(lowest))")
    }

    @Test func anOriginalAndItsImageOffsetToTheSameSideOfTheShape() throws {
        // An open outline (no base line selected): both halves go outward, or both inward, whatever the distance's sign.
        for distance in [1.0, -1.0] {
            var (s, all) = mirrored()
            let originals = all.filter { !Sketch.isGenerated($0) }, images = all.filter(Sketch.isGenerated)
            let a = s.offset(originals, distance: distance, expression: "1 mm")
            let b = s.offset(images, distance: distance, expression: "1 mm")
            func top(_ ids: [EntityID]) -> Double { ids.compactMap { s.curve($0) }.flatMap { s.pointIDs(of: $0) }.compactMap { s.position($0) }.map(\.y).max() ?? 0 }
            func bottom(_ ids: [EntityID]) -> Double { ids.compactMap { s.curve($0) }.flatMap { s.pointIDs(of: $0) }.compactMap { s.position($0) }.map(\.y).min() ?? 0 }
            // The original spans y 0…5 and its image -5…0: the top edge moving up by x means the bottom edge moves down by x.
            let up = top(a) - 5, down = bottom(b) + 5
            #expect(abs(up) > 0.5 && abs(up + down) < 1e-6, "the original's top moved \(up), the image's bottom \(down)")
        }
    }
}

/// A shape mirrored across a line that it touches is one outline with its image.
@Suite struct SketchMirrorJoinTests {
    private let none = ParameterValues()

    /// The trapezoid of the mirror offset tests: its base (on y = 0) is the mirror line, as in a half drawn to be mirrored.
    private func halfAndBase() -> (Sketch, lines: [EntityID], base: EntityID, ends: [EntityID]) {
        var s = Sketch()
        let a = s.addPoint(0, 0), b = s.addPoint(10, 0), c = s.addPoint(8, 5), d = s.addPoint(2, 5)
        let base = s.addLine(a, b, construction: true)
        let lines = [s.addLine(b, c), s.addLine(c, d), s.addLine(d, a)]
        s.mirrors = [SketchMirrorDef(id: "m", sources: lines, line: base)]
        s.refreshGenerated(none)
        return (s, lines, base, [a, b])
    }

    @Test func pointsOnTheLineAreSharedSoTheOutlineIsOneChain() throws {
        let (s, lines, _, ends) = halfAndBase()
        let images = s.curves.filter { Sketch.isGenerated($0.id) }
        #expect(images.count == 3)
        #expect(s.points.filter { Sketch.isGenerated($0.id) }.count == 2, "only the two off the line get their own")
        #expect(images.contains { s.pointIDs(of: $0).contains(ends[0]) } && images.contains { s.pointIDs(of: $0).contains(ends[1]) })
        let chain = s.chains(lines + images.map(\.id))
        #expect(chain.count == 1 && chain[0].closed && chain[0].items.count == 6, "six sides round: \(chain.map { ($0.closed, $0.items.count) })")
        // Double-click on an image takes the whole outline.
        #expect(Set(s.connectedCurves(images[0].id)) == Set(lines + images.map(\.id)))
    }

    @Test func offsettingTheWholeOutlineGivesOneClosedLoop() throws {
        var (s, lines, _, _) = halfAndBase()
        let all = lines + s.curves.filter { Sketch.isGenerated($0.id) }.map(\.id)
        let made = s.offset(all, distance: 1, expression: "1 mm")
        #expect(made.count == 6)
        let chain = s.chains(made)
        #expect(chain.count == 1 && chain[0].closed, "the offset is joined at the line too")
        #expect(SketchSolver.solve(&s, dimensionValues: s.dimensionValues(none)).status == .solved)
        // Outward: it is wider and taller than the outline (x 0…10 and y -5…5 become -1…11 and -6…6, near enough).
        let ys = made.compactMap { s.curve($0) }.flatMap { s.pointIDs(of: $0) }.compactMap { s.position($0) }.map(\.y)
        #expect((ys.max() ?? 0) > 5.5 && (ys.min() ?? 0) < -5.5)
    }

    @Test func aPointThatReachesTheLineStopsHavingItsOwnImage() throws {
        var (s, lines, _, _) = halfAndBase()
        guard case .line(let top, _)? = s.curve(lines[2])?.geometry else { Issue.record("expected a line"); return }  // the left side starts at the top-left corner
        #expect(s.points.contains { $0.id == "m~\(top)" })
        let k = s.points.firstIndex { $0.id == top }!
        s.points[k].y = 0  // down onto the line
        s.refreshGenerated(none)
        #expect(!s.points.contains { $0.id == "m~\(top)" }, "now it is its own image")
    }

    @Test func lineOnTheMirrorLineAndCircleCentredOnItAreNotCopiedOnTopOfThemselves() throws {
        var s = Sketch()
        let a = s.addPoint(0, 0), b = s.addPoint(10, 0)
        let on = s.addLine(a, b)
        let line = s.addLine(s.addPoint(-5, 0), s.addPoint(15, 0), construction: true)
        let c = s.addCircle(center: s.addPoint(3, 0), radius: 2)
        s.mirrors = [SketchMirrorDef(id: "m", sources: [on, c], line: line)]
        s.refreshGenerated(none)
        #expect(s.curves.filter { Sketch.isGenerated($0.id) }.isEmpty)
    }

    @Test func deletingTheOriginalsLeavesNoOrphanPoints() throws {
        var (s, lines, _, _) = halfAndBase()
        s.delete(Set(lines))
        s.refreshGenerated(none)
        #expect(s.points.allSatisfy { !Sketch.isGenerated($0.id) })
        #expect(s.points.count == 3, "the origin and the base line's two ends: \(s.points.map(\.id))")
    }
}

/// A mirror copies what other mirrors made, so a shape that has been mirrored once can be mirrored again whole.
@Suite struct SketchMirrorAgainTests {
    private let none = ParameterValues()

    /// A trapezoid (and a vertical construction line at x = 20) mirrored across the base line y = 0, then the whole
    /// of it, image included, mirrored across the vertical line.
    private func twice() -> (Sketch, firstSources: [EntityID]) {
        var s = Sketch()
        let a = s.addPoint(0, 0), b = s.addPoint(10, 0), c = s.addPoint(8, 5), d = s.addPoint(2, 5)
        let base = s.addLine(a, b, construction: true)
        let lines = [s.addLine(b, c), s.addLine(c, d), s.addLine(d, a)]
        let v = s.addLine(s.addPoint(20, -10), s.addPoint(20, 10), construction: true)
        s.mirrors = [SketchMirrorDef(id: "m1", sources: lines, line: base)]
        s.refreshGenerated(none)
        let second = SketchMirrorDef(id: "m2", sources: s.mirrorSources([]), line: v)
        s.mirrors.append(second)
        s.refreshGenerated(none)
        return (s, lines)
    }

    @Test func theWholeSketchIncludesTheFirstImage() throws {
        let (s, _) = twice()
        #expect(s.mirrors[1].sources.contains { $0.hasPrefix("m1~") }, "\(s.mirrors[1].sources)")
        let second = s.curves.filter { $0.id.hasPrefix("m2~") }
        #expect(second.count == 6 + 1, "the six sides, and the construction base (the vertical line itself is not copied): \(second.map(\.id))")
        // The image of the lowest image corner (x 2…8, y -5) across x = 20 lies at x 32…38.
        #expect(s.points.contains { vlen($0.position - SIMD2(38, -5)) < 1e-9 || vlen($0.position - SIMD2(32, -5)) < 1e-9 })
        #expect(s.points.contains { Sketch.isGenerated($0.id) && $0.id.hasPrefix("m2~m1~") })
    }

    @Test func imagesAreStableAndFollowTheFirstMirrorsLine() throws {
        var (s, lines) = twice()
        let before = Set(s.curves.map(\.id))
        s.refreshGenerated(none)
        #expect(Set(s.curves.map(\.id)) == before, "the same ids every time")
        // Take the first mirror to the x axis' other side: change its line to the y axis.
        s.mirrors[0].line = SketchMirrorDef.yAxis
        s.refreshGenerated(none)
        #expect(s.mirrors.count == 2 && s.curves.contains { $0.id.hasPrefix("m2~m1~") }, "the second still copies the first's image")
        _ = lines
    }

    @Test func deletingTheFirstMirrorTakesTheOneThatCopiedItsImageBack() throws {
        var (s, _) = twice()
        s.mirrors.removeAll { $0.id == "m1" }
        s.refreshGenerated(none)
        #expect(s.mirrors.map(\.id) == ["m2"], "m2 still has the drawn curves to copy")
        #expect(!s.curves.contains { $0.id.hasPrefix("m2~m1~") })
        // A mirror that copied only the first one's image has nothing left.
        var t = twice().0
        t.mirrors[1].sources = t.mirrors[1].sources.filter { $0.hasPrefix("m1~") }
        t.mirrors.removeAll { $0.id == "m1" }
        t.refreshGenerated(none)
        #expect(t.mirrors.isEmpty)
    }

    @Test func theFirstMirrorCanBeReplacedInPlaceWithoutLosingTheSecond() throws {
        var (s, _) = twice()
        var edited = s.mirrors[0]
        edited.line = SketchMirrorDef.xAxis
        s.mirrors[0] = edited
        s.refreshGenerated(none)
        #expect(s.mirrors.map(\.id) == ["m1", "m2"])
    }
}
