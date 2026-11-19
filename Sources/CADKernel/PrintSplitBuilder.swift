// Builds the pieces of a split from its settings and the finished body (PrintSplit, in CADCore): the cuts that make every piece fit
// the printer, and the connectors that put them back together. It runs after the regenerator, on the same background thread, and its
// result is never saved. The order, as in the mold builder, keeps every boolean on simple shapes:
//   cut the body by the planes, one after another → find where a connector fits on each cut (a mesh test: the pin and the wall round
//   it must lie inside the body) → one boolean per piece for all its sockets, one for all its pins.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CKernel
import Foundation
import simd

/// One piece of a split.
public struct PrintSplitPiece: Sendable, Identifiable {
    public var id: FeatureID
    public var name: String
    public var body: KBody
    /// Which cell of the grid of cuts it came from (x, y, z), counting from 0 at the low side.
    public var cell: [Int]
    /// What it measures with its connectors on (mm).
    public var size: SIMD3<Double>
    /// Whether it fits the usable build volume (turned on the bed if the setup allows).
    public var fits: Bool
    /// How many connectors it carries (pins and keys on it, sockets and pockets in it).
    public var connectors: Int
    public var volume: Double

    public var result: BodyResult { BodyResult(id: id, name: name, body: body) }
}

/// What a split build came to.
public struct PrintSplitResult: Sendable {
    public var setup: PrintSplit
    public var pieces: [PrintSplitPiece] = []
    /// Loose parts to print besides the pieces: the dowels of a dowel connector, one for each socket pair.
    public var dowels: [BodyResult] = []
    /// Why it could not be built, in words for the user; nil when it was.
    public var error: String?
    /// Things worth knowing about a split that was built (a piece too big, a cut with no room for a connector).
    public var warnings: [String] = []
    /// The printer's build volume, and what is left of it after the margin (mm).
    public var printerVolume = SIMD3<Double>.zero
    public var usableVolume = SIMD3<Double>.zero
    /// Where the body was cut, along each axis (x, y, z), low to high; and how many pieces that makes along each (cuts + 1).
    public var cutPositions: [[Double]] = [[], [], []]
    public var bodySize = SIMD3<Double>.zero
    public var bodyVolume = 0.0
    public var connectorCount = 0
    /// How many plates (builds) the pieces and dowels take, packed in rows.
    public var plates = 0
    public var seconds = 0.0

    public init(setup: PrintSplit, error: String? = nil) { self.setup = setup; self.error = error }

    public var isBuilt: Bool { error == nil && !pieces.isEmpty }
    public var allFit: Bool { pieces.allSatisfy(\.fits) }
    public var counts: [Int] { cutPositions.map { $0.count + 1 } }
    /// The pieces as bodies, in order.
    public var bodies: [BodyResult] { pieces.map(\.result) }
    /// The cuts as the setup holds them (a manual list), for switching a split from automatic to by-hand without moving anything.
    public var cuts: [PrintSplitCut] {
        MoldAxis.allCases.flatMap { axis in cutPositions[axis.index].map { PrintSplitCut(axis: axis, position: PrintSplitBuilder.text($0)) } }
    }
}

public enum PrintSplitBuilder {
    /// The wall that is kept all round a connector, in a piece: three perimeters of a 0.4 mm nozzle, about.
    static let skin = 1.2
    /// How far a pin or socket starts on the far side of the cut, so a boolean never meets a face that lies exactly on the plane.
    static let lead = 0.2
    /// The most pieces a split makes: more than this is a mistake (a wrong printer or a unit) rather than a plan.
    static let maxPieces = 64
    /// Planes that give invalid pieces (through the seam of a round face) are moved by these distances, one after another.
    static let nudges = [0.05, -0.05, 0.2]
    static let dovetailAngle = 15.0 * Double.pi / 180
    static let maxConnectorsPerCut = 12

    /// A length as the text a field shows: whole numbers without a decimal point, else two decimals.
    public static func text(_ v: Double) -> String {
        let s = abs(v - v.rounded()) < 0.005 ? String(Int(v.rounded())) : String(format: "%.2f", v)
        return "\(s) mm"
    }

    struct SplitError: Error { var message: String }

    // MARK: settings

    private static func length(_ text: String, _ what: String, in r: RegenResult, min: Double = 0, allowZero: Bool = false) throws -> Double {
        let v: Double
        do { v = try r.parameters.value(of: text, kind: .length) } catch { throw SplitError(message: "The \(what) \"\(text)\" is not a length.") }
        guard v.isFinite, allowZero ? v >= min : v > min else { throw SplitError(message: "The \(what) must be more than \(min == 0 ? "zero" : "\(min) mm").") }
        return v
    }

    /// The build volume the split is made for: a preset's, or the three sizes typed in.
    public static func printerVolume(of setup: PrintSplit, in r: RegenResult) throws -> SIMD3<Double> {
        if let preset = PrinterPreset.preset(setup.printer) { return preset.volume }
        guard setup.printer == PrinterPreset.customID else {
            throw SplitError(message: "The printer \"\(setup.printer)\" is not known. Choose one from the list, or a custom volume.")
        }
        let names = ["width", "depth", "height"]
        let v = try (0..<3).map { try length(setup.customVolume[$0], "build \(names[$0])", in: r) }
        return SIMD3(v[0], v[1], v[2])
    }

    /// The gap round a connector (mm).
    public static func clearance(of setup: PrintSplit, in r: RegenResult) throws -> Double {
        if let c = setup.fit.clearance { return c }
        return try length(setup.customClearance, "clearance", in: r, min: 0, allowZero: true)
    }

    // MARK: the plan

    /// How many pieces along each axis give the fewest that fit, and (when pieces may be turned) which way the printer's axes
    /// are matched to the body's. A connector that sticks out takes `protrusion` of every piece's length.
    public static func automaticCounts(extent: SIMD3<Double>, usable: SIMD3<Double>, protrusion: Double, turn: Bool) -> [Int]? {
        let perms: [[Int]] = turn ? [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]] : [[0, 1, 2]]
        var best: (counts: [Int], score: Double)?
        for perm in perms {
            var counts: [Int] = []
            var ok = true
            for i in 0..<3 {
                let room = usable[perm[i]]
                if extent[i] <= room + 1e-6 { counts.append(1); continue }
                let each = room - protrusion
                guard each > 1 else { ok = false; break }
                counts.append(Int((extent[i] / each - 1e-9).rounded(.up)))
            }
            guard ok else { continue }
            let score = Double(counts.reduce(1, *)) * 1000 + Double(counts.reduce(0, +))
            if best == nil || score < best!.score { best = (counts, score) }
        }
        return best?.counts
    }

    /// The cuts across an axis that make `n` equal pieces of a body from `low` to `high`.
    static func evenCuts(low: Double, high: Double, pieces n: Int) -> [Double] {
        n > 1 ? (1..<n).map { low + (high - low) * Double($0) / Double(n) } : []
    }

    // MARK: building

    /// Builds the split of `part` (the body the setup names, as the regeneration `r` made it).
    public static func build(_ setup: PrintSplit, part: KBody, in r: RegenResult) -> PrintSplitResult {
        let started = Date()
        var result = PrintSplitResult(setup: setup)
        defer { result.seconds = Date().timeIntervalSince(started) }
        do {
            try build(setup, part: part, in: r, into: &result)
        } catch let e as SplitError {
            result.error = e.message; result.pieces = []; result.dowels = []
        } catch {
            result.error = "The split could not be built: \(error)"; result.pieces = []; result.dowels = []
        }
        return result
    }

    private struct Cell {
        var index: [Int]
        var body: KBody
    }

    /// A connector placed on a cut: where, and the pieces it joins (indices into the cells).
    private struct Placement {
        var at: SIMD3<Double>
        var behind: Int
        var front: Int
    }

    private static func build(_ setup: PrintSplit, part: KBody, in r: RegenResult, into out: inout PrintSplitResult) throws {
        let kind = setup.connector
        let size = kind == .none ? 0 : try length(setup.connectorSize, "connector size", in: r)
        let depth = kind == .none ? 0 : try length(setup.connectorLength, "connector length", in: r)
        let clr = kind == .none ? 0 : try clearance(of: setup, in: r)
        let spacing = try length(setup.spacing, "connector spacing", in: r, min: 5)
        let margin = try length(setup.margin, "margin", in: r, min: 0, allowZero: true)
        let printer = try printerVolume(of: setup, in: r)
        let usable = printer - SIMD3(repeating: 2 * margin)
        guard usable.x > 5, usable.y > 5, usable.z > 5 else { throw SplitError(message: "The margin leaves no room on the bed. Make it smaller.") }
        out.printerVolume = printer
        out.usableVolume = usable

        guard part.isValid else {
            throw SplitError(message: "The body is not a valid solid (an imported mesh with gaps, for one). Repair it in Design first.")
        }
        guard let bounds = part.bounds, part.volume > 1e-6 else { throw SplitError(message: "The body is empty.") }
        let ext = bounds.max - bounds.min
        out.bodySize = ext
        out.bodyVolume = part.volume

        // The cuts: by hand, or evenly across as many pieces as it takes.
        var cuts: [[Double]] = [[], [], []]
        if let manual = setup.cuts {
            for c in manual {
                let v: Double
                do { v = try r.parameters.value(of: c.position, kind: .length) } catch {
                    throw SplitError(message: "The cut position \"\(c.position)\" is not a length.")
                }
                let i = c.axis.index
                guard v > bounds.min[i] + 0.5, v < bounds.max[i] - 0.5 else {
                    out.warnings.append("A cut across \(c.axis.rawValue.uppercased()) at \(text(v)) is outside the body, so it is left out.")
                    continue
                }
                cuts[i].append(v)
            }
            for i in 0..<3 {
                cuts[i].sort()
                var kept: [Double] = []
                for v in cuts[i] where kept.last.map({ v - $0 > 1 }) ?? true { kept.append(v) }
                cuts[i] = kept
            }
        } else {
            let protrusion = kind.protrudes && !setup.hasLooseParts ? depth : 0
            let auto = automaticCounts(extent: ext, usable: usable, protrusion: protrusion, turn: setup.turn)
            if auto == nil, setup.counts.contains(0) {
                throw SplitError(message: "The \(kind.lengthLabel.lowercased()) of the connector (\(text(depth))) is longer than the build volume allows. Make it shorter.")
            }
            for i in 0..<3 {
                let n = setup.counts[i] > 0 ? setup.counts[i] : (auto?[i] ?? 1)
                cuts[i] = evenCuts(low: bounds.min[i], high: bounds.max[i], pieces: min(n, maxPieces))
            }
        }
        let pieceEstimate = cuts.reduce(1) { $0 * ($1.count + 1) }
        guard pieceEstimate <= maxPieces else {
            throw SplitError(message: "That would cut the body into \(pieceEstimate) pieces. Use a bigger printer, or fewer cuts.")
        }

        // Cut it, plane after plane. A cell is the part of the body between two cuts of every axis; one that holds nothing is not made.
        var cells = [Cell(index: [0, 0, 0], body: part)]
        for axis in 0..<3 {
            for k in cuts[axis].indices {
                var next: [Cell] = []
                var applied = cuts[axis][k]
                for cell in cells {
                    guard cell.index[axis] == k else { next.append(cell); continue }
                    guard let pieces = try cutChecked(cell.body, axis: axis, at: &applied, id: "cut\(axis)\(k)", out: &out.warnings) else {
                        throw SplitError(message: "The body could not be cut across \(["X", "Y", "Z"][axis]) at \(text(cuts[axis][k])). Move the cut a little.")
                    }
                    for piece in pieces {
                        guard let b = piece.bounds else { continue }
                        var index = cell.index
                        if (b.min[axis] + b.max[axis]) / 2 > applied { index[axis] += 1 }
                        next.append(Cell(index: index, body: piece))
                    }
                }
                cuts[axis][k] = applied
                cells = next
            }
        }
        out.cutPositions = cuts
        guard !cells.isEmpty else { throw SplitError(message: "The cuts left nothing of the body.") }

        // The connectors.
        var adds = [[KBody]](repeating: [], count: cells.count)
        var takes = [[KBody]](repeating: [], count: cells.count)
        var counts = [Int](repeating: 0, count: cells.count)
        var dowels: [BodyResult] = []
        if kind != .none, cuts.contains(where: { !$0.isEmpty }) {
            let diagonal = simd_length(ext)
            let mesh = try part.tessellate(linearDeflection: max(0.05, diagonal * 0.002))
            let probe = SolidProbe(mesh)
            var pieceProbes: [Int: SolidProbe] = [:]
            func probeOf(_ i: Int) -> SolidProbe? {
                if let p = pieceProbes[i] { return p }
                guard let m = try? cells[i].body.tessellate(linearDeflection: max(0.05, diagonal * 0.002)) else { return nil }
                let p = SolidProbe(m)
                pieceProbes[i] = p
                return p
            }
            let tool = ConnectorTool(kind: kind, size: size, depth: depth, clearance: clr, separate: setup.separate && kind.canBeSeparate)
            for axis in 0..<3 {
                let others = (0..<3).filter { $0 != axis }
                for k in cuts[axis].indices {
                    let plane = cuts[axis][k]
                    var groups: [[Int]: (behind: [Int], front: [Int])] = [:]
                    for (i, cell) in cells.enumerated() where cell.index[axis] == k || cell.index[axis] == k + 1 {
                        let key = others.map { cell.index[$0] }
                        var g = groups[key] ?? ([], [])
                        if cell.index[axis] == k { g.behind.append(i) } else { g.front.append(i) }
                        groups[key] = g
                    }
                    var placed = 0
                    var anyInterface = false
                    for (key, g) in groups.sorted(by: { $0.key.lexicographicallyPrecedes($1.key) }) where !g.behind.isEmpty && !g.front.isEmpty {
                        anyInterface = true
                        // The cell's range across the cut, which the connectors have to stay inside.
                        func range(_ a: Int, _ i: Int) -> (Double, Double) {
                            (i == 0 ? bounds.min[a] : cuts[a][i - 1], i == cuts[a].count ? bounds.max[a] : cuts[a][i])
                        }
                        let ranges = zip(others, key).map { range($0, $1) }
                        // A dovetail slides along the in-plane axis with the fewer cuts, where nothing blocks it.
                        let slideFirst = cuts[others[0]].count <= cuts[others[1]].count
                        let slide = slideFirst ? 0 : 1
                        let spots = positions(tool: tool, plane: plane, axis: axis, others: others, ranges: ranges, slide: slide, spacing: spacing,
                                              probe: probe, pieceBehind: g.behind.compactMap { probeOf($0) }, pieceFront: g.front.compactMap { probeOf($0) })
                        for at in spots.prefix(maxConnectorsPerCut) {
                            // The piece each end of the connector belongs to: the one that holds the spot just behind the cut, and just in front.
                            let n = unit(axis)
                            guard let b = g.behind.first(where: { probeOf($0)?.contains(at - n * 0.6) == true }),
                                  let f = g.front.first(where: { probeOf($0)?.contains(at + n * 0.6) == true }) else { continue }
                            do {
                                try tool.make(at: at, axis: axis, slideAxis: others[slide], acrossAxis: others[1 - slide], slideRange: ranges[slide],
                                              behind: b, front: f, frontBody: cells[f].body, adds: &adds, takes: &takes, dowels: &dowels,
                                              id: "\(axis)\(k)-\(placed)")
                                counts[b] += 1; counts[f] += 1
                                placed += 1
                            } catch {
                                out.warnings.append("A connector at \(["X", "Y", "Z"][axis]) = \(text(plane)) could not be made, so it is left out.")
                            }
                        }
                    }
                    if anyInterface, placed == 0 {
                        out.warnings.append("No room for a \(kind.title.lowercased()) on the cut across \(["X", "Y", "Z"][axis]) at \(text(plane)): the cut is too small or too thin. Use a smaller connector, or glue it flat.")
                    }
                    out.connectorCount += placed
                }
            }
        }

        // Put the connectors on: all the sockets of a piece in one boolean, then all its pins in another.
        for i in cells.indices {
            var body = cells[i].body
            do {
                if let tool = try fused(takes[i]) {
                    let cut = try body.boolean(tool, SK_CUT)
                    guard cut.isValid, !cut.isEmpty, cut.volume < body.volume - 1e-6 else { throw SplitError(message: "sockets") }
                    body = cut
                }
                if let tool = try fused(adds[i]) {
                    let joined = try body.boolean(tool, SK_FUSE)
                    guard joined.isValid, !joined.isEmpty, joined.volume > body.volume + 1e-6 else { throw SplitError(message: "pins") }
                    body = joined
                }
            } catch {
                out.warnings.append("The connectors could not be added to one piece (\(cellLabel(cells[i].index))), so it is left plain.")
                body = cells[i].body
                counts[i] = 0
            }
            cells[i].body = body
        }

        // Number the pieces along X, then Y, then Z.
        let order = cells.indices.sorted { a, b in
            let (ca, cb) = (cells[a].index, cells[b].index)
            if ca[2] != cb[2] { return ca[2] < cb[2] }
            if ca[1] != cb[1] { return ca[1] < cb[1] }
            if ca[0] != cb[0] { return ca[0] < cb[0] }
            return (cells[a].body.bounds?.min.x ?? 0) < (cells[b].body.bounds?.min.x ?? 0)
        }
        for (k, i) in order.enumerated() {
            let body = cells[i].body
            let b = body.bounds ?? (min: SIMD3<Double>.zero, max: SIMD3<Double>.zero)
            let dims = b.max - b.min
            let fits = Self.fits(dims, in: usable, turn: setup.turn)
            out.pieces.append(PrintSplitPiece(id: setup.pieceID(k + 1), name: "\(setup.name) part \(k + 1)", body: body, cell: cells[i].index,
                                              size: dims, fits: fits, connectors: counts[i], volume: body.volume))
        }
        out.dowels = dowels.enumerated().map { BodyResult(id: setup.dowelID($0.offset + 1), name: "\(setup.name) \(setup.looseName) \($0.offset + 1)", body: $0.element.body) }

        let sizes = out.pieces.map(\.size) + dowels.map { $0.body.bounds.map { $0.max - $0.min } ?? .zero }
        out.plates = pack(sizes.map { turnedDims($0, orientation(of: $0, in: usable, turn: setup.turn)) }, in: usable, gap: 5).plates

        let big = out.pieces.filter { !$0.fits }
        if !big.isEmpty {
            let numbers = big.prefix(3).map { bigPiece in (out.pieces.firstIndex { $0.id == bigPiece.id } ?? 0) + 1 }
            let names = numbers.map { "part \($0)" }.joined(separator: ", ")
            out.warnings.append("\(big.count == 1 ? "One piece is" : "\(big.count) pieces are") bigger than the build volume (\(names)\(big.count > 3 ? "…" : "")). Add a cut, or choose a bigger printer.")
        }
        // The pieces are the body, less what the sockets took, plus what the pins added: that is checked, so a bad boolean shows up.
        let total = out.pieces.reduce(0) { $0 + $1.volume }
        if abs(total - part.volume) > part.volume * 0.25 {
            out.warnings.append("The pieces add up to \(String(format: "%.0f%%", total / part.volume * 100)) of the body's volume, which is more than the connectors explain. Check the cuts.")
        }
    }

    /// Whether a piece of these dimensions fits the volume: as it is, or (when it may be turned) in any way up.
    static func fits(_ dims: SIMD3<Double>, in volume: SIMD3<Double>, turn: Bool) -> Bool {
        let e = 1e-3
        if !turn { return dims.x <= volume.x + e && dims.y <= volume.y + e && dims.z <= volume.z + e }
        let a = [dims.x, dims.y, dims.z].sorted(), b = [volume.x, volume.y, volume.z].sorted()
        return a[0] <= b[0] + e && a[1] <= b[1] + e && a[2] <= b[2] + e
    }

    private static func cellLabel(_ index: [Int]) -> String { "cell \(index[0] + 1)·\(index[1] + 1)·\(index[2] + 1)" }

    static func unit(_ axis: Int) -> SIMD3<Double> { SIMD3(axis == 0 ? 1 : 0, axis == 1 ? 1 : 0, axis == 2 ? 1 : 0) }

    private static func fused(_ tools: [KBody]) throws -> KBody? {
        guard var tool = tools.first else { return nil }
        for t in tools.dropFirst() { tool = try tool.boolean(t, SK_FUSE) }
        return tool
    }

    /// Cuts a body by the plane across `axis` at `position`; when that gives invalid pieces (a plane through the seam of a round face
    /// does), the plane is moved by a hair until it does not. `position` is the plane as it was cut.
    private static func cutChecked(_ body: KBody, axis: Int, at position: inout Double, id: String, out warnings: inout [String]) throws -> [KBody]? {
        let n = unit(axis)
        for shift in [0.0] + nudges {
            let p = position + shift
            let pieces = try body.split(planeThrough: n * p, normal: n, featureID: id)
            guard pieces.allSatisfy({ $0.isValid && !$0.isEmpty }) else { continue }
            let sum = pieces.reduce(0) { $0 + $1.volume }
            guard abs(sum - body.volume) <= body.volume * 0.002 else { continue }
            if shift != 0 {
                warnings.append("A cut across \(["X", "Y", "Z"][axis]) was moved \(String(format: "%.2f", abs(shift))) mm: exactly there it gave a broken split.")
                position = p
            }
            return pieces
        }
        return nil
    }

    // MARK: where a connector fits

    /// The places on a cut where the connector fits inside the body, wall and all: tried on an even grid about `spacing` apart, then on
    /// a finer one when the first finds nothing. The positions are points on the cut plane.
    private static func positions(tool: ConnectorTool, plane: Double, axis: Int, others: [Int], ranges: [(Double, Double)], slide: Int, spacing: Double,
                                  probe: SolidProbe, pieceBehind: [SolidProbe], pieceFront: [SolidProbe]) -> [SIMD3<Double>] {
        let n = unit(axis)
        let reach = tool.footprintRadius + skin
        func point(_ u: Double, _ v: Double) -> SIMD3<Double> {
            var p = n * plane
            p[others[0]] = u; p[others[1]] = v
            return p
        }
        // The grid: a dovetail is one tab across the cut (along its slide), so it is spaced along the other axis only.
        let across = 1 - slide
        for level in [1, 2, 4] {
            var found: [SIMD3<Double>] = []
            let count = (0..<2).map { i -> Int in
                let w = ranges[i].1 - ranges[i].0
                if tool.kind == .dovetail && i == slide { return 1 }
                return max(1, Int((w / spacing).rounded())) * level
            }
            for i in 0..<count[0] {
                for j in 0..<count[1] where found.count < maxConnectorsPerCut {
                    let u = ranges[0].0 + (Double(i) + 0.5) * (ranges[0].1 - ranges[0].0) / Double(count[0])
                    let v = ranges[1].0 + (Double(j) + 0.5) * (ranges[1].1 - ranges[1].0) / Double(count[1])
                    let at = point(u, v)
                    if tool.kind == .dovetail {
                        let r = ranges[slide]
                        let hw = tool.size / 2 + tool.depth * tan(dovetailAngle) + tool.clearance + skin
                        let w = (ranges[across].1 - ranges[across].0)
                        guard hw * 2 < w else { continue }
                        if tool.dovetailFits(at: at, axis: axis, others: others, slide: slide, slideRange: r, probe: probe) { found.append(at) }
                    } else {
                        // Inside the cell with room to spare, and the whole connector (and its wall) inside the body.
                        guard u - reach >= ranges[0].0 + 0.2, u + reach <= ranges[0].1 - 0.2, v - reach >= ranges[1].0 + 0.2, v + reach <= ranges[1].1 - 0.2 else { continue }
                        if tool.fits(at: at, axis: axis, others: others, probe: probe) { found.append(at) }
                    }
                }
            }
            if !found.isEmpty { return found }
            if count[0] * count[1] > 40 { break }
        }
        return []
    }

    // MARK: laying the pieces out for printing

    /// The pieces (and loose dowels) as they are printed: each turned to fit the build volume if that takes turning, standing on the bed
    /// (z = 0), packed in rows on plates the size of the build volume, the plates side by side along X.
    public static func printLayout(_ result: PrintSplitResult, gap: Double = 5) -> (bodies: [BodyResult], plates: Int) {
        guard result.isBuilt else { return ([], 0) }
        let u = result.usableVolume
        var placed: [BodyResult] = []
        let parts = result.pieces.map(\.result) + result.dowels
        let sizes = parts.map { part -> SIMD3<Double> in part.body.bounds.map { $0.max - $0.min } ?? .zero }
        let slots = pack(sizes.map { turnedDims($0, orientation(of: $0, in: u, turn: result.setup.turn)) }, in: u, gap: gap)
        let step = result.printerVolume.x + 30
        for (i, part) in parts.enumerated() {
            guard let oriented = try? orient(part.body, orientation(of: sizes[i], in: u, turn: result.setup.turn)), let b = oriented.bounds,
                  let moved = try? oriented.translated(SIMD3(Double(slots.plate[i]) * step + slots.at[i].x, slots.at[i].y, 0) - b.min) else { continue }
            placed.append(BodyResult(id: part.id, name: part.name, body: moved))
        }
        return (placed, slots.plates)
    }

    /// Rows of boxes on plates of `volume`'s footprint: where each goes (on its plate) and which plate; and how many plates.
    static func pack(_ dims: [SIMD3<Double>], in volume: SIMD3<Double>, gap: Double) -> (at: [SIMD2<Double>], plate: [Int], plates: Int) {
        var at: [SIMD2<Double>] = [], plate: [Int] = []
        var current = 0
        var cursor = SIMD2<Double>(0, 0)
        var rowDepth = 0.0
        for d in dims {
            if cursor.x > 0, cursor.x + d.x > volume.x { cursor = SIMD2(0, cursor.y + rowDepth + gap); rowDepth = 0 }
            if cursor.y > 0, cursor.y + d.y > volume.y { current += 1; cursor = .zero; rowDepth = 0 }
            at.append(cursor); plate.append(current)
            cursor.x += d.x + gap
            rowDepth = max(rowDepth, d.y)
        }
        return (at, plate, current + 1)
    }

    /// The six ways a box can stand (its dimensions permuted), each as the turns that make it.
    private static let turns: [[(axis: SIMD3<Double>, angle: Double)]] = {
        let q = Double.pi / 2
        let x = SIMD3(1.0, 0, 0), y = SIMD3(0, 1.0, 0), z = SIMD3(0, 0, 1.0)
        return [[], [(z, q)], [(x, q)], [(y, q)], [(x, q), (z, q)], [(y, q), (z, q)]]
    }()

    /// The dimensions of a box of `size` stood in way `o` of the six.
    static func turnedDims(_ size: SIMD3<Double>, _ o: Int) -> SIMD3<Double> {
        switch o {
        case 1: SIMD3(size.y, size.x, size.z)
        case 2: SIMD3(size.x, size.z, size.y)
        case 3: SIMD3(size.z, size.y, size.x)
        case 4: SIMD3(size.z, size.x, size.y)
        case 5: SIMD3(size.y, size.z, size.x)
        default: size
        }
    }

    /// How a piece of this size stands on the bed: the way it is kept when that fits; else (when turning is allowed) the way that fits
    /// and stands lowest. 0 is as it is.
    static func orientation(of size: SIMD3<Double>, in volume: SIMD3<Double>, turn: Bool) -> Int {
        guard turn else { return 0 }
        let fitting = (0..<6).filter { let d = turnedDims(size, $0); return d.x <= volume.x + 1e-3 && d.y <= volume.y + 1e-3 && d.z <= volume.z + 1e-3 }
        return fitting.contains(0) ? 0 : (fitting.min { turnedDims(size, $0).z < turnedDims(size, $1).z } ?? 0)
    }

    /// The body stood in way `o` of the six, about its middle.
    static func orient(_ body: KBody, _ o: Int) throws -> KBody {
        guard o != 0, let b = body.bounds else { return body }
        var turned = body
        let centre = (b.min + b.max) / 2
        for t in turns[o] { turned = try turned.rotated(about: centre, axis: t.axis, angle: t.angle) }
        return turned
    }
}

// MARK: - Seeing inside a body

/// Tells whether a point is inside a body, from the body's mesh: a ray from the point crosses the surface an odd number of times when
/// it started inside. The ray leaves at an odd angle, so that it does not run along an edge of a flat-sided body. The triangles are
/// binned on a grid across the ray (as seen along it), so a query only meets the few triangles the ray can touch: a mesh of a hundred
/// thousand triangles answers in microseconds instead of milliseconds.
struct SolidProbe: Sendable {
    private var a: [SIMD3<Float>] = []
    private var e1: [SIMD3<Float>] = []
    private var e2: [SIMD3<Float>] = []
    private var lo = SIMD3<Float>(repeating: .infinity)
    private var hi = SIMD3<Float>(repeating: -.infinity)
    private static let direction = simd_normalize(SIMD3<Float>(0.5731, 0.3417, 0.7449))
    private static let across: (SIMD3<Float>, SIMD3<Float>) = {
        let d = direction
        let u = simd_normalize(simd_cross(d, abs(d.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)))
        return (u, simd_cross(d, u))
    }()
    /// The grid over the triangles' shadows: its origin, the size of a cell, how many cells across, and the triangles of each (CSR).
    private var gridOrigin = SIMD2<Float>(0, 0)
    private var cell: Float = 1
    private var cells = 1
    private var cellStart: [Int32] = []
    private var cellItems: [Int32] = []

    init(_ mesh: Mesh) {
        let p = mesh.positions, ix = mesh.indices
        func vertex(_ i: UInt32) -> SIMD3<Float> { SIMD3(p[Int(i) * 3], p[Int(i) * 3 + 1], p[Int(i) * 3 + 2]) }
        let count = ix.count / 3
        a.reserveCapacity(count); e1.reserveCapacity(count); e2.reserveCapacity(count)
        var boxes: [(SIMD2<Float>, SIMD2<Float>)] = []
        boxes.reserveCapacity(count)
        let (ud, vd) = Self.across
        var shadowLo = SIMD2<Float>(repeating: .infinity), shadowHi = SIMD2<Float>(repeating: -.infinity)
        for t in 0..<count {
            let (v0, v1, v2) = (vertex(ix[3 * t]), vertex(ix[3 * t + 1]), vertex(ix[3 * t + 2]))
            a.append(v0); e1.append(v1 - v0); e2.append(v2 - v0)
            lo = simd_min(lo, simd_min(v0, simd_min(v1, v2)))
            hi = simd_max(hi, simd_max(v0, simd_max(v1, v2)))
            let s0 = SIMD2(simd_dot(v0, ud), simd_dot(v0, vd)), s1 = SIMD2(simd_dot(v1, ud), simd_dot(v1, vd)), s2 = SIMD2(simd_dot(v2, ud), simd_dot(v2, vd))
            let b = (simd_min(s0, simd_min(s1, s2)), simd_max(s0, simd_max(s1, s2)))
            boxes.append(b)
            shadowLo = simd_min(shadowLo, b.0); shadowHi = simd_max(shadowHi, b.1)
        }
        guard count > 0 else { return }
        cells = max(1, min(256, Int(Double(count).squareRoot() / 2)))
        gridOrigin = shadowLo
        cell = max((shadowHi - shadowLo).max() / Float(cells), 1e-6)
        var counts = [Int32](repeating: 0, count: cells * cells + 1)
        func range(_ b: (SIMD2<Float>, SIMD2<Float>)) -> (Int, Int, Int, Int) {
            let l = (b.0 - gridOrigin) / cell, h = (b.1 - gridOrigin) / cell
            return (max(0, min(cells - 1, Int(l.x))), max(0, min(cells - 1, Int(l.y))), max(0, min(cells - 1, Int(h.x))), max(0, min(cells - 1, Int(h.y))))
        }
        for b in boxes {
            let r = range(b)
            for y in r.1...r.3 { for x in r.0...r.2 { counts[y * cells + x + 1] += 1 } }
        }
        for i in 1..<counts.count { counts[i] += counts[i - 1] }
        cellStart = counts
        cellItems = [Int32](repeating: 0, count: Int(counts[counts.count - 1]))
        var fill = counts
        for (t, b) in boxes.enumerated() {
            let r = range(b)
            for y in r.1...r.3 { for x in r.0...r.2 {
                let c = y * cells + x
                cellItems[Int(fill[c])] = Int32(t)
                fill[c] += 1
            } }
        }
    }

    func contains(_ point: SIMD3<Double>) -> Bool {
        let q = SIMD3<Float>(point)
        guard !a.isEmpty, all(q .>= lo), all(q .<= hi) else { return false }
        let d = Self.direction
        let (ud, vd) = Self.across
        let s = (SIMD2(simd_dot(q, ud), simd_dot(q, vd)) - gridOrigin) / cell
        let cx = Int(s.x), cy = Int(s.y)
        guard cx >= 0, cy >= 0, cx < cells, cy < cells else { return false }
        let c = cy * cells + cx
        var hits = 0
        for k in Int(cellStart[c])..<Int(cellStart[c + 1]) {
            let t = Int(cellItems[k])
            let h = simd_cross(d, e2[t])
            let det = simd_dot(e1[t], h)
            if abs(det) < 1e-9 { continue }
            let f = 1 / det
            let sv = q - a[t]
            let u = f * simd_dot(sv, h)
            if u < 0 || u > 1 { continue }
            let cr = simd_cross(sv, e1[t])
            let v = f * simd_dot(d, cr)
            if v < 0 || u + v > 1 { continue }
            if f * simd_dot(e2[t], cr) > 1e-6 { hits += 1 }
        }
        return hits % 2 == 1
    }
}

// MARK: - The connector solids

/// Makes the solids of one kind of connector: what is added to a piece (pins, keys, tabs) and what is cut out of it (sockets, pockets,
/// slots), and answers whether one fits at a place.
private struct ConnectorTool {
    var kind: ConnectorKind
    var size: Double
    var depth: Double
    var clearance: Double
    /// A pin or a key as a part of its own: a socket in each piece, and a loose part as long as both sockets together.
    var separate = false

    /// How far the connector reaches from its centre across the cut (a square key by its corner).
    var footprintRadius: Double {
        switch kind {
        case .key: size / 2 * 2.0.squareRoot() + clearance
        case .none: 0
        default: size / 2 + clearance
        }
    }

    /// How deep into the piece in front, and into the one behind, the connector and the wall under it reach.
    private var reachFront: Double {
        switch kind {
        case .pin, .key: depth + clearance + PrintSplitBuilder.skin
        case .dowel: depth / 2 + clearance + PrintSplitBuilder.skin
        case .magnet: depth + clearance + PrintSplitBuilder.skin
        case .dovetail: depth + clearance + PrintSplitBuilder.skin
        case .none: 0
        }
    }
    private var reachBehind: Double {
        switch kind {
        case .dowel: depth / 2 + clearance + PrintSplitBuilder.skin
        case .magnet: depth + clearance + PrintSplitBuilder.skin
        case .pin where separate, .key where separate: depth + clearance + PrintSplitBuilder.skin
        default: PrintSplitBuilder.skin
        }
    }

    // MARK: fit

    /// Whether a round or square connector at `at` (on the cut plane) lies inside the body with its wall: the axis and a ring round it,
    /// at the depths the connector reaches.
    func fits(at: SIMD3<Double>, axis: Int, others: [Int], probe: SolidProbe) -> Bool {
        let n = PrintSplitBuilder.unit(axis)
        let radius = footprintRadius + PrintSplitBuilder.skin
        let depths = [-reachBehind, 0, reachFront / 2, reachFront]
        for d in depths {
            let c = at + n * d
            if !probe.contains(c) { return false }
            for k in 0..<8 {
                let angle = Double(k) * .pi / 4
                var p = c
                p[others[0]] += cos(angle) * radius
                p[others[1]] += sin(angle) * radius
                if !probe.contains(p) { return false }
            }
        }
        return true
    }

    /// Whether a dovetail tab along `slide` at `at` has enough body round it: most of the points along its length, at its root and its tip.
    func dovetailFits(at: SIMD3<Double>, axis: Int, others: [Int], slide: Int, slideRange: (Double, Double), probe: SolidProbe) -> Bool {
        let n = PrintSplitBuilder.unit(axis)
        let across = others[1 - slide]
        let hw = size / 2 + depth * tan(PrintSplitBuilder.dovetailAngle)
        var inside = 0, total = 0
        for d in [-PrintSplitBuilder.skin, depth + clearance + PrintSplitBuilder.skin] {
            for s in 0..<5 {
                for offset in [-hw, 0, hw] {
                    var p = at + n * d
                    p[others[slide]] = slideRange.0 + (Double(s) + 0.5) * (slideRange.1 - slideRange.0) / 5
                    p[across] += offset
                    total += 1
                    if probe.contains(p) { inside += 1 }
                }
            }
        }
        return Double(inside) >= Double(total) * 0.7
    }

    // MARK: making

    private static func perpendicular(to n: SIMD3<Double>) -> SIMD3<Double> {
        let x = abs(n.x) < 0.9 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
        return simd_normalize(x - simd_dot(x, n) * n)
    }

    /// A body of revolution standing on `base`, along `dir`: `profile` is (radius, height) pairs from the axis at the base round to the axis at the top.
    static func revolved(base: SIMD3<Double>, dir: SIMD3<Double>, profile: [(Double, Double)], id: String) throws -> KBody {
        let n = simd_normalize(dir)
        let xa = perpendicular(to: n)
        let s = try KSketch(frame: Frame(origin: base, normal: simd_cross(xa, n), xAxis: xa))
        var points = [SIMD2<Double>(0, 0)] + profile.map { SIMD2($0.0, $0.1) }
        points.append(SIMD2(0, profile.last?.1 ?? 0))
        for i in points.indices {
            try s.addLine("l\(i)", points[i], points[(i + 1) % points.count])
        }
        guard let region = try s.buildRegions().first else { throw PrintSplitBuilder.SplitError(message: "A connector could not be drawn.") }
        return try KBody.revolve([s.profile(region.index)], axisOrigin: base, axisDirection: n, angle: 2 * .pi, featureID: id)
    }

    /// A round pin with a lead-in on its tip, `length` long, standing on `base` along `dir`.
    static func pin(base: SIMD3<Double>, dir: SIMD3<Double>, radius r: Double, length: Double, id: String) throws -> KBody {
        let chamfer = min(0.8, r / 3, length / 3)
        return try revolved(base: base, dir: dir, profile: [(r, 0), (r, length - chamfer), (r - chamfer, length)], id: id)
    }

    /// A plain round socket.
    static func rod(base: SIMD3<Double>, dir: SIMD3<Double>, radius r: Double, length: Double, id: String) throws -> KBody {
        try revolved(base: base, dir: dir, profile: [(r, 0), (r, length)], id: id)
    }

    static func square(base: SIMD3<Double>, dir: SIMD3<Double>, side: Double, length: Double, id: String) throws -> KBody {
        let n = simd_normalize(dir)
        return try KBody.primitive(.box(width: side, length: side, height: length), on: Frame(origin: base, normal: n, xAxis: perpendicular(to: n)), featureID: id)
    }

    /// A dovetail bar along `slide` (the axis index) through the plane point `at`: `halfRoot` wide each side at the cut plane, widening at
    /// `angle` to `depth` into the piece in front, and starting `lead` behind the plane. It runs from `from` to `to` along the slide axis.
    static func dovetailBar(at: SIMD3<Double>, axis: Int, slide: Int, across: Int, halfRoot: Double, depth: Double, lead: Double, from: Double, to: Double, id: String) throws -> KBody {
        let sv = PrintSplitBuilder.unit(slide), av = PrintSplitBuilder.unit(across), nv = PrintSplitBuilder.unit(axis)
        var origin = at
        origin[slide] = from
        let frame = Frame(origin: origin, normal: sv, xAxis: av)
        // The sketch's y axis is normal × x: it runs along the cut's normal one way or the other.
        let sign: Double = simd_dot(frame.yAxis, nv) >= 0 ? 1 : -1
        func width(_ t: Double) -> Double { halfRoot + t * tan(PrintSplitBuilder.dovetailAngle) }
        let t0 = -lead, t1 = depth
        let pts = [SIMD2(-width(t0), sign * t0), SIMD2(width(t0), sign * t0), SIMD2(width(t1), sign * t1), SIMD2(-width(t1), sign * t1)]
        let s = try KSketch(frame: frame)
        for i in pts.indices { try s.addLine("d\(i)", pts[i], pts[(i + 1) % pts.count]) }
        guard let region = try s.buildRegions().first else { throw PrintSplitBuilder.SplitError(message: "A dovetail could not be drawn.") }
        return try KBody.extrude([s.profile(region.index)], direction: sv, distance: to - from, featureID: id)
    }

    /// Makes the connector at `at` and files its solids with the pieces: pins to `behind`, sockets to `front`, and so on.
    func make(at: SIMD3<Double>, axis: Int, slideAxis: Int, acrossAxis: Int, slideRange: (Double, Double), behind: Int, front: Int, frontBody: KBody,
              adds: inout [[KBody]], takes: inout [[KBody]], dowels: inout [BodyResult], id: String) throws {
        let n = PrintSplitBuilder.unit(axis)
        let lead = PrintSplitBuilder.lead
        let r = size / 2
        switch kind {
        case .none:
            break
        case .pin where separate:
            // A pin of its own: a socket in each piece, `depth` deep, and the pin as long as the two together.
            takes[front].append(try Self.rod(base: at - n * lead, dir: n, radius: r + clearance, length: depth + clearance + lead, id: "socketF\(id)"))
            takes[behind].append(try Self.rod(base: at + n * lead, dir: -n, radius: r + clearance, length: depth + clearance + lead, id: "socketB\(id)"))
            let chamfer = min(0.8, r / 3)
            dowels.append(BodyResult(id: "pin", name: "Pin", body: try Self.revolved(base: .zero, dir: SIMD3(0, 0, 1),
                                     profile: [(r - chamfer, 0), (r, chamfer), (r, 2 * depth - chamfer), (r - chamfer, 2 * depth)], id: "pin\(id)")))
        case .key where separate:
            takes[front].append(try Self.square(base: at - n * lead, dir: n, side: size + 2 * clearance, length: depth + clearance + lead, id: "slotF\(id)"))
            takes[behind].append(try Self.square(base: at + n * lead, dir: -n, side: size + 2 * clearance, length: depth + clearance + lead, id: "slotB\(id)"))
            dowels.append(BodyResult(id: "key", name: "Key", body: try Self.square(base: .zero, dir: SIMD3(0, 0, 1), side: size, length: 2 * depth, id: "key\(id)")))
        case .pin:
            // The pin starts a little inside the piece behind (so the join is a clean overlap) and stands out in front.
            adds[behind].append(try Self.pin(base: at - n * lead, dir: n, radius: r, length: depth + lead, id: "pin\(id)"))
            takes[front].append(try Self.rod(base: at - n * lead, dir: n, radius: r + clearance, length: depth + clearance + lead, id: "socket\(id)"))
        case .key:
            adds[behind].append(try Self.square(base: at - n * lead, dir: n, side: size, length: depth + lead, id: "key\(id)"))
            takes[front].append(try Self.square(base: at - n * lead, dir: n, side: size + 2 * clearance, length: depth + clearance + lead, id: "slot\(id)"))
        case .dowel:
            let half = depth / 2
            takes[front].append(try Self.rod(base: at - n * lead, dir: n, radius: r + clearance, length: half + clearance + lead, id: "dowelsocketF\(id)"))
            takes[behind].append(try Self.rod(base: at + n * lead, dir: -n, radius: r + clearance, length: half + clearance + lead, id: "dowelsocketB\(id)"))
            let chamfer = min(0.8, r / 3)
            dowels.append(BodyResult(id: "dowel", name: "Dowel", body: try Self.revolved(base: .zero, dir: SIMD3(0, 0, 1),
                                     profile: [(r - chamfer, 0), (r, chamfer), (r, depth - chamfer), (r - chamfer, depth)], id: "dowel\(id)")))
        case .magnet:
            takes[front].append(try Self.rod(base: at - n * lead, dir: n, radius: r + clearance, length: depth + clearance + lead, id: "magnetF\(id)"))
            takes[behind].append(try Self.rod(base: at + n * lead, dir: -n, radius: r + clearance, length: depth + clearance + lead, id: "magnetB\(id)"))
        case .dovetail:
            // The tab is the piece in front's own material inside the dovetail, handed to the piece behind; the slot is the same shape, a
            // gap wider, cut from the piece in front, and open at both ends so the pieces slide together.
            let bar = try Self.dovetailBar(at: at, axis: axis, slide: slideAxis, across: acrossAxis, halfRoot: r, depth: depth, lead: 0,
                                           from: slideRange.0 - 1, to: slideRange.1 + 1, id: "tab\(id)")
            let tab = try bar.boolean(frontBody, SK_COMMON)
            guard !tab.isEmpty, tab.isValid else { throw PrintSplitBuilder.SplitError(message: "A dovetail tab could not be made.") }
            adds[behind].append(tab)
            let slot = try Self.dovetailBar(at: at, axis: axis, slide: slideAxis, across: acrossAxis,
                                            halfRoot: r + clearance / cos(PrintSplitBuilder.dovetailAngle), depth: depth + clearance, lead: lead,
                                            from: slideRange.0 - 1, to: slideRange.1 + 1, id: "slot\(id)")
            takes[front].append(slot)
        }
    }
}
