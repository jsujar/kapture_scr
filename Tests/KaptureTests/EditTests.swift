import XCTest
@testable import Kapture

/// Pixel edits and the undo/redo history.
final class EditTests: XCTestCase {
    private func pixels(_ store: CaptureStore) -> Pixels { Pixels(store.current!.image) }

    // MARK: Redact

    func testRedactPaintsOnlyTheSelectedArea() {
        let store = storeWithCapture(width: 400, height: 300)
        // Top-left quarter, in the editor's normalized top-left coordinates.
        store.edit(tool: .redact, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0.5, y: 0.5), text: "")
        let p = pixels(store)
        XCTAssertEqual(p.at(10, 10), black)
        XCTAssertEqual(p.at(190, 140), black)
        XCTAssertEqual(p.at(210, 10), white, "right of the area")
        XCTAssertEqual(p.at(10, 160), white, "below the area")
        XCTAssertEqual(p.at(390, 290), white)
    }

    func testRedactWorksWhenDraggedBackwards() {
        let store = storeWithCapture(width: 400, height: 300)
        store.edit(tool: .redact, start: CGPoint(x: 1, y: 1), end: CGPoint(x: 0.5, y: 0.5), text: "")
        let p = pixels(store)
        XCTAssertEqual(p.at(390, 290), black)
        XCTAssertEqual(p.at(10, 10), white)
    }

    // MARK: Crop

    func testCropKeepsTheSelectedRegion() {
        let store = storeWithCapture(width: 400, height: 300)
        store.edit(tool: .redact, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0.5, y: 0.5), text: "")
        store.edit(tool: .crop, start: CGPoint(x: 0.25, y: 0.25), end: CGPoint(x: 0.75, y: 0.75), text: "")
        let p = pixels(store)
        XCTAssertEqual(p.width, 200)
        XCTAssertEqual(p.height, 150)
        XCTAssertEqual(p.at(10, 10), black, "the cropped image starts inside the redacted area")
        XCTAssertEqual(p.at(190, 140), white)
    }

    func testCropClampsPointsOutsideTheImage() {
        let store = storeWithCapture(width: 400, height: 300)
        store.edit(tool: .crop, start: CGPoint(x: -0.5, y: -0.5), end: CGPoint(x: 1.5, y: 1.5), text: "")
        XCTAssertEqual(pixels(store).width, 400)
        XCTAssertEqual(pixels(store).height, 300)
    }

    func testTinyCropIsIgnored() {
        let store = storeWithCapture(width: 400, height: 300)
        store.edit(tool: .crop, start: CGPoint(x: 0.5, y: 0.5), end: CGPoint(x: 0.501, y: 0.501), text: "")
        XCTAssertEqual(pixels(store).width, 400)
        XCTAssertFalse(store.canUndo, "nothing was applied")
    }

    // MARK: Arrow and text

    func testArrowDrawsRedPixels() {
        let store = storeWithCapture(width: 400, height: 300)
        store.edit(tool: .arrow, start: CGPoint(x: 0.1, y: 0.5), end: CGPoint(x: 0.9, y: 0.5), text: "")
        let mid = pixels(store).at(200, 150)
        XCTAssertGreaterThan(mid[0], 150, "red")
        XCTAssertLessThan(mid[1], 120)
        XCTAssertLessThan(mid[2], 120)
    }

    func testZeroLengthArrowLeavesPixelsUnchanged() {
        let store = storeWithCapture()
        let before = pixels(store)
        store.edit(tool: .arrow, start: CGPoint(x: 0.5, y: 0.5), end: CGPoint(x: 0.5, y: 0.5), text: "")
        XCTAssertEqual(pixels(store), before)
    }

    func testTextChangesPixelsAndBlankTextDoesNot() {
        let store = storeWithCapture()
        let before = pixels(store)
        store.edit(tool: .text, start: CGPoint(x: 0.2, y: 0.5), end: CGPoint(x: 0.2, y: 0.5), text: "   \n ")
        XCTAssertEqual(pixels(store), before, "whitespace only")
        store.edit(tool: .text, start: CGPoint(x: 0.2, y: 0.5), end: CGPoint(x: 0.2, y: 0.5), text: "Hola · مرحبا · 你好")
        XCTAssertNotEqual(pixels(store), before)
        XCTAssertEqual(pixels(store).width, before.width, "text never resizes the image")
    }

    // MARK: Undo and redo

    func testUndoAndRedoRestoreExactPixels() {
        let store = storeWithCapture()
        let original = pixels(store)
        store.edit(tool: .redact, start: CGPoint(x: 0.1, y: 0.1), end: CGPoint(x: 0.6, y: 0.6), text: "")
        let edited = pixels(store)
        XCTAssertNotEqual(edited, original)
        XCTAssertTrue(store.canUndo)
        store.undo()
        XCTAssertEqual(pixels(store), original)
        XCTAssertTrue(store.canRedo)
        store.redo()
        XCTAssertEqual(pixels(store), edited)
    }

    func testUndoKeepsAtMostFiveSteps() {
        let store = storeWithCapture()
        for i in 0..<8 {
            let x = CGFloat(i) / 10
            store.edit(tool: .redact, start: CGPoint(x: x, y: 0), end: CGPoint(x: x + 0.05, y: 0.1), text: "")
        }
        var steps = 0
        while store.canUndo { store.undo(); steps += 1 }
        XCTAssertEqual(steps, 5)
    }

    func testUndoMemoryStaysWithin64MiB() {
        // 4000 × 3000 × 4 bytes ≈ 45.8 MiB per step: only one previous image fits.
        let store = storeWithCapture(width: 4000, height: 3000)
        for _ in 0..<3 { store.edit(tool: .redact, start: CGPoint(x: 0.1, y: 0.1), end: CGPoint(x: 0.2, y: 0.2), text: "") }
        var steps = 0
        while store.canUndo { store.undo(); steps += 1 }
        XCTAssertEqual(steps, 1)
    }

    func testNewEditClearsRedo() {
        let store = storeWithCapture()
        store.edit(tool: .redact, start: CGPoint(x: 0.1, y: 0.1), end: CGPoint(x: 0.3, y: 0.3), text: "")
        store.undo()
        XCTAssertTrue(store.canRedo)
        store.edit(tool: .redact, start: CGPoint(x: 0.5, y: 0.5), end: CGPoint(x: 0.7, y: 0.7), text: "")
        XCTAssertFalse(store.canRedo)
    }

    func testSelectingAnotherCaptureResetsUndo() throws {
        let store = CaptureStore(settings: Settings())
        let first = try XCTUnwrap(store.addOwnCapture(pngData(width: 100, height: 100), baseName: "first"))
        _ = store.addOwnCapture(pngData(width: 100, height: 100), baseName: "second")
        store.edit(tool: .redact, start: CGPoint(x: 0.1, y: 0.1), end: CGPoint(x: 0.5, y: 0.5), text: "")
        XCTAssertTrue(store.canUndo)
        store.select(first.id)
        XCTAssertFalse(store.canUndo, "undo never applies one capture's history to another")
        store.undo()
        XCTAssertEqual(Pixels(store.current!.image).at(20, 20), white)
    }

    func testEditWithoutSelectionDoesNothing() {
        let store = CaptureStore(settings: Settings())
        store.edit(tool: .redact, start: .zero, end: CGPoint(x: 1, y: 1), text: "")
        XCTAssertTrue(store.captures.isEmpty)
        XCTAssertFalse(store.canUndo)
    }
}
