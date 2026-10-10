import XCTest
@testable import Scribe

/// Liquid Glass accessibility policy, the menu-bar hint decision, and the
/// String Catalog / asset catalog files the Xcode target ships.
final class DesignPolishTests: XCTestCase {

    // MARK: - Glass policy

    func testGlassFallsBackToOpaqueUnderReduceTransparencyOrIncreasedContrast() {
        XCTAssertFalse(ScribeGlassPolicy.prefersOpaque(reduceTransparency: false, increasedContrast: false))
        XCTAssertTrue(ScribeGlassPolicy.prefersOpaque(reduceTransparency: true, increasedContrast: false))
        XCTAssertTrue(ScribeGlassPolicy.prefersOpaque(reduceTransparency: false, increasedContrast: true))
        XCTAssertTrue(ScribeGlassPolicy.prefersOpaque(reduceTransparency: true, increasedContrast: true))
    }

    // MARK: - Menu bar hint

    func testMenuBarHintOnlyWhenWantedHiddenAndNotYetShown() {
        XCTAssertTrue(MenuBarHintPolicy.shouldShow(prefersIcon: true, visibility: .hidden, alreadyShown: false))
        XCTAssertFalse(MenuBarHintPolicy.shouldShow(prefersIcon: true, visibility: .hidden, alreadyShown: true))
        XCTAssertFalse(MenuBarHintPolicy.shouldShow(prefersIcon: false, visibility: .hidden, alreadyShown: false))
        XCTAssertFalse(MenuBarHintPolicy.shouldShow(prefersIcon: true, visibility: .visible, alreadyShown: false))
        XCTAssertFalse(MenuBarHintPolicy.shouldShow(prefersIcon: true, visibility: .unknown, alreadyShown: false))
    }

    // MARK: - Resource files

    /// Repo root, derived from this file's location (ScribeTests/<file>).
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func loadJSON(_ relativePath: String) throws -> [String: Any] {
        let url = repoRoot.appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any], "\(relativePath) is not a JSON object")
    }

    func testStringCatalogGermanEntriesAreNonEmpty() throws {
        let catalog = try loadJSON("Scribe/Resources/Localizable.xcstrings")
        XCTAssertEqual(catalog["sourceLanguage"] as? String, "en")
        XCTAssertEqual(catalog["version"] as? String, "1.0")
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        XCTAssertGreaterThanOrEqual(strings.count, 60)

        var germanCount = 0
        for (key, value) in strings {
            guard let entry = value as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any],
                  let german = localizations["de"] as? [String: Any] else { continue }
            germanCount += 1
            let unit = german["stringUnit"] as? [String: Any]
            let text = (unit?["value"] as? String) ?? ""
            XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "Empty German translation for \"\(key)\"")
            // Format specifiers must survive translation one-for-one.
            XCTAssertEqual(key.components(separatedBy: "%@").count,
                           text.components(separatedBy: "%@").count,
                           "Placeholder mismatch for \"\(key)\"")
        }
        XCTAssertGreaterThanOrEqual(germanCount, 60)
    }

    func testAccentColorAssetHasLightAndDarkVariants() throws {
        let colorset = try loadJSON("Scribe/Resources/Assets.xcassets/AccentColor.colorset/Contents.json")
        let colors = try XCTUnwrap(colorset["colors"] as? [[String: Any]])
        XCTAssertEqual(colors.count, 2)
        let hasDark = colors.contains { color in
            let appearances = color["appearances"] as? [[String: String]] ?? []
            return appearances.contains { $0["value"] == "dark" }
        }
        XCTAssertTrue(hasDark)
    }

    func testMenuBarImageSetsAreTemplates() throws {
        for name in ["MenuBarIcon", "MenuBarIconPaused", "MenuBarIconRecording"] {
            let contents = try loadJSON("Scribe/Resources/Assets.xcassets/\(name).imageset/Contents.json")
            let properties = contents["properties"] as? [String: Any]
            XCTAssertEqual(properties?["template-rendering-intent"] as? String, "template", name)
        }
    }
}
