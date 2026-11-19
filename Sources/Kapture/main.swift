import AppKit
import Carbon
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import ServiceManagement
import CryptoKit
import Security

struct Capture: Identifiable {
    let id = UUID()
    let created = Date()
    var image: CGImage
    /// Base name used for files derived from this capture ("Kapture SCR 2026-11-17 13.05.22").
    var baseName: String
}

/// Looks up a user-facing string in Localizable.strings (English keys; see Resources/*.lproj).
func L(_ value: String.LocalizationValue) -> String { String(localized: value) }

/// Languages the app is translated into, each with its own name, as listed in Options › Language.
/// Computed rather than a global constant: globals in main.swift are only set when the app starts, not in tests.
var appLanguages: [(code: String, name: String)] { [
    ("en", "English"), ("de", "Deutsch"), ("es", "Español"), ("fr", "Français"), ("hu", "Magyar"),
    ("nb", "Norsk bokmål"), ("pt-BR", "Português (Brasil)"), ("sv", "Svenska"), ("ru", "Русский"),
    ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"), ("hi", "हिन्दी"), ("bn", "বাংলা"), ("ar", "العربية"), ("ur", "اردو"),
] }

/// The app language macOS picks for a list of preferred languages (for example ["pt-PT"] → "pt-BR").
func appLanguage(for preferences: [String]) -> String {
    Bundle.preferredLocalizations(from: appLanguages.map(\.code), forPreferences: preferences).first ?? "en"
}

enum EditTool: CaseIterable {
    case crop, arrow, text, redact, highlight
    var title: String {
        switch self { case .crop: L("Crop"); case .arrow: L("Arrow"); case .text: L("Text"); case .redact: L("Redact"); case .highlight: L("Highlight") }
    }
}

/// An sRGB colour that can be stored in preferences.
struct RGB: Equatable {
    var r: Double, g: Double, b: Double
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
    var color: Color { Color(.sRGB, red: r, green: g, blue: b) }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
    var stored: [Double] { [r, g, b] }
    init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
    init?(stored: Any?) {
        guard let v = stored as? [Double], v.count == 3 else { return nil }
        self.init(r: v[0], g: v[1], b: v[2])
    }
    init(_ color: Color) {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent))
    }
    /// Perceived brightness, 0 (black) to 1 (white).
    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    static let highlighterPresets: [(RGB, String)] = [
        (RGB(r: 1, g: 0.86, b: 0.1), L("Yellow")), (RGB(r: 0.4, g: 0.88, b: 0.35), L("Green")), (RGB(r: 1, g: 0.47, b: 0.72), L("Pink")),
        (RGB(r: 0.35, g: 0.72, b: 1), L("Blue")), (RGB(r: 1, g: 0.62, b: 0.2), L("Orange")), (RGB(r: 0.72, g: 0.52, b: 1), L("Purple")),
    ]
}

enum HighlightSize: String, CaseIterable {
    case thin, medium, thick
    var title: String { switch self { case .thin: L("Thin"); case .medium: L("Medium"); case .thick: L("Thick") } }
    /// Stroke width relative to the image, like the arrow tool, so it looks the same at any resolution.
    var factor: CGFloat { switch self { case .thin: 2.5; case .medium: 4; case .thick: 6.5 } }
    func width(for size: CGSize) -> CGFloat { max(6, min(size.width, size.height) / 180 * factor) }
}

/// A smooth stroke through points: quadratic curves between midpoints, so freehand jitter reads as one elegant line.
func smoothPath(_ points: [CGPoint]) -> CGPath {
    let path = CGMutablePath()
    guard let first = points.first else { return path }
    path.move(to: first)
    guard points.count > 1 else { path.addLine(to: first); return path } // a single click draws a dot
    for i in 1..<points.count - 1 {
        let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
        path.addQuadCurve(to: mid, control: points[i])
    }
    path.addLine(to: points[points.count - 1])
    return path
}

// MARK: - Preferences

/// What a capture shortcut takes: an area, a window or a whole display. Each has its own shortcut.
enum CaptureMode: String, CaseIterable {
    case selection, window, screen
}

enum Destination: String, CaseIterable {
    case clipboard, folder, both
    var title: String { switch self { case .clipboard: L("Clipboard"); case .folder: L("Folder"); case .both: L("Clipboard and Folder") } }
    var usesClipboard: Bool { self != .folder }
    var usesFolder: Bool { self != .clipboard }
}

enum ImageFormat: String, CaseIterable {
    case png, jpg
    var title: String { rawValue.uppercased() }
}

/// Persistent capture preferences (UserDefaults inside the sandbox container).
final class Settings {
    private let d: UserDefaults
    /// Name of the preferences domain behind `d`, to tell the app's own values from global ones.
    private let domain: String?
    init(defaults: UserDefaults = .standard, domain: String? = Bundle.main.bundleIdentifier) { d = defaults; self.domain = domain }

    /// Language chosen in Options › Language; nil follows the system. Stored as AppleLanguages in the app's own
    /// preferences, the same key System Settings writes for per-app languages, so it applies from the next launch.
    var language: String? {
        get { (domain.flatMap { d.persistentDomain(forName: $0) }?["AppleLanguages"] as? [String])?.first.map { appLanguage(for: [$0]) } }
        set { if let newValue { d.set([newValue], forKey: "AppleLanguages") } else { d.removeObject(forKey: "AppleLanguages") } }
    }
    var delay: Int {
        get { captureDelays.contains(d.integer(forKey: "delay")) ? d.integer(forKey: "delay") : 0 }
        set { d.set(newValue, forKey: "delay") }
    }
    var format: ImageFormat {
        get { ImageFormat(rawValue: d.string(forKey: "format") ?? "") ?? .png }
        set { d.set(newValue.rawValue, forKey: "format") }
    }
    var showCursor: Bool {
        get { d.bool(forKey: "showCursor") }
        set { d.set(newValue, forKey: "showCursor") }
    }
    /// Off by default: releasing the mouse captures at once. On: the area stays adjustable until Return.
    var adjustSelection: Bool {
        get { d.bool(forKey: "adjustSelection") }
        set { d.set(newValue, forKey: "adjustSelection") }
    }
    var windowShadow: Bool {
        get { d.object(forKey: "windowShadow") as? Bool ?? true }
        set { d.set(newValue, forKey: "windowShadow") }
    }
    var destination: Destination {
        get { Destination(rawValue: d.string(forKey: "destination") ?? "") ?? .clipboard }
        set { d.set(newValue.rawValue, forKey: "destination") }
    }
    /// Automatic watermark, off by default. The image is a copy kept in the container (see Watermark.imageURL).
    var watermarkEnabled: Bool {
        get { d.bool(forKey: "watermarkEnabled") }
        set { d.set(newValue, forKey: "watermarkEnabled") }
    }
    /// Automatic number on every capture and import, off by default.
    var numberEnabled: Bool {
        get { d.bool(forKey: "numberEnabled") }
        set { d.set(newValue, forKey: "numberEnabled") }
    }
    /// The number the next capture gets.
    var numberNext: Int {
        get { max(0, d.object(forKey: "numberNext") as? Int ?? 1) }
        set { d.set(max(0, newValue), forKey: "numberNext") }
    }
    var numberIncrement: Bool {
        get { d.object(forKey: "numberIncrement") as? Bool ?? true }
        set { d.set(newValue, forKey: "numberIncrement") }
    }
    var number: NumberOptions {
        get {
            let fallback = NumberOptions()
            func value(_ key: String, _ standard: Double) -> Double { d.object(forKey: key) as? Double ?? standard }
            return NumberOptions(x: value("numberX", fallback.x), y: value("numberY", fallback.y), size: value("numberSize", fallback.size),
                                 opacity: value("numberOpacity", fallback.opacity), font: d.string(forKey: "numberFont") ?? fallback.font,
                                 color: RGB(stored: d.object(forKey: "numberColor")) ?? fallback.color)
        }
        set {
            d.set(newValue.x, forKey: "numberX"); d.set(newValue.y, forKey: "numberY"); d.set(newValue.size, forKey: "numberSize")
            d.set(newValue.opacity, forKey: "numberOpacity"); d.set(newValue.font, forKey: "numberFont"); d.set(newValue.color.stored, forKey: "numberColor")
        }
    }
    /// Pixel rulers around the image in the editor, on by default.
    var showRulers: Bool {
        get { d.object(forKey: "showRulers") as? Bool ?? true }
        set { d.set(newValue, forKey: "showRulers") }
    }
    var highlightColor: RGB {
        get { RGB(stored: d.object(forKey: "highlightColor")) ?? RGB.highlighterPresets[0].0 }
        set { d.set(newValue.stored, forKey: "highlightColor") }
    }
    var highlightSize: HighlightSize {
        get { HighlightSize(rawValue: d.string(forKey: "highlightSize") ?? "") ?? .medium }
        set { d.set(newValue.rawValue, forKey: "highlightSize") }
    }
    var watermark: WatermarkOptions {
        get {
            let fallback = WatermarkOptions()
            func value(_ key: String, _ standard: Double) -> Double { d.object(forKey: key) as? Double ?? standard }
            return WatermarkOptions(x: value("watermarkX", fallback.x), y: value("watermarkY", fallback.y),
                                    size: value("watermarkSize", fallback.size), opacity: value("watermarkOpacity", fallback.opacity),
                                    tiled: d.bool(forKey: "watermarkTiled"))
        }
        set {
            d.set(newValue.x, forKey: "watermarkX"); d.set(newValue.y, forKey: "watermarkY")
            d.set(newValue.size, forKey: "watermarkSize"); d.set(newValue.opacity, forKey: "watermarkOpacity")
            d.set(newValue.tiled, forKey: "watermarkTiled")
        }
    }
    /// Global shortcut chosen for an action; defaults are not stored.
    func shortcut(for action: ShortcutAction) -> Shortcut {
        d.data(forKey: action.defaultsKey).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? action.defaultShortcut
    }
    func setShortcut(_ shortcut: Shortcut, for action: ShortcutAction) {
        if shortcut.sameKeys(as: action.defaultShortcut) { d.removeObject(forKey: action.defaultsKey) }
        else { d.set(try? JSONEncoder().encode(shortcut), forKey: action.defaultsKey) }
    }
    var captureShortcut: Shortcut { shortcut(for: .capture) }
    /// Security-scoped bookmark of the folder chosen by the user.
    var folder: URL? {
        get {
            guard let data = d.data(forKey: "folderBookmark") else { return nil }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
            if stale { storeBookmark(url) }
            return url
        }
        set { storeBookmark(newValue) }
    }
    private func storeBookmark(_ url: URL?) {
        if let url, let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            d.set(data, forKey: "folderBookmark")
        } else { d.removeObject(forKey: "folderBookmark") }
    }
}

// MARK: - Shortcuts

/// A global shortcut: Carbon key code and modifiers, plus the characters the key typed when it was recorded.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var chars: String

    static let defaultCapture = Shortcut(keyCode: UInt32(kVK_ANSI_6), modifiers: UInt32(cmdKey | shiftKey), chars: "6")
    static let defaultWindow = Shortcut(keyCode: UInt32(kVK_ANSI_7), modifiers: UInt32(cmdKey | shiftKey), chars: "7")
    static let importFromClipboard = Shortcut(keyCode: UInt32(kVK_ANSI_E), modifiers: UInt32(cmdKey | shiftKey), chars: "e")
    static let defaultScreen = Shortcut(keyCode: UInt32(kVK_ANSI_8), modifiers: UInt32(cmdKey | shiftKey), chars: "8")
    static let defaultRepeat = Shortcut(keyCode: UInt32(kVK_ANSI_9), modifiers: UInt32(cmdKey | shiftKey), chars: "9")
    /// Shortcuts macOS keeps for itself (screenshots, lock screen, force quit, emoji, full screen).
    private static let reserved: [(Int, Int)] = [
        (kVK_ANSI_3, cmdKey | shiftKey), (kVK_ANSI_4, cmdKey | shiftKey), (kVK_ANSI_5, cmdKey | shiftKey),
        (kVK_ANSI_3, cmdKey | shiftKey | controlKey), (kVK_ANSI_4, cmdKey | shiftKey | controlKey),
        (kVK_ANSI_Q, cmdKey | controlKey), (kVK_Escape, cmdKey | optionKey),
        (kVK_Space, cmdKey | controlKey), (kVK_ANSI_F, cmdKey | controlKey),
    ]
    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13",
        kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]
    private static let namedKeys: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_ANSI_KeypadEnter: "⌤",
    ]

    init(keyCode: UInt32, modifiers: UInt32, chars: String) { self.keyCode = keyCode; self.modifiers = modifiers; self.chars = chars }
    init(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let typed = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? ""
        self.init(keyCode: UInt32(event.keyCode), modifiers: Self.carbon(flags), chars: typed.lowercased())
    }

    func sameKeys(as other: Shortcut) -> Bool { keyCode == other.keyCode && modifiers == other.modifiers }
    var isFunctionKey: Bool { Self.functionKeys[Int(keyCode)] != nil }
    var isReserved: Bool { Self.reserved.contains { UInt32($0.0) == keyCode && UInt32($0.1) == modifiers } }
    /// Needs two modifiers including ⌘ or ⌃ (function keys excepted), so it never swallows typing or common app shortcuts.
    var isAllowed: Bool {
        if isFunctionKey { return true }
        let m = Int(modifiers)
        let count = [controlKey, optionKey, shiftKey, cmdKey].filter { m & $0 != 0 }.count
        return count >= 2 && m & (cmdKey | controlKey) != 0
    }
    var keyLabel: String {
        let code = Int(keyCode)
        if code == kVK_Space { return L("space") }
        return Self.functionKeys[code] ?? Self.namedKeys[code] ?? chars.uppercased()
    }
    /// Symbols in Apple's order: ⌃ ⌥ ⇧ ⌘, then the key.
    var symbols: [String] { Self.symbols(for: menuFlags) + [keyLabel] }
    var display: String { symbols.joined() }
    var menuFlags: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        let m = Int(modifiers)
        if m & controlKey != 0 { f.insert(.control) }
        if m & optionKey != 0 { f.insert(.option) }
        if m & shiftKey != 0 { f.insert(.shift) }
        if m & cmdKey != 0 { f.insert(.command) }
        return f
    }
    static func symbols(for flags: NSEvent.ModifierFlags) -> [String] {
        var s: [String] = []
        if flags.contains(.control) { s.append("⌃") }
        if flags.contains(.option) { s.append("⌥") }
        if flags.contains(.shift) { s.append("⇧") }
        if flags.contains(.command) { s.append("⌘") }
        return s
    }
    static func carbon(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m = 0
        if flags.contains(.control) { m |= controlKey }
        if flags.contains(.option) { m |= optionKey }
        if flags.contains(.shift) { m |= shiftKey }
        if flags.contains(.command) { m |= cmdKey }
        return UInt32(m)
    }
}

/// Actions with a user-configurable global shortcut.
enum ShortcutAction: CaseIterable {
    case capture, captureWindow, captureScreen, repeatCapture, importClipboard
    var defaultsKey: String {
        switch self {
        case .capture: "captureShortcut"; case .captureWindow: "windowShortcut"; case .captureScreen: "screenShortcut"
        case .repeatCapture: "repeatShortcut"; case .importClipboard: "importShortcut"
        }
    }
    var defaultShortcut: Shortcut {
        switch self {
        case .capture: .defaultCapture; case .captureWindow: .defaultWindow; case .captureScreen: .defaultScreen
        case .repeatCapture: .defaultRepeat; case .importClipboard: .importFromClipboard
        }
    }
    var hotKeyID: UInt32 { switch self { case .capture: 2; case .captureWindow: 3; case .captureScreen: 5; case .repeatCapture: 4; case .importClipboard: 1 } }
    var recorderTitle: String {
        switch self {
        case .capture: L("Capture Shortcut"); case .captureWindow: L("Window Shortcut"); case .captureScreen: L("Full Screen Shortcut")
        case .repeatCapture: L("Repeat Shortcut"); case .importClipboard: L("Import Shortcut")
        }
    }
}

/// Borderless panel that can take keyboard focus.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class ShortcutRecorderModel: ObservableObject {
    @Published var shown: Shortcut
    @Published var held: [String] = []
    @Published var error: String?
    @Published var saved = false
    let title: String
    let defaultShortcut: Shortcut
    init(_ shortcut: Shortcut, title: String, defaultShortcut: Shortcut) { shown = shortcut; self.title = title; self.defaultShortcut = defaultShortcut }
}

struct ShortcutRecorderView: View {
    @ObservedObject var model: ShortcutRecorderModel
    let reset: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text(model.title).font(.system(size: 15, weight: .semibold))
            HStack(spacing: 6) {
                ForEach(Array((model.held.isEmpty ? model.shown.symbols : model.held).enumerated()), id: \.offset) { _, symbol in
                    KeyCap(label: symbol, large: true)
                }
                if model.saved { Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(.green) }
            }
            .frame(height: 40)
            .animation(.snappy(duration: 0.2), value: model.held)
            Text(model.error ?? L("Press the new key combination. Esc cancels."))
                .font(.system(size: 12)).foregroundStyle(model.error == nil ? Color.secondary : Color.red)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                PillButton(title: L("Restore Default"), symbol: "arrow.counterclockwise.circle", action: reset)
                    .disabled(model.shown.sameKeys(as: model.defaultShortcut))
                Spacer()
                PillButton(title: L("Cancel"), symbol: "xmark.circle", action: cancel)
            }
        }
        .padding(18)
        .frame(width: 360)
        .glassSurface(RoundedRectangle(cornerRadius: 24, style: .continuous), tint: Smoke.panelTint)
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Smoke.rim, lineWidth: 0.5))
        .padding(12) // room for the glass shadow
    }
}

/// Small glass panel that records a new global shortcut from the next key press.
final class ShortcutRecorder: NSObject, NSWindowDelegate {
    private var panel: KeyPanel?
    private var monitor: Any?
    private var model: ShortcutRecorderModel?
    /// Tries a shortcut; returns nil when accepted or a message explaining why not.
    var apply: (Shortcut) -> String? = { _ in nil }
    var onEnd: () -> Void = {}

    func begin(current: Shortcut, title: String, defaultShortcut: Shortcut) {
        NSApp.activate(ignoringOtherApps: true)
        if let panel { panel.makeKeyAndOrderFront(nil); return }
        let model = ShortcutRecorderModel(current, title: title, defaultShortcut: defaultShortcut)
        self.model = model
        let host = NSHostingController(rootView: ShortcutRecorderView(model: model,
            reset: { [weak self] in self?.accept(defaultShortcut) },
            cancel: { [weak self] in self?.end() }))
        host.sizingOptions = [.preferredContentSize]
        let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 384, height: 220), styleMask: [.borderless], backing: .buffered, defer: false)
        p.isReleasedWhenClosed = false; p.level = .floating
        p.backgroundColor = .clear; p.isOpaque = false; p.hasShadow = false
        p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        p.contentViewController = host
        p.delegate = self
        host.view.layoutSubtreeIfNeeded()
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: f.midX - p.frame.width / 2, y: f.midY - p.frame.height / 2 + f.height * 0.15))
        }
        panel = p
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handle(event) ?? event
        }
        p.makeKeyAndOrderFront(nil)
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let model, let panel, panel.isKeyWindow else { return event }
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        if event.type == .flagsChanged { model.held = Shortcut.symbols(for: flags); return nil }
        if event.keyCode == UInt16(kVK_Escape) && flags.isEmpty { end(); return nil }
        if !model.saved { accept(Shortcut(event: event)) }
        return nil
    }

    private func accept(_ shortcut: Shortcut) {
        guard let model else { return }
        model.held = []
        if let error = apply(shortcut) { model.error = error; NSSound.beep(); return }
        model.error = nil; model.shown = shortcut; model.saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.end() }
    }

    func end() {
        guard panel != nil else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panel?.orderOut(nil); panel = nil; model = nil
        onEnd()
    }

    func windowDidResignKey(_ notification: Notification) { end() }
}

// MARK: - Files

enum FolderAccess {
    /// Asks the user for a destination folder; the sandbox grants access to what is chosen here.
    static func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("Choose"); panel.message = L("Folder where Kapture SCR will save your screenshots")
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Writes data into a security-scoped folder without overwriting existing files.
    static func write(_ data: Data, base: String, ext: String, in folder: URL) throws -> URL {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        var url = folder.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) (\(n)).\(ext)"); n += 1
        }
        try data.write(to: url, options: .withoutOverwriting)
        return url
    }

    static func baseName(for date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX") // same file names in every language
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Kapture SCR \(f.string(from: date))"
    }

    /// Encodes in the chosen file format. JPEG has no transparency, so it is flattened onto white first.
    static func encode(_ image: CGImage, as format: ImageFormat) -> Data? {
        guard format == .jpg else { return pngData(image) }
        guard let color = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: color, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let flat = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, flat, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}

// MARK: - Capture HUD: hint, options and countdown (Liquid Glass on macOS 26+, material before)

/// Timer choices offered in capture mode, in seconds (0 = none).
var captureDelays: [Int] { [0, 3, 5, 15] }
func delayTitle(_ d: Int) -> String { d == 0 ? L("Off") : L("\(d) s") }

extension View {
    /// Liquid Glass surface on macOS 26+; translucent material with a hairline edge on earlier systems.
    @ViewBuilder func glassSurface<S: Shape>(_ shape: S, id: String? = nil, in ns: Namespace.ID? = nil, tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            let glass = tint.map { Glass.regular.tint($0) } ?? .regular
            if let id, let ns { glassEffect(glass, in: shape).glassEffectID(id, in: ns) } else { glassEffect(glass, in: shape) }
        } else {
            background(tint ?? .clear, in: shape)
                .background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.22), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        }
    }
}

/// Groups glass shapes so they render together and morph into each other (macOS 26+).
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        if #available(macOS 26.0, *) { GlassEffectContainer(spacing: spacing) { content } } else { content }
    }
}

struct KeyCap: View {
    let label: String
    var large = false
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: large ? 8 : 5, style: .continuous)
        Text(label)
            .font(.system(size: large ? 17 : 11, weight: .semibold, design: .rounded))
            .padding(.horizontal, large ? 11 : 7).padding(.vertical, large ? 6 : 2.5)
            .frame(minWidth: large ? 38 : nil)
            .background(shape.fill(.primary.opacity(0.10)))
            .overlay(shape.strokeBorder(.primary.opacity(0.22), lineWidth: 0.5))
    }
}

/// The capture shortcuts as keycaps with what each one does, for empty states.
struct ShortcutHints: View {
    let capture: Shortcut
    let window: Shortcut
    let screen: Shortcut
    let again: Shortcut
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            row(capture, L("Take Screenshot"))
            row(window, L("Capture Window"))
            row(screen, L("Capture Full Screen"))
            row(again, L("Repeat Last Capture"))
        }
    }
    private func row(_ shortcut: Shortcut, _ title: String) -> some View {
        GridRow {
            HStack(spacing: 4) { ForEach(shortcut.symbols, id: \.self) { KeyCap(label: $0) } }
                .gridColumnAlignment(.trailing)
            Text(title).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

final class CaptureHUDModel: ObservableObject {
    @Published var menuOpen = false { didSet { if menuOpen != oldValue { onMenuChange?(menuOpen) } } }
    @Published var delay: Int
    @Published var dragging = false
    /// A finished selection is on screen and can be adjusted; the hint then offers a Capture button.
    @Published var adjusting = false
    var onConfirm: (() -> Void)?
    /// Corner of the HUD window the glass hangs from, so it always sits next to the pointer.
    @Published var corner: Alignment = .topLeading
    var onDelayChange: ((Int) -> Void)?
    var onMenuChange: ((Bool) -> Void)?

    init(delay: Int) { self.delay = captureDelays.contains(delay) ? delay : 0 }
    func toggleMenu() { menuOpen.toggle() }
    func select(_ d: Int) { delay = d; onDelayChange?(d) }
    func step(_ offset: Int) {
        let i = captureDelays.firstIndex(of: delay) ?? 0
        select(captureDelays[max(0, min(captureDelays.count - 1, i + offset))])
    }
}

struct CaptureHUDView: View {
    @ObservedObject var model: CaptureHUDModel
    @Namespace private var glass
    @Namespace private var chip
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    /// Transparent room around the glass for its shadow.
    static let margin: CGFloat = 14
    private var motion: Animation? { reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.82) }
    private var anchor: UnitPoint {
        switch model.corner {
        case .topTrailing: .topTrailing; case .bottomLeading: .bottomLeading; case .bottomTrailing: .bottomTrailing
        case .top: .top; case .bottom: .bottom; default: .topLeading
        }
    }

    var body: some View {
        GlassGroup(spacing: 20) {
            if model.menuOpen {
                menu.glassSurface(RoundedRectangle(cornerRadius: 24, style: .continuous), id: "hud", in: glass, tint: Smoke.panelTint)
            } else {
                hint.glassSurface(Capsule(), id: "hud", in: glass, tint: Smoke.panelTint)
            }
        }
        .opacity(appeared && !model.dragging ? 1 : 0)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.94, anchor: anchor)
        .padding(CaptureHUDView.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.corner)
        .animation(motion, value: model.menuOpen)
        .animation(motion, value: model.delay)
        .animation(motion, value: model.adjusting)
        .animation(.easeOut(duration: 0.15), value: model.dragging)
        .onAppear { withAnimation((motion ?? .linear(duration: 0)).delay(0.25)) { appeared = true } }
    }

    private var hint: some View {
        HStack(spacing: 10) {
            if model.adjusting {
                // Concentric capsule inside the hint: 4 pt inset on every side.
                Button { model.onConfirm?() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "camera.viewfinder")
                        Text(L("Capture"))
                        Text("↩").opacity(0.75)
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.leading, 12).padding(.trailing, 12)
                    .frame(height: 28)
                    .background(Capsule().fill(Color.accentColor))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(L("Capture") + " (↩)")
            }
            HStack(spacing: 10) {
                KeyCap(label: L("space"))
                Text(L("Options"))
                if model.delay > 0 {
                    Label(delayTitle(model.delay), systemImage: "timer").foregroundStyle(.tint)
                }
                Rectangle().fill(.primary.opacity(0.2)).frame(width: 0.5, height: 14)
                KeyCap(label: "esc")
                Text(L("Cancel")).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.adjusting ? L("Adjust the area, then press Return to capture") : L("Press Space for options or Escape to cancel"))
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.leading, model.adjusting ? 4 : 16).padding(.trailing, 16)
        .frame(height: 36)
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "timer").foregroundStyle(.tint)
                Text(L("Timer")).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 16)
                KeyCap(label: L("space"))
            }
            HStack(spacing: 4) {
                ForEach(captureDelays, id: \.self) { d in
                    Button { model.select(d) } label: {
                        Text(delayTitle(d))
                            .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(model.delay == d ? Color.white : Color.primary)
                            .frame(width: 56, height: 30)
                            .background {
                                if model.delay == d { Capsule().fill(Color.accentColor).matchedGeometryEffect(id: "selected", in: chip) }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .accessibilityLabel(d == 0 ? L("No timer") : L("\(d) seconds"))
                    .accessibilityAddTraits(model.delay == d ? .isSelected : [])
                }
            }
            .padding(4)
            .background(Capsule().fill(.primary.opacity(0.07)))
            Text(L("← →  to change  ·  space to close"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 280)
    }
}

/// Floating window that carries the capture HUD next to the pointer. It never takes the keyboard,
/// so Space, arrows and Esc keep going to the selection overlay.
final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class FirstMouseHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class CountdownModel: ObservableObject {
    let total: Int
    @Published var remaining: Int
    @Published var progress: Double = 1
    init(total: Int) { self.total = total; remaining = total }
}

struct CountdownView: View {
    @ObservedObject var model: CountdownModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            Circle().stroke(.primary.opacity(0.12), lineWidth: 4)
            Circle().trim(from: 0, to: model.progress)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(model.remaining)")
                    .font(.system(size: 52, weight: .semibold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                Text(L("esc to cancel")).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 136, height: 136)
        .glassSurface(Circle(), tint: Smoke.panelTint)
        .overlay(Circle().strokeBorder(Smoke.rim, lineWidth: 0.5))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : .snappy, value: model.remaining)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Capturing in \(model.remaining) seconds"))
    }
}

final class KeyCatcherView: NSView {
    var onEscape: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { if event.keyCode == UInt16(kVK_Escape) { onEscape?() } else { super.keyDown(with: event) } }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// Glass countdown shown before a delayed capture. Esc cancels.
final class CountdownHUD {
    private var window: NSWindow?
    private var timer: Timer?
    private var completion: ((Bool) -> Void)?

    /// Centres the countdown on `rect` (Cocoa global coordinates). Completion gets false if cancelled.
    func run(seconds: Int, around rect: NSRect, completion: @escaping (Bool) -> Void) {
        self.completion = completion
        let model = CountdownModel(total: seconds)
        let side: CGFloat = 180
        var frame = NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        if let visible = (NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - side)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - side)
        }
        let w = OverlayWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = .screenSaver; w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false
        w.ignoresMouseEvents = true; w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let catcher = KeyCatcherView(frame: NSRect(origin: .zero, size: frame.size))
        catcher.onEscape = { [weak self] in self?.finish(false) }
        let host = NSHostingView(rootView: CountdownView(model: model))
        host.frame = catcher.bounds; host.autoresizingMask = [.width, .height]
        catcher.addSubview(host)
        w.contentView = catcher
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil); w.makeFirstResponder(catcher)
        DispatchQueue.main.async { withAnimation(.linear(duration: Double(seconds))) { model.progress = 0 } }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            if model.remaining <= 1 { self?.finish(true) } else { model.remaining -= 1 }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func finish(_ completed: Bool) {
        timer?.invalidate(); timer = nil
        window?.orderOut(nil); window = nil
        let done = completion; completion = nil
        done?(completed)
    }
}

// MARK: - Own selection overlay (high-contrast crosshair, no coordinates)

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

final class SelectionView: NSView {
    static let cursor: NSCursor = {
        let side: CGFloat = 25, c = side / 2, gap: CGFloat = 3
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            func lines(_ path: NSBezierPath) {
                path.move(to: NSPoint(x: 1, y: c)); path.line(to: NSPoint(x: c - gap, y: c))
                path.move(to: NSPoint(x: c + gap, y: c)); path.line(to: NSPoint(x: side - 1, y: c))
                path.move(to: NSPoint(x: c, y: 1)); path.line(to: NSPoint(x: c, y: c - gap))
                path.move(to: NSPoint(x: c, y: c + gap)); path.line(to: NSPoint(x: c, y: side - 1))
            }
            let outer = NSBezierPath(); lines(outer); outer.lineWidth = 3; outer.lineCapStyle = .square
            NSColor.black.setStroke(); outer.stroke()
            let inner = NSBezierPath(); lines(inner); inner.lineWidth = 1
            NSColor.white.setStroke(); inner.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: c, y: c))
    }()

    var onDone: ((NSRect?) -> Void)?
    /// When false, releasing the mouse captures the area at once instead of keeping it adjustable.
    var adjustable = true
    /// Shared by the overlays on every screen; the glass HUD itself lives on the screen under the pointer.
    var hud: CaptureHUDModel?
    var onPointerMoved: (() -> Void)?
    /// Reports the adjustable selection in screen coordinates, or nil while there is none.
    var onSelectionChange: ((NSRect?) -> Void)?
    /// A new selection started here, so the other screens drop theirs.
    var onBegin: (() -> Void)?

    private struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1), right = Edges(rawValue: 2), bottom = Edges(rawValue: 4), top = Edges(rawValue: 8)
        var isCorner: Bool { rawValue.nonzeroBitCount == 2 }
    }
    private enum Zone { case outside, inside, edges(Edges) }
    private enum Drag { case create(NSPoint), move(NSPoint, NSRect), resize(Edges, NSPoint, NSRect) }

    private var selection: NSRect?
    private var drag: Drag?
    /// Distance from an edge that still grabs it, and from a handle that grabs the handle.
    private static let edgeGrab: CGFloat = 6
    private static let handleGrab: CGFloat = 9
    private static let handleRadius: CGFloat = 4.5
    private static let minSide: CGFloat = 4

    var hasSelection: Bool { selection != nil }
    func clearSelection() { selection = nil; drag = nil; needsDisplay = true }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseMoved, .cursorUpdate, .inVisibleRect], owner: self))
    }
    override func cursorUpdate(with event: NSEvent) { updateCursor(at: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { updateCursor(at: convert(event.locationInWindow, from: nil)); onPointerMoved?() }

    private func handles(_ r: NSRect) -> [(NSPoint, Edges)] {
        [(NSPoint(x: r.minX, y: r.maxY), [.left, .top]), (NSPoint(x: r.midX, y: r.maxY), [.top]),
         (NSPoint(x: r.maxX, y: r.maxY), [.right, .top]), (NSPoint(x: r.maxX, y: r.midY), [.right]),
         (NSPoint(x: r.maxX, y: r.minY), [.right, .bottom]), (NSPoint(x: r.midX, y: r.minY), [.bottom]),
         (NSPoint(x: r.minX, y: r.minY), [.left, .bottom]), (NSPoint(x: r.minX, y: r.midY), [.left])]
    }
    /// Edge handles only when the side is long enough not to crowd the corners.
    private func visibleHandles(_ r: NSRect) -> [(NSPoint, Edges)] {
        handles(r).filter { $0.1.isCorner || ($0.1.contains(.left) || $0.1.contains(.right) ? r.height : r.width) >= 48 }
    }
    private func zone(at p: NSPoint, in r: NSRect) -> Zone {
        if let h = visibleHandles(r).first(where: { hypot($0.0.x - p.x, $0.0.y - p.y) <= Self.handleGrab }) { return .edges(h.1) }
        let g = Self.edgeGrab
        guard r.insetBy(dx: -g, dy: -g).contains(p) else { return .outside }
        var e: Edges = []
        if abs(p.x - r.minX) <= g { e.insert(.left) } else if abs(p.x - r.maxX) <= g { e.insert(.right) }
        if abs(p.y - r.minY) <= g { e.insert(.bottom) } else if abs(p.y - r.maxY) <= g { e.insert(.top) }
        return e.isEmpty ? (r.contains(p) ? .inside : .outside) : .edges(e)
    }

    private static func resizeCursor(_ e: Edges) -> NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch e {
            case [.left, .top]: position = .topLeft
            case [.right, .top]: position = .topRight
            case [.left, .bottom]: position = .bottomLeft
            case [.right, .bottom]: position = .bottomRight
            case [.left]: position = .left
            case [.right]: position = .right
            case [.top]: position = .top
            default: position = .bottom
            }
            return .frameResize(position: position, directions: .all)
        }
        if e == [.left] || e == [.right] { return .resizeLeftRight }
        if e == [.top] || e == [.bottom] { return .resizeUpDown }
        return .crosshair
    }
    private func updateCursor(at p: NSPoint) {
        guard drag == nil else { return }
        guard let r = selection else { Self.cursor.set(); return }
        switch zone(at: p, in: r) {
        case .outside: Self.cursor.set()
        case .inside: NSCursor.openHand.set()
        case .edges(let e): Self.resizeCursor(e).set()
        }
    }

    private func clamped(_ p: NSPoint) -> NSPoint {
        NSPoint(x: min(max(p.x, bounds.minX), bounds.maxX), y: min(max(p.y, bounds.minY), bounds.maxY))
    }
    private func screenRect(_ r: NSRect) -> NSRect? { window.map { $0.convertToScreen(convert(r, to: nil)) } }
    private func publish() { onSelectionChange?(selection.flatMap(screenRect)) }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey(); window?.makeFirstResponder(self)
        hud?.menuOpen = false
        let p = convert(event.locationInWindow, from: nil)
        if let r = selection {
            switch zone(at: p, in: r) {
            case .edges(let e): drag = .resize(e, p, r)
            case .inside:
                if event.clickCount >= 2 { confirm(); return }
                drag = .move(p, r); NSCursor.closedHand.set()
            case .outside: selection = nil; drag = .create(clamped(p)); onBegin?()
            }
        } else {
            drag = .create(clamped(p)); onBegin?()
        }
        hud?.dragging = true
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        let raw = convert(event.locationInWindow, from: nil), p = clamped(raw)
        switch drag {
        case .create(let a):
            selection = NSRect(x: min(a.x, p.x), y: min(a.y, p.y), width: abs(a.x - p.x), height: abs(a.y - p.y))
        case .move(let p0, let r0):
            var r = r0.offsetBy(dx: raw.x - p0.x, dy: raw.y - p0.y)
            r.origin.x = min(max(r.minX, bounds.minX), bounds.maxX - r.width)
            r.origin.y = min(max(r.minY, bounds.minY), bounds.maxY - r.height)
            selection = r
        case .resize(let e, let p0, let r0):
            let dx = p.x - p0.x, dy = p.y - p0.y
            var x0 = r0.minX, x1 = r0.maxX, y0 = r0.minY, y1 = r0.maxY
            if e.contains(.left) { x0 += dx }
            if e.contains(.right) { x1 += dx }
            if e.contains(.bottom) { y0 += dy }
            if e.contains(.top) { y1 += dy }
            // Dragging past the opposite side flips the rectangle instead of collapsing it.
            selection = NSRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0)).intersection(bounds)
        case nil: break
        }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard drag != nil else { return }
        drag = nil
        hud?.dragging = false
        if let r = selection, r.width < Self.minSide || r.height < Self.minSide { selection = nil }
        if !adjustable, selection != nil { confirm(); return }
        publish()
        if selection == nil { onPointerMoved?() }
        updateCursor(at: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    /// Captures the current selection.
    func confirm() {
        guard let r = selection, let rect = screenRect(r) else { return }
        onDone?(rect)
    }

    /// Arrow keys move the selection (⇧ by 10 pt); with ⌥ they resize it from the right and top edges.
    private func nudge(_ event: NSEvent) {
        guard var r = selection else { return }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        var dx: CGFloat = 0, dy: CGFloat = 0
        switch Int(event.keyCode) {
        case kVK_LeftArrow: dx = -step
        case kVK_RightArrow: dx = step
        case kVK_DownArrow: dy = -step
        default: dy = step
        }
        if event.modifierFlags.contains(.option) {
            r.size.width = max(Self.minSide, r.width + dx); r.size.height = max(Self.minSide, r.height + dy)
            r = r.intersection(bounds)
        } else {
            r.origin.x = min(max(r.minX + dx, bounds.minX), bounds.maxX - r.width)
            r.origin.y = min(max(r.minY + dy, bounds.minY), bounds.maxY - r.height)
        }
        selection = r
        publish()
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        let menuOpen = hud?.menuOpen == true
        let idle = drag == nil
        switch Int(event.keyCode) {
        case kVK_Escape: cancel()
        case kVK_Space where hud != nil && idle:
            if !event.isARepeat { hud?.toggleMenu() }
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if menuOpen { hud?.menuOpen = false } else if idle { confirm() }
        case kVK_LeftArrow where menuOpen: hud?.step(NSApp.userInterfaceLayoutDirection == .rightToLeft ? 1 : -1)
        case kVK_RightArrow where menuOpen: hud?.step(NSApp.userInterfaceLayoutDirection == .rightToLeft ? -1 : 1)
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
            if idle && !menuOpen && selection != nil { nudge(event) } else { super.keyDown(with: event) }
        default: super.keyDown(with: event)
        }
    }
    override func cancelOperation(_ sender: Any?) { cancel() }
    /// Esc closes the options first; a second Esc cancels the capture.
    private func cancel() { if let hud, hud.menuOpen { hud.menuOpen = false } else { onDone?(nil) } }

    override func draw(_ dirtyRect: NSRect) {
        // Light dim so capture mode is visible; also makes the whole window receive clicks.
        NSColor(white: 0, alpha: 0.12).setFill(); bounds.fill()
        guard let rect = selection else { return }
        NSColor.clear.setFill(); rect.fill(using: .copy)
        let border = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)); border.lineWidth = 1
        NSColor.black.setStroke(); border.stroke()
        border.setLineDash([4, 4], count: 2, phase: 0)
        NSColor.white.setStroke(); border.stroke()
        // Handles appear once the selection exists and stay while it is moved or resized.
        if case .create = drag { return }
        let shadow = NSShadow(); shadow.shadowColor = .black.withAlphaComponent(0.35); shadow.shadowBlurRadius = 3; shadow.shadowOffset = NSSize(width: 0, height: -1)
        for (point, _) in visibleHandles(rect) {
            let d = Self.handleRadius * 2
            let dot = NSBezierPath(ovalIn: NSRect(x: point.x - Self.handleRadius, y: point.y - Self.handleRadius, width: d, height: d))
            NSGraphicsContext.saveGraphicsState(); shadow.set()
            NSColor.white.setFill(); dot.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.black.withAlphaComponent(0.55).setStroke(); dot.lineWidth = 0.75; dot.stroke()
        }
    }
}

final class SelectionOverlay {
    private var windows: [NSWindow] = []
    private var completion: ((NSRect?) -> Void)?
    private var hudPanel: HUDPanel?
    private var hud: CaptureHUDModel?
    private static let hudSize = NSSize(width: 560, height: 210)
    /// Selection being adjusted (screen coordinates); the HUD anchors to it instead of following the pointer.
    private var anchor: NSRect?
    private var views: [SelectionView] { windows.compactMap { $0.contentView as? SelectionView } }
    /// Gap between the pointer and the glass.
    private static let offset = NSPoint(x: 18, y: 22)

    /// Shows a selection layer on every screen and the glass hint next to the pointer.
    /// Completion gets the rect in Cocoa global coordinates, or nil on Esc.
    func begin(hud: CaptureHUDModel, adjustable: Bool, completion: @escaping (NSRect?) -> Void) {
        self.completion = completion
        self.hud = hud
        for screen in NSScreen.screens {
            let w = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.setFrame(screen.frame, display: false)
            w.level = .screenSaver; w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false
            w.ignoresMouseEvents = false; w.isReleasedWhenClosed = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onDone = { [weak self] rect in self?.finish(rect) }
            view.onPointerMoved = { [weak self] in self?.followPointer() }
            view.onSelectionChange = { [weak self] rect in self?.anchorHUD(to: rect) }
            view.onBegin = { [weak self, weak view] in
                self?.views.filter { $0 !== view }.forEach { $0.clearSelection() }
            }
            view.hud = hud
            view.adjustable = adjustable
            w.contentView = view
            w.orderFrontRegardless()
            windows.append(w)
        }

        let panel = HUDPanel(contentRect: NSRect(origin: .zero, size: Self.hudSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.isReleasedWhenClosed = false; panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = FirstMouseHostingView(rootView: CaptureHUDView(model: hud))
        hudPanel = panel
        // The hint lets clicks through; the open menu takes them. It stays put while open so it can be clicked.
        hud.onMenuChange = { [weak self] open in
            guard let self else { return }
            self.hudPanel?.ignoresMouseEvents = !(open || self.anchor != nil)
            if !open { self.positionHUD() }
        }
        hud.onConfirm = { [weak self] in self?.views.first(where: \.hasSelection)?.confirm() }
        followPointer()
        panel.orderFrontRegardless()

        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        if let key = windows.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? windows.first {
            key.makeKey(); key.makeFirstResponder(key.contentView)
        }
        SelectionView.cursor.set()
    }

    private func anchorHUD(to rect: NSRect?) {
        anchor = rect
        hud?.adjusting = rect != nil
        hudPanel?.ignoresMouseEvents = !(rect != nil || hud?.menuOpen == true)
        positionHUD()
    }

    private func positionHUD() { if let anchor { place(around: anchor) } else { followPointer() } }

    /// Centres the hint under the selection; above it when there is no room, inside it as a last resort.
    private func place(around rect: NSRect) {
        guard let panel = hudPanel, let hud, !hud.menuOpen else { return }
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main else { return }
        let size = Self.hudSize, m = CaptureHUDView.margin, area = screen.visibleFrame
        let gap: CGFloat = 12, room: CGFloat = 36 + gap
        let x = min(max(rect.midX - size.width / 2, area.minX - m), area.maxX - size.width + m)
        let y: CGFloat, corner: Alignment
        if rect.minY - room >= area.minY { y = rect.minY - gap - size.height + m; corner = .top }
        else if rect.maxY + room <= area.maxY { y = rect.maxY + gap - m; corner = .bottom }
        else { y = rect.minY + gap - m; corner = .bottom }
        if hud.corner != corner { hud.corner = corner }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Keeps the hint below and to the right of the pointer, flipping near the screen edges.
    private func followPointer() {
        guard anchor == nil, let panel = hudPanel, let hud, !hud.menuOpen else { return }
        let p = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) ?? NSScreen.main else { return }
        let size = Self.hudSize, m = CaptureHUDView.margin, area = screen.visibleFrame
        // Leading/trailing follow the reading direction, so mirror the preferred side in right-to-left languages.
        let rtl = NSApp.userInterfaceLayoutDirection == .rightToLeft
        var right = !rtl
        if right && p.x + Self.offset.x + size.width - m > area.maxX { right = false }
        if !right && p.x - Self.offset.x - size.width + m < area.minX { right = true }
        let below = p.y - Self.offset.y - size.height + m >= area.minY
        let x = right ? p.x + Self.offset.x - m : p.x - Self.offset.x - size.width + m
        let y = below ? p.y - Self.offset.y - size.height + m : p.y + Self.offset.y - m
        let leading = right != rtl
        let corner: Alignment = below ? (leading ? .topLeading : .topTrailing) : (leading ? .bottomLeading : .bottomTrailing)
        if hud.corner != corner { hud.corner = corner }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func finish(_ rect: NSRect?) {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        hudPanel?.orderOut(nil); hudPanel = nil; hud = nil; anchor = nil
        NSCursor.arrow.set()
        let done = completion; completion = nil
        done?(rect)
    }
}

// MARK: - Capture via /usr/sbin/screencapture

/// What a capture covered, so the repeat shortcut can take it again. Kept in memory only.
enum CaptureTarget: Equatable {
    /// A selected area, in global screen points (Cocoa coordinates).
    case region(NSRect)
    /// A window, followed by its window number even after it moves or is resized.
    case window(CGWindowID)
    /// A whole display, by its display ID.
    case screen(CGDirectDisplayID)
}

enum RepeatResult: Equatable { case started, nothingToRepeat, targetGone(CaptureTarget) }

final class ScreenCapturer {
    private(set) var isCapturing = false
    /// The last successful capture; the repeat shortcut takes it again.
    private(set) var last: CaptureTarget?
    private let overlay = SelectionOverlay()
    private let countdown = CountdownHUD()
    private var previousApp: NSRunningApplication?

    /// Captures into a temporary file inside the container. Completion gets nil if cancelled (Esc) or failed.
    func capture(_ settings: Settings, mode: CaptureMode, completion: @escaping (URL?) -> Void) {
        guard !isCapturing else { return }
        isCapturing = true
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front == NSRunningApplication.current ? nil : front
        let cancel: () -> Void = { [weak self] in self?.isCapturing = false; self?.restoreFocus(); completion(nil) }
        switch mode {
        case .window:
            // The system window picker runs its own timer.
            previousApp = nil
            run(settings, mode: mode, region: nil, delay: settings.delay, completion: completion)
        case .screen:
            // The display under the pointer, captured as its whole area.
            let frame = Self.screenFrame(containing: NSEvent.mouseLocation, in: NSScreen.screens.map(\.frame)) ?? NSScreen.screens.first?.frame ?? .zero
            countdownThenRun(settings, mode: mode, region: frame, around: frame, cancel: cancel, completion: completion)
        case .selection:
            let hud = CaptureHUDModel(delay: settings.delay)
            hud.onDelayChange = { settings.delay = $0 }
            overlay.begin(hud: hud, adjustable: settings.adjustSelection) { [weak self] rect in
                guard let self else { return }
                guard let rect else { cancel(); return }
                self.countdownThenRun(settings, mode: mode, region: rect, around: rect, cancel: cancel, completion: completion)
            }
        }
    }

    private func countdownThenRun(_ settings: Settings, mode: CaptureMode, region: NSRect?, around: NSRect, cancel: @escaping () -> Void, completion: @escaping (URL?) -> Void) {
        let go = { [weak self] in
            guard let self else { return }
            self.restoreFocus()
            // Let the overlay and the countdown leave the screen before capturing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.run(settings, mode: mode, region: region, delay: 0, completion: completion) }
        }
        guard settings.delay > 0 else { go(); return }
        countdown.run(seconds: settings.delay, around: around) { completed in completed ? go() : cancel() }
    }

    /// What a finished capture covered. After the system window picker, the chosen window is the one under the pointer,
    /// which is still where the user clicked.
    private func target(mode: CaptureMode, region: NSRect?, windowID: CGWindowID?) -> CaptureTarget? {
        if let windowID { return .window(windowID) }
        if mode == .screen, let region {
            return NSScreen.screens.first(where: { $0.frame == region }).flatMap(\.displayID).map { .screen($0) } ?? .region(region)
        }
        if let region { return .region(region) }
        guard mode == .window else { return nil }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let height = NSScreen.screens.first?.frame.height ?? 0
        return Self.windowID(at: NSEvent.mouseLocation, in: windows, mainScreenHeight: height, excludingPID: ProcessInfo.processInfo.processIdentifier).map { .window($0) }
    }

    /// Gives focus back so window order on screen is what the user saw before.
    private func restoreFocus() { previousApp?.activate(); previousApp = nil }

    /// The frame of the display that contains a point, in Cocoa global coordinates.
    static func screenFrame(containing point: NSPoint, in frames: [NSRect]) -> NSRect? {
        frames.first { NSMouseInRect(point, $0, false) }
    }

    /// Takes the last capture again at once: the same area, the same window wherever it is now, or the same display.
    func repeatLast(_ settings: Settings, completion: @escaping (URL?) -> Void) -> RepeatResult {
        guard !isCapturing, let last else { return .nothingToRepeat }
        let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        switch last {
        case .window(let id):
            guard Self.windowExists(id, in: windows) else { self.last = nil; return .targetGone(last) }
            isCapturing = true; run(settings, mode: .window, region: nil, windowID: id, delay: 0, completion: completion)
        case .region(let rect):
            guard NSScreen.screens.contains(where: { $0.frame.intersects(rect) }) else { self.last = nil; return .targetGone(last) }
            isCapturing = true; run(settings, mode: .selection, region: rect, delay: 0, completion: completion)
        case .screen(let id):
            // The display's current frame, in case its resolution or arrangement changed.
            guard let frame = NSScreen.screens.first(where: { $0.displayID == id })?.frame else { self.last = nil; return .targetGone(last) }
            isCapturing = true; run(settings, mode: .screen, region: frame, delay: 0, completion: completion)
        }
        return .started
    }

    /// screencapture arguments, without the output path. `mainScreen` is the main display's frame in Cocoa coordinates.
    static func arguments(format: ImageFormat, mode: CaptureMode, region: NSRect?, windowID: CGWindowID?, delay: Int,
                          showCursor: Bool, windowShadow: Bool, mainScreen: NSRect?) -> [String] {
        var args = ["-t", format.rawValue]
        if let windowID {
            args.append("-l\(windowID)")
        } else if let region, let main = mainScreen {
            // screencapture -R uses points with the origin at the top-left of the main display.
            let r = region.integral
            args.append("-R\(Int(r.minX - main.minX)),\(Int(main.maxY - r.maxY)),\(Int(r.width)),\(Int(r.height))")
        } else {
            switch mode {
            case .window: args += ["-i", "-w"]
            case .screen, .selection: args += ["-m"]
            }
        }
        if delay > 0 { args += ["-T", String(delay)] }
        if showCursor { args.append("-C") }
        if !windowShadow { args.append("-o") }
        return args
    }

    /// The front-most normal window under a point (Cocoa global coordinates), ignoring this app's own windows.
    /// `windows` is CGWindowListCopyWindowInfo output, front to back; its bounds use a top-left origin.
    static func windowID(at point: NSPoint, in windows: [[String: Any]], mainScreenHeight: CGFloat, excludingPID: pid_t) -> CGWindowID? {
        let p = CGPoint(x: point.x, y: mainScreenHeight - point.y)
        for w in windows {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? pid_t) != excludingPID,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsDict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict), bounds.contains(p),
                  let number = w[kCGWindowNumber as String] as? Int else { continue }
            return CGWindowID(number)
        }
        return nil
    }

    static func windowExists(_ id: CGWindowID, in windows: [[String: Any]]) -> Bool {
        windows.contains { ($0[kCGWindowNumber as String] as? Int).map { CGWindowID($0) } == id }
    }

    private func run(_ settings: Settings, mode: CaptureMode, region: NSRect?, windowID: CGWindowID? = nil, delay: Int, completion: @escaping (URL?) -> Void) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kapture-\(UUID().uuidString).\(settings.format.rawValue)")
        var args = Self.arguments(format: settings.format, mode: mode, region: region, windowID: windowID, delay: delay,
                                  showCursor: settings.showCursor, windowShadow: settings.windowShadow, mainScreen: NSScreen.screens.first?.frame)
        args.append(url.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = args
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isCapturing = false
                let captured = FileManager.default.fileExists(atPath: url.path)
                if captured { self.last = self.target(mode: mode, region: region, windowID: windowID) }
                completion(captured ? url : nil)
            }
        }
        do { isCapturing = true; try process.run() } catch { isCapturing = false; completion(nil) }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? { (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }
}

// MARK: - Store

final class CaptureStore: ObservableObject {
    @Published var captures: [Capture] = [] { didSet { scheduleExpiry() } }
    @Published var selected: UUID?
    @Published var message: String
    @Published var captureShortcut: Shortcut
    @Published var windowShortcut: Shortcut
    @Published var screenShortcut: Shortcut
    @Published var repeatShortcut: Shortcut
    @Published var autoImport = false
    @Published var highlightColor: RGB { didSet { settings.highlightColor = highlightColor } }
    @Published var highlightSize: HighlightSize { didSet { settings.highlightSize = highlightSize } }
    @Published var showRulers: Bool { didSet { settings.showRulers = showRulers } }
    let settings: Settings
    private var lastChange = NSPasteboard.general.changeCount
    private var undoImages: [CGImage] = []
    private var redoImages: [CGImage] = []
    private var historyID: UUID?
    var canUndo: Bool { historyID == selected && !undoImages.isEmpty }
    var canRedo: Bool { historyID == selected && !redoImages.isEmpty }
    private func resetEdits() { undoImages.removeAll(); redoImages.removeAll(); historyID = selected }
    func select(_ id: UUID?) { if selected != id { selected = id; resetEdits() } }
    /// Lets the owner pause clipboard checks (for example while the editor is open).
    var canPoll: () -> Bool = { true }
    private var clipboardTimer: Timer?
    /// The pasteboard has no change notification, so it is polled, but only while Auto images is on.
    func setAutomatic(_ enabled: Bool) {
        lastChange = NSPasteboard.general.changeCount; autoImport = enabled
        clipboardTimer?.invalidate(); clipboardTimer = nil
        guard enabled else { return }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.canPoll() else { return }
            self.poll()
        }
        t.tolerance = 0.25 // lets macOS coalesce wake-ups
        RunLoop.main.add(t, forMode: .common)
        clipboardTimer = t
    }
    func poll() {
        guard autoImport else { return }
        let count = NSPasteboard.general.changeCount
        guard count != lastChange else { return }
        lastChange = count
        let types = NSPasteboard.general.types ?? []
        guard types.contains(.png) || types.contains(.tiff) else { return }
        importImage()
    }
    func undo() {
        guard canUndo, let i = captures.firstIndex(where: { $0.id == selected }), let previous = undoImages.popLast() else { return }
        redoImages.append(captures[i].image); captures[i].image = previous; message = L("Edit undone.")
    }
    func redo() {
        guard canRedo, let i = captures.firstIndex(where: { $0.id == selected }), let next = redoImages.popLast() else { return }
        undoImages.append(captures[i].image); captures[i].image = next; message = L("Edit redone.")
    }
    private var expiryTimer: Timer?
    init(settings: Settings) {
        self.settings = settings
        highlightColor = settings.highlightColor
        highlightSize = settings.highlightSize
        showRulers = settings.showRulers
        captureShortcut = settings.captureShortcut
        windowShortcut = settings.shortcut(for: .captureWindow)
        screenShortcut = settings.shortcut(for: .captureScreen)
        repeatShortcut = settings.shortcut(for: .repeatCapture)
        let keys = settings.captureShortcut.display
        message = L("Press \(keys) or use the menu to take a screenshot.")
    }
    deinit { expiryTimer?.invalidate(); clipboardTimer?.invalidate() }
    /// One timer for the oldest capture's expiry instead of a periodic check; none when the history is empty.
    private func scheduleExpiry() {
        expiryTimer?.invalidate(); expiryTimer = nil
        guard let oldest = captures.map(\.created).min() else { return }
        let t = Timer(fire: oldest.addingTimeInterval(1800.5), interval: 0, repeats: false) { [weak self] _ in self?.expire() }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        expiryTimer = t
    }
    var current: Capture? { captures.first { $0.id == selected } }
    func expire(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-1800)
        captures.removeAll { $0.created < cutoff }
        if current == nil { select(captures.first?.id) }
    }
    func clear() { captures.removeAll(); selected = nil; resetEdits(); message = L("History cleared.") }
    func remove() { captures.removeAll { $0.id == selected }; select(captures.first?.id) }

    /// Decodes and flattens image data, enforcing size limits.
    static func decode(_ data: Data, maxBytes: Int, maxSide: Int, maxPixels: Int) -> CGImage? {
        guard data.count <= maxBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w <= maxSide, h <= maxSide, w <= maxPixels / h,
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        return raster(decoded)
    }

    /// Watermark image, loaded from the container on first use; nil when none has been chosen.
    lazy var watermarkImage: CGImage? = Watermark.loadStored()
    /// True when new captures and imports get the watermark.
    var watermarkActive: Bool { settings.watermarkEnabled && watermarkImage != nil }
    /// True when new captures and imports get the watermark, the number or both.
    var stampActive: Bool { watermarkActive || settings.numberEnabled }
    /// The image with the watermark and the number when they are on; otherwise unchanged.
    /// Each numbered image uses up the current number when it is set to increase.
    func stamped(_ image: CGImage) -> CGImage {
        var result = image
        if settings.watermarkEnabled, let mark = watermarkImage {
            result = Watermark.apply(mark, to: result, options: settings.watermark) ?? result
        }
        if settings.numberEnabled {
            let n = settings.numberNext
            result = NumberStamp.apply(n, to: result, options: settings.number) ?? result
            if settings.numberIncrement { settings.numberNext = n + 1 }
        }
        return result
    }

    @discardableResult
    private func insert(_ image: CGImage, baseName: String) -> Capture {
        let capture = Capture(image: stamped(image), baseName: baseName)
        captures.insert(capture, at: 0); if captures.count > 10 { captures.removeLast() }
        // Limit total resident raster data, in addition to number of images.
        while captures.count > 1 && captures.reduce(0, { $0 + $1.image.bytesPerRow * $1.image.height }) > 128 * 1024 * 1024 { captures.removeLast() }
        select(capture.id)
        return capture
    }

    /// Adds a capture produced by Kapture itself (trusted source, larger limits for big/multiple displays).
    func addOwnCapture(_ data: Data, baseName: String) -> Capture? {
        expire()
        guard let image = Self.decode(data, maxBytes: 256 * 1024 * 1024, maxSide: 16384, maxPixels: 50_000_000) else { return nil }
        return insert(image, baseName: baseName)
    }

    func importImage() {
        expire()
        let board = NSPasteboard.general
        let denied = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"]
        if denied.contains(where: { board.types?.contains(NSPasteboard.PasteboardType($0)) == true }) {
            message = L("Private or temporary content was not imported."); return
        }
        let initialChange = board.changeCount
        guard let data = board.data(forType: .png) ?? board.data(forType: .tiff),
              board.changeCount == initialChange,
              let image = Self.decode(data, maxBytes: 48 * 1024 * 1024, maxSide: 8192, maxPixels: 16_000_000) else {
            message = L("No valid PNG or TIFF image, or it exceeds the size limit."); return
        }
        insert(image, baseName: FolderAccess.baseName())
        lastChange = initialChange; message = L("Image imported. No file was saved.")
    }
    static func raster(_ image: CGImage, draw: ((CGContext) -> Void)? = nil) -> CGImage? {
        guard let color = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: color, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        draw?(ctx)
        return ctx.makeImage()
    }
    func replace(_ image: CGImage) {
        guard let i = captures.firstIndex(where: { $0.id == selected }) else { return }
        if historyID != selected { resetEdits() }
        undoImages.append(captures[i].image); redoImages.removeAll()
        while undoImages.count > 5 || undoImages.reduce(0, { $0 + $1.bytesPerRow * $1.height }) > 64 * 1024 * 1024 { undoImages.removeFirst() }
        captures[i].image = image; message = L("Edit applied to the pixels.")
    }

    /// Puts PNG data on the general pasteboard without re-importing it with Auto images.
    @discardableResult
    func writeToPasteboard(_ png: Data) -> Bool {
        let board = NSPasteboard.general
        board.clearContents()
        guard board.setData(png, forType: .png) else { return false }
        lastChange = board.changeCount
        return true
    }

    func copyImage() {
        expire()
        guard let image = current?.image else { return }
        guard let data = FolderAccess.pngData(image) else { message = L("Couldn’t encode the image."); return }
        message = writeToPasteboard(data) ? L("Image copied. Paste it with ⌘V.") : L("Couldn’t write to the clipboard.")
    }

    /// Opens the configured capture folder in Finder, asking for one first if none is set.
    func openFolder() {
        if settings.folder == nil, let chosen = FolderAccess.chooseFolder() { settings.folder = chosen }
        guard let folder = settings.folder else { message = L("No destination folder chosen."); return }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        if !NSWorkspace.shared.open(folder) { message = L("Couldn’t open the folder \(folder.lastPathComponent).") }
    }

    /// Saves the current (edited) image as a new PNG, never overwriting the original capture file.
    func saveEditedCopy() {
        expire()
        guard let capture = current else { return }
        guard let data = FolderAccess.pngData(capture.image) else { message = L("Couldn’t encode the image."); return }
        let base = L("\(capture.baseName) (edited)")
        if let folder = settings.folder {
            do {
                let url = try FolderAccess.write(data, base: base, ext: "png", in: folder)
                message = L("Edited copy saved: \(url.lastPathComponent)")
            } catch { message = L("Couldn’t save to the folder: \(error.localizedDescription)") }
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(base).png"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url); message = L("Edited copy saved: \(url.lastPathComponent)") }
        catch { message = L("Couldn’t save: \(error.localizedDescription)") }
    }

    /// Highlighter stroke through points given as fractions of the image (top-left origin). Multiply blending tints
    /// light areas and leaves dark text dark, like a marker on paper.
    func highlight(points: [CGPoint], color: RGB, size: HighlightSize) {
        expire(); guard let image = current?.image, !points.isEmpty else { return }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let pixels = points.map { CGPoint(x: min(w, max(0, $0.x * w)), y: h - min(h, max(0, $0.y * h))) }
        guard let result = Self.raster(image, draw: { ctx in
            ctx.setBlendMode(.multiply)
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(size.width(for: CGSize(width: w, height: h)))
            ctx.setLineCap(.round); ctx.setLineJoin(.round)
            ctx.addPath(smoothPath(pixels)); ctx.strokePath()
        }) else { return }
        replace(result)
    }

    func edit(tool: EditTool, start: CGPoint, end: CGPoint, text: String) {
        expire(); guard let image = current?.image else { return }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        func point(_ p: CGPoint) -> CGPoint { CGPoint(x: min(w,max(0,p.x*w)), y: min(h,max(0,p.y*h))) }
        let a = point(start), b = point(end)
        let rect = CGRect(x: min(a.x,b.x), y: min(a.y,b.y), width: abs(a.x-b.x), height: abs(a.y-b.y)).integral.intersection(CGRect(x:0,y:0,width:w,height:h))
        if tool == .crop {
            guard rect.width >= 2, rect.height >= 2, let cropped = image.cropping(to: rect), let flattened = Self.raster(cropped) else { return }
            replace(flattened); return
        }
        let scale = max(2, min(w,h)/180)
        guard let result = Self.raster(image, draw: { ctx in
            let p = CGPoint(x:a.x,y:h-a.y), q = CGPoint(x:b.x,y:h-b.y)
            switch tool {
            case .redact:
                guard rect.width >= 1, rect.height >= 1 else { return }
                ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x:rect.minX,y:h-rect.maxY,width:rect.width,height:rect.height))
            case .arrow:
                guard hypot(q.x-p.x,q.y-p.y) > 2 else { return }
                ctx.setStrokeColor(NSColor.systemRed.cgColor); ctx.setLineWidth(scale); ctx.setLineCap(.round); ctx.setLineJoin(.round)
                let angle = atan2(q.y-p.y,q.x-p.x), head = scale*4
                ctx.move(to:p); ctx.addLine(to:q); ctx.move(to:CGPoint(x:q.x-head*cos(angle-0.5),y:q.y-head*sin(angle-0.5))); ctx.addLine(to:q); ctx.addLine(to:CGPoint(x:q.x-head*cos(angle+0.5),y:q.y-head*sin(angle+0.5))); ctx.strokePath()
            case .text:
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: max(16,scale*4), weight:.bold), .foregroundColor: NSColor.systemRed]
                let s = String(text.prefix(500)) as NSString
                let size = s.size(withAttributes: attrs)
                s.draw(at: CGPoint(x:min(p.x,max(0,w-size.width)),y:max(0,p.y-size.height)), withAttributes:attrs)
                NSGraphicsContext.restoreGraphicsState()
            case .crop, .highlight: break
            }
        }) else { return }
        replace(result)
    }
}

// MARK: - Watermark

/// Where and how the watermark is drawn. Values are fractions so they mean the same on every display.
struct WatermarkOptions: Equatable {
    /// 0 = left edge, 0.5 = centred, 1 = right edge. A single mark always stays fully inside the capture.
    var x = 0.97
    /// 0 = top edge, 0.5 = centred, 1 = bottom edge.
    var y = 0.95
    /// Width of the mark as a fraction of the capture's width.
    var size = 0.18
    var opacity = 0.6
    /// Repeats the mark as a pattern over the whole capture; x and y then shift the pattern.
    var tiled = false
}

enum Watermark {
    static let sizeRange = 0.03...0.6
    static let opacityRange = 0.05...1.0
    /// Limits for the chosen image (it is drawn on every capture, so it stays small).
    static let maxBytes = 32 * 1024 * 1024, maxSide = 4096, maxPixels = 16_000_000

    /// Size of the mark in pixels: a fraction of the capture's width, keeping its proportions and fitting inside.
    static func markSize(_ mark: CGImage, canvas: CGSize, size: Double) -> CGSize {
        let aspect = CGFloat(mark.height) / CGFloat(max(1, mark.width))
        var w = canvas.width * CGFloat(min(max(size, sizeRange.lowerBound), sizeRange.upperBound))
        var h = w * aspect
        if h > canvas.height { h = canvas.height; w = h / aspect }
        return CGSize(width: max(1, w.rounded()), height: max(1, h.rounded()))
    }

    /// Rectangles where the mark is drawn, in Core Graphics coordinates (origin at the bottom-left).
    static func rects(mark: CGImage, canvas: CGSize, options: WatermarkOptions) -> [CGRect] {
        let s = markSize(mark, canvas: canvas, size: options.size)
        let x = CGFloat(min(max(options.x, 0), 1)), y = CGFloat(min(max(options.y, 0), 1))
        guard options.tiled else {
            return [CGRect(x: ((canvas.width - s.width) * x).rounded(), y: ((canvas.height - s.height) * (1 - y)).rounded(), width: s.width, height: s.height)]
        }
        // Brick pattern with a gap of one mark between marks; at most about 50 rows and columns.
        let stepX = max(s.width * 2, canvas.width / 50), stepY = max(s.height * 2.5, canvas.height / 50)
        var out: [CGRect] = []
        var row = 0
        var top = stepY * y - stepY // y measured from the top
        while top < canvas.height {
            var left = stepX * x - stepX * (row % 2 == 0 ? 1 : 1.5)
            while left < canvas.width {
                let r = CGRect(x: left, y: canvas.height - top - s.height, width: s.width, height: s.height)
                if r.intersects(CGRect(origin: .zero, size: canvas)) { out.append(r) }
                left += stepX
            }
            top += stepY; row += 1
        }
        return out
    }

    static func apply(_ mark: CGImage, to image: CGImage, options: WatermarkOptions) -> CGImage? {
        let canvas = CGSize(width: image.width, height: image.height)
        let rects = rects(mark: mark, canvas: canvas, options: options)
        return CaptureStore.raster(image) { ctx in
            ctx.setAlpha(CGFloat(min(max(options.opacity, opacityRange.lowerBound), opacityRange.upperBound)))
            ctx.interpolationQuality = .high
            for r in rects { ctx.draw(mark, in: r) }
        }
    }

    /// The copy of the chosen image, inside the app's sandbox container.
    static var imageURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Kapture SCR", isDirectory: true).appendingPathComponent("watermark.png")
    }

    static func loadStored(from url: URL = imageURL) -> CGImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return CaptureStore.decode(data, maxBytes: maxBytes, maxSide: maxSide, maxPixels: maxPixels)
    }

    /// Validates the chosen image and keeps a PNG copy, so the original file can move or disappear.
    static func store(_ data: Data, at url: URL = imageURL) -> CGImage? {
        guard let image = CaptureStore.decode(data, maxBytes: maxBytes, maxSide: maxSide, maxPixels: maxPixels),
              let png = FolderAccess.pngData(image) else { return nil }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
        } catch { return nil }
        return image
    }

    static func removeStored(at url: URL = imageURL) { try? FileManager.default.removeItem(at: url) }

    /// A neutral, screenshot-like picture for the settings preview: desktop, a window with text lines and a photo.
    static func sampleScreenshot(width: Int = 1440, height: Int = 900) -> CGImage? {
        guard let color = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: color, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let w = CGFloat(width), h = CGFloat(height)
        let colors = [CGColor(red: 0.20, green: 0.36, blue: 0.55, alpha: 1), CGColor(red: 0.55, green: 0.42, blue: 0.62, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: color, colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: w, y: h), options: [])
        }
        let window = CGRect(x: w * 0.12, y: h * 0.12, width: w * 0.76, height: h * 0.72)
        ctx.setFillColor(CGColor(gray: 0.98, alpha: 1)); ctx.addPath(CGPath(roundedRect: window, cornerWidth: 18, cornerHeight: 18, transform: nil)); ctx.fillPath()
        ctx.setFillColor(CGColor(gray: 0.90, alpha: 1)); ctx.fill(CGRect(x: window.minX, y: window.maxY - 56, width: window.width, height: 38))
        for (i, c) in [(1.0, 0.37, 0.34), (1.0, 0.74, 0.18), (0.16, 0.79, 0.25)].enumerated() {
            ctx.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: window.minX + 22 + CGFloat(i) * 26, y: window.maxY - 34, width: 14, height: 14))
        }
        ctx.setFillColor(CGColor(gray: 0.78, alpha: 1))
        var line = window.maxY - 110
        var n = 0
        while line > window.minY + 40 {
            let len = window.width * (n % 3 == 2 ? 0.25 : 0.42)
            ctx.fill(CGRect(x: window.minX + 40, y: line, width: len, height: 12)); line -= 30; n += 1
        }
        ctx.setFillColor(CGColor(red: 0.62, green: 0.76, blue: 0.86, alpha: 1))
        ctx.fill(CGRect(x: window.midX + 20, y: window.minY + 40, width: window.width * 0.42, height: window.height * 0.62))
        return ctx.makeImage()
    }
}

/// Where and how the automatic number is drawn. Position and size work like the watermark's.
struct NumberOptions: Equatable {
    var x = 0.03
    var y = 0.05
    /// Text height as a fraction of the capture's height.
    var size = 0.08
    var opacity = 1.0
    /// Font family; empty means the system font.
    var font = ""
    var color = RGB(r: 1, g: 0.23, b: 0.19)

    static let colorPresets: [(RGB, String)] = [
        (RGB(r: 1, g: 0.23, b: 0.19), L("Red")), (RGB(r: 1, g: 1, b: 1), L("White")), (RGB(r: 0, g: 0, b: 0), L("Black")),
        (RGB(r: 1, g: 0.8, b: 0), L("Yellow")), (RGB(r: 0, g: 0.48, b: 1), L("Blue")), (RGB(r: 0.2, g: 0.78, b: 0.35), L("Green")),
    ]
}

enum NumberStamp {
    static let sizeRange = 0.03...0.4

    /// Bold face of the family when it has one; the system font when the family is empty or not installed.
    static func font(family: String, size: CGFloat) -> NSFont {
        if !family.isEmpty, let font = NSFontManager.shared.font(withFamily: family, traits: .boldFontMask, weight: 9, size: size)
            ?? NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) { return font }
        return .systemFont(ofSize: size, weight: .bold)
    }

    /// The number in the chosen colour with a thin contrasting outline, so it reads on light and dark content.
    static func attributes(_ options: NumberOptions, canvas: CGSize) -> [NSAttributedString.Key: Any] {
        let size = max(8, canvas.height * CGFloat(min(max(options.size, sizeRange.lowerBound), sizeRange.upperBound)))
        let outline: NSColor = options.color.luminance > 0.6 ? .black : .white
        return [.font: font(family: options.font, size: size), .foregroundColor: options.color.nsColor,
                .strokeColor: outline.withAlphaComponent(0.75), .strokeWidth: -4.0]
    }

    /// Where the number goes, in Core Graphics coordinates. It always stays inside the capture.
    static func rect(for number: Int, canvas: CGSize, options: NumberOptions) -> CGRect {
        let size = ("\(number)" as NSString).size(withAttributes: attributes(options, canvas: canvas))
        let w = min(ceil(size.width), canvas.width), h = min(ceil(size.height), canvas.height)
        let x = CGFloat(min(max(options.x, 0), 1)), y = CGFloat(min(max(options.y, 0), 1))
        return CGRect(x: ((canvas.width - w) * x).rounded(), y: ((canvas.height - h) * (1 - y)).rounded(), width: w, height: h)
    }

    static func apply(_ number: Int, to image: CGImage, options: NumberOptions) -> CGImage? {
        let canvas = CGSize(width: image.width, height: image.height)
        let attrs = attributes(options, canvas: canvas)
        let origin = rect(for: number, canvas: canvas, options: options).origin
        return CaptureStore.raster(image) { ctx in
            // One transparency layer, so the outline and the fill fade together instead of doubling up.
            ctx.setAlpha(CGFloat(min(max(options.opacity, Watermark.opacityRange.lowerBound), 1)))
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            ("\(number)" as NSString).draw(at: origin, withAttributes: attrs)
            NSGraphicsContext.restoreGraphicsState()
            ctx.endTransparencyLayer()
        }
    }
}

final class WatermarkModel: ObservableObject {
    enum Section: Hashable { case watermark, number }
    let store: CaptureStore
    @Published var section = Section.watermark { didSet { render() } }
    @Published var enabled: Bool { didSet { store.settings.watermarkEnabled = enabled } }
    @Published var options: WatermarkOptions { didSet { store.settings.watermark = options; render() } }
    @Published var numberEnabled: Bool { didSet { store.settings.numberEnabled = numberEnabled; render() } }
    @Published var numberNext: Int { didSet { if numberNext < 0 { numberNext = 0 }; store.settings.numberNext = numberNext; render() } }
    @Published var numberIncrement: Bool { didSet { store.settings.numberIncrement = numberIncrement } }
    @Published var number: NumberOptions { didSet { store.settings.number = number; render() } }
    @Published private(set) var preview: CGImage?
    @Published var error: String?
    private let sample = Watermark.sampleScreenshot()
    lazy var fontFamilies: [String] = NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }.sorted()

    init(store: CaptureStore) {
        self.store = store
        enabled = store.settings.watermarkEnabled
        options = store.settings.watermark
        numberEnabled = store.settings.numberEnabled
        numberNext = store.settings.numberNext
        numberIncrement = store.settings.numberIncrement
        number = store.settings.number
        render()
    }

    /// Picks up changes made elsewhere (menu toggles, the number used up by captures) when the window opens.
    func refresh() {
        enabled = store.settings.watermarkEnabled
        numberEnabled = store.settings.numberEnabled
        numberNext = store.settings.numberNext
    }

    var mark: CGImage? { store.watermarkImage }

    /// The sample with exactly what captures will get; the number is also shown while its tab is open.
    func render() {
        guard var image = sample else { preview = nil; return }
        if let mark { image = Watermark.apply(mark, to: image, options: options) ?? image }
        if numberEnabled || section == .number { image = NumberStamp.apply(numberNext, to: image, options: number) ?? image }
        preview = image
    }

    /// Places the mark or the number (whichever tab is open) centred under a point of the preview.
    func move(to p: CGPoint) {
        guard let sample else { return }
        let canvas = CGSize(width: sample.width, height: sample.height)
        if section == .number {
            let r = NumberStamp.rect(for: numberNext, canvas: canvas, options: number)
            let fw = r.width / canvas.width, fh = r.height / canvas.height
            number.x = fw < 1 ? min(max((p.x - fw / 2) / (1 - fw), 0), 1) : 0.5
            number.y = fh < 1 ? min(max((p.y - fh / 2) / (1 - fh), 0), 1) : 0.5
            return
        }
        guard let mark else { return }
        if options.tiled { options.x = min(max(p.x, 0), 1); options.y = min(max(p.y, 0), 1); return }
        let s = Watermark.markSize(mark, canvas: CGSize(width: sample.width, height: sample.height), size: options.size)
        let mw = s.width / CGFloat(sample.width), mh = s.height / CGFloat(sample.height)
        options.x = mw < 1 ? min(max((p.x - mw / 2) / (1 - mw), 0), 1) : 0.5
        options.y = mh < 1 ? min(max((p.y - mh / 2) / (1 - mh), 0), 1) : 0.5
    }

    func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .gif, .bmp]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.prompt = L("Choose"); panel.message = L("PNG with transparency works best.")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url), let image = Watermark.store(data) else {
            error = L("Couldn’t use that image. Choose a PNG, JPEG, HEIC or TIFF up to 4096 px."); return
        }
        error = nil
        objectWillChange.send()
        store.watermarkImage = image
        enabled = true
        render()
    }

    func removeImage() {
        Watermark.removeStored()
        objectWillChange.send()
        store.watermarkImage = nil
        enabled = false
        render()
    }
}

struct WatermarkView: View {
    @ObservedObject var model: WatermarkModel
    @Environment(\.layoutDirection) private var direction
    /// Corners and edges keep a small margin; bottom right matches the default watermark position.
    private let presets: [(x: Double, y: Double, label: String)] = [
        (0.03, 0.05, L("Top Left")), (0.5, 0.05, L("Top")), (0.97, 0.05, L("Top Right")),
        (0.03, 0.5, L("Left")), (0.5, 0.5, L("Center")), (0.97, 0.5, L("Right")),
        (0.03, 0.95, L("Bottom Left")), (0.5, 0.95, L("Bottom")), (0.97, 0.95, L("Bottom Right")),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker(L("Watermark and Number"), selection: $model.section) {
                Text(L("Watermark")).tag(WatermarkModel.Section.watermark)
                Text(L("Number")).tag(WatermarkModel.Section.number)
            }
            .pickerStyle(.segmented).labelsHidden()
            if model.section == .watermark {
                imageRow
                switchRow(L("Add the watermark to every capture and imported image"), isOn: $model.enabled).disabled(model.mark == nil)
            } else {
                switchRow(L("Add a number to every capture and imported image"), isOn: $model.numberEnabled)
                numberRow
            }
            preview
            if model.section == .watermark {
                positionControls(x: $model.options.x, y: $model.options.y, size: $model.options.size, sizeRange: Watermark.sizeRange,
                                 opacity: $model.options.opacity)
                    .disabled(model.mark == nil)
                Toggle(L("Repeat as a pattern"), isOn: $model.options.tiled).disabled(model.mark == nil)
            } else {
                positionControls(x: $model.number.x, y: $model.number.y, size: $model.number.size, sizeRange: NumberStamp.sizeRange,
                                 opacity: $model.number.opacity)
                fontAndColorRow
            }
        }
        .padding(20)
        .frame(width: 600)
    }

    private func switchRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Toggle(title, isOn: isOn).toggleStyle(.switch).labelsHidden()
        }
    }

    private var imageRow: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.08))
                if let mark = model.mark { Image(decorative: mark, scale: 1).resizable().scaledToFit().padding(4) }
                else { Image(systemName: "photo").foregroundStyle(.secondary) }
            }
            .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.mark == nil ? L("No image chosen") : L("Watermark Image")).font(.system(size: 13, weight: .semibold))
                Text(model.error ?? L("PNG with transparency works best.")).font(.system(size: 12))
                    .foregroundStyle(model.error == nil ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(L("Choose Image…")) { model.chooseImage() }
            Button(L("Remove")) { model.removeImage() }.disabled(model.mark == nil)
        }
    }

    private var numberRow: some View {
        HStack(spacing: 10) {
            Text(L("Next number"))
            TextField(L("Next number"), value: $model.numberNext, format: .number.grouping(.never))
                .labelsHidden().multilineTextAlignment(.trailing).frame(width: 72)
            Stepper(L("Next number"), value: $model.numberNext, in: 0...999_999).labelsHidden()
            Spacer()
            Toggle(L("Increase after each capture"), isOn: $model.numberIncrement)
        }
    }

    private var fontAndColorRow: some View {
        HStack(spacing: 10) {
            Text(L("Font"))
            Picker(L("Font"), selection: $model.number.font) {
                Text(L("System Font")).tag("")
                Divider()
                ForEach(model.fontFamilies, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().frame(maxWidth: 200)
            Spacer()
            Text(L("Color"))
            ForEach(Array(NumberOptions.colorPresets.enumerated()), id: \.offset) { _, preset in
                let on = model.number.color == preset.0
                Button { model.number.color = preset.0 } label: {
                    Circle().fill(preset.0.color).frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(on ? 0.9 : 0.25), lineWidth: on ? 2 : 0.5).padding(on ? -3 : 0))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).help(preset.1).accessibilityLabel(preset.1).accessibilityAddTraits(on ? .isSelected : [])
            }
            ColorPicker(L("Custom color"), selection: Binding(get: { model.number.color.color }, set: { model.number.color = RGB($0) }), supportsOpacity: false)
                .labelsHidden().help(L("Custom color"))
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                ZStack {
                    if let image = model.preview { Image(decorative: image, scale: 1).resizable() }
                    if model.section == .watermark && model.mark == nil {
                        Text(L("Choose an image to see the watermark here."))
                            .font(.system(size: 13, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 8)
                            .background(.regularMaterial, in: Capsule())
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    model.move(to: CGPoint(x: v.location.x / geo.size.width, y: v.location.y / geo.size.height))
                })
            }
            .aspectRatio(1440.0 / 900.0, contentMode: .fit)
            .environment(\.layoutDirection, .leftToRight) // drag coordinates match the unmirrored image
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
            .accessibilityLabel(L("Watermark preview"))
            Text(model.section == .watermark ? L("Drag the watermark in the preview, or choose a position.") : L("Drag the number in the preview, or choose a position."))
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private func positionControls(x: Binding<Double>, y: Binding<Double>, size: Binding<Double>, sizeRange: ClosedRange<Double>,
                                  opacity: Binding<Double>) -> some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Position")).font(.system(size: 13, weight: .semibold))
                // Positions are physical places in the image, which is never mirrored, so the grid is not mirrored either.
                presetGrid(x: x, y: y).environment(\.layoutDirection, .leftToRight)
            }
            // A grid sizes the label column to the longest label in the current language.
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                slider(L("Horizontal"), value: x, in: 0...1, physical: true)
                slider(L("Vertical"), value: y, in: 0...1)
                slider(L("Size"), value: size, in: sizeRange)
                slider(L("Opacity"), value: opacity, in: Watermark.opacityRange)
            }
        }
    }

    private func presetGrid(x: Binding<Double>, y: Binding<Double>) -> some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(0..<3, id: \.self) { row in
                GridRow {
                    ForEach(0..<3, id: \.self) { col in
                        let p = presets[row * 3 + col]
                        let on = abs(x.wrappedValue - p.x) < 0.005 && abs(y.wrappedValue - p.y) < 0.005
                        Button { x.wrappedValue = p.x; y.wrappedValue = p.y } label: {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(on ? Color.accentColor : Color.primary.opacity(0.10))
                                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                                .frame(width: 30, height: 20)
                        }
                        .buttonStyle(.plain).help(p.label).accessibilityLabel(p.label)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
        }
    }

    /// `physical`: the value is a left-to-right place in the image, so the slider keeps that direction in Arabic and Urdu.
    private func slider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, physical: Bool = false) -> some View {
        GridRow {
            Text(title).font(.system(size: 12)).fixedSize()
            Slider(value: value, in: range).environment(\.layoutDirection, physical ? .leftToRight : direction)
            Text(value.wrappedValue.formatted(.percent.precision(.fractionLength(0)))).font(.system(size: 12)).monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
    }
}

// MARK: - Help and About

/// The only web address in the app. Kapture SCR never connects to it: when the user asks, the address is handed to
/// the browser. Nothing is added to it, so nothing about the user or the app is sent.
enum Links {
    static let releases = URL(string: "https://github.com/jsujar/kapture_scr/releases")!
}

/// Facts about this copy of the app, read from its own bundle and code signature on this Mac. Nothing is sent anywhere.
struct BuildInfo: Equatable {
    var version = "?"
    var build = "?"
    /// The git commit it was built from; ends in "-modified" when built with uncommitted changes.
    var commit: String?
    var buildDate: String?
    /// Common name of the signing certificate; nil when signed ad hoc or not at all.
    var signer: String?
    var team: String?
    var identifier: String?
    /// OSStatus of the signature check: 0 means the app is exactly as it was signed.
    var signatureStatus: Int32 = -1
    var sandboxed = false
    var networkAccess = false
    var sha256: String?

    var signatureValid: Bool { signatureStatus == errSecSuccess }

    /// Builds the facts from an Info.plist, the signing information and the executable's bytes (pure, for tests).
    static func make(info: [String: Any], signing: [String: Any]?, signatureStatus: Int32, executable: Data?) -> BuildInfo {
        var b = BuildInfo()
        b.version = info["CFBundleShortVersionString"] as? String ?? "?"
        b.build = info["CFBundleVersion"] as? String ?? "?"
        b.commit = info["KaptureCommit"] as? String
        b.buildDate = info["KaptureBuildDate"] as? String
        if let signing {
            if let leaf = (signing[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first {
                b.signer = SecCertificateCopySubjectSummary(leaf) as String?
            }
            b.team = signing[kSecCodeInfoTeamIdentifier as String] as? String
            b.identifier = signing[kSecCodeInfoIdentifier as String] as? String
            let entitlements = signing[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
            b.sandboxed = entitlements["com.apple.security.app-sandbox"] as? Bool == true
            b.networkAccess = entitlements["com.apple.security.network.client"] as? Bool == true
                || entitlements["com.apple.security.network.server"] as? Bool == true
        }
        b.signatureStatus = signatureStatus
        b.sha256 = executable.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        return b
    }

    /// This running copy.
    static func current(bundle: Bundle = .main) -> BuildInfo {
        var code: SecStaticCode?
        var signing: [String: Any]?
        var status: OSStatus = errSecCSUnsigned
        if SecStaticCodeCreateWithPath(bundle.bundleURL as CFURL, [], &code) == errSecSuccess, let code {
            var info: CFDictionary?
            if SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation), &info) == errSecSuccess {
                signing = info as? [String: Any]
            }
            status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), nil)
        }
        let executable = bundle.executableURL.flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }
        return make(info: bundle.infoDictionary ?? [:], signing: signing, signatureStatus: status, executable: executable)
    }

    var signerText: String { signer ?? L("Ad hoc (no certificate)") }
    var signatureText: String {
        if signatureValid { return L("Valid: unchanged since it was signed") }
        if signatureStatus == errSecCSUnsigned { return L("Not signed") }
        return L("Not valid: this copy was changed after signing") + " (\(signatureStatus))"
    }
    var networkText: String { networkAccess ? L("Allowed") : L("None (blocked by macOS)") }

    /// Rows shown in the About window and copied by Copy Details. Team appears only with a developer certificate.
    var rows: [(String, String)] {
        [(L("Version"), "\(version) (\(build))"), (L("Commit"), commit ?? "—"), (L("Built"), buildDate ?? "—"),
         (L("Signed by"), signerText)] + (team.map { [(L("Team"), $0)] } ?? []) +
        [(L("Signature"), signatureText), (L("App Sandbox"), sandboxed ? L("On") : L("Off")), (L("Network access"), networkText),
         ("SHA-256", sha256 ?? "—")]
    }
    var report: String { (["Kapture SCR"] + rows.map { "\($0.0): \($0.1)" }).joined(separator: "\n") }
}

/// Terminal commands that check this copy without trusting the app itself.
func verificationCommands(appPath: String) -> String {
    let app = "\"\(appPath)\""
    return """
    codesign --verify --deep --strict --verbose=2 \(app)
    codesign -d --entitlements - \(app)
    shasum -a 256 \(app.dropLast())/Contents/MacOS/Kapture"
    """
}

struct AboutView: View {
    let info: BuildInfo
    var openHelp: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(spacing: 14) {
            // The same horizontal logo as the empty states; it already carries the app name.
            BrandLogo(height: 64).padding(.bottom, 4)
            Text(L("Private screenshots. Offline. No network access.")).font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.bottom, 4)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 7) {
                ForEach(Array(info.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row.0).font(.system(size: 12)).foregroundStyle(.secondary).gridColumnAlignment(.trailing).fixedSize()
                        Text(row.1).font(.system(size: 12, design: row.0 == "SHA-256" || row.0 == L("Commit") ? .monospaced : .default))
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(color(for: row.0))
                    }
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
            Text(L("A tampered copy could also fake this window. To be sure, compare the SHA-256 with the one on the release page, or check the app in Terminal as Help explains."))
                .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(copied ? L("Copied") : L("Copy Details")) {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(info.report, forType: .string); copied = true
                }
                Button(L("Help")) { openHelp() }
                Spacer()
                Button(L("Check for Updates…")) { NSWorkspace.shared.open(Links.releases) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 24).padding(.top, 34).padding(.bottom, 26)
        .frame(width: 540)
    }

    private func color(for label: String) -> Color {
        switch label {
        case L("Signature"): info.signatureValid ? .green : .red
        case L("App Sandbox"): info.sandboxed ? .green : .red
        case L("Network access"): info.networkAccess ? .red : .green
        default: .primary
        }
    }
}

struct HelpView: View {
    @ObservedObject var store: CaptureStore
    var openAbout: () -> Void
    @State private var copied = false

    private struct Topic: Identifiable {
        let id: String, symbol: String, text: String
        var shortcut: Shortcut? = nil
    }

    private var topics: [Topic] {
        [
            Topic(id: L("Take Screenshot"), symbol: "viewfinder",
                  text: L("Drag over the area you want. Before dragging, press Space to pick a timer; Esc cancels. With Options › Adjust Capture Area, you can move and resize the area before capturing."),
                  shortcut: store.captureShortcut),
            Topic(id: L("Capture Window"), symbol: "macwindow", text: L("Click any window to capture it."), shortcut: store.windowShortcut),
            Topic(id: L("Capture Full Screen"), symbol: "display",
                  text: L("Captures the whole display the pointer is on, after the timer if one is chosen. With several displays, move the pointer to the one you want."),
                  shortcut: store.screenShortcut),
            Topic(id: L("Repeat Last Capture"), symbol: "arrow.clockwise",
                  text: L("Takes the last capture again at once, with no timer: the same area, the same window even if it has moved or been resized, or the same display. If that window has closed or that display is disconnected, a new capture of the same kind starts."),
                  shortcut: store.repeatShortcut),
            Topic(id: L("Editor"), symbol: "pencil.tip.crop.circle",
                  text: L("Click a recent capture to open it. Crop, arrow, text, redact and highlighter (⌘1 to ⌘5), with up to five undo steps. Save Copy writes a new file and never changes the original.")),
            Topic(id: L("Rulers"), symbol: "ruler",
                  text: L("The editor shows rulers in the capture’s own pixels. They follow the zoom and mark the pointer, the image size and the pointer position appear at the bottom, and dragging shows the size of the area. Press ⌘R to show or hide them.")),
            Topic(id: L("Zoom"), symbol: "plus.magnifyingglass",
                  text: L("In the editor, pinch the trackpad to look at a detail and swipe with two fingers to move around. Double-tap with two fingers or press ⌘0 to see the whole image again. Zooming never changes the image.")),
            Topic(id: L("Watermark and Number"), symbol: "seal",
                  text: L("Options › Watermark and Number… adds your logo, a running number or both to every capture and imported image. The preview shows exactly what your captures will get.")),
            Topic(id: L("Import from Clipboard"), symbol: "doc.on.clipboard",
                  text: L("Opens a copied image in the editor. Auto images imports PNG and TIFF images as you copy them."),
                  shortcut: store.settings.shortcut(for: .importClipboard)),
            Topic(id: L("Privacy"), symbol: "lock.shield",
                  text: L("Captures stay in memory for 30 minutes (10 at most) unless you save them. Kapture SCR has no network access: the macOS App Sandbox blocks it, so nothing is ever sent.")),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(topics) { topic in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: topic.symbol).font(.system(size: 18)).foregroundStyle(Color.accentColor).frame(width: 28)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(topic.id).font(.system(size: 13, weight: .semibold))
                                Spacer()
                                if let shortcut = topic.shortcut {
                                    HStack(spacing: 4) { ForEach(shortcut.symbols, id: \.self) { KeyCap(label: $0) } }
                                }
                            }
                            Text(topic.text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Divider()
                verify
            }
            .padding(22)
        }
        .frame(width: 560, height: 640)
    }

    private var verify: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.seal").font(.system(size: 18)).foregroundStyle(.green).frame(width: 28)
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Verify This Copy")).font(.system(size: 13, weight: .semibold))
                Text(L("About Kapture SCR shows the version, the code signature and the SHA-256 of the app. To check without trusting the app, run these commands in Terminal: the signature must be valid, the entitlements must include the App Sandbox and no network access, and the SHA-256 must match the one on the release page."))
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(verificationCommands(appPath: Bundle.main.bundlePath))
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
                    .environment(\.layoutDirection, .leftToRight)
                HStack {
                    Button(copied ? L("Copied") : L("Copy Commands")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(verificationCommands(appPath: Bundle.main.bundlePath), forType: .string); copied = true
                    }
                    Button(L("About Kapture SCR")) { openAbout() }
                }
            }
        }
    }
}

// MARK: - Views

extension EditTool {
    var symbol: String {
        switch self {
        case .crop: "crop"; case .arrow: "arrow.up.right"; case .text: "textformat"; case .redact: "rectangle.inset.filled"; case .highlight: "highlighter"
        }
    }
}

/// Lets the user move the window from an empty strip, since the canvas uses drags for editing.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override var mouseDownCanMoveWindow: Bool { true }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension View {
    /// Floating smoked-glass capsule used for the editor's toolbar groups.
    func toolbarCapsule() -> some View {
        padding(4)
            .glassSurface(Capsule(), tint: Smoke.panelTint)
            .overlay(Capsule().strokeBorder(Smoke.rim, lineWidth: 0.5))
    }
}

/// Tick spacing for the editor rulers, in image pixels. Numbered ticks use round steps (1, 2, 5 × 10ⁿ) at least
/// `labelSpacing` points apart; small ticks divide them when there is room. Follows the zoom.
enum RulerScale {
    static func steps(pointsPerPixel ppp: CGFloat, labelSpacing: CGFloat = 56, minorSpacing: CGFloat = 5) -> (major: Int, minor: Int) {
        guard ppp > 0, ppp.isFinite else { return (1, 1) }
        var major = 1, magnitude = 1
        search: while true {
            for m in [1, 2, 5] {
                major = m * magnitude
                if CGFloat(major) * ppp >= labelSpacing { break search }
            }
            if magnitude > 100_000_000 { break }
            magnitude *= 10
        }
        for divisor in [10, 5, 2] where major % divisor == 0 && CGFloat(major / divisor) * ppp >= minorSpacing {
            return (major, major / divisor)
        }
        return (major, major)
    }
}

/// A ruler along the top or left edge of the editor canvas, numbered in the capture's own pixels.
/// `origin` is where the image's first pixel is, and `shown` how long the whole image is on screen, both in points.
struct RulerView: View {
    enum Axis { case horizontal, vertical }
    static let thickness: CGFloat = 20
    let axis: Axis
    let pixels: Int
    let origin: CGFloat
    let shown: CGFloat
    /// The pointer, in image pixels.
    let cursor: CGFloat?

    var body: some View {
        Canvas { ctx, size in
            let horizontal = axis == .horizontal
            let length = horizontal ? size.width : size.height
            let depth = horizontal ? size.height : size.width
            guard pixels > 0, shown > 0 else { return }
            let ppp = shown / CGFloat(pixels)
            func line(_ pos: CGFloat, _ tick: CGFloat) -> Path {
                Path { p in
                    if horizontal { p.move(to: CGPoint(x: pos, y: depth)); p.addLine(to: CGPoint(x: pos, y: depth - tick)) }
                    else { p.move(to: CGPoint(x: depth, y: pos)); p.addLine(to: CGPoint(x: depth - tick, y: pos)) }
                }
            }
            // The image's extent, slightly lighter than the area around it.
            let start = max(0, origin), end = min(length, origin + shown)
            if end > start {
                let r = horizontal ? CGRect(x: start, y: 0, width: end - start, height: depth) : CGRect(x: 0, y: start, width: depth, height: end - start)
                ctx.fill(Path(r), with: .color(.white.opacity(0.06)))
            }
            let step = RulerScale.steps(pointsPerPixel: ppp)
            let first = max(0, Int(floor(-origin / ppp)))
            let last = min(pixels, Int(ceil((length - origin) / ppp)))
            var px = first / step.minor * step.minor
            while px <= last {
                let pos = (origin + CGFloat(px) * ppp).rounded() + 0.5
                let major = px % step.major == 0
                ctx.stroke(line(pos, major ? depth * 0.5 : depth * 0.22), with: .color(.white.opacity(major ? 0.55 : 0.3)), lineWidth: 1)
                if major {
                    let label = Text("\(px)").font(.system(size: 9, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.65))
                    if horizontal {
                        ctx.draw(label, at: CGPoint(x: pos + 3, y: 2), anchor: .topLeading)
                    } else {
                        var layer = ctx
                        layer.translateBy(x: 2, y: pos - 3)
                        layer.rotate(by: .degrees(-90))
                        layer.draw(label, at: .zero, anchor: .topLeading)
                    }
                }
                px += step.minor
            }
            if let cursor {
                let pos = (origin + cursor * ppp).rounded() + 0.5
                ctx.stroke(line(pos, depth), with: .color(.accentColor), lineWidth: 1)
            }
            // Edge next to the image.
            let edge = horizontal ? Path(CGRect(x: 0, y: depth - 0.5, width: length, height: 0.5)) : Path(CGRect(x: depth - 0.5, y: 0, width: 0.5, height: length))
            ctx.fill(edge, with: .color(.white.opacity(0.18)))
        }
        .background(Color.black.opacity(0.28))
        .accessibilityHidden(true)
    }
}

/// View-only zoom of the editor canvas: it magnifies what you see, never the image itself.
/// Positions are relative to the centre of the canvas area, in points.
struct ZoomState: Equatable {
    static let range: ClosedRange<CGFloat> = 1...8
    var zoom: CGFloat = 1
    var pan: CGSize = .zero
    var isZoomed: Bool { zoom > 1.001 }

    /// Zooms by `factor` keeping the spot under `point` where it is. `content` is the image as shown at 1×.
    mutating func zoom(by factor: CGFloat, at point: CGPoint, content: CGSize, container: CGSize) {
        let new = min(max(zoom * factor, Self.range.lowerBound), Self.range.upperBound)
        guard new != zoom else { return }
        let k = new / zoom
        pan = CGSize(width: point.x - (point.x - pan.width) * k, height: point.y - (point.y - pan.height) * k)
        zoom = new
        clamp(content: content, container: container)
    }

    mutating func move(by delta: CGSize, content: CGSize, container: CGSize) {
        guard isZoomed else { return }
        pan = CGSize(width: pan.width + delta.width, height: pan.height + delta.height)
        clamp(content: content, container: container)
    }

    /// Keeps the image covering the canvas: you can't drag it out of view. At 1× it is centred.
    mutating func clamp(content: CGSize, container: CGSize) {
        if !isZoomed { self = ZoomState(); return }
        let maxX = max(0, (content.width * zoom - container.width) / 2)
        let maxY = max(0, (content.height * zoom - container.height) / 2)
        pan = CGSize(width: min(max(pan.width, -maxX), maxX), height: min(max(pan.height, -maxY), maxY))
    }
}

/// Trackpad pinch, two-finger swipe and smart zoom (double tap with two fingers) over the editor canvas.
/// AppKit events, because SwiftUI on macOS 14 has no two-finger pan.
final class CanvasZoom: ObservableObject {
    @Published var state = ZoomState()
    /// The canvas area and the image size at 1×, in the window's SwiftUI coordinates.
    @Published var frame: CGRect = .zero
    @Published var content: CGSize = .zero
    weak var window: NSWindow?
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .smartMagnify, .scrollWheel]) { [weak self] event in
            guard let self, event.window === self.window, let point = self.point(of: event) else { return event }
            switch event.type {
            case .magnify:
                state.zoom(by: 1 + event.magnification, at: point, content: content, container: frame.size)
            case .smartMagnify:
                if state.isZoomed { reset() } else { state.zoom(by: 2.5, at: point, content: content, container: frame.size) }
            case .scrollWheel:
                guard state.isZoomed else { return event }
                let step: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
                state.move(by: CGSize(width: event.scrollingDeltaX * step, height: event.scrollingDeltaY * step), content: content, container: frame.size)
            default: return event
            }
            return nil
        }
    }

    func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    func reset() { state = ZoomState() }
    func fit() { state.clamp(content: content, container: frame.size) }

    /// The pointer relative to the canvas centre, or nil when it is outside the canvas.
    private func point(of event: NSEvent) -> CGPoint? {
        guard let view = event.window?.contentView else { return nil }
        var p = view.convert(event.locationInWindow, from: nil)
        if !view.isFlipped { p.y = view.bounds.height - p.y }
        guard frame.contains(p) else { return nil }
        return CGPoint(x: p.x - frame.midX, y: p.y - frame.midY)
    }
}

/// Hands the hosting window to the zoom monitor, so events from other windows are ignored.
struct WindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) { DispatchQueue.main.async { found(view.window) } }
}

struct EditorView: View {
    @ObservedObject var store: CaptureStore
    @State private var tool: EditTool

    init(store: CaptureStore, initialTool: EditTool = .redact) {
        self.store = store
        _tool = State(initialValue: initialTool)
    }
    @State private var annotation = ""
    @State private var start: CGPoint?
    @State private var end: CGPoint?
    @State private var stroke: [CGPoint] = []
    @State private var toastVisible = false
    @StateObject private var zoom = CanvasZoom()
    /// The pointer over the image, in image pixels.
    @State private var hover: CGPoint?
    @Namespace private var toolSelection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var motion: Animation? { reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.85) }

    var body: some View {
        ZStack {
            canvasBackground
            if store.current == nil {
                // Centred on the whole window, not on the area below the toolbar.
                emptyState.ignoresSafeArea()
            } else {
                canvas
                    .padding(.top, tool == .text || tool == .highlight ? 56 : 12)
                    .padding(.bottom, store.captures.isEmpty ? 24 : 112)
                    .padding(.horizontal, 24)
            }
            VStack(spacing: 10) {
                toolbar
                if tool == .text && store.current != nil { annotationField.transition(.move(edge: .top).combined(with: .opacity)) }
                if tool == .highlight && store.current != nil { highlightOptions.transition(.move(edge: .top).combined(with: .opacity)) }
                Spacer()
                if toastVisible && !store.message.isEmpty { toast.transition(.move(edge: .bottom).combined(with: .opacity)) }
                if !store.captures.isEmpty { filmstrip }
            }
            .padding(.top, 7).padding(.bottom, 14).padding(.horizontal, 14)
            .ignoresSafeArea(edges: .top) // the toolbar sits in the title bar row, level with the traffic lights
        }
        .frame(minWidth: 820, minHeight: 560)
                .animation(motion, value: tool)
        .animation(motion, value: toastVisible)
        .animation(motion, value: store.captures.map(\.id))
        .animation(motion, value: store.selected)
        .onChange(of: store.selected) { _, _ in annotation = ""; start = nil; end = nil; stroke = []; zoom.reset() }
        .background(WindowReader { zoom.window = $0 })
        .onAppear { zoom.start() }
        .onDisappear { zoom.stop() }
        .task(id: store.message) {
            toastVisible = true
            try? await Task.sleep(for: .seconds(4))
            toastVisible = false
        }
    }

    private var canvasBackground: some View {
        ZStack(alignment: .top) {
            RadialGradient(colors: [Smoke.canvasCenter, Smoke.canvasEdge], center: .center, startRadius: 40, endRadius: 900)
            WindowDragArea().frame(height: 52)
        }
        .ignoresSafeArea()
    }

    // MARK: Toolbar

    private var toolbar: some View {
        GlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                Spacer().frame(width: 64) // traffic lights
                HStack(spacing: 0) {
                    BareIconButton(symbol: "arrow.uturn.backward", label: L("Undo")) { store.undo() }
                        .keyboardShortcut("z", modifiers: .command).disabled(!store.canUndo)
                    BareIconButton(symbol: "arrow.uturn.forward", label: L("Redo")) { store.redo() }
                        .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!store.canRedo)
                }
                .toolbarCapsule()
                Spacer(minLength: 8)
                tools.toolbarCapsule()
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    PillButton(title: L("Copy"), symbol: "doc.on.doc", help: L("Copy the edited image (⇧⌘C)")) { store.copyImage() }
                        .keyboardShortcut("c", modifiers: [.command, .shift]).disabled(store.current == nil)
                    PillButton(title: L("Save Copy"), symbol: "square.and.arrow.down", help: L("Create a new PNG; the original is never changed (⌘S)")) { store.saveEditedCopy() }
                        .keyboardShortcut("s", modifiers: .command).disabled(store.current == nil)
                    BareIconButton(symbol: "doc.on.clipboard", label: L("Import image from clipboard (⌘I)")) { store.importImage() }
                        .keyboardShortcut("i", modifiers: .command)
                    // ⌘R toggles the rulers from anywhere in the editor.
                    Button(L("Show Rulers")) { store.showRulers.toggle() }
                        .keyboardShortcut("r", modifiers: .command)
                        .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
                    Menu {
                        Button(store.showRulers ? L("Hide Rulers") : L("Show Rulers"), systemImage: "ruler") { store.showRulers.toggle() }
                        Divider()
                        Button(L("Delete This Screenshot"), systemImage: "trash") { store.remove() }.disabled(store.current == nil)
                        Button(L("Clear History"), systemImage: "xmark.bin") { store.clear() }.disabled(store.captures.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 15, weight: .medium)).frame(width: 30, height: 30)
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .help(L("More actions"))
                }
                .toolbarCapsule()
            }
        }
    }

    /// Tool names when the window is wide enough; icons only otherwise (long translations never truncate).
    private var tools: some View {
        ViewThatFits(in: .horizontal) {
            toolButtons(labels: true)
            toolButtons(labels: false)
        }
    }

    private func toolButtons(labels: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(EditTool.allCases.enumerated()), id: \.element) { index, t in
                Button { tool = t } label: {
                    Group {
                        if labels { Label(t.title, systemImage: t.symbol).lineLimit(1).fixedSize() }
                        else { Image(systemName: t.symbol).frame(width: 18) }
                    }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(tool == t ? Color.white : Color.primary)
                        .padding(.horizontal, 12).frame(height: 30)
                        .background {
                            if tool == t { Capsule().fill(Color.accentColor).matchedGeometryEffect(id: labels ? "tool" : "toolIcon", in: toolSelection) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                .help(t.title + " (⌘\(index + 1))")
                .accessibilityAddTraits(tool == t ? .isSelected : [])
            }
        }
    }

    private var annotationField: some View {
        HStack(spacing: 8) {
            Image(systemName: "textformat").foregroundStyle(.secondary)
            TextField(L("Type the text, then click the image"), text: $annotation)
                .textFieldStyle(.plain).font(.system(size: 13))
                .frame(width: 300)
        }
        .padding(.horizontal, 14).frame(height: 34)
        .glassSurface(Capsule(), tint: Smoke.panelTint)
        .overlay(Capsule().strokeBorder(Smoke.rim, lineWidth: 0.5))
    }

    /// Colour swatches, a custom colour and three stroke widths for the highlighter.
    private var highlightOptions: some View {
        HStack(spacing: 10) {
            ForEach(Array(RGB.highlighterPresets.enumerated()), id: \.offset) { _, preset in
                let on = store.highlightColor == preset.0
                Button { store.highlightColor = preset.0 } label: {
                    Circle().fill(preset.0.color).frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(on ? 0.9 : 0.2), lineWidth: on ? 2 : 0.5).padding(on ? -3 : 0))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).help(preset.1).accessibilityLabel(preset.1).accessibilityAddTraits(on ? .isSelected : [])
            }
            ColorPicker(L("Custom color"), selection: Binding(get: { store.highlightColor.color }, set: { store.highlightColor = RGB($0) }), supportsOpacity: false)
                .labelsHidden().help(L("Custom color"))
            Divider().frame(height: 18)
            ForEach(HighlightSize.allCases, id: \.self) { size in
                let on = store.highlightSize == size
                Button { store.highlightSize = size } label: {
                    Capsule().fill(Color.primary.opacity(on ? 0.9 : 0.35))
                        .frame(width: 22, height: size.factor * 1.3)
                        .frame(width: 30, height: 24)
                        .background(Capsule().fill(on ? Color.primary.opacity(0.12) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(size.title).accessibilityLabel(size.title).accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.horizontal, 14).frame(height: 34)
        .glassSurface(Capsule(), tint: Smoke.panelTint)
        .overlay(Capsule().strokeBorder(Smoke.rim, lineWidth: 0.5))
        .help(L("Drag over the image to highlight"))
    }

    // MARK: Canvas

    @ViewBuilder private var canvas: some View {
        if let capture = store.current {
            if store.showRulers {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Color.black.opacity(0.28).frame(width: RulerView.thickness, height: RulerView.thickness)
                        ruler(.horizontal, capture).frame(height: RulerView.thickness)
                    }
                    HStack(spacing: 0) {
                        ruler(.vertical, capture).frame(width: RulerView.thickness)
                        imageArea(capture)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .bottomLeading) { measureBadge(capture) }
                // Positions are physical places in the image, which is never mirrored.
                .environment(\.layoutDirection, .leftToRight)
            } else {
                imageArea(capture)
            }
        }
    }

    private func ruler(_ axis: RulerView.Axis, _ capture: Capture) -> some View {
        let horizontal = axis == .horizontal
        let area = horizontal ? zoom.frame.width : zoom.frame.height
        let shown = (horizontal ? zoom.content.width : zoom.content.height) * zoom.state.zoom
        let pan = horizontal ? zoom.state.pan.width : zoom.state.pan.height
        return RulerView(axis: axis, pixels: horizontal ? capture.image.width : capture.image.height,
                         origin: area / 2 + pan - shown / 2, shown: shown,
                         cursor: hover.map { horizontal ? $0.x : $0.y })
    }

    /// Size of the area being dragged (or the arrow's length), in image pixels, next to the pointer.
    /// Counter-scaled so it stays readable at any zoom.
    private func selectionSize(_ a: CGPoint, _ b: CGPoint, in size: CGSize, image: CGImage) -> some View {
        let sx = CGFloat(image.width) / size.width, sy = CGFloat(image.height) / size.height
        let w = abs(b.x - a.x) * sx, h = abs(b.y - a.y) * sy
        let text = tool == .arrow ? "\(Int(hypot(w, h).rounded())) px" : "\(Int(w.rounded())) × \(Int(h.rounded())) px"
        let k = 1 / zoom.state.zoom
        return Text(text)
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(.black.opacity(0.72)))
            .fixedSize()
            .scaleEffect(k)
            .position(x: min(max(b.x + 44 * k, 44 * k), size.width - 44 * k), y: min(max(b.y + 18 * k, 12 * k), size.height - 12 * k))
            .allowsHitTesting(false)
    }

    /// The image size, and the pointer's position in pixels while it is over the image.
    private func measureBadge(_ capture: Capture) -> some View {
        HStack(spacing: 8) {
            Text("\(capture.image.width) × \(capture.image.height) px")
            if let hover {
                Text("x \(Int(hover.x)) · y \(Int(hover.y))").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .padding(.horizontal, 10).frame(height: 24)
        .glassSurface(Capsule(), tint: Smoke.panelTint)
        .overlay(Capsule().strokeBorder(Smoke.rim, lineWidth: 0.5))
        .padding(.leading, RulerView.thickness + 10).padding(.bottom, 10)
        .allowsHitTesting(false)
    }

    private func imageArea(_ capture: Capture) -> some View {
            GeometryReader { geo in
                let ratio = min(geo.size.width / CGFloat(capture.image.width), geo.size.height / CGFloat(capture.image.height), 1)
                let size = CGSize(width: CGFloat(capture.image.width) * ratio, height: CGFloat(capture.image.height) * ratio)
                ZStack(alignment: .topLeading) {
                    Image(decorative: capture.image, scale: 1).resizable().frame(width: size.width, height: size.height)
                    if !stroke.isEmpty {
                        // Live preview at the final width, scaled to the canvas.
                        Path(smoothPath(stroke))
                            .stroke(store.highlightColor.color.opacity(0.55),
                                    style: StrokeStyle(lineWidth: store.highlightSize.width(for: CGSize(width: capture.image.width, height: capture.image.height)) * ratio,
                                                       lineCap: .round, lineJoin: .round))
                            .blendMode(.multiply)
                    }
                    if let a = start, let b = end {
                        Path { p in
                            if tool == .arrow { p.move(to: a); p.addLine(to: b) }
                            else { p.addRect(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))) }
                        }
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        if store.showRulers { selectionSize(a, b, in: size, image: capture.image) }
                    }
                }
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    if case .active(let p) = phase, size.width > 0, size.height > 0 {
                        hover = CGPoint(x: min(max(p.x / size.width, 0), 1) * CGFloat(capture.image.width - 1),
                                        y: min(max(p.y / size.height, 0), 1) * CGFloat(capture.image.height - 1))
                    } else { hover = nil }
                }
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        guard tool == .highlight else { start = v.startLocation; end = v.location; return }
                        if stroke.isEmpty { stroke = [v.startLocation] }
                        // Skip points closer than 2 pt: smoother curves and less work.
                        if let last = stroke.last, hypot(v.location.x - last.x, v.location.y - last.y) >= 2 { stroke.append(v.location) }
                    }
                    .onEnded { v in
                        if tool == .highlight {
                            if store.selected == capture.id {
                                store.highlight(points: stroke.map { CGPoint(x: $0.x / size.width, y: $0.y / size.height) },
                                                color: store.highlightColor, size: store.highlightSize)
                            }
                            stroke = []; return
                        }
                        guard store.selected == capture.id else { start = nil; end = nil; return }
                        store.edit(tool: tool,
                                   start: CGPoint(x: v.startLocation.x / size.width, y: v.startLocation.y / size.height),
                                   end: CGPoint(x: v.location.x / size.width, y: v.location.y / size.height),
                                   text: annotation)
                        start = nil; end = nil; annotation = ""
                    })
                // The drag above reports points in the image's own coordinates, so tools stay exact while zoomed.
                .scaleEffect(zoom.state.zoom)
                .offset(zoom.state.pan)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Clip to the canvas only while zoomed, so the shadow shows at normal size.
                .mask(Rectangle().padding(zoom.state.isZoomed ? 0 : -80))
                .overlay(alignment: .bottomTrailing) { if zoom.state.isZoomed { zoomBadge } }
                .onAppear { zoom.frame = geo.frame(in: .global); zoom.content = size }
                .onChange(of: geo.frame(in: .global)) { _, frame in zoom.frame = frame; zoom.fit() }
                .onChange(of: size) { _, new in zoom.content = new; zoom.fit() }
                .onChange(of: CGSize(width: capture.image.width, height: capture.image.height)) { _, _ in zoom.reset() } // crop
            }
    }

    /// Current zoom; click or ⌘0 to go back to the whole image.
    private var zoomBadge: some View {
        Button { zoom.reset() } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                Text(Double(zoom.state.zoom).formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12).frame(height: 28)
            .glassSurface(Capsule(), tint: Smoke.panelTint)
            .overlay(Capsule().strokeBorder(Smoke.rim, lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("0", modifiers: .command)
        .help(L("Reset Zoom") + " (⌘0)")
        .accessibilityLabel(L("Reset Zoom"))
        .padding(10)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            BrandLogo(height: 84)
                .padding(.bottom, 8)
            Text(L("No screenshots")).font(.system(size: 17, weight: .semibold))
            ShortcutHints(capture: store.captureShortcut, window: store.windowShortcut, screen: store.screenShortcut, again: store.repeatShortcut)
                .font(.system(size: 13))
            PillButton(title: L("Import from Clipboard"), symbol: "doc.on.clipboard") { store.importImage() }
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Bottom

    private var toast: some View {
        Text(store.message)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .glassSurface(Capsule(), tint: Smoke.panelTint)
            .overlay(Capsule().strokeBorder(Smoke.rim, lineWidth: 0.5))
            .accessibilityAddTraits(.updatesFrequently)
    }

    private var filmstrip: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.captures) { capture in
                        let isSelected = store.selected == capture.id
                        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
                        Button { store.select(capture.id) } label: {
                            Image(decorative: capture.image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                                .frame(width: 92, height: 58)
                                .clipShape(shape)
                                .overlay(shape.strokeBorder(isSelected ? Color.accentColor : .white.opacity(0.12), lineWidth: isSelected ? 2 : 0.5))
                                .opacity(isSelected ? 1 : 0.75)
                                .contentShape(shape)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L("Screenshot"))
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
                .padding(4)
            }
            .frame(maxWidth: CGFloat(store.captures.count) * 100 + 8)
            Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(.secondary).padding(.trailing, 6)
                .help(L("Temporary history kept in memory: up to 10 images for 30 minutes. Save Copy creates a new PNG and never overwrites."))
        }
        .padding(6)
        .glassSurface(RoundedRectangle(cornerRadius: 20, style: .continuous), tint: Smoke.panelTint)
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Smoke.rim, lineWidth: 0.5))
    }
}

/// Smoked-glass palette shared by the menu bar panel.
enum Smoke {
    /// Colour that follows the system appearance (light or dark), including inside glass.
    private static func adaptive(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light })
    }
    static let panelTint = adaptive(dark: .black.withAlphaComponent(0.32), light: .white.withAlphaComponent(0.28))
    static let pill = adaptive(dark: .black.withAlphaComponent(0.26), light: .black.withAlphaComponent(0.06))
    static let pillHover = adaptive(dark: .black.withAlphaComponent(0.38), light: .black.withAlphaComponent(0.11))
    static let edge = adaptive(dark: .white.withAlphaComponent(0.08), light: .black.withAlphaComponent(0.06))
    static let rim = adaptive(dark: .white.withAlphaComponent(0.14), light: .white.withAlphaComponent(0.65))
    static let canvasCenter = adaptive(dark: NSColor(white: 0.17, alpha: 1), light: NSColor(white: 0.97, alpha: 1))
    static let canvasEdge = adaptive(dark: NSColor(white: 0.08, alpha: 1), light: NSColor(white: 0.86, alpha: 1))
}

/// Dark capsule control: label plus a circled symbol, dimmed when disabled.
struct PillButton: View {
    let title: String
    let symbol: String
    var help: String? = nil
    let action: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1).fixedSize()
                Image(systemName: symbol).font(.system(size: 16, weight: .regular))
            }
            .padding(.leading, 12).padding(.trailing, 7)
            .frame(height: 30)
            .background(Capsule().fill(hover && isEnabled ? Smoke.pillHover : Smoke.pill))
            .overlay(Capsule().strokeBorder(Smoke.edge, lineWidth: 0.5))
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help ?? title)
    }
}

/// Bare symbol button (no capsule), like a panel's secondary action.
struct BareIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                .frame(width: 30, height: 30)
                .background(Circle().fill(hover && isEnabled ? Smoke.pill : .clear))
                .contentShape(Circle())
                .opacity(isEnabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Recent captures panel that hangs under the menu bar icon: smoked Liquid Glass on macOS 26+.
/// Horizontal logo with the app name (transparent background), used in empty states.
struct BrandLogo: View {
    let height: CGFloat
    private static let image = Bundle.main.image(forResource: "KaptureLogo")

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(height: height)
                .accessibilityLabel("Kapture SCR")
        } else {
            Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high)
                .frame(width: height, height: height)
                .accessibilityHidden(true)
        }
    }
}

struct RecentPanelView: View {
    @ObservedObject var store: CaptureStore
    let open: () -> Void
    let dismiss: () -> Void
    @State private var hovered: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Panel corner radius and content inset; inner elements use the concentric radius.
    private static let radius: CGFloat = 24
    private static let inset: CGFloat = 14
    private var cardShape: RoundedRectangle { RoundedRectangle(cornerRadius: Self.radius - Self.inset, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if store.captures.isEmpty { empty } else { strip }
            footer
        }
        .padding(Self.inset)
        .frame(width: 600)
        .glassSurface(RoundedRectangle(cornerRadius: Self.radius, style: .continuous), tint: Smoke.panelTint)
        .overlay(RoundedRectangle(cornerRadius: Self.radius, style: .continuous).strokeBorder(Smoke.rim, lineWidth: 0.5))
                .padding(12) // room for the glass shadow
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85), value: hovered)
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: store.captures.map(\.id))
    }

    private var header: some View {
        HStack(spacing: 8) {
            // The logo carries the app name; the number of captures is visible in the strip itself.
            // Same distance from the top and left edges (panel inset + 6), so its corner follows the panel's corner.
            BrandLogo(height: 40).padding(.leading, 6).padding(.top, 6)
            Spacer()
            PillButton(title: L("Import"), symbol: "plus.circle", help: L("Import Image from Clipboard")) { store.importImage() }
            PillButton(title: L("Folder"), symbol: "folder.circle", help: L("Open the screenshots folder")) { dismiss(); store.openFolder() }
            PillButton(title: L("Editor"), symbol: "pencil.circle", help: L("Open the editor"), action: open)
            BareIconButton(symbol: "xmark", label: L("Close"), action: dismiss)
        }
    }

    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(store.captures) { card($0) }
            }
            .padding(.vertical, 6).padding(.horizontal, 2)
        }
        .frame(height: 132)
    }

    private func card(_ capture: Capture) -> some View {
        let isHovered = hovered == capture.id
        return Button { store.select(capture.id); open() } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(decorative: capture.image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 148, height: 94)
                    .clipShape(cardShape)
                    .overlay(cardShape.strokeBorder(.white.opacity(isHovered ? 0.5 : 0.12), lineWidth: 1))
                    .shadow(color: .black.opacity(isHovered ? 0.4 : 0.2), radius: isHovered ? 9 : 3, y: isHovered ? 4 : 1)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(Self.age(of: capture.created, now: context.date))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.leading, 3)
                }
            }
            .scaleEffect(isHovered ? 1.03 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = capture.id } else if hovered == capture.id { hovered = nil }
        }
        .onDrag { NSItemProvider(object: NSImage(cgImage: capture.image, size: NSSize(width: CGFloat(capture.image.width), height: CGFloat(capture.image.height)))) }
        .help(L("Click to edit · drag into another app"))
        .accessibilityLabel(L("Screenshot, \(Self.age(of: capture.created, now: .now))"))
    }

    private static func age(of date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        return minutes < 1 ? L("Just now") : L("\(minutes) min ago")
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Text(L("No screenshots yet")).font(.system(size: 13, weight: .semibold))
            ShortcutHints(capture: store.captureShortcut, window: store.windowShortcut, screen: store.screenShortcut, again: store.repeatShortcut)
                .font(.system(size: 12))
        }
        .frame(maxWidth: .infinity).frame(height: 132)
        .background(cardShape.fill(Smoke.pill.opacity(0.6)))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { store.autoImport }, set: { store.setAutomatic($0) })) {
                Text(L("Auto Images")).font(.system(size: 13, weight: .medium))
            }
            .toggleStyle(.switch).controlSize(.mini)
            .padding(.leading, 12).padding(.trailing, 8).frame(height: 30)
            .background(Capsule().fill(Smoke.pill))
            .overlay(Capsule().strokeBorder(Smoke.edge, lineWidth: 0.5))
            .help(L("Imports images you copy. Turns off when you quit."))
            Label(L("Memory only · 30 min"), systemImage: "lock.fill")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.leading, 4)
            Spacer()
            PillButton(title: L("Clear"), symbol: "trash.circle", help: L("Remove all screenshots from memory")) { store.clear() }
                .disabled(store.captures.isEmpty)
        }
    }
}

struct ThumbnailView: View {
    let image: CGImage
    let size: CGSize
    let open: () -> Void
    let hover: (Bool) -> Void
    var body: some View {
        Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.7), lineWidth: 1))
            .shadow(radius: 6)
            .padding(10)
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            .onHover(perform: hover)
            .help(L("Open in Kapture SCR to edit"))
    }
}

// MARK: - Floating thumbnail (top-right, 5 s)

final class ThumbnailController {
    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?
    private let duration: TimeInterval = 5
    var onOpen: ((UUID) -> Void)?

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.isFloatingPanel = true; panel.level = .statusBar
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    func show(_ capture: Capture) {
        let maxSize = CGSize(width: 220, height: 150)
        let ratio = min(maxSize.width / CGFloat(capture.image.width), maxSize.height / CGFloat(capture.image.height), 1)
        let size = CGSize(width: max(40, CGFloat(capture.image.width) * ratio), height: max(30, CGFloat(capture.image.height) * ratio))
        let id = capture.id
        panel.contentViewController = NSHostingController(rootView: ThumbnailView(
            image: capture.image, size: size,
            open: { [weak self] in self?.hide(); self?.onOpen?(id) },
            hover: { [weak self] inside in inside ? self?.hideWork?.cancel() : self?.scheduleHide() }))
        let frameSize = NSSize(width: size.width + 20, height: size.height + 20)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        panel.setFrame(NSRect(x: visible.maxX - frameSize.width - 6, y: visible.maxY - frameSize.height - 6, width: frameSize.width, height: frameSize.height), display: true)
        panel.orderFrontRegardless()
        scheduleHide()
    }

    func hide() { hideWork?.cancel(); panel.orderOut(nil) }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}

// MARK: - App

/// Reports when the pointer enters or leaves a view, without polling.
final class HoverTracker: NSResponder {
    var onChange: (Bool) -> Void = { _ in }
    func attach(to view: NSView) {
        view.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { onChange(true) }
    override func mouseExited(with event: NSEvent) { onChange(false) }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let settings = Settings()
    lazy var store = CaptureStore(settings: settings)
    let capturer = ScreenCapturer()
    let thumbnail = ThumbnailController()
    var status: NSStatusItem!
    var window: NSWindow!
    var recentPanel: NSPanel!
    let iconHover = HoverTracker()
    let recentPanelHover = HoverTracker()
    var overIcon = false
    var overRecentPanel = false
    var recentPanelFade: DispatchWorkItem?
    var actionHotKeys: [ShortcutAction: EventHotKeyRef] = [:]
    let recorder = ShortcutRecorder()
    var watermarkWindow: NSWindow?
    var helpWindow: NSWindow?
    var aboutWindow: NSWindow?
    var watermarkModel: WatermarkModel?
    var eventHandler: EventHandlerRef?
    var hoverSuppressed = false

    func setupHotKeys() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, data in
            guard let data, let event else { return OSStatus(eventNotHandledErr) }
            var hk = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard status == noErr else { return status }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(data).takeUnretainedValue()
            DispatchQueue.main.async {
                switch hk.id {
                case ShortcutAction.capture.hotKeyID: delegate.capture()
                case ShortcutAction.captureWindow.hotKeyID: delegate.captureWindow()
                case ShortcutAction.captureScreen.hotKeyID: delegate.captureScreen()
                case ShortcutAction.repeatCapture.hotKeyID: delegate.repeatCapture()
                case ShortcutAction.importClipboard.hotKeyID: delegate.importCapture()
                default: break
                }
            }
            return noErr
        }, 1, &type, context, &eventHandler)
        guard result == noErr else { store.message = L("Global shortcuts unavailable; use the menu."); return }
        var failed: [String] = []
        for action in ShortcutAction.allCases {
            let shortcut = settings.shortcut(for: action)
            if let ref = register(shortcut, id: action.hotKeyID) { actionHotKeys[action] = ref } else { failed.append(shortcut.display) }
        }
        if !failed.isEmpty { let names = failed.joined(separator: ", "); store.message = L("Shortcut unavailable (\(names)); use the menu.") }
    }

    func register(_ shortcut: Shortcut, id: UInt32) -> EventHotKeyRef? {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: 0x4B415054, id: id), GetApplicationEventTarget(), 0, &ref)
        return status == noErr ? ref : nil
    }

    @objc func changeShortcut() { recordShortcut(for: .capture) }
    @objc func changeWindowShortcut() { recordShortcut(for: .captureWindow) }
    @objc func changeScreenShortcut() { recordShortcut(for: .captureScreen) }
    @objc func changeImportShortcut() { recordShortcut(for: .importClipboard) }
    @objc func changeRepeatShortcut() { recordShortcut(for: .repeatCapture) }

    /// Opens the recorder; the action's current shortcut is released meanwhile so it can be pressed again.
    func recordShortcut(for action: ShortcutAction) {
        recorder.end()
        recentPanel.orderOut(nil); overRecentPanel = false
        if let ref = actionHotKeys.removeValue(forKey: action) { UnregisterEventHotKey(ref) }
        recorder.apply = { [weak self] shortcut in self?.applyShortcut(shortcut, for: action) }
        recorder.onEnd = { [weak self] in
            guard let self, self.actionHotKeys[action] == nil else { return }
            self.actionHotKeys[action] = self.register(self.settings.shortcut(for: action), id: action.hotKeyID)
        }
        recorder.begin(current: settings.shortcut(for: action), title: action.recorderTitle, defaultShortcut: action.defaultShortcut)
    }

    func applyShortcut(_ shortcut: Shortcut, for action: ShortcutAction) -> String? {
        if shortcut.isReserved { return L("macOS uses this shortcut.") }
        guard shortcut.isAllowed else { return L("Use at least two modifier keys, including ⌘ or ⌃.") }
        if ShortcutAction.allCases.contains(where: { $0 != action && settings.shortcut(for: $0).sameKeys(as: shortcut) }) {
            return L("Kapture SCR already uses this shortcut for another action.")
        }
        guard let ref = register(shortcut, id: action.hotKeyID) else { return L("This shortcut is not available.") }
        actionHotKeys[action] = ref
        settings.setShortcut(shortcut, for: action)
        let keys = shortcut.display
        switch action {
        case .capture: store.captureShortcut = shortcut; store.message = L("Capture shortcut: \(keys)")
        case .captureWindow: store.windowShortcut = shortcut; store.message = L("Window shortcut: \(keys)")
        case .captureScreen: store.screenShortcut = shortcut; store.message = L("Full screen shortcut: \(keys)")
        case .importClipboard: store.message = L("Import shortcut: \(keys)")
        case .repeatCapture: store.repeatShortcut = shortcut; store.message = L("Repeat shortcut: \(keys)")
        }
        return nil
    }

    // MARK: Capture flow

    /// Drag over an area.
    @objc func capture() { startCapture(mode: .selection) }
    /// Captures a whole window with the system picker.
    @objc func captureWindow() { startCapture(mode: .window) }
    /// Captures the whole display under the pointer.
    @objc func captureScreen() { startCapture(mode: .screen) }

    /// Screen Recording permission and, when saving to a folder, a chosen folder. False when the capture can't start.
    private func readyToCapture() -> Bool {
        guard !capturer.isCapturing else { return false }
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            store.message = L("Allow Screen Recording for Kapture SCR in System Settings › Privacy & Security, then reopen the app.")
            show(); return false
        }
        if settings.destination.usesFolder && settings.folder == nil {
            guard let folder = FolderAccess.chooseFolder() else { store.message = L("Capture cancelled: no folder was chosen."); return false }
            settings.folder = folder
        }
        thumbnail.hide(); recentPanel.orderOut(nil)
        return true
    }

    /// Takes the last area, window or display again. With nothing to repeat it starts an area capture; when that window
    /// has closed, or that area or display is gone, it starts a new capture of the same kind.
    @objc func repeatCapture() {
        guard readyToCapture() else { return }
        let result = capturer.repeatLast(settings) { [weak self] url in
            guard let self, let url else { return }
            self.finishCapture(url)
        }
        switch result {
        case .started: break
        case .nothingToRepeat: startCapture(mode: .selection)
        case .targetGone(.window):
            store.message = L("The window from the last capture is no longer open."); startCapture(mode: .window)
        case .targetGone(.screen):
            store.message = L("The display from the last capture is no longer connected."); startCapture(mode: .screen)
        case .targetGone(.region):
            store.message = L("The area from the last capture is no longer on any display."); startCapture(mode: .selection)
        }
    }

    func startCapture(mode: CaptureMode) {
        guard readyToCapture() else { return }
        capturer.capture(settings, mode: mode) { [weak self] url in
            guard let self, let url else { return } // Esc or failure: nothing to do
            self.finishCapture(url)
        }
    }

    private func finishCapture(_ tmp: URL) {
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let data = try? Data(contentsOf: tmp) else { store.message = L("Couldn’t read the screenshot."); return }
        let base = FolderAccess.baseName()
        let capture = store.addOwnCapture(data, baseName: base)
        // With a watermark, the file and the clipboard get the watermarked pixels instead of the raw screenshot.
        let marked = store.stampActive ? capture : nil
        var notes: [String] = []

        if settings.destination.usesFolder {
            if let folder = settings.folder {
                let fileData = marked.flatMap { FolderAccess.encode($0.image, as: settings.format) } ?? data
                do { let name = try FolderAccess.write(fileData, base: base, ext: settings.format.rawValue, in: folder).lastPathComponent; notes.append(L("Saved as \(name)")) }
                catch { notes.append(L("Couldn’t save to the folder: \(error.localizedDescription)")) }
            } else { notes.append(L("No destination folder.")) }
        }
        if settings.destination.usesClipboard {
            // Clipboard always gets lossless PNG; the file keeps the chosen format.
            let png = marked == nil && settings.format == .png ? data : capture.flatMap { FolderAccess.pngData($0.image) }
            notes.append(png.map { store.writeToPasteboard($0) } == true ? L("Copied to clipboard.") : L("Couldn’t copy to the clipboard."))
        }
        if capture == nil {
            notes.append(L("Too large for the editor."))
            if store.stampActive { notes.append(L("Watermark not applied.")) }
        }
        store.message = notes.joined(separator: " ")
        if let capture { thumbnail.show(capture) }
    }

    func openInEditor(_ id: UUID) { store.select(id); show() }

    // MARK: Recent captures panel

    func showRecentPanel() {
        guard let button = status.button, let barWindow = button.window, let screen = barWindow.screen ?? NSScreen.main else { return }
        defer { if !overIcon && !overRecentPanel { scheduleRecentPanelFade() } }
        guard !recentPanel.isVisible else { return }
        recentPanel.contentView?.layoutSubtreeIfNeeded()
        // Hang the panel under the menu bar icon, kept inside the screen.
        let icon = barWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let size = recentPanel.frame.size, visible = screen.visibleFrame
        let x = min(max(icon.midX - size.width / 2, visible.minX + 4), visible.maxX - size.width - 4)
        let target = NSPoint(x: x, y: visible.maxY - size.height)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        recentPanel.setFrameOrigin(reduceMotion ? target : NSPoint(x: target.x, y: target.y + 8))
        recentPanel.alphaValue = 0
        recentPanel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            recentPanel.animator().alphaValue = 1
            recentPanel.animator().setFrameOrigin(target)
        }
    }
    func fadeOutRecentPanel() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            recentPanel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.recentPanel.alphaValue == 0 else { return }
            self.recentPanel.orderOut(nil); self.recentPanel.alphaValue = 1; self.overRecentPanel = false
        })
    }
    func hideRecentPanel() { recentPanel.orderOut(nil); overRecentPanel = false; hoverSuppressed = true }
    /// Driven by tracking areas on the menu bar icon and the panel, so nothing runs while the pointer is elsewhere.
    func hoverChanged() {
        if overIcon || overRecentPanel { recentPanelFade?.cancel(); recentPanelFade = nil }
        if !overIcon { hoverSuppressed = false }
        if overIcon && !hoverSuppressed && !window.isVisible && !recentPanel.isVisible && status.button?.isHighlighted != true { showRecentPanel() }
        if !overIcon && !overRecentPanel && recentPanel.isVisible { scheduleRecentPanelFade() }
    }
    /// Hides the panel 1.5 s after the pointer leaves both the icon and the panel.
    func scheduleRecentPanelFade() {
        recentPanelFade?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.overIcon, !self.overRecentPanel, self.recentPanel.isVisible, self.recentPanel.alphaValue == 1 else { return }
            self.fadeOutRecentPanel()
        }
        recentPanelFade = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func item(_ title: String, _ action: Selector, key: String = "", tag: Int = 0, on: Bool = false) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.target = self; i.tag = tag; i.state = on ? .on : .off
            return i
        }
        let shortcut = settings.captureShortcut
        let cap = item(L("Take Screenshot"), #selector(capture), key: shortcut.chars); cap.keyEquivalentModifierMask = shortcut.menuFlags
        menu.addItem(cap)
        let windowShortcut = settings.shortcut(for: .captureWindow)
        let win = item(L("Capture Window"), #selector(captureWindow), key: windowShortcut.chars); win.keyEquivalentModifierMask = windowShortcut.menuFlags
        menu.addItem(win)
        let screenShortcut = settings.shortcut(for: .captureScreen)
        let full = item(L("Capture Full Screen"), #selector(captureScreen), key: screenShortcut.chars); full.keyEquivalentModifierMask = screenShortcut.menuFlags
        menu.addItem(full)
        let repeatShortcut = settings.shortcut(for: .repeatCapture)
        let again = item(L("Repeat Last Capture"), #selector(repeatCapture), key: repeatShortcut.chars); again.keyEquivalentModifierMask = repeatShortcut.menuFlags
        menu.addItem(again)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: L("Save To")))
        for (n, d) in Destination.allCases.enumerated() { menu.addItem(item(d.title, #selector(setDestination(_:)), tag: n, on: settings.destination == d)) }
        let folderTitle = settings.folder.map { L("Folder: \($0.lastPathComponent)…") } ?? L("Choose Folder…")
        menu.addItem(item(folderTitle, #selector(chooseFolder)))

        let options = NSMenu()
        options.addItem(NSMenuItem.sectionHeader(title: L("Timer")))
        for d in captureDelays { options.addItem(item(d == 0 ? L("None") : L("\(d) seconds"), #selector(setDelay(_:)), tag: d, on: settings.delay == d)) }
        options.addItem(NSMenuItem.sectionHeader(title: L("Format")))
        for (n, f) in ImageFormat.allCases.enumerated() { options.addItem(item(f.title, #selector(setFormat(_:)), tag: n, on: settings.format == f)) }
        options.addItem(.separator())
        options.addItem(item(L("Show Pointer"), #selector(toggleCursor), on: settings.showCursor))
        options.addItem(item(L("Window Shadow"), #selector(toggleShadow), on: settings.windowShadow))
        options.addItem(item(L("Adjust Capture Area"), #selector(toggleAdjust), on: settings.adjustSelection))
        options.addItem(.separator())
        options.addItem(item(L("Change Capture Shortcut…"), #selector(changeShortcut)))
        options.addItem(item(L("Change Window Shortcut…"), #selector(changeWindowShortcut)))
        options.addItem(item(L("Change Full Screen Shortcut…"), #selector(changeScreenShortcut)))
        options.addItem(item(L("Change Repeat Shortcut…"), #selector(changeRepeatShortcut)))
        options.addItem(item(L("Change Import Shortcut…"), #selector(changeImportShortcut)))
        options.addItem(.separator())
        options.addItem(item(L("Add Watermark"), #selector(toggleWatermark), on: store.watermarkActive))
        options.addItem(item(L("Add Number"), #selector(toggleNumber), on: settings.numberEnabled))
        options.addItem(item(L("Watermark and Number…"), #selector(showWatermarkSettings)))
        options.addItem(.separator())
        let languages = NSMenu()
        let chosen = settings.language
        languages.addItem(item(L("Same as System"), #selector(setLanguage(_:)), tag: -1, on: chosen == nil))
        languages.addItem(.separator())
        for (n, language) in appLanguages.enumerated() {
            languages.addItem(item(language.name, #selector(setLanguage(_:)), tag: n, on: chosen == language.code))
        }
        let languageItem = NSMenuItem(title: L("Language"), action: nil, keyEquivalent: "")
        languageItem.submenu = languages
        options.addItem(languageItem)
        options.addItem(item(L("Open at Login"), #selector(toggleOpenAtLogin), on: SMAppService.mainApp.status == .enabled))
        let optionsItem = NSMenuItem(title: L("Options"), action: nil, keyEquivalent: "")
        optionsItem.submenu = options
        menu.addItem(optionsItem)
        let help = NSMenu()
        help.addItem(item(L("Kapture SCR Help"), #selector(showHelp)))
        help.addItem(item(L("About Kapture SCR"), #selector(showAbout)))
        help.addItem(item(L("Check for Updates…"), #selector(checkForUpdates)))
        let helpItem = NSMenuItem(title: L("Help"), action: nil, keyEquivalent: "")
        helpItem.submenu = help
        menu.addItem(helpItem)

        menu.addItem(.separator())
        menu.addItem(item(L("Open Kapture SCR"), #selector(show)))
        menu.addItem(item(L("Show Recent"), #selector(openRecentPanel)))
        let importShortcut = settings.shortcut(for: .importClipboard)
        let imp = item(L("Import Image from Clipboard"), #selector(importCapture), key: importShortcut.chars); imp.keyEquivalentModifierMask = importShortcut.menuFlags
        menu.addItem(imp)
        menu.addItem(item(L("Clear History"), #selector(clear)))
        menu.addItem(.separator())
        menu.addItem(item(L("Quit"), #selector(quit)))
    }

    @objc func setDestination(_ sender: NSMenuItem) {
        settings.destination = Destination.allCases[sender.tag]
        if settings.destination.usesFolder && settings.folder == nil { chooseFolder() }
    }
    @objc func chooseFolder() { if let url = FolderAccess.chooseFolder() { settings.folder = url } }
    @objc func setDelay(_ sender: NSMenuItem) { settings.delay = sender.tag }
    @objc func setFormat(_ sender: NSMenuItem) { settings.format = ImageFormat.allCases[sender.tag] }
    @objc func toggleCursor() { settings.showCursor.toggle() }
    @objc func toggleShadow() { settings.windowShadow.toggle() }
    @objc func toggleAdjust() { settings.adjustSelection.toggle() }
    /// Without a watermark image there is nothing to turn on, so the settings open instead.
    @objc func toggleWatermark() {
        guard store.watermarkImage != nil else { showWatermarkSettings(); return }
        settings.watermarkEnabled.toggle()
        watermarkModel?.enabled = settings.watermarkEnabled
    }
    /// Saves the language and restarts so every window, panel and system dialog uses it (and the right layout direction).
    /// The history lives only in memory, so the user is asked first when it holds anything.
    @objc func setLanguage(_ sender: NSMenuItem) {
        let code = sender.tag >= 0 ? appLanguages[sender.tag].code : nil
        guard code != settings.language else { return }
        settings.language = code
        let system = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String] ?? ["en"]
        guard (code ?? appLanguage(for: system)) != Bundle.main.preferredLocalizations.first else { return } // already shown
        if store.captures.isEmpty { relaunch(); return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("Restart Kapture SCR to change the language?")
        alert.informativeText = L("Screenshots and imported images in the recent history are kept only in memory and will be lost. Saved files are not affected.")
        alert.addButton(withTitle: L("Restart Now"))
        alert.addButton(withTitle: L("Later"))
        if alert.runModal() == .alertFirstButtonReturn { relaunch() }
        else { store.message = L("The new language will be used the next time Kapture SCR opens.") }
    }

    /// Opens a new instance of this app, then quits; the new one waits for this one before taking the global shortcuts.
    func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { [weak self] _, error in
            DispatchQueue.main.async {
                if error == nil { NSApp.terminate(nil) }
                else { self?.store.message = L("Couldn’t restart Kapture SCR. Quit and open it again to change the language."); self?.show() }
            }
        }
    }

    /// After a restart the previous instance may still be quitting and holding the global shortcuts: wait for it (up to 5 s).
    func setupHotKeysAfterPreviousInstance() {
        let previous = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        let deadline = Date().addingTimeInterval(5)
        func attempt() {
            if previous.allSatisfy(\.isTerminated) || Date() > deadline { setupHotKeys(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: attempt)
        }
        attempt()
    }

    /// Registers the app as a login item with the system (no helper, no extra entitlement).
    @objc func toggleOpenAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            store.message = L("Couldn’t change Open at Login: \(error.localizedDescription)"); show(); return
        }
        if service.status == .requiresApproval {
            store.message = L("Allow Kapture SCR in System Settings › General › Login Items & Extensions.")
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    @objc func toggleNumber() {
        settings.numberEnabled.toggle()
        watermarkModel?.refresh()
    }

    private func present(_ window: inout NSWindow?, title: String, _ content: () -> some View) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = title; w.isReleasedWhenClosed = false
            let host = NSHostingController(rootView: content())
            host.sizingOptions = [.preferredContentSize]
            w.contentViewController = host
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc func showHelp() {
        present(&helpWindow, title: L("Kapture SCR Help")) { HelpView(store: store) { [weak self] in self?.showAbout() } }
    }

    @objc func showAbout() {
        // Read fresh each time, so the window reflects the copy on disk right now.
        aboutWindow?.close(); aboutWindow = nil
        present(&aboutWindow, title: L("About Kapture SCR")) { AboutView(info: BuildInfo.current()) { [weak self] in self?.showHelp() } }
    }

    /// Shows this version and offers the release page. Kapture SCR has no network access, so the browser opens it.
    @objc func checkForUpdates() {
        let info = BuildInfo.current()
        let alert = NSAlert()
        alert.messageText = L("Check for Updates")
        alert.informativeText = L("You have version \(info.version) (build \(info.build)). New versions are published on GitHub. Kapture SCR can’t connect to the internet, so the release page opens in your browser.")
        alert.addButton(withTitle: L("Open Release Page"))
        alert.addButton(withTitle: L("Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(Links.releases) }
    }

    @objc func showWatermarkSettings() {
        if watermarkWindow == nil {
            let model = WatermarkModel(store: store)
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = L("Watermark and Number"); w.isReleasedWhenClosed = false
            let host = NSHostingController(rootView: WatermarkView(model: model))
            host.sizingOptions = [.preferredContentSize]
            w.contentViewController = host
            w.center()
            watermarkWindow = w; watermarkModel = model
        }
        watermarkModel?.refresh()
        NSApp.activate(ignoringOtherApps: true)
        watermarkWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        status = NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        // Monochrome symbol as a template: macOS draws it white or black to match the menu bar and its highlight.
        let menuIcon = Bundle.main.image(forResource: "MenuBarIcon") ?? NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)
        menuIcon?.isTemplate = true
        menuIcon?.size = NSSize(width: 18, height: 18)
        menuIcon?.accessibilityDescription = "Kapture SCR"
        status.button?.image = menuIcon
        let menu = NSMenu()
        menu.delegate = self
        status.menu = menu
        if let button = status.button {
            iconHover.attach(to: button)
            iconHover.onChange = { [weak self] inside in self?.overIcon = inside; self?.hoverChanged() }
        }
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:1000,height:680),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        window.title="Kapture SCR"; window.isReleasedWhenClosed=false
        // Content runs under a transparent title bar; the empty unified toolbar centres the traffic lights on the glass toolbar.
        window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        window.toolbar = NSToolbar(identifier: "editor"); window.toolbarStyle = .unified
        window.minSize = NSSize(width: 820, height: 560)
        window.contentViewController=NSHostingController(rootView:EditorView(store:store)); window.center()
        recentPanel = NSPanel(contentRect:NSRect(x:0,y:0,width:624,height:240), styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        recentPanel.isReleasedWhenClosed=false; recentPanel.isFloatingPanel=true; recentPanel.level = .floating
        // The glass draws its own edge and shadow; the window itself stays invisible.
        recentPanel.backgroundColor = .clear; recentPanel.isOpaque=false; recentPanel.hasShadow=false
        recentPanel.collectionBehavior = [.moveToActiveSpace,.fullScreenAuxiliary]
        let recentPanelHost = NSHostingController(rootView:RecentPanelView(store:store,open:{ [weak self] in self?.show() },dismiss:{ [weak self] in self?.hideRecentPanel() }))
        recentPanelHost.sizingOptions = [.preferredContentSize]
        recentPanel.contentViewController = recentPanelHost
        recentPanelHover.attach(to: recentPanelHost.view)
        recentPanelHover.onChange = { [weak self] inside in self?.overRecentPanel = inside; self?.hoverChanged() }
        // Do not change the selected capture while the user edits it.
        store.canPoll = { [weak self] in self?.window.isVisible == false }
        thumbnail.onOpen = { [weak self] id in self?.openInEditor(id) }
        setupHotKeysAfterPreviousInstance()
        show()
    }
    @objc func show() { recentPanel?.orderOut(nil); overRecentPanel = false; thumbnail.hide(); NSApp.activate(ignoringOtherApps:true); window.makeKeyAndOrderFront(nil) }
    @objc func openRecentPanel() { showRecentPanel() }
    @objc func importCapture() { store.importImage(); show() }
    @objc func clear() { store.clear() }
    @objc func quit() { store.clear(); NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        recentPanelFade?.cancel()
        recorder.end()
        actionHotKeys.values.forEach { UnregisterEventHotKey($0) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        store.clear()
    }
}
let app = NSApplication.shared
// macOS takes the layout direction from the system language. Follow the app's own language instead, so Arabic or
// Urdu chosen for Kapture SCR alone is right-to-left, and another language on an Arabic or Urdu Mac is left-to-right.
UserDefaults.standard.set(["ar", "ur"].contains(Bundle.main.preferredLocalizations.first ?? ""), forKey: "AppleTextDirection")
let delegate = AppDelegate()
app.delegate = delegate
app.run()
