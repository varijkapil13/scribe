import Foundation
import Security

/// Persists the MCP bearer token in the login Keychain as a generic password
/// (service `com.varij.scribe.mcp`). The token is generated on first use and
/// only changes when the user regenerates it in Settings → MCP.
///
/// If the Keychain is unavailable the token still works for this launch (it
/// is cached in memory); it just won't survive a restart.
@MainActor
enum MCPTokenStore {

    static let service = "com.varij.scribe.mcp"
    static let account = "bearer-token"

    private static var cached: String?

    /// The current token, creating and storing one if none exists yet.
    static func loadOrCreate() -> String {
        if let cached { return cached }
        if let stored = readFromKeychain(), !stored.isEmpty {
            cached = stored
            return stored
        }
        return regenerate()
    }

    /// Replaces the token with a fresh random one and returns it.
    @discardableResult
    static func regenerate() -> String {
        let token = MCPTokenGenerator.generate()
        _ = writeToKeychain(token)
        cached = token
        return token
    }

    // MARK: - Keychain

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func readFromKeychain() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8)
        else { return nil }
        return token
    }

    private static func writeToKeychain(_ token: String) -> Bool {
        let data = Data(token.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery() as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else {
            Log.app.error("MCP token Keychain update failed: \(status, privacy: .public)")
            return false
        }

        var add = baseQuery()
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Scribe MCP server token"
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus != errSecSuccess {
            Log.app.error("MCP token Keychain add failed: \(addStatus, privacy: .public)")
        }
        return addStatus == errSecSuccess
    }
}
