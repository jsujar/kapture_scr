import XCTest
@testable import Kapture

/// The in-memory history: newest first, at most 10 images, 128 MiB of raster data and 30 minutes.
final class HistoryTests: XCTestCase {
    func testNewCaptureGoesFirstAndIsSelected() throws {
        let store = CaptureStore(settings: Settings())
        let a = try XCTUnwrap(store.addOwnCapture(pngData(width: 10, height: 10), baseName: "a"))
        let b = try XCTUnwrap(store.addOwnCapture(pngData(width: 10, height: 10), baseName: "b"))
        XCTAssertEqual(store.captures.map(\.id), [b.id, a.id])
        XCTAssertEqual(store.selected, b.id)
        XCTAssertEqual(store.current?.baseName, "b")
    }

    func testKeepsAtMostTenImagesDroppingTheOldest() {
        let store = CaptureStore(settings: Settings())
        for i in 0..<15 { _ = store.addOwnCapture(pngData(width: 20, height: 20), baseName: "\(i)") }
        XCTAssertEqual(store.captures.count, 10)
        XCTAssertEqual(store.captures.first?.baseName, "14")
        XCTAssertEqual(store.captures.last?.baseName, "5")
    }

    func testKeepsRasterDataWithin128MiB() {
        // 4000 × 3000 × 4 bytes ≈ 45.8 MiB each: two fit, a third would exceed 128 MiB.
        let store = CaptureStore(settings: Settings())
        let big = pngData(width: 4000, height: 3000)
        for i in 0..<4 { _ = store.addOwnCapture(big, baseName: "\(i)") }
        let total = store.captures.reduce(0) { $0 + $1.image.bytesPerRow * $1.image.height }
        XCTAssertLessThanOrEqual(total, 128 * 1024 * 1024)
        XCTAssertEqual(store.captures.map(\.baseName), ["3", "2"])
    }

    func testKeepsANewCaptureEvenIfItAloneExceedsTheMemoryLimit() {
        // 6000 × 6000 × 4 bytes ≈ 137 MiB: still shown, but it replaces everything else.
        let store = CaptureStore(settings: Settings())
        _ = store.addOwnCapture(pngData(width: 10, height: 10), baseName: "small")
        _ = store.addOwnCapture(pngData(width: 6000, height: 6000), baseName: "huge")
        XCTAssertEqual(store.captures.map(\.baseName), ["huge"])
    }

    func testOwnCaptureLimits() {
        let store = CaptureStore(settings: Settings())
        XCTAssertNil(store.addOwnCapture(pngData(width: 16385, height: 2), baseName: "too wide"))
        XCTAssertNil(store.addOwnCapture(Data("junk".utf8), baseName: "junk"))
        XCTAssertNotNil(store.addOwnCapture(pngData(width: 16384, height: 2), baseName: "max side"))
    }

    func testExpiresCapturesAfterThirtyMinutes() {
        let store = CaptureStore(settings: Settings())
        _ = store.addOwnCapture(pngData(width: 10, height: 10), baseName: "a")
        store.expire(now: Date().addingTimeInterval(29 * 60))
        XCTAssertEqual(store.captures.count, 1, "still within 30 minutes")
        store.expire(now: Date().addingTimeInterval(31 * 60))
        XCTAssertTrue(store.captures.isEmpty)
        XCTAssertNil(store.selected)
    }

    func testExpiryReselectsTheNewestRemainingCapture() throws {
        let store = CaptureStore(settings: Settings())
        let old = try XCTUnwrap(store.addOwnCapture(pngData(width: 10, height: 10), baseName: "old"))
        let cutoff = Date().addingTimeInterval(1800.25)
        Thread.sleep(forTimeInterval: 0.5)
        let fresh = try XCTUnwrap(store.addOwnCapture(pngData(width: 10, height: 10), baseName: "fresh"))
        store.select(old.id)
        store.expire(now: cutoff) // past "old"'s expiry, before "fresh"'s
        XCTAssertEqual(store.captures.map(\.id), [fresh.id])
        XCTAssertEqual(store.selected, fresh.id)
    }

    func testRemoveDeletesSelectedAndSelectsNewest() throws {
        let store = CaptureStore(settings: Settings())
        let a = try XCTUnwrap(store.addOwnCapture(pngData(width: 10, height: 10), baseName: "a"))
        _ = store.addOwnCapture(pngData(width: 10, height: 10), baseName: "b")
        store.remove()
        XCTAssertEqual(store.captures.map(\.id), [a.id])
        XCTAssertEqual(store.selected, a.id)
    }

    func testClearEmptiesEverything() {
        let store = storeWithCapture()
        store.edit(tool: .redact, start: CGPoint(x: 0.1, y: 0.1), end: CGPoint(x: 0.5, y: 0.5), text: "")
        store.clear()
        XCTAssertTrue(store.captures.isEmpty)
        XCTAssertNil(store.selected)
        XCTAssertFalse(store.canUndo)
    }
}
