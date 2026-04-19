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
    private var isReady = false
    private var stagesSeen: [String] = []
    private var logMessages: [String] = []
    private var pending: ((Result<SecretResult, APIError>) -> Void)?
    private var queued: (() -> Void)?

    private override init() {
        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        config.userContentController = ucc
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
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

    private func loadHarness() {
        guard let url = Bundle.main.url(forResource: "harness", withExtension: "html"),
              let html = try? String(contentsOf: url, encoding: .utf8) else {
            return
        }
        webView.loadHTMLString(html, baseURL: URL(string: "https://scrt.link/")!)
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
        let token = KeychainStore.apiToken
        guard !token.isEmpty else {
            completion(.failure(.missingToken))
            return
        }
        guard pending == nil else {
            completion(.failure(.server("Another secret is still being created.")))
            return
        }
        pending = completion

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
        let js = "void window.scrtCreate(\(tokenLit), \(textLit), \(optsJSON));"

        let fire: () -> Void = { [weak self] in
            guard let self else { return }
            self.handleLog("swift->js: calling scrtCreate (js.len=\(js.count))")
            self.webView.evaluateJavaScript(js) { [weak self] _, err in
                guard let self else { return }
                if let err {
                    self.handleLog("evaluateJavaScript error: \(err.localizedDescription)")
                    if let comp = self.pending {
                        self.pending = nil
                        comp(.failure(.server("JS error: \(err.localizedDescription)")))
                    }
                } else {
                    self.handleLog("evaluateJavaScript returned (scrtCreate promise pending)")
                }
            }
        }

        if isReady {
            fire()
        } else {
            queued = fire
        }

        // If nothing comes back in 15s, assume the harness hung (e.g. module
        // import never resolved) and surface a useful error instead of a
        // forever-spinner.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self, let comp = self.pending else { return }
            self.pending = nil
            let stages = self.stagesSeen.joined(separator: ",")
            let stateInfo = self.isReady
                ? "harness ready but no response"
                : "harness never loaded (stages: \(stages))"
            comp(.failure(.server("timeout after 15s — \(stateInfo)")))
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
        guard let completion = pending else { return }
        pending = nil

        let ok = body["ok"] as? Bool ?? false
        if ok, let link = body["link"] as? String {
            completion(.success(SecretResult(
                secretLink: link,
                receiptId: body["receiptId"] as? String ?? "",
                expiresAt: body["expiresAt"] as? String ?? ""
            )))
        } else {
            let err = body["error"] as? String ?? "Unknown error"
            completion(.failure(.server(err)))
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
