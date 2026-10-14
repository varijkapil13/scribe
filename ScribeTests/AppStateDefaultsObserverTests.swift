import XCTest
@testable import Scribe

@MainActor
final class AppStateDefaultsObserverTests: XCTestCase {

    func testDefaultsWriteFromBackgroundThreadDoesNotTrapMainActorObservers() async throws {
        let manager = try DatabaseManager(path: ":memory:")
        let state = AppState(transcriptStore: TranscriptStore(databaseManager: manager))
        let key = "scribe.tests.backgroundDefaultsWrite"
        defer { UserDefaults.standard.removeObject(forKey: key) }

        await Task.detached {
            UserDefaults.standard.set(UUID().uuidString, forKey: key)
        }.value
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertNil(state.lastError)
    }
}
