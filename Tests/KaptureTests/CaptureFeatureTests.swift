import XCTest
import Carbon
@testable import Kapture

/// Repeat capture: the screencapture arguments for each target, and finding the window the user picked.
final class RepeatCaptureTests: XCTestCase {
    private let main = NSRect(x: 0, y: 0, width: 1440, height: 900)

    private func args(mode: CaptureMode = .selection, region: NSRect? = nil, window: CGWindowID? = nil, delay: Int = 0,
                      cursor: Bool = false, shadow: Bool = true) -> [String] {
        ScreenCapturer.arguments(format: .png, mode: mode, region: region, windowID: window, delay: delay,
                                 showCursor: cursor, windowShadow: shadow, mainScreen: main)
    }

    func testRegionUsesTopLeftOriginOfTheMainDisplay() {
        // Cocoa rect from the bottom-left: 100 pt from the left, 200 pt from the bottom, 300 × 150.
        XCTAssertEqual(args(region: NSRect(x: 100, y: 200, width: 300, height: 150)), ["-t", "png", "-R100,550,300,150"])
    }

    func testRegionOnASecondDisplayAboveOrLeft() {
        XCTAssertEqual(args(region: NSRect(x: -800, y: 1000, width: 200, height: 100)), ["-t", "png", "-R-800,-200,200,100"])
    }

    func testWindowIsCapturedByNumberWithoutThePicker() {
        XCTAssertEqual(args(mode: .window, window: 4242), ["-t", "png", "-l4242"])
        XCTAssertEqual(args(mode: .window, window: 4242, shadow: false), ["-t", "png", "-l4242", "-o"], "window shadow setting still applies")
    }

    func testInteractiveWindowAndScreen() {
        XCTAssertEqual(args(mode: .window), ["-t", "png", "-i", "-w"])
        XCTAssertEqual(args(mode: .screen), ["-t", "png", "-m"])
    }

    func testOptions() {
        XCTAssertEqual(args(mode: .screen, delay: 5, cursor: true, shadow: false), ["-t", "png", "-m", "-T", "5", "-C", "-o"])
        XCTAssertEqual(ScreenCapturer.arguments(format: .jpg, mode: .screen, region: nil, windowID: nil, delay: 0,
                                                showCursor: false, windowShadow: true, mainScreen: main), ["-t", "jpg", "-m"])
    }

    // MARK: Finding the picked window

    private func window(_ number: Int, _ bounds: CGRect, layer: Int = 0, pid: pid_t = 100, alpha: Double = 1) -> [String: Any] {
        [kCGWindowNumber as String: number, kCGWindowLayer as String: layer, kCGWindowOwnerPID as String: pid,
         kCGWindowAlpha as String: alpha, kCGWindowBounds as String: bounds.dictionaryRepresentation]
    }

    func testPicksTheFrontMostWindowUnderThePointer() {
        // Window bounds use a top-left origin; the pointer uses Cocoa's bottom-left origin (900 pt tall display).
        let windows = [window(1, CGRect(x: 0, y: 0, width: 400, height: 300)), window(2, CGRect(x: 0, y: 0, width: 1000, height: 800))]
        XCTAssertEqual(ScreenCapturer.windowID(at: NSPoint(x: 100, y: 800), in: windows, mainScreenHeight: 900, excludingPID: 1), 1, "front window")
        XCTAssertEqual(ScreenCapturer.windowID(at: NSPoint(x: 600, y: 800), in: windows, mainScreenHeight: 900, excludingPID: 1), 2, "only the back one there")
        XCTAssertNil(ScreenCapturer.windowID(at: NSPoint(x: 1200, y: 50), in: windows, mainScreenHeight: 900, excludingPID: 1))
    }

    func testIgnoresMenuBarDockOwnAppAndInvisibleWindows() {
        let windows = [
            window(9, CGRect(x: 0, y: 0, width: 1440, height: 25), layer: 24), // menu bar
            window(8, CGRect(x: 0, y: 0, width: 1440, height: 900), pid: 1),     // Kapture SCR's own overlay
            window(7, CGRect(x: 0, y: 0, width: 1440, height: 900), alpha: 0),   // invisible
            window(6, CGRect(x: 0, y: 0, width: 1440, height: 900)),
        ]
        XCTAssertEqual(ScreenCapturer.windowID(at: NSPoint(x: 10, y: 890), in: windows, mainScreenHeight: 900, excludingPID: 1), 6)
    }

    func testWindowExists() {
        let windows = [window(5, .zero), window(6, .zero)]
        XCTAssertTrue(ScreenCapturer.windowExists(6, in: windows))
        XCTAssertFalse(ScreenCapturer.windowExists(7, in: windows))
    }

    func testNothingToRepeatAtFirst() {
        let capturer = ScreenCapturer()
        XCTAssertNil(capturer.last)
        XCTAssertEqual(capturer.repeatLast(Settings(defaults: UserDefaults(suiteName: "KaptureTests-\(UUID().uuidString)")!)) { _ in }, .nothingToRepeat)
    }

    func testRepeatShortcutDefault() {
        let s = ShortcutAction.repeatCapture.defaultShortcut
        XCTAssertEqual(s.display, "⇧⌘8")
        XCTAssertTrue(s.isAllowed)
        XCTAssertFalse(s.isReserved)
        // ⌘⇧5 belongs to macOS's screenshot toolbar.
        XCTAssertTrue(Shortcut(keyCode: UInt32(kVK_ANSI_5), modifiers: UInt32(cmdKey | shiftKey), chars: "5").isReserved)
    }
}

/// Highlighter: smooth multiply strokes in the chosen colour and width.
final class HighlightTests: XCTestCase {
    private func store(gray: CGFloat = 1) -> CaptureStore {
        let store = CaptureStore(settings: Settings(defaults: UserDefaults(suiteName: "KaptureTests-\(UUID().uuidString)")!))
        _ = store.addOwnCapture(pngData(width: 900, height: 600, gray: gray), baseName: "h")
        return store
    }
    private let yellow = RGB(r: 1, g: 0.86, b: 0.1)

    func testStrokeTintsWhiteWithTheColour() {
        let s = store()
        s.highlight(points: [CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.9, y: 0.5)], color: yellow, size: .medium)
        let p = Pixels(s.current!.image)
        let mid = p.at(450, 300)
        XCTAssertEqual(Int(mid[0]), 255, accuracy: 2)
        XCTAssertEqual(Int(mid[1]), 219, accuracy: 3)
        XCTAssertEqual(Int(mid[2]), 26, accuracy: 3)
        XCTAssertEqual(p.at(450, 100), white, "away from the stroke")
    }

    func testDarkContentStaysDark() {
        // Multiply: black text under the marker stays black, so it remains readable.
        let s = store(gray: 0)
        s.highlight(points: [CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.9, y: 0.5)], color: yellow, size: .thick)
        XCTAssertEqual(Pixels(s.current!.image).at(450, 300), black)
    }

    func testWidthFollowsTheSizeAndTheImage() {
        let size = CGSize(width: 900, height: 600)
        XCTAssertLessThan(HighlightSize.thin.width(for: size), HighlightSize.medium.width(for: size))
        XCTAssertLessThan(HighlightSize.medium.width(for: size), HighlightSize.thick.width(for: size))
        XCTAssertEqual(HighlightSize.medium.width(for: CGSize(width: 1800, height: 1200)), HighlightSize.medium.width(for: size) * 2, accuracy: 0.01)

        let s = store()
        s.highlight(points: [CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.9, y: 0.5)], color: yellow, size: .medium)
        let half = HighlightSize.medium.width(for: size) / 2 // 600/180 × 4 / 2 ≈ 6.7 px
        let p = Pixels(s.current!.image)
        XCTAssertNotEqual(p.at(450, 300 + Int(half) - 2), white, "inside the stroke")
        XCTAssertEqual(p.at(450, 300 + Int(half) + 3), white, "outside the stroke")
    }

    func testSingleClickDrawsADot() {
        let s = store()
        s.highlight(points: [CGPoint(x: 0.5, y: 0.5)], color: yellow, size: .thick)
        XCTAssertNotEqual(Pixels(s.current!.image).at(450, 300), white)
    }

    func testUndoRestoresAndColourIsRemembered() {
        let settings = Settings(defaults: UserDefaults(suiteName: "KaptureTests-\(UUID().uuidString)")!)
        let s = CaptureStore(settings: settings)
        _ = s.addOwnCapture(pngData(width: 300, height: 200), baseName: "h")
        let before = Pixels(s.current!.image)
        s.highlight(points: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.8)], color: yellow, size: .thin)
        XCTAssertTrue(s.canUndo)
        s.undo()
        XCTAssertEqual(Pixels(s.current!.image), before)

        s.highlightColor = RGB.highlighterPresets[3].0
        s.highlightSize = .thick
        let again = CaptureStore(settings: settings)
        XCTAssertEqual(again.highlightColor, RGB.highlighterPresets[3].0)
        XCTAssertEqual(again.highlightSize, .thick)
    }

    func testSmoothPathPassesThroughTheEnds() {
        let path = smoothPath([CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 5), CGPoint(x: 20, y: 0)])
        XCTAssertEqual(path.currentPoint, CGPoint(x: 20, y: 0))
        XCTAssertTrue(smoothPath([]).isEmpty)
    }
}

/// Automatic number: placement, font, colour, opacity, and how it counts up.
final class NumberStampTests: XCTestCase {
    private func settings() -> Settings {
        let suite = "KaptureTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return Settings(defaults: defaults)
    }
    private let canvas = CGSize(width: 1000, height: 500)

    private func darkPixels(_ p: Pixels, in rect: CGRect) -> Int {
        var n = 0
        for y in stride(from: Int(rect.minY), to: Int(rect.maxY), by: 2) {
            for x in stride(from: Int(rect.minX), to: Int(rect.maxX), by: 2) where p.at(x, y)[1] < 128 { n += 1 }
        }
        return n
    }

    func testDrawnWhereChosen() throws {
        let options = NumberOptions(x: 1, y: 1, size: 0.2, opacity: 1, font: "", color: RGB(r: 0, g: 0, b: 0))
        let image = try XCTUnwrap(NumberStamp.apply(7, to: solidImage(width: 1000, height: 500), options: options))
        let p = Pixels(image)
        XCTAssertGreaterThan(darkPixels(p, in: CGRect(x: 850, y: 380, width: 150, height: 120)), 20, "bottom-right corner")
        XCTAssertEqual(darkPixels(p, in: CGRect(x: 0, y: 0, width: 500, height: 250)), 0, "nothing elsewhere")
    }

    func testAlwaysInsideAndSizedByHeight() {
        let bounds = CGRect(origin: .zero, size: canvas)
        for x in [-1, 0, 0.5, 1, 2.0] { for y in [-1, 0, 1, 3.0] { for size in [0, 0.1, 0.4, 9.0] {
            let r = NumberStamp.rect(for: 123456, canvas: canvas, options: NumberOptions(x: x, y: y, size: size))
            XCTAssertTrue(bounds.contains(r), "\(x) \(y) \(size) → \(r)")
        } } }
        let small = NumberStamp.rect(for: 5, canvas: canvas, options: NumberOptions(size: 0.05))
        let big = NumberStamp.rect(for: 5, canvas: canvas, options: NumberOptions(size: 0.2))
        XCTAssertGreaterThan(big.height, small.height * 3)
    }

    func testUnknownFontFallsBackToTheSystemFont() {
        XCTAssertEqual(NumberStamp.font(family: "No Such Font 123", size: 20).familyName, NSFont.systemFont(ofSize: 20).familyName)
        XCTAssertEqual(NumberStamp.font(family: "Helvetica", size: 20).familyName, "Helvetica")
    }

    func testOutlineContrastsWithTheColour() {
        let light = NumberStamp.attributes(NumberOptions(color: RGB(r: 1, g: 1, b: 1)), canvas: canvas)[.strokeColor] as? NSColor
        let dark = NumberStamp.attributes(NumberOptions(color: RGB(r: 0, g: 0, b: 0)), canvas: canvas)[.strokeColor] as? NSColor
        XCTAssertLessThan(light?.usingColorSpace(.sRGB)?.redComponent ?? 1, 0.1, "white number, dark outline")
        XCTAssertGreaterThan(dark?.usingColorSpace(.sRGB)?.redComponent ?? 0, 0.9, "black number, light outline")
    }

    func testCountsUpOnEveryCaptureAndImport() {
        let settings = settings()
        settings.numberEnabled = true
        settings.numberNext = 41
        let store = CaptureStore(settings: settings)
        for _ in 0..<3 { _ = store.addOwnCapture(pngData(width: 400, height: 300), baseName: "n") }
        XCTAssertEqual(settings.numberNext, 44)
        XCTAssertTrue(store.stampActive)
    }

    func testFixedNumberWhenNotIncreasing() {
        let settings = settings()
        settings.numberEnabled = true
        settings.numberIncrement = false
        settings.numberNext = 5
        let store = CaptureStore(settings: settings)
        let a = store.addOwnCapture(pngData(width: 400, height: 300), baseName: "a")!
        let b = store.addOwnCapture(pngData(width: 400, height: 300), baseName: "b")!
        XCTAssertEqual(settings.numberNext, 5)
        XCTAssertEqual(Pixels(a.image), Pixels(b.image), "same number on both")
    }

    func testOffByDefaultAndNothingDrawn() {
        let settings = settings()
        XCTAssertFalse(settings.numberEnabled)
        XCTAssertEqual(settings.numberNext, 1)
        XCTAssertTrue(settings.numberIncrement)
        let store = CaptureStore(settings: settings)
        let c = store.addOwnCapture(pngData(width: 400, height: 300), baseName: "n")!
        XCTAssertEqual(Pixels(c.image), Pixels(solidImage(width: 400, height: 300)))
        XCTAssertEqual(settings.numberNext, 1, "not used up while off")
    }

    func testSettingsRoundTrip() {
        let settings = settings()
        let custom = NumberOptions(x: 0.2, y: 0.8, size: 0.15, opacity: 0.5, font: "Georgia", color: RGB(r: 0, g: 0.48, b: 1))
        settings.number = custom
        XCTAssertEqual(settings.number, custom)
        settings.numberNext = -3
        XCTAssertEqual(settings.numberNext, 0, "never negative")
    }

    func testWatermarkAndNumberTogether() {
        let settings = settings()
        settings.watermarkEnabled = true
        settings.watermark = WatermarkOptions(x: 1, y: 1, size: 0.1, opacity: 1, tiled: false)
        settings.numberEnabled = true
        settings.number = NumberOptions(x: 0, y: 0, size: 0.2, opacity: 1, font: "", color: RGB(r: 0, g: 0, b: 0))
        let store = CaptureStore(settings: settings)
        store.watermarkImage = solidImage(width: 100, height: 50, gray: 0)
        let c = store.addOwnCapture(pngData(width: 1000, height: 500), baseName: "both")!
        let p = Pixels(c.image)
        XCTAssertEqual(p.at(950, 475), black, "watermark bottom right")
        XCTAssertGreaterThan(darkPixels(p, in: CGRect(x: 0, y: 0, width: 150, height: 120)), 20, "number top left")
    }
}

/// Editor zoom: view only, anchored under the pointer, and never lets the image leave the canvas.
final class ZoomStateTests: XCTestCase {
    private let content = CGSize(width: 800, height: 500)
    private let container = CGSize(width: 1000, height: 500)

    func testZoomKeepsThePointUnderThePointer() {
        var z = ZoomState()
        let point = CGPoint(x: 200, y: -100) // relative to the canvas centre
        z.zoom(by: 2, at: point, content: content, container: container)
        XCTAssertEqual(z.zoom, 2)
        // The image spot that was under the pointer (point at 1×) is still under it: pan + spot × zoom = point.
        XCTAssertEqual(z.pan.width + point.x * z.zoom, point.x * 2 - point.x, accuracy: 0.001)
        XCTAssertEqual(z.pan, CGSize(width: -200, height: 100))
    }

    func testLimits() {
        var z = ZoomState()
        z.zoom(by: 100, at: .zero, content: content, container: container)
        XCTAssertEqual(z.zoom, ZoomState.range.upperBound)
        z.zoom(by: 0.001, at: .zero, content: content, container: container)
        XCTAssertEqual(z, ZoomState(), "back to 1×, centred")
    }

    func testImageCannotBeDraggedOutOfView() {
        var z = ZoomState()
        z.zoom(by: 2, at: .zero, content: content, container: container) // 1600 × 1000 shown in 1000 × 500
        z.move(by: CGSize(width: 5000, height: -5000), content: content, container: container)
        XCTAssertEqual(z.pan, CGSize(width: 300, height: -250))
    }

    func testNoPanningAtNormalSize() {
        var z = ZoomState()
        z.move(by: CGSize(width: 50, height: 50), content: content, container: container)
        XCTAssertEqual(z, ZoomState())
    }

    func testSmallImageStaysCentredOnTheShortSide() {
        var z = ZoomState()
        z.zoom(by: 1.5, at: CGPoint(x: 0, y: 200), content: CGSize(width: 400, height: 200), container: container) // 600 × 300: fits
        XCTAssertEqual(z.pan, .zero)
    }
}
