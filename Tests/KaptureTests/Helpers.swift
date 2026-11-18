import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import Kapture

/// A solid-colour sRGB image.
func solidImage(width: Int, height: Int, gray: CGFloat = 1) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(gray: gray, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

func pngData(width: Int, height: Int, gray: CGFloat = 1) -> Data {
    FolderAccess.pngData(solidImage(width: width, height: height, gray: gray))!
}

func encoded(_ image: CGImage, as type: UTType) -> Data {
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    precondition(CGImageDestinationFinalize(dest))
    return data as Data
}

/// RGBA bytes of an image, top row first, so (x, y) matches the editor's top-left coordinates.
struct Pixels: Equatable {
    let width: Int, height: Int
    let bytes: [UInt8]
    init(_ image: CGImage) {
        width = image.width; height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = CGContext(data: &buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        bytes = buffer
    }
    /// (r, g, b, a) at a pixel, measured from the top-left corner.
    func at(_ x: Int, _ y: Int) -> [UInt8] { let i = (y * width + x) * 4; return Array(bytes[i..<i + 4]) }
}

let white: [UInt8] = [255, 255, 255, 255]
let black: [UInt8] = [0, 0, 0, 255]

/// A store that starts with one white capture selected.
func storeWithCapture(width: Int = 400, height: Int = 300) -> CaptureStore {
    let store = CaptureStore(settings: Settings())
    _ = store.addOwnCapture(pngData(width: width, height: height), baseName: "test")
    return store
}

/// Repository root, for tests that check resources and metadata.
let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
