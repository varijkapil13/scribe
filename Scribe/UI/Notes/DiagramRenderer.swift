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

    nonisolated private static let blockRegex = try? NSRegularExpression(
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
        // callAsyncJavaScript awaits the Promise returned by __scribeRender and bridges
        // the resulting Dictionary back to Swift. The wrapper rasterizes mermaid's SVG
        // to PNG via canvas because NSImage's SVG parser doesn't support CSS variables.
        let result: Any?
        do {
            result = try await wv.callAsyncJavaScript(
                "return await __scribeRender(source)",
                arguments: ["source": source],
                in: nil,
                contentWorld: .page
            )
        } catch {
            log.error("mermaid: callAsyncJavaScript threw: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let dict = result as? [String: Any] else {
            log.error("mermaid: callAsyncJavaScript returned non-dictionary (\(String(describing: result), privacy: .public))")
            return nil
        }
        guard let ok = dict["ok"] as? Bool, ok else {
            let err = (dict["error"] as? String) ?? "unknown"
            if let diag = dict["diag"] as? [String: Any] {
                let diagStr = (try? JSONSerialization.data(withJSONObject: diag, options: []))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "?"
                log.error("mermaid: render returned ok=false error=\(err, privacy: .public) diag=\(diagStr, privacy: .public)")
            } else {
                log.error("mermaid: render returned ok=false error=\(err, privacy: .public)")
            }
            return nil
        }
        guard let pngBase64 = dict["png"] as? String,
              let pngData = Data(base64Encoded: pngBase64) else {
            log.error("mermaid: png missing or not base64 in response")
            return nil
        }
        guard let img = NSImage(data: pngData) else {
            log.error("mermaid: NSImage(data:) returned nil for \(pngData.count) bytes of PNG")
            return nil
        }
        // Use the logical SVG dimensions for layout; the PNG itself is at 2x for retina.
        if let w = (dict["w"] as? Double).map({ CGFloat($0) }),
           let h = (dict["h"] as? Double).map({ CGFloat($0) }),
           w > 0, h > 0 {
            img.size = NSSize(width: w, height: h)
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

        // We previously tried `WKUserScript(injectionTime: .atDocumentStart)` to inject the
        // mermaid bundle, but on a headless WKWebView the user script silently fails to
        // run (`scriptStart` never goes true). Instead, the bundle is injected via
        // `evaluateJavaScript` from `didFinish` (see WKNavigationDelegate below) — that
        // path is well-exercised because we use it for the render call itself.
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
            log.debug("bootstrap: didFinish — injecting mermaid bundle via evaluateJavaScript")
            await self.injectMermaidBundle(into: webView)
            log.debug("bootstrap: bundle injected — webView ready")
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

    @MainActor
    private func injectMermaidBundle(into webView: WKWebView) async {
        // Order matters: elk MUST run first so `window.ELK` exists before the mermaid
        // bundle's `var ELKBundled = window.ELK` aliasing executes.
        await injectScript(named: "elk.bundled", into: webView, label: "elk")
        await injectScript(named: "beautiful-mermaid", into: webView, label: "mermaid")
    }

    @MainActor
    private func injectScript(named resourceName: String, into webView: WKWebView, label: String) async {
        guard let jsURL = Bundle.main.url(forResource: resourceName, withExtension: "js"),
              let jsSource = try? String(contentsOf: jsURL, encoding: .utf8) else {
            log.error("inject(\(label, privacy: .public)): \(resourceName, privacy: .public).js missing from bundle")
            return
        }
        log.debug("inject(\(label, privacy: .public)): evaluating \(resourceName, privacy: .public).js (\(jsSource.count) chars)")
        // Trailing `null;` ensures evaluateJavaScript can bridge a result type back
        // to Swift even when the last expression in the script is a function value.
        let evalScript = jsSource + "\n;null;"
        let errDesc: String? = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            webView.evaluateJavaScript(evalScript) { _, error in
                continuation.resume(returning: error?.localizedDescription)
            }
        }
        if let errDesc {
            log.error("inject(\(label, privacy: .public)): evaluation threw — \(errDesc, privacy: .public)")
        } else {
            log.debug("inject(\(label, privacy: .public)): evaluation succeeded")
        }
    }
}
