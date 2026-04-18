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
    private var pending: ((Result<SecretResult, APIError>) -> Void)?
    private var queued: (() -> Void)?

    private override init() {
        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        config.userContentController = ucc
        // Persistent store is fine; nothing sensitive is written (keys are ephemeral).
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        ucc.add(ScriptMessageRelay(owner: self), name: "scrtReady")
        ucc.add(ScriptMessageRelay(owner: self), name: "scrtResult")
        loadHarness()
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

        let optsJSON = jsonString(from: opts) ?? "{}"
        let textLit = jsLiteral(from: text)
        let tokenLit = jsLiteral(from: token)

        let js = "window.scrtCreate(\(tokenLit), \(textLit), \(optsJSON));"

        let fire: () -> Void = { [weak self] in
            guard let self else { return }
            self.webView.evaluateJavaScript(js) { _, err in
                guard let err else { return }
                if let comp = self.pending {
                    self.pending = nil
                    comp(.failure(.server("JS error: \(err.localizedDescription)")))
                }
            }
        }

        if isReady {
            fire()
        } else {
            queued = fire
        }
    }

    // MARK: - Message handling

    fileprivate func handleReady() {
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
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
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
                owner.handleReady()
            } else if message.name == "scrtResult" {
                owner.handleResult(body)
            }
        }
    }
}
