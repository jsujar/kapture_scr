import XCTest
import UniformTypeIdentifiers
@testable import Kapture

/// Image decoding and the size limits that protect the app from oversized or hostile input (clipboard imports).
final class DecodeTests: XCTestCase {
    private let limits = (maxBytes: 48 * 1024 * 1024, maxSide: 8192, maxPixels: 16_000_000) // clipboard import limits

    private func decode(_ data: Data) -> CGImage? {
        CaptureStore.decode(data, maxBytes: limits.maxBytes, maxSide: limits.maxSide, maxPixels: limits.maxPixels)
    }

    func testDecodesPNGKeepingSizeAndPixels() throws {
        let image = try XCTUnwrap(decode(pngData(width: 120, height: 80, gray: 0)))
        XCTAssertEqual(image.width, 120)
        XCTAssertEqual(image.height, 80)
        XCTAssertEqual(Pixels(image).at(60, 40), black)
    }

    func testDecodesTIFF() throws {
        let tiff = encoded(solidImage(width: 50, height: 40), as: .tiff)
        let image = try XCTUnwrap(decode(tiff))
        XCTAssertEqual(image.width, 50)
        XCTAssertEqual(image.height, 40)
    }

    func testOutputIsFlattenedToSRGB() throws {
        let image = try XCTUnwrap(decode(pngData(width: 10, height: 10)))
        XCTAssertEqual(image.colorSpace?.name, CGColorSpace.sRGB)
        XCTAssertEqual(image.bitsPerComponent, 8)
        XCTAssertEqual(image.alphaInfo, .premultipliedLast)
    }

    func testRejectsDataOverByteLimit() {
        let data = pngData(width: 64, height: 64)
        XCTAssertNil(CaptureStore.decode(data, maxBytes: data.count - 1, maxSide: 8192, maxPixels: 16_000_000))
        XCTAssertNotNil(CaptureStore.decode(data, maxBytes: data.count, maxSide: 8192, maxPixels: 16_000_000))
    }

    func testRejectsSideOverLimit() {
        XCTAssertNil(decode(pngData(width: 8193, height: 10)))
        XCTAssertNil(decode(pngData(width: 10, height: 8193)))
        XCTAssertNotNil(decode(pngData(width: 8192, height: 10)))
    }

    func testRejectsPixelCountOverLimit() {
        // 5000 × 3201 = 16,005,000 px: each side is allowed, the area is not.
        XCTAssertNil(decode(pngData(width: 5000, height: 3201)))
        XCTAssertNotNil(decode(pngData(width: 5000, height: 3200)))
    }

    func testRejectsGarbageAndEmptyData() {
        XCTAssertNil(decode(Data()))
        XCTAssertNil(decode(Data("not an image".utf8)))
        var truncated = pngData(width: 100, height: 100)
        truncated = truncated.prefix(40)
        XCTAssertNil(decode(truncated))
    }

    func testPNGEncodingRoundTrips() throws {
        let original = solidImage(width: 33, height: 21, gray: 0)
        let data = try XCTUnwrap(FolderAccess.pngData(original))
        XCTAssertEqual(Array(data.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) // PNG signature
        let back = try XCTUnwrap(decode(data))
        XCTAssertEqual(Pixels(back), Pixels(original))
    }
}
