import Foundation

// Pure, side-effect-free helpers backing the MCP server's HTTP transport.
// Nothing here touches the network, the Keychain or the main actor, so every
// rule (port sanitising, request parsing, origin/host/token checks) is unit
// tested directly in ScribeTests/MCPSecurityTests.swift.

// MARK: - Port policy

/// Validation for the user-configurable MCP port. The stored value is a plain
/// `Int` in UserDefaults, so it can hold anything (0 when unset, a negative
/// number or > 65535 if edited by hand). Converting that with `UInt16(_:)`
/// traps; everything goes through here instead.
enum MCPPortPolicy {
    static let defaultPort: UInt16 = 3333
    /// Unprivileged TCP ports only.
    static let allowedRange: ClosedRange<Int> = 1024...65535

    /// The port as a `UInt16` when it is inside `allowedRange`, else nil.
    static func validated(_ raw: Int) -> UInt16? {
        guard allowedRange.contains(raw) else { return nil }
        return UInt16(exactly: raw)
    }

    /// Parses user-typed text ("3333", " 8080 ") into a valid port.
    static func validated(text: String) -> UInt16? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(trimmed) else { return nil }
        return validated(value)
    }

    /// Never traps: any invalid stored value falls back to `defaultPort`.
    static func sanitize(_ raw: Int) -> UInt16 {
        validated(raw) ?? defaultPort
    }
}

// MARK: - HTTP request parsing

/// A fully received HTTP/1.x request (headers plus exactly `Content-Length`
/// body bytes).
struct MCPHTTPRequest: Equatable, Sendable {
    let method: String
    /// The raw request-target, including any query string.
    let target: String
    /// Header names are lower-cased. Repeated headers are joined with ", "
    /// (RFC 9110 §5.3), which makes a duplicated Host / Content-Length fail
    /// validation instead of silently picking one.
    let headers: [String: String]
    let body: Data

    /// The request-target without its query string.
    var path: String {
        if let q = target.firstIndex(of: "?") { return String(target[..<q]) }
        return target
    }

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    /// Percent-decoded value of the first `key=value` pair in the query.
    func queryValue(_ key: String) -> String? {
        guard let q = target.firstIndex(of: "?") else { return nil }
        let query = target[target.index(after: q)...]
        for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let name = String(pair[..<eq])
            guard name == key else { continue }
            let raw = String(pair[pair.index(after: eq)...])
            return raw.removingPercentEncoding ?? raw
        }
        return nil
    }
}

enum MCPHTTPError: Error, Equatable, Sendable {
    case malformed
    case headersTooLarge
    case bodyTooLarge
    case unsupportedTransferEncoding

    /// HTTP status line fragment used when rejecting the request.
    var status: String {
        switch self {
        case .malformed:                   return "400 Bad Request"
        case .headersTooLarge:             return "431 Request Header Fields Too Large"
        case .bodyTooLarge:                return "413 Content Too Large"
        case .unsupportedTransferEncoding: return "501 Not Implemented"
        }
    }
}

enum MCPHTTPParseResult: Equatable, Sendable {
    /// More bytes are needed (headers or body not yet complete).
    case incomplete
    case complete(MCPHTTPRequest)
    case invalid(MCPHTTPError)
}

enum MCPHTTPParser {
    static let defaultMaxHeaderBytes = 16 * 1024
    static let defaultMaxBodyBytes = 4 * 1024 * 1024

    private static let headerTerminator = Data([13, 10, 13, 10]) // \r\n\r\n

    /// Parses the bytes received so far on a connection. Returns `.incomplete`
    /// until the header block and `Content-Length` body bytes have all
    /// arrived; callers keep accumulating and re-parse.
    static func parse(_ data: Data,
                      maxHeaderBytes: Int = defaultMaxHeaderBytes,
                      maxBodyBytes: Int = defaultMaxBodyBytes) -> MCPHTTPParseResult {
        guard let separator = data.range(of: headerTerminator) else {
            return data.count > maxHeaderBytes ? .invalid(.headersTooLarge) : .incomplete
        }
        let headerByteCount = data.distance(from: data.startIndex, to: separator.lowerBound)
        guard headerByteCount <= maxHeaderBytes else { return .invalid(.headersTooLarge) }

        guard let headerText = String(data: data[data.startIndex..<separator.lowerBound], encoding: .utf8)
        else { return .invalid(.malformed) }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .invalid(.malformed) }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              !parts[0].isEmpty, !parts[1].isEmpty,
              parts[2].hasPrefix("HTTP/1.")
        else { return .invalid(.malformed) }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .invalid(.malformed) }
            let name = line[..<colon].lowercased()
            // Whitespace before the colon is forbidden (RFC 9112 §5.1).
            guard !name.isEmpty, !name.contains(" "), !name.contains("\t") else {
                return .invalid(.malformed)
            }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }

        // Chunked / other transfer codings are not supported; refusing them
        // also rules out Content-Length vs Transfer-Encoding ambiguity.
        if headers["transfer-encoding"] != nil { return .invalid(.unsupportedTransferEncoding) }

        var contentLength = 0
        if let rawLength = headers["content-length"] {
            guard !rawLength.isEmpty,
                  rawLength.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let parsed = Int(rawLength)
            else { return .invalid(.malformed) }
            contentLength = parsed
        }
        guard contentLength <= maxBodyBytes else { return .invalid(.bodyTooLarge) }

        let available = data.distance(from: separator.upperBound, to: data.endIndex)
        guard available >= contentLength else { return .incomplete }

        let bodyEnd = data.index(separator.upperBound, offsetBy: contentLength)
        let body = Data(data[separator.upperBound..<bodyEnd])
        return .complete(MCPHTTPRequest(method: parts[0], target: parts[1],
                                        headers: headers, body: body))
    }
}

// MARK: - Request guard

/// Security checks applied to every request before it is routed.
enum MCPRequestGuard {

    enum Rejection: Equatable, Sendable {
        /// The request came from a browser page (it carries an Origin header).
        case forbiddenOrigin
        /// Host header is not 127.0.0.1:<port> / localhost:<port> (DNS rebinding).
        case invalidHost
        /// Missing or wrong bearer token.
        case unauthorized
        /// POST body is not declared as application/json.
        case unsupportedMediaType

        var status: String {
            switch self {
            case .forbiddenOrigin:      return "403 Forbidden"
            case .invalidHost:          return "400 Bad Request"
            case .unauthorized:         return "401 Unauthorized"
            case .unsupportedMediaType: return "415 Unsupported Media Type"
            }
        }

        var message: String {
            switch self {
            case .forbiddenOrigin:      return "cross-origin requests are not allowed"
            case .invalidHost:          return "invalid Host header"
            case .unauthorized:         return "missing or invalid bearer token"
            case .unsupportedMediaType: return "Content-Type must be application/json"
            }
        }
    }

    /// Browsers always attach Origin to cross-site fetches; native MCP clients
    /// don't. Only requests without one are accepted.
    static func isAllowedOrigin(_ origin: String?) -> Bool {
        origin == nil
    }

    /// DNS-rebinding defence: the Host header must name the loopback listener.
    static func isAllowedHost(_ host: String?, port: UInt16) -> Bool {
        guard let host = host?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return host == "127.0.0.1:\(port)" || host == "localhost:\(port)"
    }

    /// Extracts the token from an `Authorization: Bearer <token>` value.
    static func bearerToken(fromAuthorization value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces),
              let space = value.firstIndex(of: " ") else { return nil }
        let scheme = value[..<space]
        guard scheme.lowercased() == "bearer" else { return nil }
        let token = value[value.index(after: space)...].trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }

    /// The token the client presented: the Authorization header wins; the
    /// `?token=` query parameter is accepted for SSE clients that cannot set
    /// headers. `viaQuery` tells the server to echo the token into the POST
    /// endpoint URL it hands back.
    static func presentedToken(in request: MCPHTTPRequest) -> (token: String, viaQuery: Bool)? {
        if let header = request.header("authorization") {
            guard let token = bearerToken(fromAuthorization: header) else { return nil }
            return (token, false)
        }
        if let token = request.queryValue("token"), !token.isEmpty {
            return (token, true)
        }
        return nil
    }

    /// Constant-time comparison (no early exit on the first differing byte).
    static func tokensMatch(_ presented: String, _ expected: String) -> Bool {
        let a = Array(presented.utf8)
        let b = Array(expected.utf8)
        guard !b.isEmpty, a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    /// True for `application/json`, optionally with parameters
    /// (`application/json; charset=utf-8`).
    static func isJSONContentType(_ value: String?) -> Bool {
        guard let value else { return false }
        let mediaType = value.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        return mediaType == "application/json"
    }

    /// Runs every check in order (origin, host, token, media type). Returns
    /// nil when the request may be routed.
    static func validate(_ request: MCPHTTPRequest, port: UInt16, expectedToken: String) -> Rejection? {
        guard isAllowedOrigin(request.header("origin")) else { return .forbiddenOrigin }
        guard isAllowedHost(request.header("host"), port: port) else { return .invalidHost }
        guard let presented = presentedToken(in: request),
              tokensMatch(presented.token, expectedToken)
        else { return .unauthorized }
        if request.method == "POST", !isJSONContentType(request.header("content-type")) {
            return .unsupportedMediaType
        }
        return nil
    }
}

// MARK: - Token generation

enum MCPTokenGenerator {
    /// 32 random bytes → 43-character base64url token.
    static let defaultByteCount = 32

    /// `SystemRandomNumberGenerator` is backed by the OS CSPRNG
    /// (arc4random_buf) on Apple platforms.
    static func generate(byteCount: Int = defaultByteCount) -> String {
        var rng = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: max(byteCount, 1))
        for i in bytes.indices { bytes[i] = UInt8.random(in: UInt8.min...UInt8.max, using: &rng) }
        return base64URLEncode(Data(bytes))
    }

    /// RFC 4648 §5 base64url without padding.
    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Client config snippet

enum MCPClientConfig {
    static func sseURL(port: UInt16) -> String {
        "http://127.0.0.1:\(port)/sse"
    }

    /// JSON snippet for an MCP client config (`mcpServers` block).
    static func snippet(port: UInt16, token: String) -> String {
        """
        {
          "mcpServers": {
            "scribe": {
              "type": "sse",
              "url": "\(sseURL(port: port))",
              "headers": {
                "Authorization": "Bearer \(token)"
              }
            }
          }
        }
        """
    }

    /// For clients that cannot send headers on the SSE request.
    static func urlWithToken(port: UInt16, token: String) -> String {
        "\(sseURL(port: port))?token=\(token)"
    }
}
