// Which settings of a feature the AI interface can change, and how. One table per kind of feature; a kind that isn't here
// can be read but not changed yet. The names are the ones FeatureDescriber returns, so what get_feature shows is what
// modify_feature accepts.
// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import Foundation

struct FieldSpec {
    let name: String
    let unit: UnitKind
    /// A size that has to be more than zero (a position can be anything).
    let positive: Bool
    let read: (Feature.Kind) -> String?
    let write: (inout Feature.Kind, String) -> Void
    /// The setting is words (a text's letters), not an expression: it is taken as it is.
    var isText = false
}

enum FeatureFields {
    /// The settings of this feature that can be changed.
    static func specs(for kind: Feature.Kind) -> [FieldSpec] {
        switch kind {
        case .primitive(let p):
            var out: [FieldSpec] = []
            switch p.kind {
            case .box: out = [size("width", \.width), size("length", \.length), size("height", \.height)]
            case .cylinder: out = [size("diameter", \.diameter), size("height", \.height)]
            case .sphere: out = [size("diameter", \.diameter)]
            case .torus: out = [size("diameter", \.diameter), size("tube", \.tube)]
            case .coil: out = [size("diameter", \.diameter), size("tube", \.tube), size("pitch", \.pitch), size("turns", \.turns, unit: .none)]
            }
            return out + [position("u", \.u), position("v", \.v)]
        case .sketch(let sf):
            // Every dimension by its id ("key.width"), and every text's height ("name.height").
            var out: [FieldSpec] = sf.sketch.dimensions.map { d in
                let isPosition: Bool
                switch d.kind {
                case .horizontalDistance, .verticalDistance, .angle, .lineAngle: isPosition = true
                default: isPosition = false
                }
                return FieldSpec(
                    name: d.id, unit: d.unitKind, positive: !isPosition,
                    read: { kind in if case .sketch(let s) = kind { return s.sketch.dimensions.first { $0.id == d.id }?.expression } else { return nil } },
                    write: { kind, text in
                        guard case .sketch(var s) = kind, let i = s.sketch.dimensions.firstIndex(where: { $0.id == d.id }) else { return }
                        s.sketch.dimensions[i].expression = text
                        kind = .sketch(s)
                    })
            }
            out += sf.sketch.texts.map { t in
                FieldSpec(
                    name: "\(t.id).text", unit: .none, positive: false,
                    read: { kind in if case .sketch(let s) = kind { return s.sketch.texts.first { $0.id == t.id }?.text } else { return nil } },
                    write: { kind, text in
                        guard case .sketch(var s) = kind, let i = s.sketch.texts.firstIndex(where: { $0.id == t.id }) else { return }
                        s.sketch.texts[i].text = text
                        kind = .sketch(s)
                    }, isText: true)
            }
            out += sf.sketch.texts.map { t in
                FieldSpec(
                    name: "\(t.id).height", unit: .length, positive: true,
                    read: { kind in if case .sketch(let s) = kind { return s.sketch.texts.first { $0.id == t.id }?.height } else { return nil } },
                    write: { kind, text in
                        guard case .sketch(var s) = kind, let i = s.sketch.texts.firstIndex(where: { $0.id == t.id }) else { return }
                        s.sketch.texts[i].height = text
                        kind = .sketch(s)
                    })
            }
            return out
        case .extrude(let e):
            var out: [FieldSpec] = []
            func extent(_ name: String, _ body: @escaping (inout ExtrudeFeature, String) -> Void, read: @escaping (ExtrudeFeature) -> String?) -> FieldSpec {
                FieldSpec(name: name, unit: .length, positive: true,
                          read: { if case .extrude(let x) = $0 { return read(x) } else { return nil } },
                          write: { kind, text in if case .extrude(var x) = kind { body(&x, text); kind = .extrude(x) } })
            }
            switch e.extent {
            case .distance, .symmetric, .twoSides:
                out.append(extent("distance", { x, text in
                    switch x.extent {
                    case .distance: x.extent = .distance(text)
                    case .symmetric: x.extent = .symmetric(text)
                    case .twoSides(_, let back): x.extent = .twoSides(text, back: back)
                    default: break
                    }
                }, read: { $0.extent.size }))
            case .throughAll, .toFace: break
            }
            if case .twoSides = e.extent {
                out.append(extent("back_distance", { x, text in if case .twoSides(let d, _) = x.extent { x.extent = .twoSides(d, back: text) } },
                                  read: { x in if case .twoSides(_, let back) = x.extent { return back } else { return nil } }))
            }
            out.append(FieldSpec(name: "taper", unit: .angle, positive: false,
                                 read: { if case .extrude(let x) = $0 { return x.taper ?? "0 deg" } else { return nil } },
                                 write: { kind, text in if case .extrude(var x) = kind { x.taper = text; kind = .extrude(x) } }))
            return out
        default:
            return []
        }
    }

    /// For the message when a feature can't be changed.
    static let supportedTypes = "Box, Cylinder, Sphere, Torus and Coil (their sizes), Sketch (its dimensions and text heights) and Extrude (distance, taper)"

    private static func size(_ name: String, _ path: WritableKeyPath<PrimitiveFeature, String>, unit: UnitKind = .length) -> FieldSpec {
        primitive(name, unit, true, path)
    }

    private static func position(_ name: String, _ path: WritableKeyPath<PrimitiveFeature, String>) -> FieldSpec {
        primitive(name, .length, false, path)
    }

    private static func primitive(_ name: String, _ unit: UnitKind, _ positive: Bool, _ path: WritableKeyPath<PrimitiveFeature, String>) -> FieldSpec {
        FieldSpec(name: name, unit: unit, positive: positive,
                  read: { if case .primitive(let p) = $0 { return p[keyPath: path] } else { return nil } },
                  write: { kind, text in if case .primitive(var p) = kind { p[keyPath: path] = text; kind = .primitive(p) } })
    }
}
