// What an AI client can do with molds: make and change one around a body, read what it came to, and export its halves. A mold is not
// a feature of the timeline (see MoldStudio.swift), so these have tools of their own. Offered only while the Mold workspace is.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation

/// One mold as an AI client reads it: its settings, and what building it came to.
struct MoldInfo: Encodable, Equatable {
    var id: String
    var name: String
    var body: String
    /// "x", "y" or "z" for the middle of the body across that axis, or the plane ("xy", "xz", "yz", a construction plane's id).
    var parting: String
    var partingOffset: String
    var pour: String
    var wall: String
    var gateDiameter: String
    /// Where the gate goes in by hand [x, y, z]; nil = at the body's highest point.
    var gatePoint: [Double]?
    var ventDiameter: String
    var vents: [[Double]]
    var keys: Bool
    var keySize: String
    var keyClearance: String
    /// "silicone" or "resin".
    var casting: String
    /// "built" or "failed".
    var status: String
    var error: String?
    var warnings: [String]
    /// Faces of the body the halves cannot let go of (they lean back against the pull), and the shares of the body's surface that are
    /// undercut and that have no draft (parallel to the pull), in percent. Present even when a rigid cast was refused for an undercut.
    var undercutFaces: [String]?
    var undercutPercent: Double?
    var noDraftPercent: Double?
    /// What the cavity holds (the body, the gate and the vents), in millilitres: the silicone to mix.
    var siliconeMl: Double?
    var blockMm: [Double]?
    /// Where the parting plane is: a point and the normal (which half is "front": the side the normal points to).
    var partingPoint: [Double]?
    var partingNormal: [Double]?
    /// The ids of the halves: behind the plane, in front of it.
    var halves: [String]?
    var seconds: Double?
}

struct MoldChangeResult: Encodable, Equatable {
    var success = true
    var documentId: String
    var revision: Int
    var message: String
    var mold: MoldInfo?
}

struct MoldsResult: Encodable, Equatable {
    var documentId: String
    var revision: Int
    var molds: [MoldInfo]
}

extension CADService {
    // MARK: reading

    static func moldInfo(_ m: MoldSetup, _ r: MoldResult?) -> MoldInfo {
        var parting: String
        switch m.parting {
        case .middle(let axis): parting = axis.rawValue
        case .plane(.xy): parting = "xy"
        case .plane(.xz): parting = "xz"
        case .plane(.yz): parting = "yz"
        case .plane(.plane(let id)): parting = id
        case .plane(.face(let ref)): parting = "face \(ref.body)/\(ref.face)"
        }
        var info = MoldInfo(id: m.id, name: m.name, body: m.body, parting: parting, partingOffset: m.partingOffset, pour: m.up.rawValue,
                            wall: m.wall, gateDiameter: m.gateDiameter, gatePoint: m.gatePoint.map { [$0.x, $0.y, $0.z] },
                            ventDiameter: m.ventDiameter, vents: m.vents.map { [$0.x, $0.y, $0.z] }, keys: m.keys, keySize: m.keyDiameter,
                            keyClearance: m.keyClearance, casting: m.casting.rawValue, status: "failed", warnings: [])
        guard let r else { info.error = "Not built yet."; return info }
        info.error = r.error
        info.warnings = r.warnings
        if let a = r.analysis {
            info.undercutFaces = a.undercutFaces.sorted()
            info.undercutPercent = (a.undercutShare * 1000).rounded() / 10
            info.noDraftPercent = (a.noDraftShare * 1000).rounded() / 10
        }
        if r.isBuilt {
            info.status = "built"
            info.siliconeMl = (r.cavityVolume / 1000 * 10).rounded() / 10
            info.blockMm = [r.blockSize.x, r.blockSize.y, r.blockSize.z].map { ($0 * 10).rounded() / 10 }
            info.partingPoint = [r.partingPoint.x, r.partingPoint.y, r.partingPoint.z]
            info.partingNormal = [r.partingNormal.x, r.partingNormal.y, r.partingNormal.z]
            info.halves = [m.halfIDs.behind, m.halfIDs.front]
        }
        info.seconds = (r.seconds * 100).rounded() / 100
        return info
    }

    /// Works the molds out now (in any workspace) and waits for them.
    private func buildMolds(_ model: DocumentModel) async throws {
        await model.rebuilt()
        model.rebuildMolds()
        for _ in 0..<12_000 where model.moldBuilding { try await Task.sleep(for: .milliseconds(10)) }  // up to two minutes
        if model.moldBuilding {
            throw AIError(.rebuildFailed, "The mold is still being built after two minutes.", reason: "The body is very heavy. Try again, or use a lighter body.")
        }
    }

    func getMolds(documentID: String?) async throws -> MoldsResult {
        let (id, model) = try resolve(documentID)
        if !model.document.molds.isEmpty { try await buildMolds(model) }
        return MoldsResult(documentId: id, revision: model.documentRevision,
                           molds: model.document.molds.map { Self.moldInfo($0, model.moldResults[$0.id]) })
    }

    // MARK: changing

    /// Makes a mold around a body (body_id), or changes or deletes one (mold_id). Whatever the arguments leave out stays as it is.
    func createMold(documentID: String, expectedRevision: Int?, _ a: AIArguments) async throws -> MoldChangeResult {
        let (id, model) = try resolve(documentID)
        try refuseIfBusy(model)
        await model.rebuilt()
        try checkRevision(expectedRevision, current: model.documentRevision)

        let known = model.document.molds
        var setup: MoldSetup
        let creating: Bool
        if let moldID = try a.string("mold_id") {
            guard let found = known.first(where: { $0.id == moldID }) else {
                throw AIError(.featureNotFound, "There is no mold with the id \(moldID).",
                              reason: known.isEmpty ? "The part has no molds yet: pass body_id to make one." : "The molds are: \(known.map(\.id).joined(separator: ", ")).")
            }
            if try a.bool("delete") == true {
                model.aiActivity = "Deleting a mold"
                defer { model.aiActivity = nil }
                model.mutate("AI: Delete Mold") { $0.molds.removeAll { $0.id == moldID } }
                return MoldChangeResult(documentId: id, revision: model.documentRevision, message: "Deleted the mold \(found.name).", mold: nil)
            }
            setup = found; creating = false
        } else {
            let bodyID = try a.requiredString("body_id", hint: "The body to make the mold around, from get_document's bodies. Or pass mold_id to change a mold.")
            guard model.result?.body(bodyID) != nil else {
                let ids = (model.result?.bodies ?? []).map(\.id).joined(separator: ", ")
                throw AIError(.featureNotFound, "There is no body with the id \(bodyID).", reason: ids.isEmpty ? "The part has no bodies yet." : "The bodies are: \(ids).")
            }
            let name = try a.string("name") ?? "\(model.bodies.first { $0.id == bodyID }?.name ?? "Body") mold"
            setup = MoldSetup(name: name, body: bodyID, parting: Self.defaultParting(of: model.result?.body(bodyID), mesh: model.meshes.first { $0.id == bodyID }?.mesh))
            creating = true
        }
        try Self.apply(a, to: &setup, in: model)
        let wantsAutoVents = try a.bool("auto_vents") == true

        model.aiActivity = creating ? "Making a mold" : "Changing a mold"
        defer { model.aiActivity = nil }
        let made = setup
        model.mutate(creating ? "AI: Make Mold" : "AI: Change Mold") { doc in
            if let i = doc.molds.firstIndex(where: { $0.id == made.id }) { doc.molds[i] = made } else { doc.molds.append(made) }
        }
        model.activeMoldID = setup.id
        try await buildMolds(model)
        if wantsAutoVents {
            // After the first build: the vents go where the body's own peaks are, away from the gate it has found.
            model.addAutomaticVents()
            try await buildMolds(model)
        }
        setup = model.document.molds.first { $0.id == setup.id } ?? setup
        let info = Self.moldInfo(setup, model.moldResults[setup.id])
        let message: String
        if info.status == "built" {
            message = "\(creating ? "Made" : "Changed") the mold \(setup.name): two halves, about \(info.siliconeMl ?? 0) mL of silicone."
                + (info.warnings.isEmpty ? "" : " Warnings: " + info.warnings.joined(separator: " "))
        } else {
            message = "The mold \(setup.name) is saved but could not be built: \(info.error ?? "unknown reason")"
        }
        return MoldChangeResult(documentId: id, revision: model.documentRevision, message: message, mold: info)
    }

    /// The parting plane a new mold starts with: the axis with the least undercut, as in the Mold workspace.
    private static func defaultParting(of body: KBody?, mesh: Mesh?) -> MoldParting {
        let ext = body?.bounds.map { $0.max - $0.min } ?? SIMD3(1, 1, 1)
        if let mesh, let bounds = body?.bounds { return .middle(MoldAnalysis.bestAxis(mesh, bounds: bounds)) }
        return .middle(ext.x <= ext.y && ext.x <= ext.z ? .x : ext.y <= ext.z ? .y : .z)
    }

    private static func point(_ v: JSONValue, _ field: String) throws -> MoldPoint {
        guard let list = v.array, list.count == 3, let x = list[0].number, let y = list[1].number, let z = list[2].number,
              [x, y, z].allSatisfy(\.isFinite) else {
            throw AIError(.invalidArguments, "\(field) must be [x, y, z] in mm (three numbers).")
        }
        return MoldPoint(x, y, z)
    }

    private static func apply(_ a: AIArguments, to m: inout MoldSetup, in model: DocumentModel) throws {
        try a.rejectUnknown(["document_id", "expected_revision", "mold_id", "delete", "body_id", "name", "parting", "parting_offset", "pour", "wall",
                             "gate_diameter", "gate_point", "reset_gate", "vent_diameter", "vents", "auto_vents", "keys", "key_size", "key_clearance", "casting"], in: "create_mold")
        if let name = try a.string("name"), !name.isEmpty { m.name = name }
        if let parting = try a.string("parting") {
            switch parting.lowercased() {
            case "x", "y", "z": m.parting = .middle(MoldAxis(rawValue: parting.lowercased())!)
            case "xy": m.parting = .plane(.xy)
            case "xz": m.parting = .plane(.xz)
            case "yz": m.parting = .plane(.yz)
            default:
                guard model.planeFeatures.contains(where: { $0.id == parting }) else {
                    throw AIError(.invalidArguments, "parting \"\(parting)\" is not \"x\", \"y\", \"z\", \"xy\", \"xz\", \"yz\" or the id of a construction plane.",
                                  reason: "\"x\", \"y\" or \"z\" parts the mold across that axis through the middle of the body; the others use that plane (square to an axis).")
                }
                m.parting = .plane(.plane(parting))
            }
        }
        if let offset = try a.quantity("parting_offset", kind: .length) { m.partingOffset = offset }
        if let pour = try a.string("pour") {
            guard let direction = MoldDirection(rawValue: pour.lowercased()) else {
                throw AIError(.invalidArguments, "pour \"\(pour)\" is not one of +x, -x, +y, -y, +z, -z.", reason: "The way up while the silicone is poured; usually \"+z\".")
            }
            m.up = direction
        }
        if let v = try a.quantity("wall", kind: .length) { m.wall = v }
        if let v = try a.quantity("gate_diameter", kind: .length) { m.gateDiameter = v }
        if let v = try a.quantity("vent_diameter", kind: .length) { m.ventDiameter = v }
        if let v = try a.quantity("key_size", kind: .length) { m.keyDiameter = v }
        if let v = try a.quantity("key_clearance", kind: .length) { m.keyClearance = v }
        if let v = try a.bool("keys") { m.keys = v }
        if let c = try a.string("casting") {
            guard let casting = MoldCasting(rawValue: c.lowercased()) else {
                throw AIError(.invalidArguments, "casting \"\(c)\" is not \"silicone\" or \"resin\".",
                              reason: "Silicone is peeled out of a mild undercut, so an undercut only warns. A rigid resin is stuck in one, so the mold is refused.")
            }
            m.casting = casting
        }
        if let p = a.json["gate_point"], p != .null { m.gatePoint = try point(p, "gate_point") }
        if try a.bool("reset_gate") == true { m.gatePoint = nil }
        if let list = try a.array("vents") {
            guard list.count <= 20 else { throw AIError(.invalidArguments, "At most 20 vents.") }
            m.vents = try list.enumerated().map { try point($1, "vents[\($0)]") }
        }
    }

    // MARK: exporting

    /// Writes the two halves, laid out for printing, to the exports folder.
    func exportMold(documentID: String, moldID: String?, format: String, fileName: String?) async throws -> ExportResult {
        guard let kind = ExportFormat(rawValue: format) else {
            throw AIError(.invalidArguments, "format \"\(format)\" is not stl, 3mf or step.", reason: "STL or 3MF for 3D printing, STEP for other CAD programs.")
        }
        let (id, model) = try resolve(documentID)
        guard !model.document.molds.isEmpty else {
            throw AIError(.featureNotFound, "The part has no mold.", reason: "Make one with create_mold first.")
        }
        let setup: MoldSetup
        if let moldID {
            guard let found = model.document.molds.first(where: { $0.id == moldID }) else {
                throw AIError(.featureNotFound, "There is no mold with the id \(moldID).", reason: "The molds are: \(model.document.molds.map(\.id).joined(separator: ", ")).")
            }
            setup = found
        } else {
            setup = model.document.molds[0]
        }
        try await buildMolds(model)
        guard let built = model.moldResults[setup.id], built.isBuilt else {
            throw AIError(.invalidArguments, "The mold could not be built: \(model.moldResults[setup.id]?.error ?? "unknown reason").",
                          reason: "Read it with get_mold, change what it says, and try again.")
        }
        let placed = MoldBuilder.printLayout(built)
        guard placed.count == 2 else { throw AIError(.invalidArguments, "The halves could not be laid out.") }

        let directory = Self.exportFolder
        let base = Self.safeFileName(fileName.map { ($0 as NSString).deletingPathExtension } ?? setup.name)
        let fm = FileManager.default
        do { try fm.createDirectory(at: directory, withIntermediateDirectories: true) } catch {
            throw AIError(.invalidArguments, "The export folder could not be made: \(error.localizedDescription)")
        }
        var url = directory.appendingPathComponent("\(base).\(format)")
        var n = 2
        while fm.fileExists(atPath: url.path) { url = directory.appendingPathComponent("\(base) \(n).\(format)"); n += 1 }
        let kernelBodies = placed.map(\.body)
        let named = placed.map { (name: $0.name, body: $0.body, color: model.document.bodyColors[$0.id], faceColors: [String: BodyColor]()) }
        let target = url
        do {
            try await Task.detached(priority: .userInitiated) {
                switch kind {
                case .stl: try KBody.exportSTL(kernelBodies, to: target)
                case .step: try KBody.exportSTEP(kernelBodies, to: target)
                case .threeMF: try ThreeMF.write(named, to: target)
                }
            }.value
        } catch {
            throw AIError(.invalidArguments, "The export failed: \(error).")
        }
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return ExportResult(documentId: id, message: "Exported the two halves of \(setup.name), laid out for printing, to \(url.path).",
                            path: url.path, format: format, bytes: size, bodies: placed.map(\.id))
    }
}
