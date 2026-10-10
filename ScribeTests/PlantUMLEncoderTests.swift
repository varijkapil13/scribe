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

/// Remote PlantUML rendering sends diagram source to plantuml.com, so it must
/// be strictly opt-in.
final class PlantUMLRenderingPreferenceTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        let name = "PlantUMLRenderingPreferenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testRemoteRenderingIsOffByDefault() {
        XCTAssertFalse(PlantUMLRenderingPreference.defaultValue)
        XCTAssertFalse(PlantUMLRenderingPreference.isRemoteEnabled(in: freshDefaults()))
    }

    func testRemoteRenderingHonoursExplicitOptIn() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: PlantUMLRenderingPreference.remoteEnabledKey)
        XCTAssertTrue(PlantUMLRenderingPreference.isRemoteEnabled(in: defaults))
        defaults.set(false, forKey: PlantUMLRenderingPreference.remoteEnabledKey)
        XCTAssertFalse(PlantUMLRenderingPreference.isRemoteEnabled(in: defaults))
    }

    func testConfigScriptEmbedsLiteralBoolean() {
        let on = PlantUMLRenderingPreference.configScript(remoteEnabled: true)
        let off = PlantUMLRenderingPreference.configScript(remoteEnabled: false)
        XCTAssertTrue(on.contains("window.scribeConfig"))
        XCTAssertTrue(on.contains("plantUMLRemote: true"))
        XCTAssertTrue(off.contains("plantUMLRemote: false"))
        XCTAssertFalse(off.contains("true"))
    }

    func testSetRemoteScriptCallsBridgeFunction() {
        let script = PlantUMLRenderingPreference.setRemoteScript(remoteEnabled: false)
        XCTAssertTrue(script.contains("window.scribeSetPlantUMLRemote(false)"))
    }
}
