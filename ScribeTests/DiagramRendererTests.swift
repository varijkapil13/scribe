import XCTest
@testable import Scribe

final class DiagramRendererTests: XCTestCase {

    func testEmptyBodyReturnsNoBlocks() {
        XCTAssertTrue(DiagramRenderer.extractBlocks(from: "").isEmpty)
    }

    func testPlainTextReturnsNoBlocks() {
        XCTAssertTrue(DiagramRenderer.extractBlocks(from: "Just some text here.").isEmpty)
    }

    func testExtractsSingleMermaidBlock() {
        let body = """
        Some text

        ```mermaid
        graph LR
            A --> B
        ```

        More text
        """
        let blocks = DiagramRenderer.extractBlocks(from: body)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].type, .mermaid)
        XCTAssertEqual(blocks[0].source, "graph LR\n    A --> B")
    }

    func testExtractsSinglePlantUMLBlock() {
        let body = """
        ```plantuml
        @startuml
        A -> B
        @enduml
        ```
        """
        let blocks = DiagramRenderer.extractBlocks(from: body)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].type, .plantuml)
        XCTAssertTrue(blocks[0].source.contains("@startuml"))
    }

    func testExtractsMixedBlocksInOrder() {
        let body = """
        ```mermaid
        graph TD
            A --> B
        ```

        Some text between diagrams.

        ```plantuml
        @startuml
        A -> B
        @enduml
        ```
        """
        let blocks = DiagramRenderer.extractBlocks(from: body)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].type, .mermaid)
        XCTAssertEqual(blocks[1].type, .plantuml)
    }

    func testUnterminatedBlockIsIgnored() {
        let body = """
        ```mermaid
        graph LR
            A --> B
        """
        XCTAssertTrue(DiagramRenderer.extractBlocks(from: body).isEmpty)
    }

    func testSourceIsStrippedOfLeadingAndTrailingNewlines() {
        let body = "```mermaid\n\ngraph LR\n    A --> B\n\n```"
        let blocks = DiagramRenderer.extractBlocks(from: body)
        XCTAssertFalse(blocks[0].source.hasPrefix("\n"))
        XCTAssertFalse(blocks[0].source.hasSuffix("\n"))
    }

    // MARK: - Cache key & extractBlocks shape

    func testExtractBlocksReturnsFullTextAndRange() {
        let body = "before\n```mermaid\ngraph LR\n  A-->B\n```\nafter"
        let blocks = DiagramRenderer.extractBlocks(from: body)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].fullText, "```mermaid\ngraph LR\n  A-->B\n```")
        // nsRange should cover the full fence
        let nsBody = body as NSString
        XCTAssertEqual(nsBody.substring(with: blocks[0].nsRange), blocks[0].fullText)
    }

    @MainActor
    func testImageReturnsNilForUncachedSourceAndDoesNotCrash() {
        // Simply asserts the API is callable on the singleton; render itself depends
        // on a real WKWebView/network, so we don't await here.
        let image = DiagramRenderer.shared.image(type: .mermaid, source: "graph TD\n A-->B", onReady: {})
        XCTAssertNil(image, "first call for an uncached source should return nil")
    }
}
