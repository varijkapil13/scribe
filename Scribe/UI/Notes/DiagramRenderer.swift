// Scribe/UI/Notes/DiagramRenderer.swift
import Foundation
import Combine
import WebKit

enum DiagramType: Equatable {
    case mermaid
    case plantuml
}

struct DiagramBlock: Equatable {
    let type: DiagramType
    let source: String
}

@MainActor
final class DiagramRenderer: ObservableObject {

    @Published var renderedHTML: String = ""

    private var cancellable: AnyCancellable?
    private weak var webView: WKWebView?

    // MARK: - Public

    /// Attach to a note body publisher; renders after 500ms debounce.
    func bind(bodyPublisher: AnyPublisher<String, Never>, webView: WKWebView) {
        self.webView = webView
        cancellable = bodyPublisher
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] text in
                guard let self else { return }
                let blocks = Self.extractBlocks(from: text)
                Task { await self.renderBlocks(blocks) }
            }
    }

    /// Parses fenced ```mermaid and ```plantuml blocks. Pure function — no side effects.
    nonisolated static func extractBlocks(from body: String) -> [DiagramBlock] {
        guard let regex = try? NSRegularExpression(
            pattern: #"```(mermaid|plantuml)\n([\s\S]*?)```"#
        ) else { return [] }

        var blocks: [DiagramBlock] = []
        let fullRange = NSRange(body.startIndex..., in: body)

        for match in regex.matches(in: body, range: fullRange) {
            guard match.numberOfRanges == 3,
                  let typeRange   = Range(match.range(at: 1), in: body),
                  let sourceRange = Range(match.range(at: 2), in: body) else { continue }

            let typeStr = String(body[typeRange])
            let source  = String(body[sourceRange]).trimmingCharacters(in: .newlines)
            let type: DiagramType = typeStr == "mermaid" ? .mermaid : .plantuml
            blocks.append(DiagramBlock(type: type, source: source))
        }
        return blocks
    }

    // MARK: - Private rendering

    private func renderBlocks(_ blocks: [DiagramBlock]) async {
        guard !blocks.isEmpty else {
            renderedHTML = ""
            return
        }

        var parts: [String] = []
        for block in blocks {
            switch block.type {
            case .mermaid:
                let svg = await renderMermaid(block.source)
                parts.append(svg ?? "<p class='error'>Mermaid render failed</p>")
            case .plantuml:
                let svg = await fetchPlantUMLSVG(block.source)
                parts.append(svg ?? "<p class='error'>PlantUML unavailable (check internet)</p>")
            }
        }

        let html = parts.joined(separator: "\n<hr>\n")
        webView?.evaluateJavaScript("setContent(\(jsonString(html)))") { _, _ in }
        renderedHTML = html
    }

    private func renderMermaid(_ source: String) async -> String? {
        guard let wv = webView else { return nil }
        let escaped = jsonString(source)
        let js = "renderMermaid(\(escaped))"
        return await withCheckedContinuation { continuation in
            wv.evaluateJavaScript(js) { result, _ in
                guard let jsonStr = result as? String,
                      let data = jsonStr.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let ok = obj["ok"] as? Bool, ok,
                      let svg = obj["svg"] as? String else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: svg)
            }
        }
    }

    private func fetchPlantUMLSVG(_ source: String) async -> String? {
        guard let encoded = PlantUMLEncoder.encode(source) else { return nil }
        let urlString = "https://www.plantuml.com/plantuml/svg/\(encoded)"
        guard let url = URL(string: urlString) else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private func jsonString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }
}
