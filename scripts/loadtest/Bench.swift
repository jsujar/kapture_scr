// Load test for Kapture SCR's in-process pipeline.
// Compiled together with an unmodified copy of Sources/Kapture/main.swift (minus its 4 start-up lines)
// by scripts/loadtest/run.sh, so it exercises the real CaptureStore, decode, raster, edit and PNG code.
// It never touches the general clipboard, the user's folder or the screen.
import AppKit
import Darwin

// MARK: - Measurement helpers

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

@discardableResult
func timed<T>(_ body: () -> T) -> (T, Double) {
    let t0 = DispatchTime.now().uptimeNanoseconds
    let r = body()
    return (r, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
}

struct Series {
    let name: String
    var ms: [Double] = []
    func pct(_ p: Double, _ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted(); return s[min(s.count - 1, Int(Double(s.count - 1) * p))]
    }
    /// Median of the first and last 10% of samples: the "degradation" ratio.
    var drift: (Double, Double) {
        let k = max(1, ms.count / 10)
        return (pct(0.5, Array(ms.prefix(k))), pct(0.5, Array(ms.suffix(k))))
    }
    func row() -> String {
        let (a, b) = drift
        return name.padding(toLength: 26, withPad: " ", startingAt: 0) + String(format: " %6d %9.1f %9.1f %9.1f %9.1f   %7.1f → %-7.1f %+6.1f%%",
                      ms.count, pct(0.5, ms), pct(0.95, ms), pct(0.99, ms), ms.max() ?? 0, a, b, a > 0 ? (b / a - 1) * 100 : 0)
    }
}

// MARK: - Synthetic screenshots

/// A screenshot-like image: flat UI areas, gradients, "text" lines and a noisy photo region (hard for PNG).
func syntheticPNG(width: Int, height: Int, seed: UInt64) -> Data {
    var rng = seed
    func next() -> UInt64 { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return rng >> 33 }
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.96, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    for _ in 0..<40 {
        let r = CGRect(x: Int(next() % UInt64(width)), y: Int(next() % UInt64(height)), width: Int(next() % 900) + 60, height: Int(next() % 500) + 30)
        ctx.setFillColor(CGColor(red: CGFloat(next() % 255) / 255, green: CGFloat(next() % 255) / 255, blue: CGFloat(next() % 255) / 255, alpha: 1)); ctx.fill(r)
    }
    ctx.setFillColor(CGColor(gray: 0.15, alpha: 1))
    for line in stride(from: 40, to: height / 2, by: 34) {
        var x = 60
        while x < width / 2 { let w = Int(next() % 70) + 12; ctx.fill(CGRect(x: x, y: line, width: w, height: 14)); x += w + 9 }
    }
    // Noisy region ≈ 1/6 of the image, like a photo or video frame on screen.
    if let data = ctx.data?.assumingMemoryBound(to: UInt32.self) {
        let stride = ctx.bytesPerRow / 4
        for y in (height / 2)..<(height / 2 + height / 3) { for x in (width / 2)..<(width / 2 + width / 2) { data[y * stride + x] = UInt32(truncatingIfNeeded: next()) | 0xFF000000 } }
    }
    return FolderAccess.pngData(ctx.makeImage()!)!
}

// MARK: - Run

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
let scale = args.count > 1 ? Double(args[1]) ?? 1 : 1
let outDir = URL(fileURLWithPath: args.count > 2 ? args[2] : NSTemporaryDirectory())
let saveDir = outDir.appendingPathComponent("saved-\(getpid())")
try? FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
let board = NSPasteboard(name: NSPasteboard.Name("kapture.loadtest.\(getpid())")) // private, not the user's clipboard
defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: saveDir) }

let displays: [(String, Int, Int)] = [("MacBook Air 13\" Retina", 2560, 1664), ("MacBook Pro 14\"", 3024, 1964),
                                       ("Studio Display 5K", 5120, 2880), ("Pro Display XDR 6K", 6016, 3384)]
print("Kapture SCR load test — \(ProcessInfo.processInfo.processorCount) cores, \(ProcessInfo.processInfo.physicalMemory >> 30) GB, scale ×\(scale)")
print("Preparing synthetic screenshots…")
var pngs: [(String, Data)] = []
for (i, d) in displays.enumerated() { for v in 0..<2 { pngs.append((d.0, syntheticPNG(width: d.1, height: d.2, seed: UInt64(i * 10 + v + 1)))) } }
for (name, data) in pngs where pngs.firstIndex(where: { $0.0 == name })! == pngs.firstIndex(where: { $0.1 == data })! {
    print("  " + name.padding(toLength: 24, withPad: " ", startingAt: 0) + String(format: " %5.1f MB PNG", Double(data.count) / 1_048_576))
}

let store = CaptureStore(settings: Settings())
let baseline = footprintMB()
var mem: [(phase: String, i: Int, mb: Double, count: Int)] = []
var peak = baseline
func sample(_ phase: String, _ i: Int) { let m = footprintMB(); peak = max(peak, m); mem.append((phase, i, m, store.captures.count)) }
var series: [Series] = []
let started = Date()

// 1) Capture burst: what finishCapture does per screenshot (decode → raster → history, file save, clipboard PNG).
let nCaptures = Int(400 * scale)
var sCapture = Series(name: "Capture → history"), sSave = Series(name: "Save file to folder"), sClip = Series(name: "Copy PNG to pasteboard")
print("\n[1/4] Capture burst: \(nCaptures) screenshots back to back, mixed displays")
for i in 0..<nCaptures {
    autoreleasepool {
        let (name, data) = pngs[i % pngs.count]
        let (cap, t) = timed { store.addOwnCapture(data, baseName: FolderAccess.baseName()) }
        precondition(cap != nil, "decode failed for \(name)")
        sCapture.ms.append(t)
        sSave.ms.append(timed { _ = try! FolderAccess.write(data, base: "cap", ext: "png", in: saveDir) }.1)
        sClip.ms.append(timed { board.clearContents(); _ = board.setData(data, forType: .png) }.1)
        if i % 20 == 0 { // keep the temp folder small
            for f in (try? FileManager.default.contentsOfDirectory(at: saveDir, includingPropertiesForKeys: nil)) ?? [] { try? FileManager.default.removeItem(at: f) }
        }
    }
    sample("capture", i)
}
series += [sCapture, sSave, sClip]
print("  history: \(store.captures.count) images, \(store.captures.reduce(0) { $0 + $1.image.bytesPerRow * $1.image.height } >> 20) MB raster")

// 2) Edit storm on the largest image: arrows, redactions, text and occasional crop, with undo/redo.
let nEdits = Int(1500 * scale)
var sArrow = Series(name: "Edit: arrow"), sRedact = Series(name: "Edit: redact"), sText = Series(name: "Edit: text"),
    sCrop = Series(name: "Edit: crop"), sUndo = Series(name: "Undo / redo")
print("[2/4] Edit storm: \(nEdits) edits + undo/redo on a 6K capture")
func loadBig() { _ = store.addOwnCapture(pngs.last!.1, baseName: "big") }
loadBig()
var rng = SystemRandomNumberGenerator()
for i in 0..<nEdits {
    autoreleasepool {
        let a = CGPoint(x: .random(in: 0.05...0.6, using: &rng), y: .random(in: 0.05...0.6, using: &rng))
        let b = CGPoint(x: a.x + .random(in: 0.05...0.35, using: &rng), y: a.y + .random(in: 0.05...0.35, using: &rng))
        switch i % 10 {
        case 0, 1, 2, 3: sArrow.ms.append(timed { store.edit(tool: .arrow, start: a, end: b, text: "") }.1)
        case 4, 5, 6: sRedact.ms.append(timed { store.edit(tool: .redact, start: a, end: b, text: "") }.1)
        case 7: sText.ms.append(timed { store.edit(tool: .text, start: a, end: b, text: "Load test #\(i) — ünïcödé ✓") }.1)
        case 8: sUndo.ms.append(timed { store.undo(); store.redo() }.1)
        default:
            if i % 100 == 99 { // crop rarely, then go back to a full-size capture so edits stay on 6K pixels
                sCrop.ms.append(timed { store.edit(tool: .crop, start: CGPoint(x: 0.1, y: 0.1), end: CGPoint(x: 0.9, y: 0.9), text: "") }.1)
                loadBig()
            } else { sUndo.ms.append(timed { store.undo() }.1) }
        }
    }
    if i % 5 == 0 { sample("edit", i) }
}
series += [sArrow, sRedact, sText, sCrop, sUndo]

// 3) Copy / save edited copy, as from the editor buttons.
let nCopies = Int(300 * scale)
var sCopy = Series(name: "Copy edited image (PNG)"), sSaveCopy = Series(name: "Save edited copy")
print("[3/4] Copy and save: \(nCopies) times each")
for i in 0..<nCopies {
    autoreleasepool {
        if i % 4 == 0 { store.select(store.captures[i / 4 % store.captures.count].id) }
        let image = store.current!.image
        sCopy.ms.append(timed { let d = FolderAccess.pngData(image)!; board.clearContents(); _ = board.setData(d, forType: .png) }.1)
        sSaveCopy.ms.append(timed { _ = try! FolderAccess.write(FolderAccess.pngData(image)!, base: "edited", ext: "png", in: saveDir) }.1)
        for f in (try? FileManager.default.contentsOfDirectory(at: saveDir, includingPropertiesForKeys: nil)) ?? [] { try? FileManager.default.removeItem(at: f) }
    }
    if i % 5 == 0 { sample("copy", i) }
}
series += [sCopy, sSaveCopy]

// 4) Soak: everything mixed for a long session, to see whether memory or latency creep.
let nSoak = Int(2000 * scale)
var sMixed = Series(name: "Soak: mixed operation")
print("[4/4] Soak: \(nSoak) mixed operations")
for i in 0..<nSoak {
    autoreleasepool {
        let t: Double
        switch i % 8 {
        case 0: t = timed { _ = store.addOwnCapture(pngs[i % pngs.count].1, baseName: "soak") }.1
        case 1, 2, 3: t = timed { store.edit(tool: .arrow, start: CGPoint(x: 0.2, y: 0.2), end: CGPoint(x: 0.7, y: 0.6), text: "") }.1
        case 4: t = timed { store.edit(tool: .redact, start: CGPoint(x: 0.3, y: 0.3), end: CGPoint(x: 0.5, y: 0.4), text: "") }.1
        case 5: t = timed { store.undo() }.1
        case 6: t = timed { store.select(store.captures.randomElement()?.id) }.1
        default: t = timed { _ = FolderAccess.pngData(store.current?.image ?? store.captures[0].image) }.1
        }
        sMixed.ms.append(t)
    }
    if i % 10 == 0 { sample("soak", i) }
}
series.append(sMixed)
store.clear()
let afterClear = footprintMB()

// MARK: - Report

let elapsed = Date().timeIntervalSince(started)
print("\nOperation (ms)                  n       p50       p95       p99       max   p50 first 10% → last 10%   drift")
print(String(repeating: "─", count: 112))
for s in series where !s.ms.isEmpty { print(s.row()) }
let phaseEnd = { (p: String) in mem.last(where: { $0.phase == p })?.mb ?? 0 }
print(String(format: "\nMemory (phys footprint): baseline %.0f MB · peak %.0f MB · end of phases: capture %.0f, edit %.0f, copy %.0f, soak %.0f · after Clear %.0f MB",
             baseline, peak, phaseEnd("capture"), phaseEnd("edit"), phaseEnd("copy"), phaseEnd("soak"), afterClear))
let total = series.reduce(0) { $0 + $1.ms.count }
print(String(format: "%d operations in %.0f s (%.1f ops/s)", total, elapsed, Double(total) / elapsed))

// CSVs for charts
var csv = "phase,i,footprint_mb,history_count\n"
for m in mem { csv += "\(m.phase),\(m.i),\(String(format: "%.1f", m.mb)),\(m.count)\n" }
try? csv.write(to: outDir.appendingPathComponent("memory.csv"), atomically: true, encoding: .utf8)
var lat = "operation,i,ms\n"
for s in series { for (i, v) in s.ms.enumerated() { lat += "\(s.name),\(i),\(String(format: "%.3f", v))\n" } }
try? lat.write(to: outDir.appendingPathComponent("latency.csv"), atomically: true, encoding: .utf8)
print("CSV: \(outDir.path)/memory.csv, latency.csv")
