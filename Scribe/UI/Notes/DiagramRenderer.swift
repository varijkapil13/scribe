// Scribe/UI/Notes/DiagramRenderer.swift
import AppKit
import Foundation
import Combine
import CryptoKit
import WebKit

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

    // MARK: - Public API (legacy — Task 9 deletes this)

    private var legacyCancellable: AnyCancellable?

    func bind(bodyPublisher: AnyPublisher<String, Never>, webView: WKWebView) {
        legacyCancellable = bodyPublisher
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in _ = self  /* no-op during migration */ }
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
        var image: NSImage? = nil
        switch type {
        case .mermaid:  image = await renderMermaid(source)
        case .plantuml: image = await fetchPlantUML(source)
        }
        if let image {
            cache[key] = image
        } else {
            failedKeys.insert(key)
        }
        let callbacks = inFlight.removeValue(forKey: key) ?? []
        for cb in callbacks { cb() }
    }

    private func renderMermaid(_ source: String) async -> NSImage? {
        await ensureWebViewLoaded()
        guard let wv = webView else { return nil }
        let js = "renderMermaid(\(jsonString(source)))"
        let svg: String? = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            wv.evaluateJavaScript(js) { result, _ in
                guard let jsonStr = result as? String,
                      let data = jsonStr.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let ok = obj["ok"] as? Bool, ok,
                      let svgStr = obj["svg"] as? String else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: svgStr)
            }
        }
        guard let svg, let data = svg.data(using: .utf8) else { return nil }
        return NSImage(data: data)
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
        let wv = WKWebView(frame: .zero)
        wv.navigationDelegate = self
        webView = wv
        guard let resourceDir = Bundle.main.resourceURL,
              let htmlURL = Bundle.main.url(forResource: "diagram-renderer", withExtension: "html") else {
            // Resource missing — fail all waiters with no-op so callers move on.
            webViewReady = true
            drainBootstrapWaiters()
            return
        }
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
            self.webViewReady = true
            self.drainBootstrapWaiters()
        }
    }
}
