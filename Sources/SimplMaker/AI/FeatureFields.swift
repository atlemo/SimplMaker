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
        case .fillet(let e), .chamfer(let e):
            func edge(_ name: String, _ unit: UnitKind, read: @escaping (EdgeFeature) -> String?, write: @escaping (inout EdgeFeature, String) -> Void) -> FieldSpec {
                FieldSpec(name: name, unit: unit, positive: true,
                          read: { kind in
                              switch kind { case .fillet(let x), .chamfer(let x): return read(x); default: return nil }
                          },
                          write: { kind, text in
                              switch kind {
                              case .fillet(var x): write(&x, text); kind = .fillet(x)
                              case .chamfer(var x): write(&x, text); kind = .chamfer(x)
                              default: break
                              }
                          })
            }
            var out = [edge("size", .length, read: { $0.size }, write: { $0.size = $1 })]
            if case .chamfer = kind, let secondKind = e.mode.secondKind {
                out.append(edge("second", secondKind, read: { $0.second }, write: { $0.second = $1 }))
            }
            return out
        case .hole(let h):
            func hole(_ name: String, _ unit: UnitKind, _ positive: Bool, _ path: WritableKeyPath<HoleFeature, String>) -> FieldSpec {
                FieldSpec(name: name, unit: unit, positive: positive,
                          read: { if case .hole(let x) = $0 { return x[keyPath: path] } else { return nil } },
                          write: { kind, text in if case .hole(var x) = kind { x[keyPath: path] = text; kind = .hole(x) } })
            }
            var out = [hole("diameter", .length, true, \.diameter), hole("u", .length, false, \.u), hole("v", .length, false, \.v)]
            if h.depth != nil {  // a hole through everything has no depth to set
                out.append(FieldSpec(name: "depth", unit: .length, positive: true,
                                     read: { if case .hole(let x) = $0 { return x.depth } else { return nil } },
                                     write: { kind, text in if case .hole(var x) = kind { x.depth = text; kind = .hole(x) } }))
                out.append(hole("tip_angle", .angle, false, \.tipAngle))
            }
            if h.kind != .simple { out.append(hole("head_diameter", .length, true, \.headDiameter)) }
            if h.kind == .counterbore { out.append(hole("head_depth", .length, true, \.headDepth)) }
            if h.kind == .countersink { out.append(hole("head_angle", .angle, true, \.headAngle)) }
            return out
        case .shell:
            return [FieldSpec(name: "thickness", unit: .length, positive: true,
                              read: { if case .shell(let x) = $0 { return x.thickness } else { return nil } },
                              write: { kind, text in if case .shell(var x) = kind { x.thickness = text; kind = .shell(x) } })]
        case .revolve:
            return [FieldSpec(name: "angle", unit: .angle, positive: true,
                              read: { if case .revolve(let x) = $0 { return x.angle } else { return nil } },
                              write: { kind, text in if case .revolve(var x) = kind { x.angle = text; kind = .revolve(x) } })]
        case .pattern(let p):
            return [FieldSpec(name: "count", unit: .none, positive: true,
                              read: { if case .pattern(let x) = $0 { return x.count } else { return nil } },
                              write: { kind, text in if case .pattern(var x) = kind { x.count = text; kind = .pattern(x) } }),
                    FieldSpec(name: "spacing", unit: p.kind == .linear ? .length : .angle, positive: true,
                              read: { if case .pattern(let x) = $0 { return x.spacing } else { return nil } },
                              write: { kind, text in if case .pattern(var x) = kind { x.spacing = text; kind = .pattern(x) } })]
        case .thread(let t):
            var out: [FieldSpec] = []
            if t.length != nil {
                out.append(FieldSpec(name: "length", unit: .length, positive: true,
                                     read: { if case .thread(let x) = $0 { return x.length } else { return nil } },
                                     write: { kind, text in if case .thread(var x) = kind { x.length = text; kind = .thread(x) } }))
            }
            if t.tolerance != nil {
                out.append(FieldSpec(name: "tolerance", unit: t.toleranceUnit == .percent ? .none : .length, positive: false,
                                     read: { if case .thread(let x) = $0 { return x.tolerance } else { return nil } },
                                     write: { kind, text in if case .thread(var x) = kind { x.tolerance = text; x.toleranceMaterial = nil; kind = .thread(x) } }))
            }
            return out
        case .draft:
            return [FieldSpec(name: "angle", unit: .angle, positive: false,
                              read: { if case .draft(let x) = $0 { return x.angle } else { return nil } },
                              write: { kind, text in if case .draft(var x) = kind { x.angle = text; kind = .draft(x) } })]
        case .plane:
            func plane(_ name: String, _ unit: UnitKind, _ path: WritableKeyPath<PlaneFeature, String>) -> FieldSpec {
                FieldSpec(name: name, unit: unit, positive: false,
                          read: { if case .plane(let x) = $0 { return x[keyPath: path] } else { return nil } },
                          write: { kind, text in if case .plane(var x) = kind { x[keyPath: path] = text; kind = .plane(x) } })
            }
            return [plane("offset", .length, \.offset), plane("angle", .angle, \.angle)]
        case .move:
            func move(_ name: String, _ unit: UnitKind, _ path: WritableKeyPath<MoveFeature, String>) -> FieldSpec {
                FieldSpec(name: name, unit: unit, positive: false,
                          read: { if case .move(let x) = $0 { return x[keyPath: path] } else { return nil } },
                          write: { kind, text in if case .move(var x) = kind { x[keyPath: path] = text; kind = .move(x) } })
            }
            return [move("dx", .length, \.dx), move("dy", .length, \.dy), move("dz", .length, \.dz),
                    move("rx", .angle, \.rx), move("ry", .angle, \.ry), move("rz", .angle, \.rz)]
        case .scale:
            return [FieldSpec(name: "factor", unit: .none, positive: true,
                              read: { if case .scale(let x) = $0 { return x.factor } else { return nil } },
                              write: { kind, text in if case .scale(var x) = kind { x.factor = text; kind = .scale(x) } })]
        default:
            return []
        }
    }

    /// For the message when a feature can't be changed.
    static let supportedTypes = "Box, Cylinder, Sphere, Torus and Coil (their sizes), Sketch (its dimensions and text heights), Extrude (distance, taper), Fillet and Chamfer (size, second), Hole (diameter, depth, position…), Shell (thickness), Revolve (angle), Pattern (count, spacing), Thread (length, tolerance), Draft (angle), Plane (offset, angle), Move (distances, turns) and Scale (factor)"

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
