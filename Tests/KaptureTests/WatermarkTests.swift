import XCTest
import UniformTypeIdentifiers
@testable import Kapture

/// Automatic watermark: placement, size, opacity, pattern, settings and how it reaches captures.
final class WatermarkTests: XCTestCase {
    private let canvas = CGSize(width: 1000, height: 500)
    private lazy var mark = solidImage(width: 100, height: 50, gray: 0) // black, 2:1
    private lazy var page = solidImage(width: 1000, height: 500)        // white

    private func options(x: Double, y: Double, size: Double = 0.1, opacity: Double = 1, tiled: Bool = false) -> WatermarkOptions {
        WatermarkOptions(x: x, y: y, size: size, opacity: opacity, tiled: tiled)
    }

    private func applied(_ o: WatermarkOptions, mark: CGImage? = nil) throws -> Pixels {
        Pixels(try XCTUnwrap(Watermark.apply(mark ?? self.mark, to: page, options: o)))
    }

    private func isolatedSettings() -> Settings {
        let suite = "KaptureTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return Settings(defaults: defaults)
    }

    // MARK: Placement

    func testBottomRight() throws {
        let p = try applied(options(x: 1, y: 1))
        XCTAssertEqual(p.at(950, 475), black)
        XCTAssertEqual(p.at(999, 499), black, "touches the corner")
        XCTAssertEqual(p.at(890, 475), white, "mark is 100 px wide")
        XCTAssertEqual(p.at(950, 440), white, "mark is 50 px tall")
        XCTAssertEqual(p.at(50, 25), white)
    }

    func testTopLeft() throws {
        let p = try applied(options(x: 0, y: 0))
        XCTAssertEqual(p.at(0, 0), black)
        XCTAssertEqual(p.at(99, 49), black)
        XCTAssertEqual(p.at(110, 25), white)
        XCTAssertEqual(p.at(950, 475), white)
    }

    func testCentre() throws {
        let p = try applied(options(x: 0.5, y: 0.5))
        XCTAssertEqual(p.at(500, 250), black)
        XCTAssertEqual(p.at(445, 250), white)
        XCTAssertEqual(p.at(555, 250), white)
    }

    func testSingleMarkAlwaysStaysInside() {
        let bounds = CGRect(origin: .zero, size: canvas)
        for x in [-1, 0, 0.3, 0.5, 1, 2.0] { for y in [-1, 0, 0.7, 1, 3.0] { for size in [0, 0.03, 0.2, 0.6, 5.0] {
            let rects = Watermark.rects(mark: mark, canvas: canvas, options: options(x: x, y: y, size: size))
            XCTAssertEqual(rects.count, 1)
            XCTAssertTrue(bounds.contains(rects[0]), "x \(x) y \(y) size \(size): \(rects[0])")
        } } }
    }

    // MARK: Size and opacity

    func testSizeIsAFractionOfTheWidthKeepingProportions() {
        let s = Watermark.markSize(mark, canvas: canvas, size: 0.25)
        XCTAssertEqual(s, CGSize(width: 250, height: 125))
        XCTAssertEqual(Watermark.markSize(mark, canvas: CGSize(width: 4000, height: 2000), size: 0.25), CGSize(width: 1000, height: 500),
                       "same proportion of the capture on a larger display")
    }

    func testTallMarkIsShrunkToFitTheHeight() {
        let tall = solidImage(width: 100, height: 400)
        let s = Watermark.markSize(tall, canvas: canvas, size: 0.6) // 600 × 2400 would not fit
        XCTAssertEqual(s, CGSize(width: 125, height: 500))
    }

    func testSizeIsClampedToItsRange() {
        XCTAssertEqual(Watermark.markSize(mark, canvas: canvas, size: 0).width, 30, "3% minimum")
        XCTAssertEqual(Watermark.markSize(mark, canvas: canvas, size: 9).width, 600, "60% maximum")
    }

    func testOpacityBlendsTheMark() throws {
        let p = try applied(options(x: 0.5, y: 0.5, opacity: 0.5))
        let mid = p.at(500, 250)
        XCTAssertEqual(Int(mid[0]), 128, accuracy: 3)
        XCTAssertEqual(mid[3], 255, "the capture stays opaque")
    }

    func testTransparentPartsOfTheMarkLeaveTheCaptureUntouched() throws {
        // Left half black, right half fully transparent.
        let ctx = CGContext(data: nil, width: 100, height: 50, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 50, height: 50))
        let p = try applied(options(x: 0, y: 0), mark: ctx.makeImage()!)
        XCTAssertEqual(p.at(25, 25), black)
        XCTAssertEqual(p.at(75, 25), white)
    }

    // MARK: Pattern

    func testPatternCoversTheWholeCapture() {
        let rects = Watermark.rects(mark: mark, canvas: canvas, options: options(x: 0, y: 0, tiled: true))
        XCTAssertGreaterThan(rects.count, 8)
        let quadrants = [CGRect(x: 0, y: 0, width: 500, height: 250), CGRect(x: 500, y: 0, width: 500, height: 250),
                         CGRect(x: 0, y: 250, width: 500, height: 250), CGRect(x: 500, y: 250, width: 500, height: 250)]
        for q in quadrants { XCTAssertTrue(rects.contains { $0.intersects(q) }, "no mark in \(q)") }
        XCTAssertTrue(rects.allSatisfy { $0.intersects(CGRect(origin: .zero, size: canvas)) }, "no marks drawn off the image")
    }

    func testPatternLeavesGapsBetweenMarks() throws {
        let p = try applied(options(x: 0, y: 0, tiled: true))
        let pixels = stride(from: 0, to: 1000, by: 10).flatMap { x in stride(from: 0, to: 500, by: 10).map { p.at(x, $0) } }
        let dark = pixels.filter { $0 == black }.count
        XCTAssertGreaterThan(dark, pixels.count / 10)
        XCTAssertLessThan(dark, pixels.count / 2, "about a quarter of the image is covered")
    }

    func testPatternMovesWithPosition() {
        let a = Watermark.rects(mark: mark, canvas: canvas, options: options(x: 0, y: 0, tiled: true))
        let b = Watermark.rects(mark: mark, canvas: canvas, options: options(x: 0.5, y: 0.5, tiled: true))
        XCTAssertNotEqual(a, b)
    }

    func testPatternWithAThinMarkStaysBounded() {
        let thin = solidImage(width: 4000, height: 1)
        let rects = Watermark.rects(mark: thin, canvas: CGSize(width: 6016, height: 3384), options: options(x: 0, y: 0, size: 0.03, tiled: true))
        XCTAssertLessThan(rects.count, 3000)
    }

    // MARK: Captures and imports

    func testCapturesGetTheWatermarkWhenOn() throws {
        let settings = isolatedSettings()
        settings.watermarkEnabled = true
        settings.watermark = options(x: 1, y: 1)
        let store = CaptureStore(settings: settings)
        store.watermarkImage = mark
        XCTAssertTrue(store.watermarkActive)
        let capture = try XCTUnwrap(store.addOwnCapture(pngData(width: 1000, height: 500), baseName: "a"))
        XCTAssertEqual(Pixels(capture.image).at(950, 475), black)
        XCTAssertEqual(Pixels(capture.image).at(50, 25), white)
    }

    func testNoWatermarkWhenOffOrWithoutImage() throws {
        let settings = isolatedSettings()
        settings.watermark = options(x: 1, y: 1)
        let store = CaptureStore(settings: settings)
        store.watermarkImage = mark
        let off = try XCTUnwrap(store.addOwnCapture(pngData(width: 1000, height: 500), baseName: "off"))
        XCTAssertEqual(Pixels(off.image).at(950, 475), white, "turned off")

        settings.watermarkEnabled = true
        store.watermarkImage = nil
        XCTAssertFalse(store.watermarkActive)
        let noImage = try XCTUnwrap(store.addOwnCapture(pngData(width: 1000, height: 500), baseName: "none"))
        XCTAssertEqual(Pixels(noImage.image).at(950, 475), white, "no image chosen")
    }

    func testEditingDoesNotAddTheWatermarkAgain() throws {
        let settings = isolatedSettings()
        settings.watermarkEnabled = true
        settings.watermark = options(x: 0.5, y: 0.5, opacity: 0.5)
        let store = CaptureStore(settings: settings)
        store.watermarkImage = mark
        _ = store.addOwnCapture(pngData(width: 1000, height: 500), baseName: "a")
        let before = Pixels(store.current!.image).at(500, 250)
        store.edit(tool: .redact, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0.1, y: 0.1), text: "")
        XCTAssertEqual(Pixels(store.current!.image).at(500, 250), before, "a second pass would darken the mark")
    }

    // MARK: Settings and the stored image

    func testSettingsRoundTripAndDefaults() {
        let settings = isolatedSettings()
        XCTAssertFalse(settings.watermarkEnabled, "off by default")
        XCTAssertEqual(settings.watermark, WatermarkOptions())
        let custom = options(x: 0.1, y: 0.9, size: 0.33, opacity: 0.4, tiled: true)
        settings.watermark = custom
        settings.watermarkEnabled = true
        XCTAssertEqual(settings.watermark, custom)
        XCTAssertTrue(settings.watermarkEnabled)
    }

    func testStoredImageRoundTripsAndRejectsInvalidImages() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("KaptureTests-\(UUID().uuidString)/watermark.png")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let source = encoded(solidImage(width: 120, height: 60, gray: 0), as: .jpeg)
        let stored = try XCTUnwrap(Watermark.store(source, at: url))
        XCTAssertEqual(stored.width, 120)
        let loaded = try XCTUnwrap(Watermark.loadStored(from: url))
        XCTAssertEqual(Pixels(loaded), Pixels(stored), "kept as a lossless PNG copy")

        XCTAssertNil(Watermark.store(Data("junk".utf8), at: url))
        XCTAssertNil(Watermark.store(pngData(width: 4097, height: 10), at: url), "over 4096 px")
        Watermark.removeStored(at: url)
        XCTAssertNil(Watermark.loadStored(from: url))
    }

    func testJPEGFilesAreFlattenedOntoWhite() throws {
        let clear = CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        let jpeg = try XCTUnwrap(FolderAccess.encode(clear, as: .jpg))
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8], "JPEG signature")
        let back = try XCTUnwrap(CaptureStore.decode(jpeg, maxBytes: 1 << 20, maxSide: 100, maxPixels: 10_000))
        XCTAssertGreaterThan(Pixels(back).at(10, 10)[0], 250, "transparent areas become white, not black")
        XCTAssertEqual(Array(try XCTUnwrap(FolderAccess.encode(clear, as: .png)).prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }
}
