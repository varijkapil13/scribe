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
}
