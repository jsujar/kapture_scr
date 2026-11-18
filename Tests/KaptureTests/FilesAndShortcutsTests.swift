import XCTest
import Carbon
@testable import Kapture

/// Saving files without overwriting, file names, and global shortcut rules.
final class FileTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("KaptureTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    func testNeverOverwritesExistingFiles() throws {
        let a = try FolderAccess.write(Data("first".utf8), base: "Shot", ext: "png", in: folder)
        let b = try FolderAccess.write(Data("second".utf8), base: "Shot", ext: "png", in: folder)
        let c = try FolderAccess.write(Data("third".utf8), base: "Shot", ext: "png", in: folder)
        XCTAssertEqual([a, b, c].map(\.lastPathComponent), ["Shot.png", "Shot (2).png", "Shot (3).png"])
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "first", "the original file is untouched")
        XCTAssertEqual(try String(contentsOf: c, encoding: .utf8), "third")
    }

    func testDifferentExtensionsDoNotCollide() throws {
        let png = try FolderAccess.write(Data([1]), base: "Shot", ext: "png", in: folder)
        let jpg = try FolderAccess.write(Data([2]), base: "Shot", ext: "jpg", in: folder)
        XCTAssertEqual([png, jpg].map(\.lastPathComponent), ["Shot.png", "Shot.jpg"])
    }

    func testBaseNameFormat() {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 11; parts.day = 7; parts.hour = 9; parts.minute = 5; parts.second = 3
        let date = Calendar.current.date(from: parts)!
        XCTAssertEqual(FolderAccess.baseName(for: date), "Kapture SCR 2026-11-07 09.05.03")
    }

    func testBaseNameHasNoCharactersFinderOrShellsDislike() {
        let name = FolderAccess.baseName()
        XCTAssertNil(name.range(of: "[/:]", options: .regularExpression))
        XCTAssertNotNil(name.range(of: #"^Kapture SCR \d{4}-\d{2}-\d{2} \d{2}\.\d{2}\.\d{2}$"#, options: .regularExpression))
    }
}

final class ShortcutTests: XCTestCase {
    private func shortcut(_ key: Int, _ modifiers: Int, _ chars: String = "x") -> Shortcut {
        Shortcut(keyCode: UInt32(key), modifiers: UInt32(modifiers), chars: chars)
    }

    func testDefaultsAreAllowedAndNotReserved() {
        for action in ShortcutAction.allCases {
            XCTAssertTrue(action.defaultShortcut.isAllowed, "\(action)")
            XCTAssertFalse(action.defaultShortcut.isReserved, "\(action)")
        }
    }

    func testDefaultsAreDistinct() {
        let all = ShortcutAction.allCases.map(\.defaultShortcut)
        for (i, a) in all.enumerated() { for b in all[(i + 1)...] { XCTAssertFalse(a.sameKeys(as: b)) } }
        XCTAssertEqual(Set(ShortcutAction.allCases.map(\.hotKeyID)).count, ShortcutAction.allCases.count)
    }

    func testNeedsTwoModifiersIncludingCommandOrControl() {
        XCTAssertTrue(shortcut(kVK_ANSI_6, cmdKey | shiftKey).isAllowed)
        XCTAssertTrue(shortcut(kVK_ANSI_6, controlKey | optionKey).isAllowed)
        XCTAssertFalse(shortcut(kVK_ANSI_6, cmdKey).isAllowed, "one modifier would steal app shortcuts")
        XCTAssertFalse(shortcut(kVK_ANSI_6, shiftKey).isAllowed, "would swallow typing")
        XCTAssertFalse(shortcut(kVK_ANSI_6, optionKey | shiftKey).isAllowed, "⌥⇧ types special characters")
        XCTAssertFalse(shortcut(kVK_ANSI_6, 0).isAllowed)
    }

    func testFunctionKeysWorkAlone() {
        XCTAssertTrue(shortcut(kVK_F5, 0).isAllowed)
        XCTAssertEqual(shortcut(kVK_F5, 0).keyLabel, "F5")
    }

    func testMacOSScreenshotShortcutsAreReserved() {
        XCTAssertTrue(shortcut(kVK_ANSI_3, cmdKey | shiftKey).isReserved)
        XCTAssertTrue(shortcut(kVK_ANSI_4, cmdKey | shiftKey).isReserved)
        XCTAssertTrue(shortcut(kVK_ANSI_5, cmdKey | shiftKey).isReserved)
        XCTAssertTrue(shortcut(kVK_ANSI_Q, cmdKey | controlKey).isReserved, "lock screen")
        XCTAssertFalse(shortcut(kVK_ANSI_6, cmdKey | shiftKey).isReserved)
    }

    func testDisplayUsesApplesModifierOrder() {
        XCTAssertEqual(Shortcut.defaultCapture.display, "⇧⌘6")
        XCTAssertEqual(shortcut(kVK_ANSI_K, cmdKey | shiftKey | optionKey | controlKey, "k").display, "⌃⌥⇧⌘K")
        XCTAssertEqual(shortcut(kVK_Return, cmdKey | controlKey).display, "⌃⌘↩")
    }

    func testModifierConversionRoundTrips() {
        let flags: NSEvent.ModifierFlags = [.command, .option]
        let s = Shortcut(keyCode: 0, modifiers: Shortcut.carbon(flags), chars: "a")
        XCTAssertEqual(s.menuFlags, flags)
    }

    func testCodableRoundTrip() throws {
        let original = shortcut(kVK_ANSI_K, cmdKey | controlKey, "k")
        let back = try JSONDecoder().decode(Shortcut.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(back, original)
    }
}

final class LanguageSettingTests: XCTestCase {
    func testLanguageChoiceIsStoredAsAppleLanguagesInTheAppsOwnDomain() {
        let suite = "KaptureTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = Settings(defaults: defaults, domain: suite)
        XCTAssertNil(settings.language, "follows the system by default")
        settings.language = "zh-Hant"
        XCTAssertEqual(defaults.persistentDomain(forName: suite)?["AppleLanguages"] as? [String], ["zh-Hant"])
        XCTAssertEqual(settings.language, "zh-Hant")
        settings.language = nil
        XCTAssertNil(defaults.persistentDomain(forName: suite)?["AppleLanguages"])
        XCTAssertNil(settings.language)
    }

    func testPerAppLanguageFromSystemSettingsIsRecognised() {
        // System Settings › Language & Region › Applications writes a regional code such as "pt-PT".
        let suite = "KaptureTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["pt-PT"], forKey: "AppleLanguages")
        XCTAssertEqual(Settings(defaults: defaults, domain: suite).language, "pt-BR")
    }
}
