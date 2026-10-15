import Foundation
import WebKit

struct ScrapePayload {
    var text: String
    var hook: [[String: Any]]
    var debugSnippet: String {
        let hookNote = hook.isEmpty ? "" : " · hook:\(hook.count)"
        return truncate(text, maxLength: 300) + hookNote
    }
}

enum ScrapeError: LocalizedError {
    case timedOut
    case badPayload

    var errorDescription: String? {
        switch self {
        case .timedOut: return "webview timed out"
        case .badPayload: return "unreadable page payload"
        }
    }
}

/// Offscreen `WKWebView` used for one scrape. It is never added to a window
/// and is torn down as soon as the result is delivered.
///
/// Reads once a fixed 4 s after `didFinish` (SPEC §3), plus at most one further
/// read when that carried nothing the parser could use — the common failure is
/// a single-page render that has painted its chrome but not its numbers yet.
/// Bounded: no polling loop, one extra one-shot read at most, and the 40 s hard
/// ceiling still applies.
final class OffscreenScraper: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private let completion: (Result<ScrapePayload, Error>) -> Void
    private var finished = false
    private var evaluationScheduled = false
    private var retried = false
    private var timeoutWork: DispatchWorkItem?
    private var evaluationWork: DispatchWorkItem?

    /// Wraps `window.fetch` at document start, recording JSON-ish responses
    /// whose URL mentions usage/limit/go into `window.__ub_json` (max 20).
    static let hookJS = """
    (function () {
      if (window.__ub_json) { return; }
      window.__ub_json = [];
      var orig = window.fetch;
      if (typeof orig !== 'function') { return; }
      window.fetch = function () {
        var p = orig.apply(this, arguments);
        try {
          p.then(function (resp) {
            try {
              var u = (resp && resp.url) ? String(resp.url) : '';
              if (/usage|limit|go/i.test(u)) {
                resp.clone().text().then(function (t) {
                  try {
                    JSON.parse(t);
                    window.__ub_json.push({ url: u, body: String(t) });
                    while (window.__ub_json.length > 20) { window.__ub_json.shift(); }
                  } catch (e) {}
                }).catch(function () {});
              }
            } catch (e) {}
            return resp;
          }).catch(function () {});
        } catch (e) {}
        return p;
      };
    })();
    """

    init(url: URL, completion: @escaping (Result<ScrapePayload, Error>) -> Void) {
        self.completion = completion
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        config.userContentController.addUserScript(
            WKUserScript(
                source: OffscreenScraper.hookJS,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        self.webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1000, height: 800), configuration: config)
        super.init()
        webView?.navigationDelegate = self
        webView?.load(URLRequest(url: url))

        let timeout = DispatchWorkItem { [weak self] in
            self?.finish(.failure(ScrapeError.timedOut))
        }
        timeoutWork = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 40, execute: timeout)
    }

    func start() {
        // Load already kicked off in init; this exists so callers can express intent.
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !finished, !evaluationScheduled else { return }
        evaluationScheduled = true
        let work = DispatchWorkItem { [weak self] in self?.evaluate() }
        evaluationWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    private func evaluate() {
        guard !finished, let webView else { return }
        let js = "JSON.stringify({t: (document.body ? document.body.innerText : '') || '', j: (window.__ub_json || [])})"
        webView.evaluateJavaScript(js) { [weak self] result, error in
            guard let self else { return }
            if let error {
                self.finish(.failure(error))
                return
            }
            guard let string = result as? String else {
                self.finish(.failure(ScrapeError.badPayload))
                return
            }
            DispatchQueue.global(qos: .utility).async {
                let payload: Result<ScrapePayload, Error>
                if let data = string.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    payload = .success(ScrapePayload(
                        text: object["t"] as? String ?? "",
                        hook: object["j"] as? [[String: Any]] ?? []
                    ))
                } else {
                    payload = .failure(ScrapeError.badPayload)
                }
                DispatchQueue.main.async { self.finishOrRetry(payload) }
            }
        }
    }

    /// A read that carried nothing the parser could use gets one more chance:
    /// the common failure is a single-page render that has painted its chrome
    /// but not its numbers yet. The test is deliberately loose — it only decides
    /// whether to read *again*, so it can never commit anything worse than the
    /// first read, only add one bounded 4 s read.
    private func finishOrRetry(_ payload: Result<ScrapePayload, Error>) {
        guard !finished else { return }
        if !retried, case .success(let scrape) = payload, !Self.looksUsable(scrape) {
            retried = true
            let work = DispatchWorkItem { [weak self] in self?.evaluate() }
            evaluationWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
            return
        }
        finish(payload)
    }

    /// True when the payload carries something the parser can act on: a
    /// percentage, a `$a / $b` pair, or a captured fetch response.
    private static func looksUsable(_ payload: ScrapePayload) -> Bool {
        if !payload.hook.isEmpty { return true }
        if payload.text.range(of: #"\d+(\.\d+)?\s*%"#, options: .regularExpression) != nil { return true }
        if payload.text.range(of: #"\$\s*\d+(\.\d+)?\s*/\s*\$\s*\d"#, options: .regularExpression) != nil { return true }
        return false
    }

    private func finish(_ result: Result<ScrapePayload, Error>) {
        guard !finished else { return }
        finished = true
        timeoutWork?.cancel()
        evaluationWork?.cancel()
        timeoutWork = nil
        evaluationWork = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        Self.clearCaches()
        completion(result)
    }

    /// Each load would otherwise leave the console's scripts and assets in
    /// ~/Library/Caches, growing it over time. Only caches are removed:
    /// cookies and site storage (the OpenCode sign-in) are kept.
    static func clearCaches() {
        let types: Set<String> = [
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeFetchCache,
            WKWebsiteDataTypeOfflineWebApplicationCache
        ]
        WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast) {}
    }
}
