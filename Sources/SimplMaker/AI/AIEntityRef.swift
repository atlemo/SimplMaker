// How the AI interface names things in the model. Features, sketches, parameters and bodies are named by
// their ids as they are (a body by the id of the feature that made it). The rest are text with a prefix:
//
//   face:<body>/<name>            a face, by its persistent name ("face:plate/plate.end")
//   edge:<body>/<name>            an edge ("edge:plate/plate.end|plate.side.L3")
//   profile:<sketch>/<curves>[@n] a closed region of a sketch, by the ids of the curves around it (@n tells apart regions with the same curves)
//   curve:<sketch>/<curve>        one curve of a sketch
//   plane:xy | plane:xz | plane:yz, plane:<feature>   an origin plane, or a construction plane
//
// Nothing here is an index into what is on screen: every one of them is looked up again by name when it is used,
// so it means the same thing after the model has been rebuilt. Faces and edges are named by the kernel's history
// and can go away or split when the shape upstream changes; the others only go when what they name is deleted.
// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import Foundation

enum AIEntityRef: Equatable, Hashable, Sendable {
    case face(FaceRef)
    case edge(EdgeRef)
    /// `curves` are the ids around the region; `copy` tells apart regions bounded by the same curves (two halves of a
    /// circle split by a line), counting from 1; 0 when nothing else has the same curves.
    case profile(sketch: FeatureID, curves: [EntityID], copy: Int)
    case curve(sketch: FeatureID, id: EntityID)
    /// An origin plane ("xy", "xz", "yz") or the id of a construction plane's feature.
    case plane(String)

    var string: String {
        switch self {
        case .face(let f): return "face:\(f.body)/\(f.face)"
        case .edge(let e): return "edge:\(e.body)/\(e.edge)"
        case .profile(let sketch, let curves, let copy):
            return "profile:\(sketch)/\(curves.sorted().joined(separator: ","))" + (copy > 0 ? "@\(copy)" : "")
        case .curve(let sketch, let id): return "curve:\(sketch)/\(id)"
        case .plane(let p): return "plane:\(p)"
        }
    }

    init?(_ text: String) {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let kind = text[..<colon], rest = String(text[text.index(after: colon)...])
        func split() -> (String, String)? {
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            let head = String(rest[..<slash]), tail = String(rest[rest.index(after: slash)...])
            return head.isEmpty || tail.isEmpty ? nil : (head, tail)
        }
        switch kind {
        case "face": guard let (b, n) = split() else { return nil }; self = .face(FaceRef(body: b, face: n))
        case "edge": guard let (b, n) = split() else { return nil }; self = .edge(EdgeRef(body: b, edge: n))
        case "profile":
            guard let (sketch, tail) = split() else { return nil }
            var list = tail, copy = 0
            if let at = tail.lastIndex(of: "@"), let n = Int(tail[tail.index(after: at)...]), n > 0 {
                list = String(tail[..<at]); copy = n
            }
            let curves = list.split(separator: ",").map(String.init)
            guard !curves.isEmpty else { return nil }
            self = .profile(sketch: sketch, curves: curves.sorted(), copy: copy)
        case "curve": guard let (s, c) = split() else { return nil }; self = .curve(sketch: s, id: c)
        case "plane": guard !rest.isEmpty else { return nil }; self = .plane(rest)
        default: return nil
        }
    }

    /// How a plane a feature sits on is named: an origin or construction plane, or a flat face.
    static func text(for plane: PlaneRef) -> String {
        switch plane {
        case .xy: return AIEntityRef.plane("xy").string
        case .xz: return AIEntityRef.plane("xz").string
        case .yz: return AIEntityRef.plane("yz").string
        case .plane(let id): return AIEntityRef.plane(id).string
        case .face(let f): return AIEntityRef.face(f).string
        }
    }
}
