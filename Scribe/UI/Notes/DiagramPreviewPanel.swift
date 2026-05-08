// Scribe/UI/Notes/DiagramPreviewPanel.swift
import SwiftUI
import WebKit
import Combine

struct DiagramPreviewPanel: NSViewRepresentable {

    /// Publisher of the note body text.
    let bodyPublisher: AnyPublisher<String, Never>

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let wv = WKWebView(frame: .zero)
        wv.navigationDelegate = context.coordinator

        guard
            let resourceDir = Bundle.main.resourceURL,
            let htmlURL = Bundle.main.url(forResource: "diagram-renderer", withExtension: "html")
        else {
            return wv
        }
        wv.loadFileURL(htmlURL, allowingReadAccessTo: resourceDir)
        context.coordinator.webView = wv
        context.coordinator.pendingPublisher = bodyPublisher
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        // Publisher binding handled once in makeNSView / navigationDelegate didFinish.
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var webView: WKWebView?
        var pendingPublisher: AnyPublisher<String, Never>?
        private var renderer = DiagramRenderer.shared

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let publisher = pendingPublisher else { return }
            renderer.bind(bodyPublisher: publisher, webView: webView)
            pendingPublisher = nil
        }
    }
}
