import Foundation
import SwiftUI
import WebKit

/// Owns one `WKWebView` per tab so switching tabs keeps each page.
///
/// All tabs share a non-persistent website data store: cookies, cache and
/// local storage live in memory only and disappear when the app quits.
@MainActor
final class WebViewStore: NSObject, WKUIDelegate {
    private var webViews: [UUID: WKWebView] = [:]
    private var observations: [UUID: [NSKeyValueObservation]] = [:]
    private let dataStore = WKWebsiteDataStore.nonPersistent()

    /// Called whenever a tab's navigation state changes.
    var onStateChange: (@MainActor (UUID, BrowserPageState) -> Void)?

    /// The web view for a tab, created (and loaded with the tab's URL) on first use.
    func webView(for tab: BrowserTab) -> WKWebView {
        if let existing = webViews[tab.id] { return existing }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.uiDelegate = self
        webViews[tab.id] = webView
        observe(webView, tabID: tab.id)
        if let url = tab.url {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func load(_ url: URL, in tab: BrowserTab) {
        let webView = webView(for: tab)
        if webView.url != url || !webView.isLoading {
            webView.load(URLRequest(url: url))
        }
    }

    func goBack(_ id: UUID) { webViews[id]?.goBack() }
    func goForward(_ id: UUID) { webViews[id]?.goForward() }
    func reload(_ id: UUID) { webViews[id]?.reload() }
    func stop(_ id: UUID) { webViews[id]?.stopLoading() }

    func remove(_ id: UUID) {
        observations[id]?.forEach { $0.invalidate() }
        observations[id] = nil
        webViews[id]?.stopLoading()
        webViews[id] = nil
    }

    /// Removes web views for tabs that no longer exist.
    func retain(only ids: Set<UUID>) {
        for id in webViews.keys where !ids.contains(id) {
            remove(id)
        }
    }

    private func observe(_ webView: WKWebView, tabID: UUID) {
        let report: @Sendable (WKWebView) -> Void = { [weak self] webView in
            MainActor.assumeIsolated {
                self?.onStateChange?(tabID, BrowserPageState(
                    url: webView.url,
                    title: webView.title,
                    canGoBack: webView.canGoBack,
                    canGoForward: webView.canGoForward,
                    isLoading: webView.isLoading,
                    progress: webView.estimatedProgress
                ))
            }
        }
        observations[tabID] = [
            webView.observe(\.url) { view, _ in report(view) },
            webView.observe(\.title) { view, _ in report(view) },
            webView.observe(\.canGoBack) { view, _ in report(view) },
            webView.observe(\.canGoForward) { view, _ in report(view) },
            webView.observe(\.isLoading) { view, _ in report(view) },
            webView.observe(\.estimatedProgress) { view, _ in report(view) },
        ]
    }

    // MARK: WKUIDelegate

    /// Links that ask for a new window open in the same tab.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}

/// Shows the selected tab's web view.
struct BrowserWebView: UIViewRepresentable {
    let tab: BrowserTab
    let store: WebViewStore

    func makeUIView(context: Context) -> WKWebView {
        store.webView(for: tab)
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
