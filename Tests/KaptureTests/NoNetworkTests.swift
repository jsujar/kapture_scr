import XCTest

/// Kapture SCR must never reach the network or report anything. This is enforced in three layers:
/// 1. Entitlements: the app runs in the App Sandbox without the network entitlements, so macOS itself
///    blocks every outgoing and incoming connection, including those of the screencapture child process.
/// 2. Source: no networking, web, telemetry or URL-opening APIs, and no helper processes besides screencapture.
/// 3. Binary: the compiled executable links no networking framework and imports no socket or URL-loading symbol.
/// These tests fail if any layer is weakened.
final class NoNetworkTests: XCTestCase {
    private var source: String { get throws { try String(contentsOf: repoRoot.appendingPathComponent("Sources/Kapture/main.swift"), encoding: .utf8) } }

    /// True if the code calls a free C function such as `socket(`; methods like `.system(` (SwiftUI fonts) don't count.
    private func callsCFunction(_ name: String, in code: String) -> Bool {
        code.range(of: #"(?<![.\w])"# + name + #"\s*\("#, options: .regularExpression) != nil
    }

    // MARK: 1. Entitlements

    func testEntitlementsAreExactlyTheExpectedSet() throws {
        let url = repoRoot.appendingPathComponent("Kapture.entitlements")
        let entitlements = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: Any])
        XCTAssertEqual(entitlements["com.apple.security.app-sandbox"] as? Bool, true, "the App Sandbox must stay on")
        XCTAssertEqual(Set(entitlements.keys), [
            "com.apple.security.app-sandbox",
            "com.apple.security.files.user-selected.read-write",
            "com.apple.security.files.bookmarks.app-scope",
        ], "any new entitlement needs a deliberate review")
    }

    func testNoNetworkEntitlement() throws {
        let text = try String(contentsOf: repoRoot.appendingPathComponent("Kapture.entitlements"), encoding: .utf8)
        for key in ["com.apple.security.network.client", "com.apple.security.network.server", "temporary-exception", "inherit"] {
            XCTAssertFalse(text.contains(key), "found \(key)")
        }
    }

    func testInfoPlistHasNoNetworkConfiguration() throws {
        let plist = try XCTUnwrap(NSDictionary(contentsOf: repoRoot.appendingPathComponent("Info.plist")) as? [String: Any])
        // App Transport Security exceptions, update feeds (Sparkle) or Bonjour services would all imply network use.
        for key in ["NSAppTransportSecurity", "SUFeedURL", "SUPublicEDKey", "NSBonjourServices", "NSLocalNetworkUsageDescription"] {
            XCTAssertNil(plist[key], "Info.plist declares \(key)")
        }
    }

    // MARK: 2. Source

    func testSourceUsesNoNetworkingOrTelemetryAPIs() throws {
        let code = try source
        let forbidden = [
            "URLSession", "NSURLConnection", "NSURLRequest", "URLRequest", "NSURLDownload",
            "import Network", "NWConnection", "NWListener", "NWBrowser", "NWPathMonitor", "NWEndpoint",
            "CFSocket", "CFStreamCreatePairWithSocketToHost", "CFHost", "CFNetwork", "SCNetworkReachability",
            "getaddrinfo", "gethostbyname",
            "import WebKit", "WKWebView", "WebView", "SFSafariViewController", "ASWebAuthenticationSession",
            "NSXPCConnection(machServiceName", "MultipeerConnectivity", "GameKit", "CloudKit", "CKContainer",
            "NSUbiquitousKeyValueStore", "NSSharingService", "MetricKit", "MXMetricManager", "os_signpost",
            "Data(contentsOf: URL(string", "String(contentsOf: URL(string",
        ]
        for token in forbidden { XCTAssertFalse(code.contains(token), "Sources/Kapture/main.swift uses \(token)") }
        for function in ["socket", "connect", "bind", "listen", "sendto", "sendmsg"] {
            XCTAssertFalse(callsCFunction(function, in: code), "Sources/Kapture/main.swift calls \(function)()")
        }
    }

    func testSourceContainsNoRemoteAddresses() throws {
        let code = try source
        let remote = try NSRegularExpression(pattern: #"(?i)\b(https?|wss?|ftp)://"#)
        let matches = remote.matches(in: code, range: NSRange(code.startIndex..., in: code))
        let found = matches.map { (code as NSString).substring(with: NSRange(location: $0.range.location, length: min(60, (code as NSString).length - $0.range.location))) }
        XCTAssertEqual(found, [], "remote addresses in the source")
        XCTAssertFalse(code.contains("URL(string:"), "URLs are built from file paths only")
    }

    func testOnlyHelperProcessIsScreencapture() throws {
        let code = try source
        XCTAssertEqual(code.components(separatedBy: "Process()").count - 1, 1, "exactly one subprocess")
        let paths = try NSRegularExpression(pattern: #"executableURL\s*=\s*URL\(fileURLWithPath:\s*"([^"]+)"\)"#)
        let found = paths.matches(in: code, range: NSRange(code.startIndex..., in: code)).map { (code as NSString).substring(with: $0.range(at: 1)) }
        XCTAssertEqual(found, ["/usr/sbin/screencapture"])
        for token in ["launchPath", "posix_spawn", "NSAppleScript", "osascript", "NSTask", "NSUserUnixTask"] {
            XCTAssertFalse(code.contains(token), "found \(token)")
        }
        for function in ["system", "popen", "execv", "execve", "execvp", "fork"] {
            XCTAssertFalse(callsCFunction(function, in: code), "calls \(function)()")
        }
    }

    func testOpensOnlyLocalFoldersInOtherApps() throws {
        // NSWorkspace.open with a web address would hand data to a browser; the app only opens the capture folder.
        let code = try source
        let calls = code.components(separatedBy: "NSWorkspace.shared.open(").dropFirst().map { String($0.prefix(while: { $0 != ")" })) }
        XCTAssertEqual(calls, ["folder"])
    }

    // MARK: 3. Binary

    /// The executable SwiftPM built next to this test bundle (same configuration).
    private func executable() throws -> URL {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let url = products.appendingPathComponent("Kapture")
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw XCTSkip("Kapture executable not found at \(url.path)") }
        return url
    }

    private func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = [tool] + args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        try p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "\(tool) failed")
        return out
    }

    func testBinaryLinksNoNetworkingFramework() throws {
        let libraries = try run("otool", ["-L", executable().path])
        for name in ["Network.framework", "CFNetwork.framework", "WebKit.framework", "libcurl", "SystemConfiguration.framework",
                     "CloudKit.framework", "MultipeerConnectivity.framework", "libswiftNetwork"] {
            XCTAssertFalse(libraries.contains(name), "links \(name)")
        }
    }

    func testBinaryImportsNoSocketOrURLLoadingSymbols() throws {
        let symbols = try run("nm", ["-u", executable().path]).split(separator: "\n").map(String.init)
        let forbidden = try NSRegularExpression(pattern:
            #"^(_socket|_connect|_bind|_listen|_sendto|_sendmsg|_getaddrinfo|_gethostbyname.*|_nw_.*|_CFSocket.*|_CFStream.*Socket.*|_CFHost.*|_SCNetwork.*|_OBJC_CLASS_\$_NSURL(Session|Connection|Request|Download).*|_OBJC_CLASS_\$_NSMutableURLRequest|_OBJC_CLASS_\$_WK.*)$|URLSession|URLRequest"#)
        let found = symbols.filter { forbidden.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
        XCTAssertEqual(found, [], "network symbols in the executable")
        XCTAssertFalse(symbols.isEmpty, "nm returned no symbols, so the check above proves nothing")
    }
}
