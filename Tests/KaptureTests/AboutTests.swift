import XCTest
import CryptoKit
@testable import Kapture

/// About Kapture SCR: the facts it shows about this copy, and the commands to check it independently.
final class AboutTests: XCTestCase {
    private let info: [String: Any] = ["CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "4",
                                       "KaptureCommit": "abc123def456", "KaptureBuildDate": "2026-11-18T20:00:00Z"]

    func testVersionCommitAndChecksum() {
        let data = Data("Kapture".utf8)
        let b = BuildInfo.make(info: info, signing: nil, signatureStatus: errSecCSUnsigned, executable: data)
        XCTAssertEqual(b.version, "1.0.0")
        XCTAssertEqual(b.build, "4")
        XCTAssertEqual(b.commit, "abc123def456")
        XCTAssertEqual(b.buildDate, "2026-11-18T20:00:00Z")
        XCTAssertEqual(b.sha256, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(b.sha256?.count, 64)
        XCTAssertFalse(b.signatureValid)
        XCTAssertNil(b.signer)
    }

    func testEntitlementsFromTheSignature() {
        let sandboxOnly: [String: Any] = [kSecCodeInfoEntitlementsDict as String: ["com.apple.security.app-sandbox": true],
                                          kSecCodeInfoIdentifier as String: "io.github.jsujar.kapture"]
        let safe = BuildInfo.make(info: info, signing: sandboxOnly, signatureStatus: errSecSuccess, executable: nil)
        XCTAssertTrue(safe.sandboxed)
        XCTAssertFalse(safe.networkAccess)
        XCTAssertTrue(safe.signatureValid)
        XCTAssertEqual(safe.identifier, "io.github.jsujar.kapture")

        let withNetwork: [String: Any] = [kSecCodeInfoEntitlementsDict as String: ["com.apple.security.app-sandbox": true,
                                                                                    "com.apple.security.network.client": true]]
        XCTAssertTrue(BuildInfo.make(info: info, signing: withNetwork, signatureStatus: errSecSuccess, executable: nil).networkAccess,
                      "a copy with network access must say so")
        XCTAssertFalse(BuildInfo.make(info: info, signing: [:], signatureStatus: errSecSuccess, executable: nil).sandboxed)
    }

    func testReportListsEveryFact() {
        let b = BuildInfo.make(info: info, signing: nil, signatureStatus: errSecSuccess, executable: Data([1, 2, 3]))
        XCTAssertEqual(b.rows.count, 8, "no Team row without a developer certificate")
        let team = BuildInfo.make(info: info, signing: [kSecCodeInfoTeamIdentifier as String: "ABCDE12345"], signatureStatus: errSecSuccess, executable: nil)
        XCTAssertTrue(team.report.contains("ABCDE12345"))
        XCTAssertTrue(b.report.hasPrefix("Kapture SCR\n"))
        for fact in ["1.0.0 (4)", "abc123def456", b.sha256!] { XCTAssertTrue(b.report.contains(fact), fact) }
    }

    func testModifiedCopyIsReported() {
        let b = BuildInfo.make(info: info, signing: nil, signatureStatus: errSecCSSignatureFailed, executable: nil)
        XCTAssertFalse(b.signatureValid)
        XCTAssertTrue(b.signatureText.contains("\(errSecCSSignatureFailed)"))
    }

    func testVerificationCommandsQuoteThePath() {
        let commands = verificationCommands(appPath: "/Applications/Kapture SCR.app").split(separator: "\n").map(String.init)
        XCTAssertEqual(commands, [
            #"codesign --verify --deep --strict --verbose=2 "/Applications/Kapture SCR.app""#,
            #"codesign -d --entitlements - "/Applications/Kapture SCR.app""#,
            #"shasum -a 256 "/Applications/Kapture SCR.app/Contents/MacOS/Kapture""#,
            #"spctl --assess --type execute --verbose=2 "/Applications/Kapture SCR.app""#,
        ])
    }
}
