// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CADCore

@Suite struct ExpressionTests {
    func eval(_ s: String, _ kind: UnitKind = .length, _ vars: [String: Quantity] = [:]) throws -> Double {
        try Expressions.value(of: s, kind: kind) { name in
            guard let q = vars[name] else { throw ExpressionError("unknown \(name)") }
            return q
        }
    }

    @Test func arithmeticAndPrecedence() throws {
        #expect(try eval("1 + 2 * 3") == 7)
        #expect(try eval("(1 + 2) * 3") == 9)
        #expect(try eval("2 ^ 3 ^ 2", .none) == 512)
        #expect(try eval("-2 ^ 2", .none) == -4)
        #expect(try eval("10 / 4") == 2.5)
        #expect(try eval("1.5e1") == 15)
    }

    @Test func decimalCommas() throws {
        #expect(try eval("12,5") == 12.5)
        #expect(try eval("12,5 mm + 0,5") == 13)
        #expect(abs(try eval("1,5 in") - 38.1) < 1e-9)
        #expect(try eval("max(1, 5)") == 5, "with a space, the comma separates arguments")
        #expect(try eval("max(1,5 , 2)") == 2)
        #expect(throws: ExpressionError.self) { try eval("1,2,3") }
    }

    @Test func units() throws {
        #expect(try eval("1 in") == 25.4)
        #expect(try eval("2cm + 3 mm") == 23)
        #expect(abs(try eval("90", .angle) - .pi / 2) < 1e-12)       // bare number in angle field = degrees
        #expect(abs(try eval("1 rad", .angle) - 1) < 1e-12)
        #expect(try eval("w / 2 + 5", .length, ["w": .mm(60)]) == 35)  // bare 5 takes the unit of w
        #expect(throws: ExpressionError.self) { try eval("10 mm", .angle) }
        #expect(throws: ExpressionError.self) { try eval("1 mm + 1 deg") }
        #expect(throws: ExpressionError.self) { try eval("w mm", .length, ["w": .mm(1)]) }
    }

    @Test func functions() throws {
        #expect(abs(try eval("sin(30)", .none) - 0.5) < 1e-12)
        #expect(abs(try eval("atan(1)", .angle) - .pi / 4) < 1e-12)
        #expect(try eval("sqrt(a * a)", .length, ["a": .mm(7)]) == 7)
        #expect(try eval("max(3 mm, 1 cm, 2)") == 10)
        #expect(try eval("pi * 2", .none) == 2 * .pi)
    }

    @Test func errors() {
        #expect(throws: ExpressionError.self) { try eval("1 +") }
        #expect(throws: ExpressionError.self) { try eval("foo(1)") }
        #expect(throws: ExpressionError.self) { try eval("1 / 0") }
        #expect(throws: ExpressionError.self) { try eval("2 $ 3") }
    }

    @Test func parameterTable() {
        let v = ParameterEvaluator.evaluate([
            Parameter("hole", "depth / 4"),  // forward reference is fine
            Parameter("depth", "40 mm"),
            Parameter("angle", "45", unit: .angle),
            Parameter("count", "3", unit: .none),
            Parameter("a", "b + 1"), Parameter("b", "a * 2"),  // cycle
            Parameter("mm", "3"),  // reserved
        ])
        #expect(v.values["hole"]?.value == 10)
        #expect(abs((v.values["angle"]?.value ?? 0) - .pi / 4) < 1e-12)
        #expect(v.values["count"]?.value == 3)
        #expect(v.errors["a"]?.contains("circular") == true)
        #expect(v.errors["b"] != nil)
        #expect(v.errors["mm"] == "invalid name")
    }
}
