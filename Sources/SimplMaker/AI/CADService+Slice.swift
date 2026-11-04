// slice_body: the outline of a body cut by a plane, at one or several stations. Read-only. The reason it exists is reverse
// engineering: an imported STL is a lump of triangles with no feature tree, so to rebuild it the AI slices it, reads the section
// sizes (chord, thickness, tilt) and draws them again.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import simd

struct SliceLoopInfo: Encodable, Equatable {
    /// Positive for an outer outline, negative for a hole.
    var area: Double
    var hole: Bool
    /// False for a path that did not close (a mesh with a gap in it).
    var closed: Bool
    /// The corners as [u, v] in the plane's sketch coordinates; left out when the caller asked for the sizes only.
    var points: [[Double]]?
}

struct SliceSectionInfo: Encodable, Equatable {
    /// Where the plane cuts, along the axis, in mm.
    var offset: Double
    var loops: [SliceLoopInfo]
    /// Total area of the cut (holes subtracted), nil when the plane misses the body.
    var area: Double?
    /// Where the middle of the cut is: [u, v].
    var centroid: [Double]?
    /// [min u, min v, max u, max v].
    var bounds: [Double]?
    /// The direction the cut is longest in, degrees counter-clockwise from the u axis, in (-90, 90]. A thin plate cut across has
    /// its tilt here.
    var majorAxisDegrees: Double?
    /// How far the cut reaches along that direction (a plate's chord) and across it (a plate's thickness).
    var length: Double?
    var width: Double?
}

struct SliceResult: Encodable, Equatable {
    var documentId: String
    var revision: Int
    var body: String
    var axis: String
    /// "yz", "xz" or "xy": a sketch on this plane (moved to the offset) uses the same u, v as the points.
    var plane: String
    var coordinates: String
    /// How far along the axis the body reaches: [min, max].
    var bodyRange: [Double]
    var tolerance: Double
    var sections: [SliceSectionInfo]
}

extension CADService {
    nonisolated static let maxSliceOffsets = 100

    func sliceBody(documentID: String?, bodyID: String, axis axisText: String, offsets: [Double], tolerance: Double,
                   includePoints: Bool) async throws -> SliceResult {
        guard let axis = ["x", "y", "z"].firstIndex(of: axisText.lowercased()) else {
            throw AIError(.invalidArguments, "axis \"\(axisText)\" is not one of x, y, z.",
                          reason: "The plane is square to this axis: \"x\" cuts across the part's length along X (a section in the YZ plane).")
        }
        guard !offsets.isEmpty, offsets.count <= Self.maxSliceOffsets, offsets.allSatisfy(\.isFinite) else {
            throw AIError(.invalidArguments, "Send between 1 and \(Self.maxSliceOffsets) offsets (finite numbers, mm).",
                          reason: "Either offsets: [..], or from, to and count for evenly spaced stations.")
        }
        guard tolerance.isFinite, tolerance >= 0 else {
            throw AIError(.invalidArguments, "tolerance must be 0 or more (mm).", reason: "0 keeps every point; 0.02 drops corners within 0.02 mm of a straight line.")
        }
        let (docID, model) = try resolve(documentID)
        await model.rebuilt()
        guard let body = model.result?.body(bodyID) else {
            let known = (model.result?.bodies ?? []).map(\.id).joined(separator: ", ")
            throw AIError(.featureNotFound, "There is no body with the id \(bodyID).",
                          reason: known.isEmpty ? "The part has no bodies yet." : "The bodies are: \(known). get_document lists them.")
        }
        // A fine tessellation: for an imported mesh this is the mesh itself, for a curved body it keeps the outline within 0.01 mm.
        let (sections, range): ([SliceSectionInfo], [Double])
        do {
            (sections, range) = try await Task.detached(priority: .userInitiated) { () throws -> ([SliceSectionInfo], [Double]) in
                let mesh = try body.tessellate(linearDeflection: 0.01, angularDeflection: 0.2)
                var lo = Double.infinity, hi = -Double.infinity
                for i in stride(from: axis, to: mesh.positions.count, by: 3) {
                    lo = min(lo, Double(mesh.positions[i])); hi = max(hi, Double(mesh.positions[i]))
                }
                let made = offsets.map { offset in
                    Self.sliceSection(mesh, axis: axis, offset: offset, tolerance: tolerance, includePoints: includePoints)
                }
                return (made, [Self.round(lo), Self.round(hi)])
            }.value
        } catch {
            throw AIError(.invalidValue, "\(bodyID) could not be sliced: \(error).", reason: "Try another body.")
        }
        let (u, v) = BodySlicer.planeAxes(axis)
        let names = ["x", "y", "z"]
        return SliceResult(
            documentId: docID, revision: model.documentRevision, body: bodyID, axis: names[axis], plane: BodySlicer.planeName(axis),
            coordinates: "points are [\(names[u]), \(names[v])] in model mm (u = \(names[u]), v = \(names[v])), the sketch coordinates of a sketch on the \"\(BodySlicer.planeName(axis))\" plane moved to the offset (create_plane with base \"\(BodySlicer.planeName(axis))\" and offset)",
            bodyRange: range, tolerance: tolerance, sections: sections)
    }

    nonisolated static func round(_ x: Double, places: Double = 1e4) -> Double { (x * places).rounded() / places }

    nonisolated static func sliceSection(_ mesh: Mesh, axis: Int, offset: Double, tolerance: Double, includePoints: Bool) -> SliceSectionInfo {
        let loops = BodySlicer.slice(mesh, axis: axis, offset: offset, tolerance: tolerance)
        let infos = loops.map { loop in
            SliceLoopInfo(area: round(abs(loop.signedArea), places: 1e3), hole: loop.isHole, closed: loop.closed,
                          points: includePoints ? loop.points.map { [round($0.x), round($0.y)] } : nil)
        }
        guard let shape = BodySlicer.shape(of: loops) else {
            return SliceSectionInfo(offset: offset, loops: infos)
        }
        return SliceSectionInfo(offset: offset, loops: infos, area: round(shape.area, places: 1e3),
                                centroid: [round(shape.centroid.x), round(shape.centroid.y)],
                                bounds: [round(shape.boundsMin.x), round(shape.boundsMin.y), round(shape.boundsMax.x), round(shape.boundsMax.y)],
                                majorAxisDegrees: round(shape.majorAxisDegrees, places: 1e3), length: round(shape.length), width: round(shape.width))
    }
}
