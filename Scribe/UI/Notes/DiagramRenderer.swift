// Scribe/UI/Notes/DiagramRenderer.swift
import AppKit
import Foundation
import CryptoKit
import OSLog
import WebKit

private let log = Logger(subsystem: "com.varij.scribe", category: "diagram-renderer")

enum DiagramType: Equatable {
    case mermaid
    case plantuml
}

struct DiagramBlock: Equatable {
    let type: DiagramType
    let source: String
    /// Full fence text including ```fence``` markers, used for fold replacement.
    let fullText: String
    /// Range of `fullText` within the original body string (UTF-16 indices, NSRange-compatible).
    let nsRange: NSRange
}

@MainActor
final class DiagramRenderer: NSObject {

    static let shared = DiagramRenderer()

    // MARK: - Cache

    private var cache: [String: NSImage] = [:]
    private var inFlight: [String: [() -> Void]] = [:]
    private var failedKeys: Set<String> = []

    // MARK: - WKWebView (lazy, headless, off-screen)

    private var webView: WKWebView?
    private var hostWindow: NSWindow?
    private var webViewReady = false
    private var bootstrapWaiters: [() -> Void] = []

    private override init() { super.init() }

    // MARK: - Public API (new)

    /// Returns a cached image immediately if present. Otherwise returns `nil` and starts an
    /// async render; `onReady` fires on the main actor when the image lands in cache.
    /// If the same (type, source) is already in flight, the new `onReady` is queued onto it.
    func image(type: DiagramType, source: String, onReady: @escaping () -> Void) -> NSImage? {
        let key = Self.cacheKey(type: type, source: source)
        if let img = cache[key] { return img }
        if failedKeys.contains(key) { return nil }

        if inFlight[key] != nil {
            inFlight[key]?.append(onReady)
            return nil
        }
        inFlight[key] = [onReady]
        Task { await self.renderToCache(type: type, source: source, key: key) }
        return nil
    }

    // MARK: - Parsing (unchanged behaviour, returns richer blocks)

    nonisolated(unsafe) private static let blockRegex = try? NSRegularExpression(
        pattern: #"```(mermaid|plantuml)\n([\s\S]*?)```"#
    )

    nonisolated static func extractBlocks(from body: String) -> [DiagramBlock] {
        guard let regex = blockRegex else { return [] }
        var blocks: [DiagramBlock] = []
        let nsBody = body as NSString
        let fullRange = NSRange(location: 0, length: nsBody.length)

        for match in regex.matches(in: body, range: fullRange) {
            guard match.numberOfRanges == 3 else { continue }
            let fullNS = match.range(at: 0)
            let typeNS = match.range(at: 1)
            let sourceNS = match.range(at: 2)
            guard fullNS.location != NSNotFound,
                  typeNS.location != NSNotFound,
                  sourceNS.location != NSNotFound else { continue }

            let fullText = nsBody.substring(with: fullNS)
            let typeStr  = nsBody.substring(with: typeNS)
            let source   = nsBody.substring(with: sourceNS).trimmingCharacters(in: .newlines)
            let type: DiagramType = typeStr == "mermaid" ? .mermaid : .plantuml
            blocks.append(DiagramBlock(type: type, source: source, fullText: fullText, nsRange: fullNS))
        }
        return blocks
    }

    // MARK: - Rendering

    private func renderToCache(type: DiagramType, source: String, key: String) async {
        log.debug("render begin: type=\(String(describing: type), privacy: .public) key=\(key.prefix(20), privacy: .public)…")
        var image: NSImage? = nil
        switch type {
        case .mermaid:  image = await renderMermaid(source)
        case .plantuml: image = await fetchPlantUML(source)
        }
        if let image {
            log.debug("render ok: key=\(key.prefix(20), privacy: .public)… size=\(image.size.width)x\(image.size.height)")
            cache[key] = image
        } else {
            log.error("render FAILED: type=\(String(describing: type), privacy: .public) key=\(key.prefix(20), privacy: .public)…")
            failedKeys.insert(key)
        }
        let callbacks = inFlight.removeValue(forKey: key) ?? []
        for cb in callbacks { cb() }
    }

    private func renderMermaid(_ source: String) async -> NSImage? {
        log.debug("mermaid: awaiting WKWebView ready (current=\(self.webViewReady))")
        await ensureWebViewLoaded()
        log.debug("mermaid: WKWebView ready=\(self.webViewReady) hasView=\(self.webView != nil)")
        guard let wv = webView else {
            log.error("mermaid: webView is nil after bootstrap")
            return nil
        }
        let js = "renderMermaid(\(jsonString(source)))"
        let outcome: (json: String?, errorDesc: String?) = await withCheckedContinuation { (continuation: CheckedContinuation<(String?, String?), Never>) in
            wv.evaluateJavaScript(js) { result, error in
                continuation.resume(returning: (result as? String, error?.localizedDescription))
            }
        }
        if let errDesc = outcome.errorDesc {
            log.error("mermaid: evaluateJavaScript error: \(errDesc, privacy: .public)")
        }
        guard let jsonStr = outcome.json else {
            log.error("mermaid: evaluateJavaScript returned non-string (or nil)")
            return nil
        }
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log.error("mermaid: response not JSON: \(jsonStr.prefix(200), privacy: .public)")
            return nil
        }
        guard let ok = obj["ok"] as? Bool, ok else {
            let err = (obj["error"] as? String) ?? "unknown"
            log.error("mermaid: render returned ok=false error=\(err, privacy: .public)")
            return nil
        }
        guard let svgStr = obj["svg"] as? String, let svgData = svgStr.data(using: .utf8) else {
            log.error("mermaid: svg missing in response")
            return nil
        }
        guard let img = NSImage(data: svgData) else {
            log.error("mermaid: NSImage(data:) returned nil for \(svgData.count) bytes of SVG (first 80 chars: \(svgStr.prefix(80), privacy: .public))")
            return nil
        }
        if img.size.width == 0 || img.size.height == 0 {
            log.error("mermaid: NSImage has zero size; SVG likely lacks width/height attrs (first 200 chars: \(svgStr.prefix(200), privacy: .public))")
            return nil
        }
        return img
    }

    private func fetchPlantUML(_ source: String) async -> NSImage? {
        guard let encoded = PlantUMLEncoder.encode(source) else { return nil }
        guard let url = URL(string: "https://www.plantuml.com/plantuml/svg/\(encoded)") else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return NSImage(data: data)
        } catch {
            return nil
        }
    }

    // MARK: - WKWebView bootstrap

    private func ensureWebViewLoaded() async {
        if webViewReady { return }
        if webView == nil { startWebViewBootstrap() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if webViewReady { continuation.resume(); return }
            bootstrapWaiters.append { continuation.resume() }
        }
    }

    private func startWebViewBootstrap() {
        log.debug("bootstrap: starting WKWebView")
        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let wv = WKWebView(frame: frame)
        wv.navigationDelegate = self
        webView = wv

        // WebKit suspends the WebContent process for WKWebViews whose layers aren't in
        // the visible compositor (logged as "WebProcess::markAllLayersVolatile"). An
        // off-screen NSWindow at large negative coords is treated as not-visible and
        // suspends the page; we instead place the host window on-screen, behind every
        // other window, and fully transparent.
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.isReleasedWhenClosed = false
        win.alphaValue = 0.0
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        win.contentView?.addSubview(wv)
        win.orderBack(nil)
        hostWindow = win

        guard let resourceDir = Bundle.main.resourceURL,
              let htmlURL = Bundle.main.url(forResource: "diagram-renderer", withExtension: "html") else {
            log.error("bootstrap: diagram-renderer.html resource missing — Mermaid will not render")
            webViewReady = true
            drainBootstrapWaiters()
            return
        }
        log.debug("bootstrap: loading \(htmlURL.lastPathComponent, privacy: .public)")
        wv.loadFileURL(htmlURL, allowingReadAccessTo: resourceDir)
    }

    private func drainBootstrapWaiters() {
        let waiters = bootstrapWaiters
        bootstrapWaiters = []
        for w in waiters { w() }
    }

    // MARK: - Helpers

    private static func cacheKey(type: DiagramType, source: String) -> String {
        let typeStr = type == .mermaid ? "mermaid" : "plantuml"
        let digest = SHA256.hash(data: Data(source.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(typeStr):\(hex)"
    }

    private func jsonString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return "\"\(escaped)\""
    }
}

extension DiagramRenderer: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            log.debug("bootstrap: didFinish — webView ready")
            self.webViewReady = true
            self.drainBootstrapWaiters()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        Task { @MainActor in
            log.error("bootstrap: didFail — \(error.localizedDescription, privacy: .public)")
            self.webViewReady = true
            self.drainBootstrapWaiters()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        Task { @MainActor in
            log.error("bootstrap: didFailProvisionalNavigation — \(error.localizedDescription, privacy: .public)")
            self.webViewReady = true
            self.drainBootstrapWaiters()
        }
    }
}
