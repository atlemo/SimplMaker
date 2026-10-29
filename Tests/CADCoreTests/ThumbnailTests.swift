import XCTest
@testable import CADCore

final class ThumbnailTests: XCTestCase {
    func testThumbnailIsStoredInTheFileAndReadBack() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let data = try CADDocument().encoded(thumbnail: png)
        XCTAssertEqual(CADDocument.thumbnail(in: data), png)
        XCTAssertEqual(try CADDocument.decode(data), CADDocument())  // the design itself is unchanged
    }

    func testFileWithoutThumbnailHasNone() throws {
        XCTAssertNil(CADDocument.thumbnail(in: try CADDocument().encoded()))
    }
}
