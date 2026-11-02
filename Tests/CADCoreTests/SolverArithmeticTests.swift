// The solver's linear algebra is written with unsafe buffers and index loops for speed; it has to give the very same numbers as the
// plain version, since every sketch's solved positions come from it.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
@testable import CADCore
import Foundation
import Testing

@Suite struct SolverArithmeticTests {
    /// The straightforward Cholesky solve the fast one replaced.
    private func reference(_ M: [Double], _ b: [Double], _ n: Int) -> [Double]? {
        var L = [Double](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in 0...i {
                var sum = M[i * n + j]
                for k in 0..<j { sum -= L[i * n + k] * L[j * n + k] }
                if i == j {
                    guard sum > 1e-300 else { return nil }
                    L[i * n + i] = sum.squareRoot()
                } else {
                    L[i * n + j] = sum / L[j * n + j]
                }
            }
        }
        var y = b
        for i in 0..<n {
            for k in 0..<i { y[i] -= L[i * n + k] * y[k] }
            y[i] /= L[i * n + i]
        }
        for i in stride(from: n - 1, through: 0, by: -1) {
            for k in (i + 1)..<n { y[i] -= L[k * n + i] * y[k] }
            y[i] /= L[i * n + i]
        }
        return y.allSatisfy(\.isFinite) ? y : nil
    }

    private struct Rng { var s: UInt64; mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) - 0.5 } }

    @Test func choleskyGivesTheSameBitsAsThePlainVersion() {
        var rng = Rng(s: 42)
        for n in [1, 2, 5, 17, 70, 101] {
            for trial in 0..<4 {
                // M = AᵀA + λI is symmetric positive definite; the last trial of each size is made singular on purpose
                let a = (0..<(n * n)).map { _ in rng.next() }
                var m = [Double](repeating: 0, count: n * n)
                for i in 0..<n { for j in 0..<n { for k in 0..<n { m[i * n + j] += a[k * n + i] * a[k * n + j] } } }
                if trial < 3 { for i in 0..<n { m[i * n + i] += 1e-3 } } else { for i in 0..<n { m[i * n + i] = -1 } }
                let b = (0..<n).map { _ in rng.next() }
                let fast = SketchSolver.choleskySolve(m, b, n), plain = reference(m, b, n)
                #expect((fast == nil) == (plain == nil), "n \(n) trial \(trial): both refuse a matrix that is not positive definite")
                if let fast, let plain { #expect(fast.map(\.bitPattern) == plain.map(\.bitPattern), "n \(n) trial \(trial)") }
            }
        }
    }
}
