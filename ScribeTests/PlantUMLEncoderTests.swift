import XCTest
@testable import Scribe

final class PlantUMLEncoderTests: XCTestCase {

    func testEncodeReturnsNonNil() {
        let source = "@startuml\nA -> B: hello\n@enduml"
        XCTAssertNotNil(PlantUMLEncoder.encode(source))
    }

    func testEncodedStringUsesValidAlphabet() {
        let source = "@startuml\nA -> B\n@enduml"
        guard let encoded = PlantUMLEncoder.encode(source) else {
            return XCTFail("encode returned nil")
        }
        let validChars = CharacterSet(charactersIn: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-_")
        XCTAssertTrue(encoded.unicodeScalars.allSatisfy { validChars.contains($0) },
                      "Encoded string contains invalid characters: \(encoded)")
    }

    func testEncodedLengthIsMultipleOfFour() {
        let source = "@startuml\nA -> B: test\n@enduml"
        guard let encoded = PlantUMLEncoder.encode(source) else {
            return XCTFail("encode returned nil")
        }
        XCTAssertEqual(encoded.count % 4, 0, "PlantUML base64 encodes 3 bytes → 4 chars")
    }

    func testEmptyStringEncodesWithoutCrash() {
        XCTAssertNotNil(PlantUMLEncoder.encode(""))
    }

    func testKnownDiagramProducesNonEmptyEncoding() {
        let source = """
        @startuml
        Alice -> Bob: Authentication Request
        Bob --> Alice: Authentication Response
        @enduml
        """
        let encoded = PlantUMLEncoder.encode(source)
        XCTAssertNotNil(encoded)
        XCTAssertGreaterThan(encoded?.count ?? 0, 10)
    }
}
