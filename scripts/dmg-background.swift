// Draws the background of the Kapture SCR disk image window.
// Usage: swift scripts/dmg-background.swift <logo.png> <out-dir>
// Writes background.png (660×420) and background@2x.png; make-dmg.sh merges them into a HiDPI TIFF.
// The layout must match the icon positions set in make-dmg.sh (app at 170,215; Applications at 490,215).
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let logo = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write("usage: dmg-background.swift <logo.png> <out-dir>\n".data(using: .utf8)!)
    exit(1)
}
let size = NSSize(width: 660, height: 420)

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.imageInterpolation = .high

    // Soft light background with a gentle vertical gradient.
    NSGradient(starting: NSColor(srgbRed: 0.965, green: 0.965, blue: 0.972, alpha: 1),
               ending: NSColor(srgbRed: 0.918, green: 0.920, blue: 0.930, alpha: 1))!
        .draw(in: NSRect(origin: .zero, size: size), angle: -90)

    // Logo, centred near the top (Cocoa coordinates: origin bottom-left).
    let logoHeight: CGFloat = 58
    let logoWidth = logoHeight * logo.size.width / logo.size.height
    logo.draw(in: NSRect(x: (size.width - logoWidth) / 2, y: size.height - 40 - logoHeight, width: logoWidth, height: logoHeight))

    // Arrow between the two icons (icon centres at y = 215 from the top).
    let y = size.height - 205
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 268, y: y)); arrow.line(to: NSPoint(x: 384, y: y))
    arrow.move(to: NSPoint(x: 372, y: y + 10)); arrow.line(to: NSPoint(x: 386, y: y)); arrow.line(to: NSPoint(x: 372, y: y - 10))
    arrow.lineWidth = 3; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    NSColor(white: 0.62, alpha: 1).setStroke(); arrow.stroke()

    func text(_ s: String, size points: CGFloat, weight: NSFont.Weight, color: NSColor, y: CGFloat) {
        let style = NSMutableParagraphStyle(); style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: points, weight: weight), .foregroundColor: color, .paragraphStyle: style]
        NSAttributedString(string: s, attributes: attrs).draw(in: NSRect(x: 40, y: y, width: size.width - 80, height: points * 1.5))
    }
    text("Drag Kapture SCR to Applications", size: 14, weight: .semibold, color: NSColor(white: 0.22, alpha: 1), y: 92)
    text("On first launch, allow Screen Recording when asked.", size: 11, weight: .regular, color: NSColor(white: 0.45, alpha: 1), y: 52)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: args[2])
try render(scale: 1).write(to: out.appendingPathComponent("background.png"))
try render(scale: 2).write(to: out.appendingPathComponent("background@2x.png"))
