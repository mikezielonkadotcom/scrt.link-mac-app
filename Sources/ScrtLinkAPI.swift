import AppKit
import WebKit

/// Creates secrets via scrt.link's API by running their official JS client
/// module inside a hidden WKWebView. The module handles the client-side
/// encryption (AES-GCM via WebCrypto) that the REST endpoint requires.
///
/// The WebView is loaded with `baseURL: https://scrt.link/` so the module's
/// subsequent fetches to `https://scrt.link/api/v1/secrets` are same-origin.
@MainActor
class ScrtLinkAPI: NSObject {
    static let shared = ScrtLinkAPI()

    struct SecretResult {
        let secretLink: String
        let receiptId: String
        let expiresAt: String
    }

    enum APIError: Error, LocalizedError {
        case missingToken
        case notReady
        case server(String)

        var errorDescription: String? {
            switch self {
            case .missingToken: return "No API token configured. Set it in Preferences."
            case .notReady:     return "Crypto harness not ready yet. Try again in a moment."
            case .server(let m): return m
            }
        }
    }

    private let webView: WKWebView
    private let harnessHTML: () -> String?
    private let tokenProvider: () -> String
    private let timeoutSeconds: Double
    private var isReady = false
    /// Set when the harness failed to load or its web content process died.
    /// The next createSecret reloads it instead of queueing behind a harness
    /// that will never become ready.
    private var harnessFailed = false
    /// The current harness load. Failures of an older, superseded load
    /// (for example one cancelled by a reload) are ignored.
    private var harnessNavigation: WKNavigation?
    private var stagesSeen: [String] = []
    private var logMessages: [String] = []
    /// The single in-flight request. Its id travels through the harness and
    /// back, so a stale timeout or a late result from an earlier request can
    /// never complete a newer one.
    private var pending: (id: Int, completion: (Result<SecretResult, APIError>) -> Void)?
    private var lastRequestID = 0
    /// Starts the pending request once the harness is ready.
    private var queued: (() -> Void)?

    /// Tests inject an offline harness, a fake token, and a short timeout.
    init(
        harnessHTML: @escaping () -> String? = ScrtLinkAPI.bundledHarnessHTML,
        tokenProvider: @escaping () -> String = { KeychainStore.apiToken },
        timeoutSeconds: Double = 15
    ) {
        self.harnessHTML = harnessHTML
        self.tokenProvider = tokenProvider
        self.timeoutSeconds = timeoutSeconds
        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        config.userContentController = ucc
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        ucc.add(ScriptMessageRelay(owner: self), name: "scrtReady")
        ucc.add(ScriptMessageRelay(owner: self), name: "scrtResult")
        ucc.add(ScriptMessageRelay(owner: self), name: "scrtLog")
        // Allow Safari Web Inspector to attach for debugging.
        if webView.responds(to: Selector(("setInspectable:"))) {
            webView.perform(Selector(("setInspectable:")), with: NSNumber(value: true))
        }
        loadHarness()
    }

    /// Runs a simple probe in the harness webView and returns a human-readable
    /// string that describes the current state. Used by the debug menu item.
    func runDiagnostic(completion: @escaping (String) -> Void) {
        let stages = stagesSeen.joined(separator: ",")
        let readyFlag = isReady
        let failedFlag = harnessFailed
        let pendingFlag = pending != nil
        let script = """
        (function(){
            return JSON.stringify({
                doc: document.readyState,
                scrtCreate: typeof window.scrtCreate,
                href: location.href,
                origin: location.origin,
            });
        })();
        """
        let logs = logMessages
        webView.evaluateJavaScript(script) { value, error in
            var lines: [String] = []
            lines.append("Swift state:")
            lines.append("  stagesSeen: [\(stages)]")
            lines.append("  isReady: \(readyFlag)")
            lines.append("  harnessFailed: \(failedFlag)")
            lines.append("  pending: \(pendingFlag)")
            lines.append("")
            lines.append("WebView state:")
            if let err = error {
                lines.append("  evaluateJavaScript error: \(err.localizedDescription)")
            }
            if let v = value {
                lines.append("  \(v)")
            }
            lines.append("")
            lines.append("JS log (last \(logs.count)):")
            if logs.isEmpty {
                lines.append("  <no log messages>")
            } else {
                for l in logs { lines.append("  \(l)") }
            }
            completion(lines.joined(separator: "\n"))
        }
    }

    nonisolated static func bundledHarnessHTML() -> String? {
        guard let url = Bundle.main.url(forResource: "harness", withExtension: "html") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func loadHarness() {
        isReady = false
        harnessFailed = false
        stagesSeen = []
        guard let html = harnessHTML() else {
            harnessFailed = true
            handleLog("harness resource missing")
            return
        }
        harnessNavigation = webView.loadHTMLString(html, baseURL: URL(string: "https://scrt.link/")!)
    }

    /// Marks the harness unusable and fails the in-flight request right away
    /// instead of letting it wait for the timeout.
    private func harnessDidFail(_ reason: String) {
        handleLog("harness failed: \(reason)")
        isReady = false
        harnessFailed = true
        if let current = pending {
            finish(current.id, .failure(.server("Secret creation was interrupted (\(reason)). Try again.")))
        }
    }

    private func finish(_ requestID: Int, _ result: Result<SecretResult, APIError>) {
        guard let current = pending, current.id == requestID else { return }
        pending = nil
        queued = nil
        current.completion(result)
    }

    // MARK: - Public

    func createSecret(
        text: String,
        secretType: String,
        expiresInMs: Int,
        password: String?,
        publicNote: String?,
        completion: @escaping (Result<SecretResult, APIError>) -> Void
    ) {
        let token = tokenProvider()
        guard !token.isEmpty else {
            completion(.failure(.missingToken))
            return
        }
        guard pending == nil else {
            completion(.failure(.server("Another secret is still being created.")))
            return
        }
        lastRequestID += 1
        let requestID = lastRequestID
        pending = (requestID, completion)

        var opts: [String: Any] = [
            "secretType": secretType,
            "expiresIn": expiresInMs,
        ]
        if let p = password, !p.isEmpty { opts["password"] = p }
        if let n = publicNote, !n.isEmpty { opts["publicNote"] = n }
        // White-label host (Secret Service tier). When set, scrt.link's
        // client module POSTs to https://<host>/api/v1/secrets and returns
        // a link on that host.
        let customHost = Preferences.customHost
        if !customHost.isEmpty { opts["host"] = customHost }

        let optsJSON = jsonString(from: opts) ?? "{}"
        let textLit = jsLiteral(from: text)
        let tokenLit = jsLiteral(from: token)

        // `void` so the expression yields `undefined` instead of a Promise —
        // otherwise evaluateJavaScript errors with "unsupported type" because
        // it can't serialize a Promise back to Swift. The real result arrives
        // asynchronously via the scrtResult message channel.
        let js = "void window.scrtCreate(\(tokenLit), \(textLit), \(optsJSON), \(requestID));"

        let fire: () -> Void = { [weak self] in
            guard let self else { return }
            self.handleLog("swift->js: calling scrtCreate")
            self.webView.evaluateJavaScript(js) { [weak self] _, err in
                guard let self else { return }
                if let err {
                    self.handleLog("evaluateJavaScript error")
                    self.finish(requestID, .failure(.server("JS error: \(err.localizedDescription)")))
                } else {
                    self.handleLog("evaluateJavaScript returned (scrtCreate promise pending)")
                }
            }
        }

        if harnessFailed {
            handleLog("reloading harness after an earlier failure")
            loadHarness()
        }
        if isReady {
            fire()
        } else {
            queued = fire
        }

        // If nothing comes back in time, assume the harness hung (e.g. module
        // import never resolved) and surface a useful error instead of a
        // forever-spinner. Only this request's timer may fail it.
        let timeout = timeoutSeconds
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self, self.pending?.id == requestID else { return }
            let stages = self.stagesSeen.joined(separator: ",")
            let stateInfo = self.isReady
                ? "harness ready but no response"
                : "harness never loaded (stages: \(stages))"
            // A harness that never became ready is stuck; reload it next time.
            if !self.isReady { self.harnessFailed = true }
            self.finish(requestID, .failure(.server("timeout after \(Int(timeout))s — \(stateInfo)")))
        }
    }

    // MARK: - Message handling

    fileprivate func handleLog(_ msg: String) {
        let ts = String(format: "%.2f", ProcessInfo.processInfo.systemUptime)
        logMessages.append("[\(ts)] \(msg)")
        if logMessages.count > 80 { logMessages.removeFirst() }
    }

    fileprivate func handleReady(stage: String) {
        stagesSeen.append(stage)
        // Only flip isReady when the module has actually loaded — the
        // "document-loaded" stage just means the HTML finished parsing.
        guard stage == "module-loaded" else { return }
        isReady = true
        let q = queued
        queued = nil
        q?()
    }

    fileprivate func handleResult(_ body: [String: Any]) {
        // A failed module import is fatal for this harness load: it will
        // never become ready, so reload it on the next attempt.
        if body["fatal"] as? Bool == true {
            isReady = false
            harnessFailed = true
        }
        guard let current = pending else { return }
        // scrtCreate results carry their request id. Page-level errors
        // (module import, window.onerror) carry none and apply to the
        // in-flight request.
        if let id = (body["requestId"] as? NSNumber)?.intValue, id != current.id {
            handleLog("ignored a late result from an earlier request")
            return
        }

        let ok = body["ok"] as? Bool ?? false
        if ok, let link = body["link"] as? String {
            finish(current.id, .success(SecretResult(
                secretLink: link,
                receiptId: body["receiptId"] as? String ?? "",
                expiresAt: body["expiresAt"] as? String ?? ""
            )))
        } else {
            let err = body["error"] as? String ?? "Unknown error"
            finish(current.id, .failure(.server(err)))
        }
    }

    // MARK: - JSON helpers

    private func jsonString(from obj: Any) -> String? {
        // `.fragmentsAllowed` is critical — without it, JSONSerialization
        // refuses top-level scalars (Strings, Numbers) and silently yields
        // nil here, which previously produced malformed JS and hung the call.
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed]),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    /// Produces a JavaScript string literal for `s` that's safe to interpolate
    /// into generated JS source. Uses JSON encoding since JSON strings are a
    /// strict subset of JS string syntax.
    private func jsLiteral(from s: String) -> String {
        return jsonString(from: s) ?? "\"\""
    }
}

extension ScrtLinkAPI: WKNavigationDelegate {
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        harnessDidFail("web content process terminated")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard let navigation, navigation === harnessNavigation else { return }
        harnessDidFail("harness navigation failed")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard let navigation, navigation === harnessNavigation else { return }
        harnessDidFail("harness navigation failed")
    }
}

/// Tiny relay so the script message handler conformance can sit on a helper
/// and the main class doesn't need to expose its handling methods publicly
/// or fight Swift 6 actor isolation for the protocol.
@MainActor
private final class ScriptMessageRelay: NSObject, WKScriptMessageHandler {
    private weak var owner: ScrtLinkAPI?
    init(owner: ScrtLinkAPI) { self.owner = owner }

    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        // WKScriptMessage properties are main-actor isolated, so hop first.
        Task { @MainActor in
            guard let owner = self.owner else { return }
            let body = message.body as? [String: Any] ?? [:]
            if message.name == "scrtReady" {
                let stage = body["stage"] as? String ?? ""
                owner.handleReady(stage: stage)
            } else if message.name == "scrtResult" {
                owner.handleResult(body)
            } else if message.name == "scrtLog" {
                owner.handleLog(body["msg"] as? String ?? "")
            }
        }
    }
}
