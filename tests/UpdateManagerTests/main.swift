import AppKit

// Offline regression tests for the auto-updater's release gates, compiled by
// tests/test-update-verification.sh together with Sources/UpdateManager.swift.
//
// argv[1] is a freshly built ad hoc ScrtLink.app. It has a valid structure,
// bundle ID and version, but no Developer ID signature and no pinned team, so
// every verifyUpdate call below must return false. A regression that lets any
// of them pass would let the updater install an unsigned bundle.

var failures = 0
var checks = 0

@MainActor
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    checks += 1
    if condition {
        print("  ✓ \(message)")
    } else {
        failures += 1
        print("  ✗ \(message)  (line \(line))")
    }
}

guard CommandLine.arguments.count > 1 else {
    print("  ✗ usage: update-manager-tests <path/to/ScrtLink.app>")
    exit(2)
}
let appURL = URL(fileURLWithPath: CommandLine.arguments[1])
let owner = "mikezielonkadotcom"
let repo = "scrt.link-mac-app"
let realBundleID = "com.mikezielonka.scrt-link"
let realTeamID = "LTB247PXZ7"

// --- Version comparison -------------------------------------------------------

print("▸ Version comparison")
func newer(_ remote: String, _ current: String) -> Bool {
    UpdateManager.isNewerVersion(remote: remote, current: current)
}
check(newer("1.6.2", "1.6.1"), "patch bump is newer")
check(newer("1.7.0", "1.6.9"), "minor bump is newer")
check(newer("2.0.0", "1.99.99"), "major bump is newer")
check(newer("1.10.0", "1.9.9"), "comparison is numeric, not lexical (1.10.0 > 1.9.9)")
check(!newer("1.6.1", "1.6.1"), "same version is not newer")
check(!newer("1.6.0", "1.6.1"), "older version is not newer")
check(!newer("1.6", "1.6.0"), "missing component counts as zero (1.6 == 1.6.0)")
check(newer("1.6.0.1", "1.6.0"), "extra component can make it newer")
check(!newer("garbage", "1.6.1"), "non-numeric remote tag is never newer")
check(newer("1.6.1", "0.0.0"), "anything beats the 0.0.0 fallback")

// --- HTTP status handling -------------------------------------------------------

print("")
print("▸ HTTP status handling")
func http(_ status: Int) -> URLResponse {
    HTTPURLResponse(url: URL(string: "https://api.github.com/x")!, statusCode: status, httpVersion: nil, headerFields: nil)!
}
check(UpdateManager.describeHTTPFailure(nil) == nil, "no response → no HTTP failure (error path handles it)")
check(UpdateManager.describeHTTPFailure(http(200)) == nil, "200 is not a failure")
check(UpdateManager.describeHTTPFailure(http(403))?.contains("rate-limited") == true, "403 is reported as a rate limit")
check(UpdateManager.describeHTTPFailure(http(429))?.contains("rate-limited") == true, "429 is reported as a rate limit")
check(UpdateManager.describeHTTPFailure(http(404))?.contains("404") == true, "404 is reported as no release")
check(UpdateManager.describeHTTPFailure(http(502))?.contains("502") == true, "other statuses name the code")

// --- Download URL pinning ---------------------------------------------------

print("")
print("▸ Download URL pinning")
func asset(_ name: String, _ url: String) -> [String: Any] {
    ["name": name, "browser_download_url": url]
}
func download(_ version: String, _ assets: [[String: Any]]) -> URL? {
    UpdateManager.releaseDownloadURL(version: version, assets: assets, repoOwner: owner, repoName: repo)
}
let good = "https://github.com/\(owner)/\(repo)/releases/download/v1.7.0/ScrtLink-v1.7.0.zip"
check(download("1.7.0", [asset("ScrtLink-v1.7.0.zip", good)]) == URL(string: good),
      "exact versioned asset on github.com is accepted")
check(download("1.7.0", [asset("ScrtLink-v1.7.0.zip.sha256", good + ".sha256"),
                         asset("ScrtLink-v1.7.0.zip", good)]) == URL(string: good),
      "the ZIP is picked out of several assets")
check(download("1.7.0", []) == nil, "no assets → nil")
check(download("1.7.0", [asset("ScrtLink.zip", good)]) == nil, "asset name must include the version")
check(download("1.7.0", [asset("ScrtLink-v1.7.1.zip",
                               good.replacingOccurrences(of: "v1.7.0/ScrtLink-v1.7.0", with: "v1.7.1/ScrtLink-v1.7.1"))]) == nil,
      "asset for a different version is rejected")
check(download("1.7.0", [asset("ScrtLink-v1.7.0.zip", good.replacingOccurrences(of: "https://", with: "http://"))]) == nil,
      "plain http is rejected")
check(download("1.7.0", [asset("ScrtLink-v1.7.0.zip", good.replacingOccurrences(of: "github.com", with: "github.com.evil.example"))]) == nil,
      "lookalike host is rejected")
check(download("1.7.0", [asset("ScrtLink-v1.7.0.zip", good.replacingOccurrences(of: "github.com", with: "objects.githubusercontent.com"))]) == nil,
      "a different GitHub host is rejected")
check(download("1.7.0", [asset("ScrtLink-v1.7.0.zip", good.replacingOccurrences(of: "https://github.com", with: "https://github.com@evil.example"))]) == nil,
      "userinfo trick (github.com@evil.example) is rejected")
check(download("1.7.0", [asset("ScrtLink-v1.7.0.zip", good.replacingOccurrences(of: "github.com/", with: "github.com:443/"))]) == nil,
      "explicit port is rejected")
check(download("1.7.0", [asset("ScrtLink-v1.7.0.zip", good.replacingOccurrences(of: owner, with: "someone-else"))]) == nil,
      "another owner's repository is rejected")
check(download("1.7.0", [asset("ScrtLink-v1.7.0.zip", good.replacingOccurrences(of: repo, with: "scrt.link-mac-app-fork"))]) == nil,
      "another repository name is rejected")
check(download("1.7.0", [asset("ScrtLink-v1.7.0.zip", good.replacingOccurrences(of: "/v1.7.0/", with: "/v1.7.0/../v0.0.1/"))]) == nil,
      "path traversal in the release path is rejected")
check(download("1.7.0", [asset("ScrtLink-v1.7.0.zip", good + "?download=1")]) == URL(string: good + "?download=1"),
      "a query string does not change scheme, host or path (accepted as GitHub serves it)")
check(download("1.7.0", [["name": "ScrtLink-v1.7.0.zip"]]) == nil, "asset without a download URL → nil")

// --- Bundle verification --------------------------------------------------------

print("")
print("▸ Bundle verification against the ad hoc build")
guard let bundle = Bundle(url: appURL),
      let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
    print("  ✗ \(appURL.path) is not a readable app bundle")
    exit(1)
}
check(bundle.bundleIdentifier == realBundleID, "fixture bundle ID is \(realBundleID)")
check(bundle.object(forInfoDictionaryKey: "ScrtLinkTeamID") == nil, "fixture has no pinned team (ad hoc build)")

func verify(_ app: URL = appURL, version v: String = version,
            teamID: String? = realTeamID, bundleID: String? = realBundleID) -> Bool {
    UpdateManager.verifyUpdate(app, version: v, teamID: teamID, bundleID: bundleID)
}
check(!verify(teamID: nil), "no pinned team → refused")
check(!verify(teamID: ""), "empty team ID → refused")
check(!verify(teamID: "short"), "malformed team ID → refused")
check(!verify(teamID: "ltb247pxz7"), "lowercase team ID fails the shape check → refused")
check(!verify(bundleID: nil), "no bundle ID → refused")
check(!verify(bundleID: "com.example.other"), "wrong bundle ID → refused")
check(!verify(version: "0.0.0"), "wrong version → refused")
check(!verify(appURL.appendingPathComponent("does-not-exist.app")), "missing bundle → refused")
check(!verify(), "ad hoc build with the right ID, version and a valid team ID is still refused (no Developer ID signature)")

// The requirement string is the whole gate once metadata matches, so make
// sure the fixture would pass the metadata part: the same inputs with a
// trivially-satisfied requirement would have reached codesign. We prove that
// by checking the bundle's ad hoc signature is at least structurally valid;
// if it were not, the refusal above would be meaningless.
check(UpdateManager.run("/usr/bin/codesign", ["--verify", "--strict", "--deep", appURL.path]),
      "fixture's ad hoc signature is structurally valid, so the refusal came from the team requirement")
check(!UpdateManager.run("/usr/bin/codesign", ["--verify", "--strict", "--deep",
                                               "-R=anchor apple generic and certificate leaf[subject.OU] = \"\(realTeamID)\"",
                                               appURL.path]),
      "the pinned-team requirement alone rejects the ad hoc signature")
check(!UpdateManager.run("/usr/bin/nonexistent-tool", []), "run() reports a missing executable as failure")
check(UpdateManager.run("/usr/bin/true", []), "run() reports exit 0 as success")
check(!UpdateManager.run("/usr/bin/false", []), "run() reports exit 1 as failure")

print("")
print("═══════════════════════════════════════════")
print("  Checks: \(checks)   Failed: \(failures)")
print("═══════════════════════════════════════════")
exit(failures == 0 ? 0 : 1)
