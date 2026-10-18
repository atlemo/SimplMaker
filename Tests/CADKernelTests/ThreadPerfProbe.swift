// Not tests of behaviour: timings for the thread code, to compare before and after a change to it.
//
// ThreadPerfProbe rebuilds a saved file from scratch (THREAD_PROBE_FILE=path, THREAD_PROBE_ROUNDS=n, default 2) and prints
// how long each feature took, and the volume, face count and a digest of the face names of every body at the end: the
// digest and volume must not change when the thread code is only made faster (THREAD_PROBE_NAMES=path writes the names).
// THREAD_PROBE_SUPPRESS=1 leaves the threads out, to see what the other features cost without them.
// ThreadColdProbe (THREAD_COLD_PROBE=1) times threads of sizes the kernel has not built before.
//
// Run with: THREAD_PROBE_FILE=... swift test --filter ThreadPerfProbe
// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import Foundation
import Testing
@testable import CADKernel

@Suite(.serialized) struct ThreadPerfProbe {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["THREAD_PROBE_FILE"] != nil))
    func rebuildAndTimeEachFeature() throws {
        let path = ProcessInfo.processInfo.environment["THREAD_PROBE_FILE"]!
        var doc = try CADDocument.decode(try #require(FileManager.default.contents(atPath: path)))
        if ProcessInfo.processInfo.environment["THREAD_PROBE_SUPPRESS"] != nil {  // what the later features cost without threads
            for i in doc.features.indices { if case .thread = doc.features[i].kind { doc.features[i].suppressed = true } }
        }
        for round in 1...(Int(ProcessInfo.processInfo.environment["THREAD_PROBE_ROUNDS"] ?? "") ?? 2) {
            final class Log: @unchecked Sendable { var marks: [(String, Date)] = [] }
            let log = Log()
            let r = Regenerator.regenerate(doc) { _, _, feature in log.marks.append((feature.name, Date())) }
            let end = Date()
            var line = "PROBE round \(round): total \(Int(r.duration * 1000)) ms\n"
            for (i, mark) in log.marks.enumerated() {
                let next = i + 1 < log.marks.count ? log.marks[i + 1].1 : end
                let ms = Int(next.timeIntervalSince(mark.1) * 1000)
                if ms >= 5 { line += "  \(mark.0): \(ms) ms\n" }
            }
            for b in r.bodies {
                // FNV-1a over the sorted face names: the same names (and so the same references from later features).
                var hash: UInt64 = 14695981039346656037
                for name in b.body.faceNames.sorted() { for byte in name.utf8 + [10] { hash = (hash ^ UInt64(byte)) &* 1099511628211 } }
                line += "  body \(b.id): volume \(b.body.volume) faces \(b.body.faceNames.count) valid \(b.body.isValid) names \(String(hash, radix: 16))\n"
                if let path = ProcessInfo.processInfo.environment["THREAD_PROBE_NAMES"], round == 1 {
                    try? b.body.faceNames.sorted().joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
                }
            }
            for (id, e) in r.errors { line += "  ERROR \(id): \(e)\n" }
            print(line)
        }
    }
}

/// Cold cost of a thread size: every call uses sizes the kernel has not built before.
@Suite(.serialized) struct ThreadColdProbe {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["THREAD_COLD_PROBE"] != nil))
    func newSizesEveryTime() throws {
        let (features, walls) = try ThreadTogetherTests.block(holes: [("6.8", -24), ("6.8", -8), ("6.8", 8), ("6.8", 24)])
        var doc = CADDocument()
        doc.features = features
        let drilled = try #require(Regenerator.regenerate(doc).body("b"))
        var line = "COLD PROBE\n"
        var salt = 0.0
        func fresh() -> [Double] { salt += 0.0013; return (0..<4).map { 8.0 + salt + Double($0) * 0.0007 } }
        for round in 1...3 {
            let diameters = fresh()
            let t0 = Date()
            let both = try drilled.threads(faces: walls.map(\.face), majorDiameters: diameters, pitches: [1.25, 1.25, 1.25, 1.25],
                                           length: nil, flipped: false, leftHanded: false, featureID: "th")
            line += "  round \(round): four new sizes together \(Int(Date().timeIntervalSince(t0) * 1000)) ms, valid \(both.isValid)\n"
            let again = fresh()
            var body = drilled
            let t1 = Date()
            for (n, wall) in walls.enumerated() {
                body = try body.thread(face: wall.face, majorDiameter: again[n], pitch: 1.25, length: nil, flipped: false,
                                       leftHanded: false, featureID: "th\(n)")
            }
            line += "  round \(round): four new sizes one by one \(Int(Date().timeIntervalSince(t1) * 1000)) ms\n"
            let t2 = Date()
            _ = try drilled.threads(faces: walls.map(\.face), majorDiameters: diameters, pitches: [1.25, 1.25, 1.25, 1.25],
                                    length: nil, flipped: false, leftHanded: false, featureID: "th")
            line += "  round \(round): the same sizes again \(Int(Date().timeIntervalSince(t2) * 1000)) ms\n"
        }
        print(line)
    }
}
