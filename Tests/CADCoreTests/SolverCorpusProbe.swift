// Not a test of behaviour: solves every sketch of the saved files in a folder, as stored and with the length dimensions made 25 %
// larger, and writes status, iterations, time and the solved positions to a JSON file. Run before and after a change to the solver
// and compare the two files (scripts/compare-solver-probe.py). Off unless SOLVER_PROBE_OUT is set; SOLVER_PROBE_DIR names the folder.
// Copyright © 2026 Atle Mo. All rights reserved.
@testable import CADCore
import Foundation
import Testing

@Suite struct SolverCorpusProbe {
    struct Row: Codable {
        var file: String, sketch: String, scenario: String
        var status: String, iterations: Int, seconds: Double, dof: Int, residual: Double
        var points: [String: [Double]]
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SOLVER_PROBE_OUT"] != nil))
    func solveEverySketchOfTheFolder() throws {
        let env = ProcessInfo.processInfo.environment
        let dir = URL(fileURLWithPath: env["SOLVER_PROBE_DIR"] ?? NSHomeDirectory() + "/Documents/SimplCAD")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".simplmaker") || $0.hasSuffix(".simplcad") }.sorted()
        var rows: [Row] = []
        for name in files {
            guard let data = FileManager.default.contents(atPath: dir.appendingPathComponent(name).path),
                  let doc = try? CADDocument.decode(data) else { continue }
            let params = ParameterEvaluator.evaluate(doc.parameters)
            for feature in doc.features {
                guard case .sketch(let sf) = feature.kind else { continue }
                var values: [EntityID: Double] = [:]
                for d in sf.sketch.dimensions { if let v = try? params.value(of: d.expression, kind: d.unitKind) { values[d.id] = v } }
                for scenario in ["stored", "longer"] {
                    var vals = values
                    if scenario == "longer" { for d in sf.sketch.dimensions where d.unitKind == .length { vals[d.id] = vals[d.id].map { $0 * 1.25 } } }
                    var sketch = sf.sketch
                    let t0 = Date()
                    let r = SketchSolver.solveLocally(&sketch, dimensionValues: vals)
                    let seconds = Date().timeIntervalSince(t0)
                    rows.append(Row(file: name, sketch: feature.id, scenario: scenario,
                                    status: r.status == .solved ? "solved" : "failed", iterations: r.iterations, seconds: seconds,
                                    dof: r.degreesOfFreedom, residual: r.maxResidual,
                                    points: Dictionary(sketch.points.map { ($0.id, [$0.x, $0.y]) }, uniquingKeysWith: { a, _ in a })))
                }
            }
        }
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        try enc.encode(rows).write(to: URL(fileURLWithPath: env["SOLVER_PROBE_OUT"]!))
        let solved = rows.filter { $0.status == "solved" }.count
        print("PROBE: \(rows.count) solves in \(files.count) files, \(solved) solved, \(rows.map(\.iterations).reduce(0, +)) iterations, "
              + "\(String(format: "%.2f", rows.map(\.seconds).reduce(0, +))) s")
    }
}
