// The Split workspace's settings: cut a body that is too big for the printer into pieces that fit it, with connectors (pins, keys,
// dovetails, dowels or magnet pockets) so the pieces go back together after printing. Like a mold, a split is not a feature of the
// timeline: it is linked to a body, lives beside the features (`CADDocument.printSplits`) and follows the body when the part changes.
// The pieces are worked out from it (PrintSplitBuilder, in CADKernel) and never stored.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// MARK: - Printers

/// A printer's build volume, as its maker publishes it (mm). The list is a starting point: a printer that is not in it is a
/// custom volume.
public struct PrinterPreset: Identifiable, Hashable, Sendable {
    public var id: String
    public var maker: String
    public var name: String
    /// The build volume: x across, y deep, z high.
    public var volume: SIMD3<Double>

    public init(_ id: String, _ maker: String, _ name: String, _ x: Double, _ y: Double, _ z: Double) {
        self.id = id; self.maker = maker; self.name = name; volume = SIMD3(x, y, z)
    }

    /// The id the setup holds when the volume is typed in.
    public static let customID = "custom"
    public static let defaultID = "bambu-256"

    public var title: String { "\(maker) \(name)" }
    public var sizeText: String { "\(Self.number(volume.x)) × \(Self.number(volume.y)) × \(Self.number(volume.z)) mm" }

    static func number(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }

    public static func preset(_ id: String) -> PrinterPreset? { catalog.first { $0.id == id } }

    /// Popular printers, grouped by maker. Where several models share a volume they share a row.
    public static let catalog: [PrinterPreset] = [
        PrinterPreset("bambu-256", "Bambu Lab", "X1C · P1S · P2S · A1", 256, 256, 256),
        PrinterPreset("bambu-a1-mini", "Bambu Lab", "A1 mini", 180, 180, 180),
        PrinterPreset("bambu-h2d", "Bambu Lab", "H2D", 350, 320, 325),
        PrinterPreset("bambu-h2s", "Bambu Lab", "H2S", 340, 320, 340),
        PrinterPreset("prusa-mk4", "Prusa", "MK4 · MK4S", 250, 210, 220),
        PrinterPreset("prusa-mk3", "Prusa", "MK3S+", 250, 210, 210),
        PrinterPreset("prusa-core-one", "Prusa", "Core One", 250, 220, 270),
        PrinterPreset("prusa-mini", "Prusa", "MINI+", 180, 180, 180),
        PrinterPreset("prusa-xl", "Prusa", "XL", 360, 360, 360),
        PrinterPreset("creality-ender3", "Creality", "Ender-3 V2 · V3 · K1 · K1C", 220, 220, 250),
        PrinterPreset("creality-k1-max", "Creality", "K1 Max", 300, 300, 300),
        PrinterPreset("creality-cr10", "Creality", "CR-10", 300, 300, 400),
        PrinterPreset("creality-ender5-max", "Creality", "Ender-5 Max", 400, 400, 400),
        PrinterPreset("elegoo-neptune4", "Elegoo", "Neptune 4 · Neptune 4 Pro", 225, 225, 265),
        PrinterPreset("elegoo-centauri", "Elegoo", "Centauri Carbon", 256, 256, 256),
        PrinterPreset("elegoo-neptune4-max", "Elegoo", "Neptune 4 Max", 420, 420, 480),
        PrinterPreset("anycubic-kobra2", "Anycubic", "Kobra 2 · Kobra 2 Pro", 220, 220, 250),
        PrinterPreset("anycubic-kobra3", "Anycubic", "Kobra 3 · Kobra S1", 250, 250, 260),
        PrinterPreset("anycubic-kobra2-max", "Anycubic", "Kobra 2 Max", 420, 420, 500),
        PrinterPreset("sovol-sv06", "Sovol", "SV06", 220, 220, 250),
        PrinterPreset("sovol-sv08", "Sovol", "SV08", 350, 350, 345),
        PrinterPreset("artillery-x3-plus", "Artillery", "Sidewinder X3 Plus", 300, 300, 400),
        PrinterPreset("flashforge-5m", "Flashforge", "Adventurer 5M", 220, 220, 220),
        PrinterPreset("ultimaker-s5", "UltiMaker", "S5", 330, 240, 300),
        PrinterPreset("voron-350", "Voron", "2.4 (350 mm)", 350, 350, 330),
        PrinterPreset("elegoo-saturn4", "Elegoo", "Saturn 4 Ultra (resin)", 218, 123, 220),
        PrinterPreset("formlabs-form4", "Formlabs", "Form 4 (resin)", 200, 125, 210),
    ]

    /// The makers, in the order the catalog lists them.
    public static var makers: [String] {
        var seen: [String] = []
        for p in catalog where !seen.contains(p.maker) { seen.append(p.maker) }
        return seen
    }
}

// MARK: - Connectors and fit

/// How two pieces are joined where they were cut.
public enum ConnectorKind: String, Codable, CaseIterable, Sendable {
    /// A flat cut: the pieces are glued.
    case none
    /// A round pin printed on one piece, in a round socket in the other.
    case pin
    /// A square key printed on one piece, in a square socket in the other.
    case key
    /// A dovetail tab printed on one piece that slides into a slot in the other: it locks the pieces against being pulled apart.
    case dovetail
    /// A socket in each piece and a loose dowel (printed apart, or a bought rod) that joins them.
    case dowel
    /// A pocket in each piece for a round magnet.
    case magnet

    public var title: String {
        switch self {
        case .none: "Flat (glue)"
        case .pin: "Round pin"
        case .key: "Square key"
        case .dovetail: "Dovetail"
        case .dowel: "Loose dowel"
        case .magnet: "Magnet pocket"
        }
    }

    public var help: String {
        switch self {
        case .none: "No connectors: the pieces are cut flat and glued"
        case .pin: "A round pin on one piece, a socket in the other. Quick to print and easy to line up"
        case .key: "A square key on one piece, a socket in the other. It also stops the pieces turning against each other"
        case .dovetail: "A dovetail tab slides into a slot: the pieces lock sideways as well as line up. Slide them together"
        case .dowel: "A socket in both pieces and a separate dowel (printed apart, or a rod you buy) that joins them"
        case .magnet: "A pocket in each piece for a round magnet: the pieces can be taken apart again"
        }
    }

    public var symbol: String {
        switch self {
        case .none: "minus"
        case .pin: "circle-dot"
        case .key: "square"
        case .dovetail: "pyramid"
        case .dowel: "cylinder"
        case .magnet: "magnet"
        }
    }

    /// What the size and the length of this kind mean, for the labels of the two fields.
    public var sizeLabel: String {
        switch self {
        case .none: "Size"
        case .pin, .dowel: "Diameter"
        case .key: "Width"
        case .dovetail: "Width at the root"
        case .magnet: "Magnet diameter"
        }
    }
    public var lengthLabel: String {
        switch self {
        case .none, .pin, .key: "Length"
        case .dovetail: "Depth"
        case .dowel: "Dowel length"
        case .magnet: "Magnet thickness"
        }
    }

    /// The size and length a kind starts with when it is chosen (mm): 6 mm pins, 6 × 3 mm magnets, a 10 mm dovetail.
    public var defaults: (size: String, length: String) {
        switch self {
        case .none, .pin: ("6 mm", "8 mm")
        case .key: ("6 mm", "8 mm")
        case .dovetail: ("10 mm", "6 mm")
        case .dowel: ("6 mm", "16 mm")
        case .magnet: ("6 mm", "3 mm")
        }
    }

    /// Whether the connector sticks out of one piece (so the piece is longer by it, and the cuts have to leave room).
    public var protrudes: Bool { self == .pin || self == .key || self == .dovetail }

    /// Whether the connector can be a part of its own instead of being printed on a piece: a pin or a key then sits in a socket in each piece.
    public var canBeSeparate: Bool { self == .pin || self == .key }
}

/// How snugly the connectors fit: the gap left all round a pin, key, dowel or magnet in its socket. A printer that is well tuned
/// holds 0.1 mm; most hold 0.2 mm; a loose or fast print wants 0.3 mm.
public enum SplitFit: String, Codable, CaseIterable, Sendable {
    case tight, standard, loose, custom

    public var title: String {
        switch self {
        case .tight: "Tight"
        case .standard: "Standard"
        case .loose: "Loose"
        case .custom: "Custom"
        }
    }

    /// The gap (mm); nil for a custom fit, which has its own number.
    public var clearance: Double? {
        switch self {
        case .tight: 0.1
        case .standard: 0.2
        case .loose: 0.3
        case .custom: nil
        }
    }

    public var help: String {
        switch self {
        case .tight: "0.1 mm all round: a well tuned printer, resin, or a press fit"
        case .standard: "0.2 mm all round: an FDM printer in good order"
        case .loose: "0.3 mm all round: a fast or coarse print, or a pin you want to slide in easily"
        case .custom: "Your own gap"
        }
    }
}

/// One cut of the body: a plane square to an axis, at a place along it (a coordinate of the world, mm).
public struct PrintSplitCut: Codable, Hashable, Sendable {
    public var axis: MoldAxis
    public var position: String
    public init(axis: MoldAxis, position: String) { self.axis = axis; self.position = position }
}

// MARK: - The setup

/// One split: a body, the printer it has to fit, how it is cut and what joins the pieces. Sizes are expressions like every other
/// size (so they can use parameters), in mm.
public struct PrintSplit: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// The body that is cut, by the id of the feature that made it.
    public var body: FeatureID
    /// A preset's id (`PrinterPreset.catalog`), or `PrinterPreset.customID`: then the build volume is `customVolume`.
    public var printer: String
    public var customVolume: [String]
    /// How much of the build volume is kept free all round (the skirt, the brim, the edge of the bed).
    public var margin: String
    /// Whether a piece may be turned on the bed to fit (it is laid out that way for printing).
    public var turn: Bool
    /// How many pieces along each axis (x, y, z); 0 lets the program choose the fewest that fit.
    public var counts: [Int]
    /// The cuts by hand, or nil to cut evenly by `counts`.
    public var cuts: [PrintSplitCut]?
    public var connector: ConnectorKind
    public var connectorSize: String
    public var connectorLength: String
    /// A pin or a key as a part of its own (printed apart, or cut from a rod), in a socket in each piece, instead of printed on one piece.
    /// Then the length is how deep it goes into each piece.
    public var separate: Bool
    public var fit: SplitFit
    public var customClearance: String
    /// About how far apart the connectors are on a wide cut.
    public var spacing: String

    public init(id: String = UUID().uuidString, name: String, body: FeatureID, printer: String = PrinterPreset.defaultID,
                customVolume: [String] = ["200 mm", "200 mm", "200 mm"], margin: String = "3 mm", turn: Bool = true,
                counts: [Int] = [0, 0, 0], cuts: [PrintSplitCut]? = nil, connector: ConnectorKind = .pin,
                connectorSize: String? = nil, connectorLength: String? = nil, separate: Bool = false, fit: SplitFit = .standard,
                customClearance: String = "0.2 mm", spacing: String = "40 mm") {
        self.id = id; self.name = name; self.body = body; self.printer = printer; self.customVolume = customVolume
        self.margin = margin; self.turn = turn; self.counts = counts; self.cuts = cuts; self.connector = connector
        self.connectorSize = connectorSize ?? connector.defaults.size
        self.connectorLength = connectorLength ?? connector.defaults.length
        self.separate = separate; self.fit = fit; self.customClearance = customClearance; self.spacing = spacing
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, body, printer, customVolume, margin, turn, counts, cuts, connector, connectorSize, connectorLength, separate, fit, customClearance, spacing
    }

    /// Every setting is optional in a file, so a later version can add one and an older file still opens.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PrintSplit(name: "", body: "")
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Split"
        body = try c.decode(FeatureID.self, forKey: .body)
        printer = try c.decodeIfPresent(String.self, forKey: .printer) ?? d.printer
        customVolume = try c.decodeIfPresent([String].self, forKey: .customVolume) ?? d.customVolume
        if customVolume.count != 3 { customVolume = d.customVolume }
        margin = try c.decodeIfPresent(String.self, forKey: .margin) ?? d.margin
        turn = try c.decodeIfPresent(Bool.self, forKey: .turn) ?? true
        counts = try c.decodeIfPresent([Int].self, forKey: .counts) ?? d.counts
        if counts.count != 3 { counts = d.counts }
        cuts = try c.decodeIfPresent([PrintSplitCut].self, forKey: .cuts)
        connector = try c.decodeIfPresent(ConnectorKind.self, forKey: .connector) ?? d.connector
        connectorSize = try c.decodeIfPresent(String.self, forKey: .connectorSize) ?? connector.defaults.size
        connectorLength = try c.decodeIfPresent(String.self, forKey: .connectorLength) ?? connector.defaults.length
        separate = try c.decodeIfPresent(Bool.self, forKey: .separate) ?? false
        fit = try c.decodeIfPresent(SplitFit.self, forKey: .fit) ?? d.fit
        customClearance = try c.decodeIfPresent(String.self, forKey: .customClearance) ?? d.customClearance
        spacing = try c.decodeIfPresent(String.self, forKey: .spacing) ?? d.spacing
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(body, forKey: .body)
        try c.encode(printer, forKey: .printer)
        if printer == PrinterPreset.customID { try c.encode(customVolume, forKey: .customVolume) }
        try c.encode(margin, forKey: .margin)
        if !turn { try c.encode(turn, forKey: .turn) }
        if counts != [0, 0, 0] { try c.encode(counts, forKey: .counts) }
        try c.encodeIfPresent(cuts, forKey: .cuts)
        try c.encode(connector, forKey: .connector)
        try c.encode(connectorSize, forKey: .connectorSize)
        try c.encode(connectorLength, forKey: .connectorLength)
        if separate { try c.encode(separate, forKey: .separate) }
        try c.encode(fit, forKey: .fit)
        if fit == .custom { try c.encode(customClearance, forKey: .customClearance) }
        try c.encode(spacing, forKey: .spacing)
    }

    /// Chooses a connector, with the size and length that kind starts with.
    public mutating func choose(_ kind: ConnectorKind) {
        guard kind != connector else { return }
        connector = kind
        if kind != .none { connectorSize = kind.defaults.size; connectorLength = kind.defaults.length }
    }

    /// The id a piece has as a body (the way a split names its pieces): the k-th piece, counting from 1.
    public func pieceID(_ k: Int) -> FeatureID { "split~\(id)~\(k)" }
    /// Whether the connector is a loose part (a dowel, or a pin or key set to be separate), and so sticks out of no piece.
    public var hasLooseParts: Bool { connector == .dowel || (separate && connector.canBeSeparate) }
    /// What the loose parts are called.
    public var looseName: String { connector == .key ? "key" : connector == .pin ? "pin" : "dowel" }

    /// The id of a loose dowel.
    public func dowelID(_ k: Int) -> FeatureID { "split~\(id)~dowel\(k)" }

    /// The printer's name for a heading.
    public var printerTitle: String { PrinterPreset.preset(printer)?.title ?? "Custom printer" }
}
