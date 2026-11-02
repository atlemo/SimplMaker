// A second pair of eyes on a part meant to be printed: what is likely to go wrong that the numbers of a single feature do not
// show. It reads the built bodies (faces, sizes) and the feature list, and says what it finds; it never changes anything. The checks
// are heuristics on flat faces and are worded as such.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import simd

struct DesignFinding: Encodable, Equatable {
    /// "error", "warning" or "note".
    var severity: String
    var code: String
    var message: String
    /// The bodies, faces or features it is about.
    var about: [String] = []
    var fix: String?
}

struct DesignCheckResult: Encodable, Equatable {
    var success = true
    var documentId: String
    var revision: Int
    var summary: String
    var findings: [DesignFinding]
    /// What was checked against.
    var bed: [Double]
    var minWall: Double
}

enum DesignChecker {
    struct BodyData {
        var id: String
        var valid: Bool
        var min: [Double]
        var max: [Double]
        var faces: [FaceInfo]
    }

    /// Flat faces only: their normal, centre and box are what the checks use.
    private struct Flat: Equatable {
        var id: String
        var body: String
        var n: SIMD3<Double>
        var c: SIMD3<Double>
        var lo: SIMD3<Double>
        var hi: SIMD3<Double>
        var area: Double
    }

    private static func v(_ a: [Double]) -> SIMD3<Double> { a.count == 3 ? SIMD3(a[0], a[1], a[2]) : .zero }

    private static func flats(_ body: BodyData) -> [Flat] {
        body.faces.compactMap { f in
            guard f.shape == "plane", let d = f.direction, d.count == 3 else { return nil }
            return Flat(id: f.id, body: body.id, n: v(d), c: v(f.center), lo: v(f.boundsMin), hi: v(f.boundsMax), area: f.area)
        }
    }

    private static func boxesOverlap(_ a: Flat, _ b: Flat, slack: Double) -> Bool {
        (0..<3).allSatisfy { a.lo[$0] - slack <= b.hi[$0] && b.lo[$0] - slack <= a.hi[$0] }
    }

    static func num(_ x: Double) -> String { AIValues.number((x * 100).rounded() / 100) }

    static func check(bodies: [BodyData], errors: [(feature: String, message: String)], parameterCount: Int, fixedSizes: [String], featureCount: Int,
                      bed: [Double], minWall: Double) -> [DesignFinding] {
        var out: [DesignFinding] = []

        for e in errors {
            out.append(DesignFinding(severity: "error", code: "FEATURE_ERROR", message: "\(e.feature) does not build: \(e.message)", about: [e.feature],
                                     fix: "Fix or remove it before anything else."))
        }
        for b in bodies where !b.valid {
            out.append(DesignFinding(severity: "error", code: "INVALID_BODY", message: "\(b.id) is not a valid solid, so it may not slice or export correctly.", about: [b.id],
                                     fix: "Look for features that only touch (make them overlap by 0.4 mm or more) or sliver faces from a fillet that is almost as big as its faces."))
        }

        // Parameters: the user will want to change sizes later.
        if parameterCount == 0 && featureCount >= 3 {
            out.append(DesignFinding(severity: "warning", code: "NO_PARAMETERS",
                                     message: "The part has no named parameters: every size is a fixed number, so resizing means editing many features.",
                                     fix: "Name the dimensions that matter with set_parameter and make the features use them (modify_feature with expressions such as \"width - 2 * wall\"), or rebuild with parameters from the start."))
        } else if fixedSizes.count >= 4 && Double(fixedSizes.count) > 0.5 * Double(fixedSizes.count + parameterCount) {
            out.append(DesignFinding(severity: "note", code: "MANY_FIXED_SIZES",
                                     message: "\(fixedSizes.count) sizes are fixed numbers although the part has parameters, for example \(fixedSizes.prefix(3).joined(separator: ", ")).",
                                     about: Array(fixedSizes.prefix(6)), fix: "Tie the ones the user may want to change to a parameter."))
        }

        // The bed.
        let bedSorted = bed.sorted()
        for b in bodies where b.min.count == 3 && b.max.count == 3 {
            let size = (0..<3).map { b.max[$0] - b.min[$0] }
            if zip(size, bed).allSatisfy({ $0 <= $1 + 1e-6 }) { continue }
            if zip(size.sorted(), bedSorted).allSatisfy({ $0 <= $1 + 1e-6 }) {
                out.append(DesignFinding(severity: "note", code: "NEEDS_ROTATING", message: "\(b.id) is \(size.map(num).joined(separator: " × ")) mm: it fits a \(bed.map(num).joined(separator: " × ")) mm bed only if turned.", about: [b.id]))
            } else {
                out.append(DesignFinding(severity: "warning", code: "TOO_BIG", message: "\(b.id) is \(size.map(num).joined(separator: " × ")) mm: it does not fit a \(bed.map(num).joined(separator: " × ")) mm bed in any orientation.",
                                         about: [b.id], fix: "Split it into parts that fit (a joint or a dovetail between them), make it smaller with a scale, or tell the user the bed size you assumed."))
            }
        }

        // Where it stands: a body that floats or sinks is not in a print position.
        if bodies.count == 1, let b = bodies.first, b.min.count == 3, abs(b.min[2]) > 0.5 {
            out.append(DesignFinding(severity: "note", code: "OFF_THE_BED", message: "\(b.id) starts at z = \(num(b.min[2])) mm, not on the build plane z = 0.", about: [b.id],
                                     fix: "Fine for a model; for printing, lay it on its flattest face (create_move with dz)."))
        }

        // Overhangs, in the orientation as modelled and turned upside down: the better one is named.
        for b in bodies where b.min.count == 3 {
            let list = flats(b)
            func area(upsideDown: Bool) -> (total: Double, faces: [Flat]) {
                let bed = upsideDown ? b.max[2] : b.min[2]
                let hanging = list.filter { f in
                    let down = upsideDown ? f.n.z : -f.n.z
                    let onBed = upsideDown ? f.lo.z >= bed - 0.01 : f.hi.z <= bed + 0.01
                    return down > 0.72 && !onBed && f.area > 2  // steeper than 45° (a 45° chamfer prints without support)
                }
                return (hanging.reduce(0) { $0 + $1.area }, hanging)
            }
            let up = area(upsideDown: false), down = area(upsideDown: true)
            let best = down.total < up.total * 0.5 ? down : up
            if best.total > 2 {
                let flipped = best.faces == down.faces && down.total < up.total * 0.5
                let worst = best.faces.sorted { $0.area > $1.area }.prefix(4)
                // A level roof whose shorter side is 5 mm or less bridges without support.
                let bridge = worst.allSatisfy { f in abs(f.n.z) > 0.99 && min(f.hi.x - f.lo.x, f.hi.y - f.lo.y) <= 5 }
                out.append(DesignFinding(
                    severity: bridge ? "note" : "warning", code: bridge ? "SHORT_BRIDGES" : "OVERHANG",
                    message: "\(b.id) printed \(flipped ? "upside down" : "as modelled") has \(num(best.total)) mm² of downward-facing flat faces that are not on the bed" + (flipped ? " (as modelled it would have \(num(up.total)) mm²)" : "") + (bridge ? "; they are short enough to bridge." : "; they need support or a 45° chamfer."),
                    about: [b.id] + worst.map(\.id),
                    fix: bridge ? nil : "Make the underside a 45° chamfer (create_chamfer), turn the part so a large flat face is down, or tell the user to print with supports."))
            } else if down.total < up.total * 0.5, up.total > 2 {
                out.append(DesignFinding(severity: "note", code: "PRINT_ORIENTATION", message: "\(b.id) should be printed upside down: \(num(up.total)) mm² of overhang as modelled, none turned over.", about: [b.id]))
            }
        }

        // Thin walls, and gaps: flat faces facing away from each other (material between) or toward each other (air between).
        for b in bodies {
            let list = flats(b)
            var walls: [(Double, Flat, Flat)] = []
            var gaps: [(Double, Flat, Flat)] = []
            for i in 0..<list.count {
                for j in (i + 1)..<list.count {
                    let a = list[i], c = list[j]
                    guard simd_dot(a.n, c.n) < -0.999 else { continue }
                    let d = simd_dot(c.c - a.c, c.n)  // > 0: c is beyond a on c's outward side: material lies between
                    if d > 0.01, d < minWall, boxesOverlap(a, c, slack: d) { walls.append((d, a, c)) }
                    if d < -0.01, -d < 0.15, boxesOverlap(a, c, slack: -d) { gaps.append((-d, a, c)) }
                }
            }
            for (d, a, c) in walls.sorted(by: { $0.0 < $1.0 }).prefix(4) {
                out.append(DesignFinding(severity: "warning", code: "THIN_WALL", message: "\(b.id) is \(num(d)) mm thick between two faces (less than \(num(minWall)) mm): a 0.4 mm nozzle makes this weak or leaves it out.",
                                         about: [a.id, c.id], fix: "Thicken it to \(num(minWall)) mm or more (wall parameter), or accept it if it is decoration."))
            }
            for (d, a, c) in gaps.sorted(by: { $0.0 < $1.0 }).prefix(3) {
                out.append(DesignFinding(severity: "warning", code: "NARROW_GAP", message: "\(b.id) has a gap of \(num(d)) mm between two faces: it will fuse shut when printed.", about: [a.id, c.id],
                                         fix: "Open it to 0.2 mm or more, or close it if it is not meant to be a gap."))
            }
        }

        // The fit between separate bodies: the smallest clearances.
        if bodies.count > 1 {
            var fits: [(Double, Flat, Flat)] = []
            let all = bodies.map(flats)
            for i in 0..<all.count {
                for j in (i + 1)..<all.count {
                    for a in all[i] {
                        for c in all[j] where simd_dot(a.n, c.n) < -0.999 {
                            let g = simd_dot(c.c - a.c, a.n)  // > 0: c lies in front of a: they face each other with air between
                            if g > 0.01, g < 1.0, boxesOverlap(a, c, slack: g) { fits.append((g, a, c)) }
                        }
                    }
                }
            }
            if let tightest = fits.min(by: { $0.0 < $1.0 }) {
                let g = tightest.0
                let verdict = g < 0.1 ? "too tight: it will fuse or need sanding" : g < 0.15 ? "a tight press fit" : g <= 0.3 ? "a snug fit" : "loose"
                out.append(DesignFinding(severity: g < 0.1 ? "warning" : "note", code: "CLEARANCE",
                                         message: "The closest flat faces of two different bodies are \(num(g)) mm apart (\(verdict)): \(tightest.1.body) and \(tightest.2.body).",
                                         about: [tightest.1.id, tightest.2.id], fix: g < 0.1 ? "Make the clearance 0.2 mm per side for FDM." : nil))
            }
        }

        let rank = ["error": 0, "warning": 1, "note": 2]
        return Array(out.sorted { (rank[$0.severity] ?? 3) < (rank[$1.severity] ?? 3) }.prefix(24))
    }
}

extension CADService {
    func checkDesign(documentID: String?, bed: [Double]?, minWall: Double?) async throws -> DesignCheckResult {
        let bedSize = bed ?? [220, 220, 250]
        guard bedSize.count == 3, bedSize.allSatisfy({ $0 > 10 && $0 < 5000 }) else {
            throw AIError(.invalidArguments, "bed must be three sizes [x, y, z] in mm, for example [220, 220, 250].")
        }
        let wall = minWall ?? 1.2
        guard wall > 0.1, wall < 20 else { throw AIError(.invalidArguments, "min_wall must be between 0.1 and 20 mm.") }
        let (id, model) = try resolve(documentID)
        await model.rebuilt()
        let infos = bodies(of: model)
        var data: [DesignChecker.BodyData] = []
        for info in infos {
            let detail = try? await getBody(documentID: id, bodyID: info.id)
            data.append(DesignChecker.BodyData(id: info.id, valid: info.isValid, min: info.boundsMin, max: info.boundsMax, faces: detail?.faces ?? []))
        }
        let doc = model.document
        let errors = doc.features.compactMap { f in model.result?.errors[f.id].map { (f.name, $0) } }
        var fixed: [String] = []
        for f in doc.features {
            for spec in FeatureFields.specs(for: f.kind) where spec.unit == .length && spec.positive {
                if let text = spec.read(f.kind), !DocumentModel.isParametric(text) { fixed.append("\(f.name).\(spec.name)") }
            }
        }
        let findings = DesignChecker.check(bodies: data, errors: errors.map { (feature: $0.0, message: $0.1) }, parameterCount: doc.parameters.count, fixedSizes: fixed,
                                           featureCount: doc.features.count, bed: bedSize, minWall: wall)
        let errorsN = findings.filter { $0.severity == "error" }.count, warnings = findings.filter { $0.severity == "warning" }.count
        let notes = findings.filter { $0.severity == "note" }.count
        let summary = findings.isEmpty ? "No problems found." : [errorsN > 0 ? "\(errorsN) error\(errorsN == 1 ? "" : "s")" : nil, warnings > 0 ? "\(warnings) warning\(warnings == 1 ? "" : "s")" : nil,
                                                              notes > 0 ? "\(notes) note\(notes == 1 ? "" : "s")" : nil].compactMap { $0 }.joined(separator: ", ")
        return DesignCheckResult(documentId: id, revision: model.documentRevision, summary: summary, findings: findings, bed: bedSize, minWall: wall)
    }

    func designGuide(topic: String?) throws -> JSONValue {
        guard let topic, !topic.isEmpty else {
            return ["topics": .array(AIDesignGuide.topics.map { ["id": .string($0.id), "title": .string($0.title), "when": .string($0.summary)] }),
                    "how_to_use": "Call get_design_guide again with one topic id. Read \"workflow\" and \"parameters\" first for any build."]
        }
        guard let found = AIDesignGuide.topic(topic) else {
            throw AIError(.invalidArguments, "There is no guide topic \"\(topic)\".", reason: "The topics are: \(AIDesignGuide.topics.map(\.id).joined(separator: ", ")).")
        }
        return ["topic": .string(found.id), "title": .string(found.title), "guide": .string(found.body)]
    }
}
