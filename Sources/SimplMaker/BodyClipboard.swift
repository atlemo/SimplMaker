// Edit ▸ Copy and Paste for bodies. A copied body travels as a STEP file on the pasteboard, so it can be
// pasted into the same part, another part or another window, and comes back as an Import body (its
// history stays behind, as with any imported part).
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import CADCore
import CADKernel

#if os(macOS)
typealias BodyPasteboard = NSPasteboard

extension NSPasteboard.PasteboardType {
    /// Bodies copied from SimplMaker: a JSON list of `CopiedBody`.
    static let simplMakerBodies = NSPasteboard.PasteboardType("com.simplmaker.bodies")
}

extension NSPasteboard {
    var bodiesData: Data? { data(forType: .simplMakerBodies) }
    func setBodiesData(_ data: Data) { clearContents(); setData(data, forType: .simplMakerBodies) }
}
#else
typealias BodyPasteboard = UIPasteboard

extension UIPasteboard {
    /// Bodies copied from SimplMaker: a JSON list of `CopiedBody`.
    static let simplMakerBodiesType = "com.simplmaker.bodies"
    var bodiesData: Data? { data(forPasteboardType: Self.simplMakerBodiesType) }
    func setBodiesData(_ data: Data) { setData(data, forPasteboardType: Self.simplMakerBodiesType) }
}
#endif

/// One body on the pasteboard.
struct CopiedBody: Codable {
    var name: String
    var color: BodyColor?
    /// Plastic, metal, glass or wood (absent when it was plain, and in anything copied before materials existed).
    var material: BodyMaterial?
    /// The roughness it was given (absent: its material's own).
    var roughness: Double?
    /// The body as a STEP file.
    var step: Data
}

extension DocumentModel {
    /// The bodies a copy takes, in the order they were made: the ones selected whole, or owning a picked
    /// face or edge; else the body of the feature open for editing.
    var copyableBodies: [FeatureID] {
        var ids = Set<FeatureID>()
        for pick in selection where pick.isFace || pick.isEdge {
            if let id = meshes[safe: pick.body]?.id { ids.insert(id) }
        }
        if ids.isEmpty, let id = selectedFeature, document.features.first(where: { $0.id == id })?.createsBody == true { ids.insert(id) }
        return (result?.bodies ?? []).map(\.id).filter(ids.contains)
    }

    static func pasteboardHasBodies(_ pasteboard: BodyPasteboard = .general) -> Bool {
        pasteboard.bodiesData != nil
    }

    /// Puts the selected bodies on the pasteboard. False if there are none to take (nothing is changed then).
    @discardableResult
    func copyBodies(to pasteboard: BodyPasteboard = .general) -> Bool {
        guard sketchSession == nil else { return false }
        let wanted = copyableBodies.compactMap { id in bodies.first { $0.id == id } }
        guard !wanted.isEmpty else { return false }
        do {
            let copied = try wanted.map { b in
                CopiedBody(name: b.name, color: document.bodyColors[b.id], material: document.bodyMaterials[b.id], roughness: document.bodyRoughness[b.id], step: try Self.stepData(of: b.body))
            }
            pasteboard.setBodiesData(try JSONEncoder().encode(copied))
            return true
        } catch {
            alert = AlertInfo(title: "The bodies couldn't be copied", message: "\(error)")
            return false
        }
    }

    /// Adds the bodies on the pasteboard to the timeline, where they were (on top of the originals, if
    /// those are still there), and opens the Move tool on them. False if the pasteboard holds none.
    @discardableResult
    func pasteBodies(from pasteboard: BodyPasteboard = .general) -> Bool {
        guard sketchSession == nil, let data = pasteboard.bodiesData,
              let copied = try? JSONDecoder().decode([CopiedBody].self, from: data), !copied.isEmpty else { return false }
        pendingTool = nil
        var pasted: [(id: FeatureID, copy: CopiedBody)] = []
        for body in copied {
            let id = IDs.make()
            guard (try? Regenerator.importedBody(body.step, featureID: id)) != nil else { continue }  // not a body we can read
            pasted.append((id, body))
        }
        guard !pasted.isEmpty else { return false }
        var taken = Set(bodies.map(\.name))
        mutate(pasted.count == 1 ? "Paste Body" : "Paste Bodies") { doc in
            for (id, body) in pasted {
                var name = body.name, n = 1
                while taken.contains(name) { n += 1; name = "\(body.name) copy" + (n > 2 ? " \(n - 1)" : "") }
                taken.insert(name)
                doc.insertAtMarker(Feature(id: id, name: doc.nextName("Import"),
                                           .importBody(ImportFeature(fileName: "\(body.name).step", data: body.step))))
                doc.bodyNames[id] = name
                if let color = body.color { doc.bodyColors[id] = color }
                if let material = body.material { doc.bodyMaterials[id] = material }
                if let roughness = body.roughness { doc.bodyRoughness[id] = roughness }
            }
        }
        guard let last = pasted.last?.id, document.index(of: last) != nil else { return false }  // editing was locked
        // Straight into Move, so the pasted bodies can be slid off the originals right away.
        add(Feature(name: document.nextName(DesignTool.move.rawValue), .move(MoveFeature(
            bodies: pasted.map(\.id), sketches: [], arrow: .x, rotating: false))))
        return true
    }

    /// A body written out as STEP and read back as bytes.
    private static func stepData(of body: KBody) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).step")
        defer { try? FileManager.default.removeItem(at: url) }
        try KBody.exportSTEP([body], to: url)
        return try Data(contentsOf: url)
    }
}

#if os(macOS)
/// Edit ▸ Cut, Copy, Paste and Select All. A text field being typed in gets them first, as it always did;
/// otherwise Copy and Paste work on the bodies.
@MainActor
enum EditCommands {
    private static var typingInText: Bool { NSApp.keyWindow?.firstResponder is NSText }

    static func copy(_ model: DocumentModel?) {
        if typingInText { send("copy:") } else if model?.copyBodies() != true { NSSound.beep() }
    }

    static func paste(_ model: DocumentModel?) {
        if typingInText { send("paste:") } else if model?.pasteBodies() != true { NSSound.beep() }
    }

    static func send(_ action: String) {
        NSApp.sendAction(Selector(action), to: nil, from: nil)
    }
}
#endif
