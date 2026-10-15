import AppKit
import WebKit

/// Visible webview window used once to sign in to OpenCode. It shares the
/// default (persisted) website data store with the offscreen scraper, so the
/// session carries over. Close the window when done.
final class OpenCodeLoginController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var webView: WKWebView?

    func show(urlString: String) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let frame = NSRect(x: 0, y: 0, width: 980, height: 720)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sign in to OpenCode"
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false

        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        let webView = WKWebView(frame: frame, configuration: config)
        webView.autoresizingMask = [.width, .height]
        window.contentView = webView

        if let url = URL(string: urlString) {
            webView.load(URLRequest(url: url))
        }

        self.window = window
        self.webView = webView

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        webView?.stopLoading()
        webView = nil
        window = nil
    }
}
