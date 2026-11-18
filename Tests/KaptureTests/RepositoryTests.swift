import XCTest

/// Supply-chain hygiene of the repository: what CI runs, and how security reports reach the project.
final class RepositoryTests: XCTestCase {
    private var workflows: [URL] {
        get throws {
            let dir = repoRoot.appendingPathComponent(".github/workflows")
            return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { ["yml", "yaml"].contains($0.pathExtension) }
        }
    }

    func testEveryActionIsPinnedToACommit() throws {
        // A tag such as @v5 can be moved to different code; a full commit SHA cannot. Dependabot keeps the SHAs current.
        let uses = try NSRegularExpression(pattern: #"^\s*-?\s*uses:\s*([^\s#]+)"#, options: .anchorsMatchLines)
        var checked = 0
        for file in try workflows {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in uses.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let ref = (text as NSString).substring(with: match.range(at: 1))
                if ref.hasPrefix("./") { continue } // local action in this repository
                XCTAssertNotNil(ref.range(of: #"^[\w.-]+/[\w./-]+@[0-9a-f]{40}$"#, options: .regularExpression),
                                "\(file.lastPathComponent): \(ref) is not pinned to a full commit SHA")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 0, "no actions found, so the check above proves nothing")
    }

    func testWorkflowsStartWithReadOnlyPermissions() throws {
        for file in try workflows {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertTrue(text.contains("\npermissions:\n  contents: read"), "\(file.lastPathComponent): default token must be read-only")
            XCTAssertFalse(text.contains("pull_request_target"), "\(file.lastPathComponent): pull_request_target runs untrusted code with secrets")
        }
    }

    func testDependabotWatchesTheActions() throws {
        let text = try String(contentsOf: repoRoot.appendingPathComponent(".github/dependabot.yml"), encoding: .utf8)
        XCTAssertTrue(text.contains("package-ecosystem: github-actions"))
    }

    func testSecurityPolicyExplainsPrivateReporting() throws {
        let text = try String(contentsOf: repoRoot.appendingPathComponent("SECURITY.md"), encoding: .utf8)
        XCTAssertTrue(text.contains("Report a vulnerability"))
        XCTAssertFalse(text.contains("@"), "no e-mail addresses: reports go through GitHub's private reporting")
    }

    func testNoThirdPartyPackages() throws {
        // The no-network guarantee covers all the code in the app; a package dependency would need the same review.
        let manifest = try String(contentsOf: repoRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        XCTAssertFalse(manifest.contains(".package("), "Package.swift adds a dependency")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("Package.resolved").path))
    }
}
