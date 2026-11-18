import XCTest
@testable import Kapture

/// The 15 languages promised in the README: every table exists, parses, is complete and keeps placeholders intact.
final class LocalizationTests: XCTestCase {
    private let expected = ["en", "de", "es", "fr", "hu", "nb", "pt-BR", "sv", "ru", "zh-Hans", "zh-Hant", "hi", "bn", "ar", "ur"]

    private func table(_ lang: String) throws -> [String: String] {
        let url = repoRoot.appendingPathComponent("Resources/\(lang).lproj/Localizable.strings")
        let dict = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], "\(lang): missing or invalid .strings file")
        return dict
    }

    func testEveryLanguageHasATable() throws {
        let found = try FileManager.default.contentsOfDirectory(atPath: repoRoot.appendingPathComponent("Resources").path)
            .filter { $0.hasSuffix(".lproj") }.map { String($0.dropLast(6)) }
        XCTAssertEqual(Set(found), Set(expected))
    }

    func testLanguageMenuListsEveryLanguageOnce() {
        XCTAssertEqual(appLanguages.map(\.code), expected, "Options › Language follows the same list and order")
        XCTAssertEqual(Set(appLanguages.map(\.name)).count, appLanguages.count)
    }

    func testMacOSPicksTheExpectedLanguage() {
        let cases: [([String], String)] = [
            (["es-MX"], "es"), (["pt-PT"], "pt-BR"), (["zh-Hant-TW"], "zh-Hant"), (["zh-HK"], "zh-Hant"), (["zh-Hans-CN"], "zh-Hans"),
            (["de-AT"], "de"), (["nb-NO"], "nb"), (["no-NO"], "nb"), (["nn-NO"], "nb"), (["sv-FI"], "sv"), (["hu-HU"], "hu"),
            (["ja-JP", "sv-SE"], "sv"), (["ja-JP"], "en"), (["fr-CA"], "fr"), (["ar-EG"], "ar"),
        ]
        for (preferences, language) in cases { XCTAssertEqual(appLanguage(for: preferences), language, "\(preferences)") }
    }

    func testInfoPlistDeclaresTheSameLanguages() throws {
        let plist = try XCTUnwrap(NSDictionary(contentsOf: repoRoot.appendingPathComponent("Info.plist")))
        XCTAssertEqual(Set(plist["CFBundleLocalizations"] as? [String] ?? []), Set(expected))
        XCTAssertEqual(plist["CFBundleDevelopmentRegion"] as? String, "en")
    }

    func testAllTablesHaveTheSameKeysAsEnglish() throws {
        let english = Set(try table("en").keys)
        XCTAssertFalse(english.isEmpty)
        for lang in expected where lang != "en" {
            let keys = Set(try table(lang).keys)
            XCTAssertEqual(english.subtracting(keys).sorted(), [], "\(lang): missing translations")
            XCTAssertEqual(keys.subtracting(english).sorted(), [], "\(lang): extra keys")
        }
    }

    func testTranslationsKeepFormatPlaceholders() throws {
        func placeholders(_ s: String) -> [String] {
            let regex = try! NSRegularExpression(pattern: #"%(\d+\$)?(@|lld|d)"#)
            return regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { m in
                (s as NSString).substring(with: m.range(at: 2)) // the type; positional order may change between languages
            }.sorted()
        }
        for lang in expected {
            for (key, value) in try table(lang) {
                XCTAssertEqual(placeholders(value), placeholders(key), "\(lang): \(key) → \(value)")
                XCTAssertFalse(value.trimmingCharacters(in: .whitespaces).isEmpty, "\(lang): empty translation for \(key)")
            }
        }
    }

    func testStringsCheckerPasses() throws {
        // Every L("…") key used in the code exists in every table.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "scripts/check-strings.py"]
        process.currentDirectoryURL = repoRoot
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        try process.run(); process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, output)
    }
}
