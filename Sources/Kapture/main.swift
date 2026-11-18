import AppKit
import Carbon
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

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
    case crop, arrow, text, redact
    var title: String { switch self { case .crop: L("Crop"); case .arrow: L("Arrow"); case .text: L("Text"); case .redact: L("Redact") } }
}

// MARK: - Preferences

enum CaptureMode: String, CaseIterable {
    case selection, window, screen
    var title: String { switch self { case .selection: L("Selection"); case .window: L("Window"); case .screen: L("Full Screen") } }
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
    var mode: CaptureMode {
        get { CaptureMode(rawValue: d.string(forKey: "mode") ?? "") ?? .selection }
        set { d.set(newValue.rawValue, forKey: "mode") }
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
    case capture, captureWindow, importClipboard
    var defaultsKey: String {
        switch self { case .capture: "captureShortcut"; case .captureWindow: "windowShortcut"; case .importClipboard: "importShortcut" }
    }
    var defaultShortcut: Shortcut {
        switch self { case .capture: .defaultCapture; case .captureWindow: .defaultWindow; case .importClipboard: .importFromClipboard }
    }
    var hotKeyID: UInt32 { switch self { case .capture: 2; case .captureWindow: 3; case .importClipboard: 1 } }
    var recorderTitle: String {
        switch self { case .capture: L("Capture Shortcut"); case .captureWindow: L("Window Shortcut"); case .importClipboard: L("Import Shortcut") }
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

/// The two capture shortcuts as keycaps with what each one does, for empty states.
struct ShortcutHints: View {
    let capture: Shortcut
    let window: Shortcut
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            row(capture, L("Take Screenshot"))
            row(window, L("Capture Window"))
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

final class ScreenCapturer {
    private(set) var isCapturing = false
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
            countdownThenRun(settings, mode: mode, region: nil, around: NSScreen.screens.first?.frame ?? .zero, cancel: cancel, completion: completion)
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

    /// Gives focus back so window order on screen is what the user saw before.
    private func restoreFocus() { previousApp?.activate(); previousApp = nil }

    private func run(_ settings: Settings, mode: CaptureMode, region: NSRect?, delay: Int, completion: @escaping (URL?) -> Void) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kapture-\(UUID().uuidString).\(settings.format.rawValue)")
        var args = ["-t", settings.format.rawValue]
        if let region, let main = NSScreen.screens.first?.frame {
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
        if settings.showCursor { args.append("-C") }
        if !settings.windowShadow { args.append("-o") }
        args.append(url.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = args
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.isCapturing = false
                completion(FileManager.default.fileExists(atPath: url.path) ? url : nil)
            }
        }
        do { isCapturing = true; try process.run() } catch { isCapturing = false; completion(nil) }
    }
}

// MARK: - Store

final class CaptureStore: ObservableObject {
    @Published var captures: [Capture] = [] { didSet { scheduleExpiry() } }
    @Published var selected: UUID?
    @Published var message: String
    @Published var captureShortcut: Shortcut
    @Published var windowShortcut: Shortcut
    @Published var autoImport = false
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
        captureShortcut = settings.captureShortcut
        windowShortcut = settings.shortcut(for: .captureWindow)
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
    /// The image with the watermark when it is on; otherwise unchanged.
    func watermarked(_ image: CGImage) -> CGImage {
        guard settings.watermarkEnabled, let mark = watermarkImage else { return image }
        return Watermark.apply(mark, to: image, options: settings.watermark) ?? image
    }

    @discardableResult
    private func insert(_ image: CGImage, baseName: String) -> Capture {
        let capture = Capture(image: watermarked(image), baseName: baseName)
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
            case .crop: break
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

final class WatermarkModel: ObservableObject {
    let store: CaptureStore
    @Published var enabled: Bool { didSet { store.settings.watermarkEnabled = enabled } }
    @Published var options: WatermarkOptions { didSet { store.settings.watermark = options; render() } }
    @Published private(set) var preview: CGImage?
    @Published var error: String?
    private let sample = Watermark.sampleScreenshot()

    init(store: CaptureStore) {
        self.store = store
        enabled = store.settings.watermarkEnabled
        options = store.settings.watermark
        render()
    }

    var mark: CGImage? { store.watermarkImage }

    func render() {
        guard let sample else { preview = nil; return }
        preview = mark.flatMap { Watermark.apply($0, to: sample, options: options) } ?? sample
    }

    /// Places a single mark centred under a point of the preview (fractions of its width and height).
    func move(to p: CGPoint) {
        guard let sample, let mark else { return }
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
    /// Corners and edges keep a small margin; bottom right matches the default position.
    private let presets: [(x: Double, y: Double, label: String)] = [
        (0.03, 0.05, L("Top Left")), (0.5, 0.05, L("Top")), (0.97, 0.05, L("Top Right")),
        (0.03, 0.5, L("Left")), (0.5, 0.5, L("Center")), (0.97, 0.5, L("Right")),
        (0.03, 0.95, L("Bottom Left")), (0.5, 0.95, L("Bottom")), (0.97, 0.95, L("Bottom Right")),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            imageRow
            HStack {
                Text(L("Add the watermark to every capture and imported image"))
                Spacer()
                Toggle(L("Add the watermark to every capture and imported image"), isOn: $model.enabled)
                    .toggleStyle(.switch).labelsHidden()
            }
            .disabled(model.mark == nil)
            preview
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Position")).font(.system(size: 13, weight: .semibold))
                    // Positions are physical places in the image, which is never mirrored, so the grid is not mirrored either.
                    presetGrid.environment(\.layoutDirection, .leftToRight)
                }
                // A grid sizes the label column to the longest label in the current language.
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    slider(L("Horizontal"), value: $model.options.x, in: 0...1, physical: true)
                    slider(L("Vertical"), value: $model.options.y, in: 0...1)
                    slider(L("Size"), value: $model.options.size, in: Watermark.sizeRange)
                    slider(L("Opacity"), value: $model.options.opacity, in: Watermark.opacityRange)
                }
            }
            .disabled(model.mark == nil)
            Toggle(L("Repeat as a pattern"), isOn: $model.options.tiled).disabled(model.mark == nil)
        }
        .padding(20)
        .frame(width: 600)
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

    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                ZStack {
                    if let image = model.preview { Image(decorative: image, scale: 1).resizable() }
                    if model.mark == nil {
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
            Text(L("Drag the watermark in the preview, or choose a position.")).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private var presetGrid: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(0..<3, id: \.self) { row in
                GridRow {
                    ForEach(0..<3, id: \.self) { col in
                        let p = presets[row * 3 + col]
                        let on = abs(model.options.x - p.x) < 0.005 && abs(model.options.y - p.y) < 0.005
                        Button { model.options.x = p.x; model.options.y = p.y } label: {
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

// MARK: - Views

extension EditTool {
    var symbol: String {
        switch self { case .crop: "crop"; case .arrow: "arrow.up.right"; case .text: "textformat"; case .redact: "rectangle.inset.filled" }
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

struct EditorView: View {
    @ObservedObject var store: CaptureStore
    @State private var tool: EditTool = .redact
    @State private var annotation = ""
    @State private var start: CGPoint?
    @State private var end: CGPoint?
    @State private var toastVisible = false
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
                    .padding(.top, tool == .text ? 56 : 12)
                    .padding(.bottom, store.captures.isEmpty ? 24 : 112)
                    .padding(.horizontal, 24)
            }
            VStack(spacing: 10) {
                toolbar
                if tool == .text && store.current != nil { annotationField.transition(.move(edge: .top).combined(with: .opacity)) }
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
        .onChange(of: store.selected) { _, _ in annotation = ""; start = nil; end = nil }
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
                    Menu {
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

    // MARK: Canvas

    @ViewBuilder private var canvas: some View {
        if let capture = store.current {
            GeometryReader { geo in
                let ratio = min(geo.size.width / CGFloat(capture.image.width), geo.size.height / CGFloat(capture.image.height), 1)
                let size = CGSize(width: CGFloat(capture.image.width) * ratio, height: CGFloat(capture.image.height) * ratio)
                ZStack(alignment: .topLeading) {
                    Image(decorative: capture.image, scale: 1).resizable().frame(width: size.width, height: size.height)
                    if let a = start, let b = end {
                        Path { p in
                            if tool == .arrow { p.move(to: a); p.addLine(to: b) }
                            else { p.addRect(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))) }
                        }
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    }
                }
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in start = v.startLocation; end = v.location }
                    .onEnded { v in
                        guard store.selected == capture.id else { start = nil; end = nil; return }
                        store.edit(tool: tool,
                                   start: CGPoint(x: v.startLocation.x / size.width, y: v.startLocation.y / size.height),
                                   end: CGPoint(x: v.location.x / size.width, y: v.location.y / size.height),
                                   text: annotation)
                        start = nil; end = nil; annotation = ""
                    })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            BrandLogo(height: 84)
                .padding(.bottom, 8)
            Text(L("No screenshots")).font(.system(size: 17, weight: .semibold))
            ShortcutHints(capture: store.captureShortcut, window: store.windowShortcut)
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
            HStack(spacing: 4) {
                Text(L("Recent:")).font(.system(size: 13, weight: .bold))
                Text("\(store.captures.count)").font(.system(size: 13, weight: .medium)).monospacedDigit()
            }
            .padding(.horizontal, 12).frame(height: 30)
            .background(Capsule().fill(Smoke.pill))
            .overlay(Capsule().strokeBorder(Smoke.edge, lineWidth: 0.5))
            .accessibilityElement(children: .combine)
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
        VStack(spacing: 8) {
            BrandLogo(height: 34)
                .padding(.bottom, 2)
            Text(L("No screenshots yet")).font(.system(size: 13, weight: .semibold))
            ShortcutHints(capture: store.captureShortcut, window: store.windowShortcut)
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
    @objc func changeImportShortcut() { recordShortcut(for: .importClipboard) }

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
        case .importClipboard: store.message = L("Import shortcut: \(keys)")
        }
        return nil
    }

    // MARK: Capture flow

    @objc func capture() { startCapture(mode: nil) }
    /// Captures a whole window with the system picker, whatever mode is selected in the menu.
    @objc func captureWindow() { startCapture(mode: .window) }

    func startCapture(mode: CaptureMode?) {
        guard !capturer.isCapturing else { return }
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            store.message = L("Allow Screen Recording for Kapture SCR in System Settings › Privacy & Security, then reopen the app.")
            show(); return
        }
        if settings.destination.usesFolder && settings.folder == nil {
            guard let folder = FolderAccess.chooseFolder() else { store.message = L("Capture cancelled: no folder was chosen."); return }
            settings.folder = folder
        }
        thumbnail.hide(); recentPanel.orderOut(nil)
        capturer.capture(settings, mode: mode ?? settings.mode) { [weak self] url in
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
        let marked = store.watermarkActive ? capture : nil
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
            if store.watermarkActive { notes.append(L("Watermark not applied.")) }
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
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: L("Mode")))
        for (n, m) in CaptureMode.allCases.enumerated() { menu.addItem(item(m.title, #selector(setMode(_:)), tag: n, on: settings.mode == m)) }
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
        options.addItem(item(L("Change Import Shortcut…"), #selector(changeImportShortcut)))
        options.addItem(.separator())
        options.addItem(item(L("Add Watermark"), #selector(toggleWatermark), on: store.watermarkActive))
        options.addItem(item(L("Watermark Settings…"), #selector(showWatermarkSettings)))
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
        let optionsItem = NSMenuItem(title: L("Options"), action: nil, keyEquivalent: "")
        optionsItem.submenu = options
        menu.addItem(optionsItem)

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

    @objc func setMode(_ sender: NSMenuItem) { settings.mode = CaptureMode.allCases[sender.tag] }
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

    @objc func showWatermarkSettings() {
        if watermarkWindow == nil {
            let model = WatermarkModel(store: store)
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = L("Watermark"); w.isReleasedWhenClosed = false
            let host = NSHostingController(rootView: WatermarkView(model: model))
            host.sizingOptions = [.preferredContentSize]
            w.contentViewController = host
            w.center()
            watermarkWindow = w; watermarkModel = model
        }
        watermarkModel?.enabled = settings.watermarkEnabled
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
