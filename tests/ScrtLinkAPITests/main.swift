import AppKit
import WebKit

// Offline regression tests for the Swift <-> JS secret-creation bridge,
// compiled by tests/test-scrtlink-api.sh with Sources/ScrtLinkAPI.swift,
// KeychainStore.swift and Preferences.swift.
//
// Each test loads the REAL Resources/harness.html in a real WKWebView, with
// only the scrt.link client-module import swapped for an inline fake module,
// so nothing touches the network, the Keychain (the token is injected), or
// scrt.link. The fake module echoes the secret text into the link and blocks
// the page for `delay:<ms>` (passed as the public note) before resolving.
// It busy-waits on purpose: a hidden WKWebView throttles setTimeout, which
// made timer-based delays unpredictable.

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

/// Pumps the main run loop (WebKit callbacks, main-actor tasks) until
/// `condition` holds or `timeout` elapses.
@discardableResult
@MainActor
func spin(timeout: Double, until condition: () -> Bool = { false }) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    return condition()
}

@MainActor
final class Outcome {
    var result: Result<ScrtLinkAPI.SecretResult, ScrtLinkAPI.APIError>?
    var done: Bool { result != nil }
    var link: String? {
        if case .success(let r)? = result { return r.secretLink }
        return nil
    }
    var error: String? {
        if case .failure(let e)? = result { return e.localizedDescription }
        return nil
    }
}

@MainActor
func create(_ api: ScrtLinkAPI, _ text: String, delayMs: Int) -> Outcome {
    let outcome = Outcome()
    api.createSecret(text: text, secretType: "text", expiresInMs: 600_000,
                     password: nil, publicNote: "delay:\(delayMs)") { outcome.result = $0 }
    return outcome
}

// --- Harness fixtures ---------------------------------------------------------

// Isolated defaults domain (Preferences.customHost reads it).
UserDefaults.standard.removePersistentDomain(forName: ProcessInfo.processInfo.processName)

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let harnessPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/harness.html"
guard let realHarness = try? String(contentsOfFile: harnessPath, encoding: .utf8) else {
    print("  ✗ could not read \(harnessPath)")
    exit(1)
}
let moduleURL = "https://scrt.link/api/v1/client-module"
let fakeToken = "fake-test-token"

func harness(module: String) -> String {
    let encoded = module.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    return realHarness.replacingOccurrences(of: moduleURL, with: "data:text/javascript," + encoded)
}

let workingHarness = harness(module: """
export default (apiKey) => ({
    createSecret: async (text, opts) => {
        if (apiKey !== '\(fakeToken)') throw new Error('wrong token');
        const delay = parseInt(String(opts.publicNote || '').replace('delay:', ''), 10) || 0;
        const end = Date.now() + delay;
        while (Date.now() < end) {}
        return { secretLink: 'https://scrt.link/s#' + text, receiptId: 'r-' + text, expiresAt: '' };
    },
});
""")
let failingHarness = harness(module: "throw new Error('offline');")

print("▸ Fixture")
check(realHarness.contains("'\(moduleURL)'"), "real harness imports the scrt.link client module")

@MainActor
func makeAPI(timeout: Double, html: @escaping () -> String?) -> ScrtLinkAPI {
    ScrtLinkAPI(harnessHTML: html, tokenProvider: { fakeToken }, timeoutSeconds: timeout)
}

// --- Happy path + diagnostic privacy -----------------------------------------

print("")
print("▸ Create through the real harness")
let basic = makeAPI(timeout: 5) { workingHarness }
let first = create(basic, "private-secret-text", delayMs: 0)
spin(timeout: 8) { first.done }
check(first.link == "https://scrt.link/s#private-secret-text",
      "link is returned (\(first.link ?? first.error ?? "no result"))")

var report: String?
basic.runDiagnostic { report = $0 }
spin(timeout: 5) { report != nil }
check(report != nil, "diagnostic report is produced")
check(!(report ?? "").contains("private-secret-text"), "diagnostic report omits the secret text")
check(!(report ?? "").contains(fakeToken), "diagnostic report omits the API token")
check(!(report ?? "").contains("scrt.link/s#"), "diagnostic report omits the secret link")

// --- Harness recovery ---------------------------------------------------------

print("")
print("▸ Harness recovers after the client module failed to load")
// E.g. the first Create happened offline. The next Create must reload the
// harness instead of queueing behind a harness that will never be ready.
var currentHarness = failingHarness
let recovering = makeAPI(timeout: 3) { currentHarness }
let offline = create(recovering, "while-offline", delayMs: 0)
spin(timeout: 6) { offline.done }
check(offline.error?.contains("module import failed") == true,
      "offline attempt reports the import failure (\(offline.error ?? "no error"))")
currentHarness = workingHarness  // network is back
let online = create(recovering, "after-recovery", delayMs: 0)
spin(timeout: 8) { online.done }
check(online.link == "https://scrt.link/s#after-recovery",
      "next attempt reloads the harness and succeeds (\(online.link ?? online.error ?? "no result"))")

// --- Stale timeout ----------------------------------------------------------------

print("")
print("▸ An earlier request's timeout cannot fail a later request")
let timed = makeAPI(timeout: 2) { workingHarness }
let warm = create(timed, "warm-up", delayMs: 0)
spin(timeout: 8) { warm.done }
spin(timeout: 2.3)  // let the warm-up request's own timer expire
let a = create(timed, "a", delayMs: 0)
let t0 = Date()
spin(timeout: 2) { a.done }
check(a.link == "https://scrt.link/s#a", "request A succeeds")
spin(timeout: max(0, 1.2 - Date().timeIntervalSince(t0)))
let b = create(timed, "b", delayMs: 1300)  // still pending when A's timer fires at 2.0 s
spin(timeout: 4) { b.done }
check(b.link == "https://scrt.link/s#b",
      "request B completes with its own link (\(b.link ?? b.error ?? "no result"))")

// --- Late result ----------------------------------------------------------------

print("")
print("▸ A timed-out request's late result cannot complete a later request")
let late = makeAPI(timeout: 2) { workingHarness }
let warm2 = create(late, "warm-up", delayMs: 0)
spin(timeout: 8) { warm2.done }
spin(timeout: 2.3)
let c = create(late, "c", delayMs: 3000)  // times out at 2.0 s, resolves at 3.0 s
spin(timeout: 4) { c.done }
check(c.error?.contains("timeout") == true, "request C times out (\(c.error ?? c.link ?? "no result"))")
// D waits behind C in the page, so C's late result lands while D is pending.
// D then resolves at about 3.5 s, before its own timeout at about 4.0 s.
let d = create(late, "d", delayMs: 500)
spin(timeout: 4) { d.done }
check(d.link == "https://scrt.link/s#d",
      "request D gets its own link, not C's (\(d.link ?? d.error ?? "no result"))")

print("")
print("═══════════════════════════════════════════")
print("  Checks: \(checks)   Failed: \(failures)")
print("═══════════════════════════════════════════")
exit(failures == 0 ? 0 : 1)
