// Screw threads: the common ISO metric and unified (inch) sizes, and the Thread feature that cuts
// one into a round face.
// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation

/// A family of 60° threads. Metric sizes are ISO 261/262; inch sizes are ASME B1.1.
public enum ThreadStandard: String, Codable, Hashable, Sendable, CaseIterable {
    case metric = "ISO Metric"
    case metricFine = "ISO Metric Fine"
    case unc = "UNC"
    case unf = "UNF"

    public var sizes: [ThreadSize] {
        switch self {
        case .metric: return ThreadSize.metric
        case .metricFine: return ThreadSize.metricFine
        case .unc: return ThreadSize.unc
        case .unf: return ThreadSize.unf
        }
    }

    public func size(_ name: String) -> ThreadSize? { sizes.first { $0.name == name } }

    public var isInch: Bool { self == .unc || self == .unf }
}

/// One thread size: its name ("M8x1.25", "1/4-20"), major diameter and pitch, in mm.
public struct ThreadSize: Hashable, Sendable {
    public var name: String
    public var diameter: Double
    public var pitch: Double

    /// The basic minor diameter, where a nut's crests are (ISO 68: 5/8 of the 60° triangle deep).
    public var minorDiameter: Double { diameter - 1.082531754731 * pitch }
    /// The usual tap drill: the major diameter less one pitch.
    public var tapDrill: Double { diameter - pitch }
    /// "M8 × 1.25", "1/4-20 UNC".
    public func label(_ standard: ThreadStandard) -> String {
        standard.isInch ? "\(name) \(standard.rawValue)" : name.replacingOccurrences(of: "x", with: " × ")
    }

    static func m(_ d: Double, _ p: Double) -> ThreadSize {
        ThreadSize(name: "M\(trim(d))x\(trim(p))", diameter: d, pitch: p)
    }

    /// An inch size: "1/4-20" from the diameter in inches and threads per inch.
    static func inch(_ name: String, _ d: Double, _ tpi: Double) -> ThreadSize {
        ThreadSize(name: "\(name)-\(trim(tpi))", diameter: d * 25.4, pitch: 25.4 / tpi)
    }

    private static func trim(_ x: Double) -> String {
        x == x.rounded() ? String(Int(x)) : String(format: "%g", x)
    }

    static let metric: [ThreadSize] = [
        m(1.6, 0.35), m(2, 0.4), m(2.5, 0.45), m(3, 0.5), m(3.5, 0.6), m(4, 0.7), m(5, 0.8), m(6, 1), m(8, 1.25),
        m(10, 1.5), m(12, 1.75), m(14, 2), m(16, 2), m(18, 2.5), m(20, 2.5), m(22, 2.5), m(24, 3), m(27, 3),
        m(30, 3.5), m(33, 3.5), m(36, 4), m(42, 4.5), m(48, 5),
    ]

    static let metricFine: [ThreadSize] = [
        m(5, 0.5), m(6, 0.75), m(8, 1), m(10, 1), m(10, 1.25), m(12, 1.25), m(12, 1.5), m(14, 1.5), m(16, 1.5),
        m(18, 1.5), m(20, 1.5), m(20, 2), m(22, 1.5), m(24, 1.5), m(24, 2), m(27, 2), m(30, 2), m(33, 2),
        m(36, 3), m(42, 3), m(48, 3),
    ]

    static let unc: [ThreadSize] = [
        inch("#1", 0.073, 64), inch("#2", 0.086, 56), inch("#3", 0.099, 48), inch("#4", 0.112, 40),
        inch("#5", 0.125, 40), inch("#6", 0.138, 32), inch("#8", 0.164, 32), inch("#10", 0.190, 24),
        inch("#12", 0.216, 24), inch("1/4", 0.25, 20), inch("5/16", 0.3125, 18), inch("3/8", 0.375, 16),
        inch("7/16", 0.4375, 14), inch("1/2", 0.5, 13), inch("9/16", 0.5625, 12), inch("5/8", 0.625, 11),
        inch("3/4", 0.75, 10), inch("7/8", 0.875, 9), inch("1", 1, 8), inch("1-1/8", 1.125, 7),
        inch("1-1/4", 1.25, 7), inch("1-3/8", 1.375, 6), inch("1-1/2", 1.5, 6),
    ]

    static let unf: [ThreadSize] = [
        inch("#0", 0.060, 80), inch("#1", 0.073, 72), inch("#2", 0.086, 64), inch("#3", 0.099, 56),
        inch("#4", 0.112, 48), inch("#5", 0.125, 44), inch("#6", 0.138, 40), inch("#8", 0.164, 36),
        inch("#10", 0.190, 32), inch("#12", 0.216, 28), inch("1/4", 0.25, 28), inch("5/16", 0.3125, 24),
        inch("3/8", 0.375, 24), inch("7/16", 0.4375, 20), inch("1/2", 0.5, 20), inch("9/16", 0.5625, 18),
        inch("5/8", 0.625, 18), inch("3/4", 0.75, 16), inch("7/8", 0.875, 14), inch("1", 1, 12),
        inch("1-1/8", 1.125, 12), inch("1-1/4", 1.25, 12), inch("1-1/2", 1.5, 12),
    ]

    /// The size that suits a round face `diameter` mm across, from the metric and UNC lists (metric
    /// when both fit as well): for a shaft, the one as wide as it; for a hole, one it could be tapped
    /// for (between the thread's minor and major diameters) whose tap drill or size it matches.
    public static func best(forDiameter diameter: Double, hole: Bool) -> (ThreadStandard, ThreadSize)? {
        func error(_ s: ThreadSize) -> Double {
            guard hole else { return abs(s.diameter - diameter) }
            let tappable = diameter >= s.minorDiameter - 0.05 && diameter <= s.diameter + 0.05
            // Drawn at the thread's own size, or at the tap drill (the own size wins a tie: a Ø5 hole is an M5, not
            // the M6 whose tap drill it also is).
            let match = min(abs(s.diameter - diameter), abs(s.tapDrill - diameter) + 0.01)
            return tappable ? match : 1000 + abs(s.diameter - diameter)
        }
        func nearest(_ standard: ThreadStandard) -> (ThreadStandard, ThreadSize, Double)? {
            standard.sizes.map { (standard, $0, error($0)) }.min { $0.2 < $1.2 }
        }
        guard let metric = nearest(.metric) else { return nil }
        guard let inch = nearest(.unc), inch.2 < metric.2 - 0.01 else { return (metric.0, metric.1) }
        return (inch.0, inch.1)
    }
}

/// How a thread's tolerance offset is measured.
public enum ThreadToleranceUnit: String, Codable, Hashable, Sendable, CaseIterable {
    /// A share of the thread's nominal major diameter (unitless: 2 = 2 %).
    case percent = "Percent"
    /// A length on the diameter, in mm.
    case distance = "Distance"
}

/// A 3D-printing material with a suggested tolerance offset. Printed threads come out off size (plastic
/// shrinks as it cools, and printed holes come out tight), so the modeled thread is made a little larger.
/// These are starting points that combine the material's shrinkage with the usual undersize of printed
/// holes; print a test piece and adjust.
public enum ThreadMaterial: String, Codable, Hashable, Sendable, CaseIterable {
    case petg = "PETG"
    case abs = "ABS"
    case asa = "ASA"
    case nylon = "Nylon"

    /// The suggested offset, in percent of the major diameter.
    public var percent: Double {
        switch self {
        case .petg: return 2
        case .asa: return 3
        case .abs: return 4
        case .nylon: return 6
        }
    }
}

/// One thread's standard and size, for a face of a thread feature that is not threaded like the first.
public struct ThreadSpec: Codable, Hashable, Sendable {
    public var standard: ThreadStandard
    public var size: String
    public init(standard: ThreadStandard, size: String) { self.standard = standard; self.size = size }
}

/// A screw thread cut into a round face: external on a shaft, internal in a hole (the face says
/// which). The face is sized to the thread first: a shaft turned to its major diameter, a hole
/// bored or filled to its minor one.
public struct ThreadFeature: Codable, Hashable, Sendable {
    public var face: FaceRef
    /// More round faces (other holes), threaded with the same length, direction and tolerance offset.
    public var moreFaces: [FaceRef]
    /// The standard and size of `face` (and of every other face, unless `moreSpecs` says otherwise).
    public var standard: ThreadStandard
    /// The size's name in the standard ("M8x1.25", "1/4-20").
    public var size: String
    /// The standard and size of each of `moreFaces`, in step with it, for holes of different sizes picked together;
    /// empty when they are all threaded like `face`.
    public var moreSpecs: [ThreadSpec]
    /// How far along the face it runs; nil = all of it.
    public var length: String?
    /// Starts from the other end (by default the end with air beyond it: a shaft's tip, a hole's mouth).
    public var flipped: Bool
    public var leftHanded: Bool
    /// A tolerance offset: how much larger (or, if negative, smaller) the thread is modeled than its
    /// nominal size, on its major and minor diameters alike (the pitch stays), for printing. An
    /// expression in `toleranceUnit`; nil = none.
    public var tolerance: String?
    public var toleranceUnit: ThreadToleranceUnit
    /// The material preset the offset was taken from, for the inspector to show; editing the value clears it.
    public var toleranceMaterial: ThreadMaterial?

    /// Every face the thread is cut into, `face` first.
    public var faces: [FaceRef] { [face] + moreFaces }

    public init(face: FaceRef, moreFaces: [FaceRef] = [], moreSpecs: [ThreadSpec] = [], standard: ThreadStandard = .metric,
                size: String = "M6x1", length: String? = nil, flipped: Bool = false, leftHanded: Bool = false, tolerance: String? = nil,
                toleranceUnit: ThreadToleranceUnit = .percent, toleranceMaterial: ThreadMaterial? = nil) {
        self.face = face; self.moreFaces = moreFaces; self.moreSpecs = moreSpecs; self.standard = standard; self.size = size
        self.length = length
        self.flipped = flipped; self.leftHanded = leftHanded; self.tolerance = tolerance; self.toleranceUnit = toleranceUnit
        self.toleranceMaterial = toleranceMaterial
    }

    /// The standard and size of the face at `index` in `faces`.
    public func spec(at index: Int) -> ThreadSpec {
        index > 0 && index - 1 < moreSpecs.count ? moreSpecs[index - 1] : ThreadSpec(standard: standard, size: size)
    }

    /// Sets the standard and size of the face at `index` in `faces`; the specs are kept only while they differ.
    public mutating func setSpec(_ spec: ThreadSpec, at index: Int) {
        var all = (0..<faces.count).map { self.spec(at: $0) }
        all[index] = spec
        standard = all[0].standard; size = all[0].size
        moreSpecs = all.dropFirst().contains { $0 != all[0] } ? Array(all.dropFirst()) : []
    }

    /// The faces are not all threaded in one size.
    public var isMixed: Bool { moreSpecs.contains { $0 != ThreadSpec(standard: standard, size: size) } }

    /// The major diameter to model, mm: the size's own, plus the tolerance offset.
    public func modeledDiameter(of size: ThreadSize, _ parameters: ParameterValues) throws -> Double {
        guard let tolerance else { return size.diameter }
        switch toleranceUnit {
        case .percent: return size.diameter * (1 + (try parameters.value(of: tolerance, kind: .none)) / 100)
        case .distance: return size.diameter + (try parameters.value(of: tolerance, kind: .length))
        }
    }

    // Files from before several faces can share a thread have no `moreFaces`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        face = try c.decode(FaceRef.self, forKey: .face)
        moreFaces = try c.decodeIfPresent([FaceRef].self, forKey: .moreFaces) ?? []
        moreSpecs = try c.decodeIfPresent([ThreadSpec].self, forKey: .moreSpecs) ?? []
        standard = try c.decode(ThreadStandard.self, forKey: .standard)
        size = try c.decode(String.self, forKey: .size)
        length = try c.decodeIfPresent(String.self, forKey: .length)
        flipped = try c.decode(Bool.self, forKey: .flipped)
        leftHanded = try c.decode(Bool.self, forKey: .leftHanded)
        // Files from before the tolerance offset have neither key.
        tolerance = try c.decodeIfPresent(String.self, forKey: .tolerance)
        toleranceUnit = try c.decodeIfPresent(ThreadToleranceUnit.self, forKey: .toleranceUnit) ?? .percent
        toleranceMaterial = try c.decodeIfPresent(ThreadMaterial.self, forKey: .toleranceMaterial)
    }
}
