// 3MF export: the format slicers read, with units, one object per body and a colour for each (as a Materials-extension colour group).
// A 3MF file is a zip with three small parts; the parts are stored without compression, which every reader accepts.
// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import Foundation

public enum ThreeMF {
    /// One body in the file.
    public struct Object {
        public var name: String
        public var mesh: Mesh
        public var color: BodyColor?

        public init(name: String, mesh: Mesh, color: BodyColor? = nil) {
            self.name = name
            self.mesh = mesh
            self.color = color
        }
    }

    /// The bytes of a 3MF file holding these objects, in millimetres. Throws if there is no triangle to write.
    public static func data(_ objects: [Object]) throws -> Data {
        let usable = objects.filter { !$0.mesh.indices.isEmpty }
        guard !usable.isEmpty else { throw KernelError(message: "3MF export: there is no surface to write") }
        let model = Data(modelXML(usable).utf8)
        var zip = ZipWriter()
        zip.add("[Content_Types].xml", Data(contentTypes.utf8))
        zip.add("_rels/.rels", Data(rels.utf8))
        zip.add("3D/3dmodel.model", model)
        return zip.finish()
    }

    public static func write(_ objects: [Object], to url: URL) throws {
        try data(objects).write(to: url, options: .atomic)
    }

    /// Tessellates the bodies and writes them as one 3MF file. `deflection` is the chord error in mm.
    public static func write(_ bodies: [(name: String, body: KBody, color: BodyColor?)], to url: URL, deflection: Double = 0.02) throws {
        let objects = try bodies.map {
            Object(name: $0.name, mesh: try $0.body.tessellate(linearDeflection: deflection), color: $0.color)
        }
        try write(objects, to: url)
    }

    // MARK: Parts

    private static let contentTypes = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/>\
        </Types>
        """

    private static let rels = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Target="/3D/3dmodel.model" Id="rel0" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>\
        </Relationships>
        """

    static func modelXML(_ objects: [Object]) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += "<model unit=\"millimeter\" xml:lang=\"en-US\" xmlns=\"http://schemas.microsoft.com/3dmanufacturing/core/2015/02\" xmlns:m=\"http://schemas.microsoft.com/3dmanufacturing/material/2015/02\">\n"
        xml += "<metadata name=\"Application\">SimplMaker</metadata>\n<resources>\n"

        // Colours go in one colour group of the Materials extension (resource 1); objects point at their entry. Slicers
        // (Bambu Studio, OrcaSlicer) read these and ignore the core spec's base materials.
        var colors: [BodyColor] = []
        var colorIndex: [BodyColor: Int] = [:]
        for color in objects.compactMap(\.color) where colorIndex[color] == nil {
            colorIndex[color] = colors.count
            colors.append(color)
        }
        if !colors.isEmpty {
            xml += "<m:colorgroup id=\"1\">\n"
            for c in colors { xml += "<m:color color=\"\(c.hex)FF\"/>\n" }
            xml += "</m:colorgroup>\n"
        }

        for (n, object) in objects.enumerated() {
            let id = n + 2
            var attributes = "id=\"\(id)\" name=\"\(escape(object.name))\" type=\"model\""
            if let color = object.color, let index = colorIndex[color] { attributes += " pid=\"1\" pindex=\"\(index)\"" }
            xml += "<object \(attributes)>\n<mesh>\n"
            let (vertices, triangles) = welded(object.mesh)
            xml += "<vertices>\n"
            for v in vertices { xml += "<vertex x=\"\(number(v.x))\" y=\"\(number(v.y))\" z=\"\(number(v.z))\"/>\n" }
            xml += "</vertices>\n<triangles>\n"
            for t in triangles { xml += "<triangle v1=\"\(t.0)\" v2=\"\(t.1)\" v3=\"\(t.2)\"/>\n" }
            xml += "</triangles>\n</mesh>\n</object>\n"
        }
        xml += "</resources>\n<build>\n"
        for n in objects.indices { xml += "<item objectid=\"\(n + 2)\"/>\n" }
        xml += "</build>\n</model>\n"
        return xml
    }

    /// The mesh with equal corner points merged, which is what a slicer needs to see a closed surface, and without
    /// the triangles that collapsed to a line or a point when merged.
    static func welded(_ mesh: Mesh) -> (vertices: [SIMD3<Float>], triangles: [(UInt32, UInt32, UInt32)]) {
        struct Key: Hashable { var x: UInt32, y: UInt32, z: UInt32 }
        let count = mesh.positions.count / 3
        var remap = [UInt32](repeating: 0, count: count)
        var seen: [Key: UInt32] = [:]
        var vertices: [SIMD3<Float>] = []
        for i in 0..<count {
            // -0 and 0 are the same point.
            let p = SIMD3(mesh.positions[3 * i] + 0, mesh.positions[3 * i + 1] + 0, mesh.positions[3 * i + 2] + 0)
            let key = Key(x: p.x.bitPattern, y: p.y.bitPattern, z: p.z.bitPattern)
            if let existing = seen[key] { remap[i] = existing; continue }
            let new = UInt32(vertices.count)
            seen[key] = new
            remap[i] = new
            vertices.append(p)
        }
        var triangles: [(UInt32, UInt32, UInt32)] = []
        triangles.reserveCapacity(mesh.indices.count / 3)
        var t = 0
        while t + 2 < mesh.indices.count {
            let i0 = Int(mesh.indices[t]), i1 = Int(mesh.indices[t + 1]), i2 = Int(mesh.indices[t + 2])
            t += 3
            guard i0 < count, i1 < count, i2 < count else { continue }
            let a = remap[i0], b = remap[i1], c = remap[i2]
            if a != b && b != c && a != c { triangles.append((a, b, c)) }
        }
        return (vertices, triangles)
    }

    private static func number(_ v: Float) -> String {
        v == v.rounded() && abs(v) < 1e9 ? String(Int(v)) : String(v)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// A zip file written with stored (uncompressed) entries.
struct ZipWriter {
    private var body = Data()
    private var directory = Data()
    private var entries: UInt16 = 0

    mutating func add(_ name: String, _ content: Data) {
        let nameBytes = Data(name.utf8)
        let crc = Self.crc32(content)
        let offset = UInt32(body.count)
        // Local file header.
        body.appendLE(UInt32(0x04034b50)); body.appendLE(UInt16(20)); body.appendLE(UInt16(0x0800)); body.appendLE(UInt16(0))
        body.appendLE(UInt16(0)); body.appendLE(UInt16(0x21))  // time 00:00, date 1980-01-01
        body.appendLE(crc); body.appendLE(UInt32(content.count)); body.appendLE(UInt32(content.count))
        body.appendLE(UInt16(nameBytes.count)); body.appendLE(UInt16(0))
        body.append(nameBytes); body.append(content)
        // Central directory entry.
        directory.appendLE(UInt32(0x02014b50)); directory.appendLE(UInt16(20)); directory.appendLE(UInt16(20))
        directory.appendLE(UInt16(0x0800)); directory.appendLE(UInt16(0))
        directory.appendLE(UInt16(0)); directory.appendLE(UInt16(0x21))
        directory.appendLE(crc); directory.appendLE(UInt32(content.count)); directory.appendLE(UInt32(content.count))
        directory.appendLE(UInt16(nameBytes.count)); directory.appendLE(UInt16(0)); directory.appendLE(UInt16(0))
        directory.appendLE(UInt16(0)); directory.appendLE(UInt16(0)); directory.appendLE(UInt32(0)); directory.appendLE(offset)
        directory.append(nameBytes)
        entries += 1
    }

    func finish() -> Data {
        var out = body
        let start = UInt32(body.count)
        out.append(directory)
        out.appendLE(UInt32(0x06054b50)); out.appendLE(UInt16(0)); out.appendLE(UInt16(0))
        out.appendLE(entries); out.appendLE(entries)
        out.appendLE(UInt32(directory.count)); out.appendLE(start); out.appendLE(UInt16(0))
        return out
    }

    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
