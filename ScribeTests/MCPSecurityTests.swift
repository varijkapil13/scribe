// ScribeTests/MCPSecurityTests.swift
import XCTest
@testable import Scribe

final class MCPSecurityTests: XCTestCase {

    private let token = "abcDEF123_-xyz"
    private let port: UInt16 = 3333

    // MARK: - Helpers

    private struct NotComplete: Error {}

    private func raw(_ lines: [String], body: String = "") -> Data {
        Data((lines.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8)
    }

    private func parsed(_ data: Data, file: StaticString = #filePath, line: UInt = #line) throws -> MCPHTTPRequest {
        guard case .complete(let req) = MCPHTTPParser.parse(data) else {
            XCTFail("expected a complete request, got \(MCPHTTPParser.parse(data))", file: file, line: line)
            throw NotComplete()
        }
        return req
    }

    private func request(method: String = "GET",
                         target: String = "/sse",
                         headers: [String: String]) -> MCPHTTPRequest {
        var lower: [String: String] = [:]
        for (k, v) in headers { lower[k.lowercased()] = v }
        return MCPHTTPRequest(method: method, target: target, headers: lower, body: Data())
    }

    private var goodHeaders: [String: String] {
        ["Host": "127.0.0.1:3333", "Authorization": "Bearer \(token)"]
    }

    // MARK: - Port policy

    func testPortSanitizeFallsBackForInvalidValues() {
        XCTAssertEqual(MCPPortPolicy.sanitize(0), 3333)
        XCTAssertEqual(MCPPortPolicy.sanitize(-1), 3333)
        XCTAssertEqual(MCPPortPolicy.sanitize(80), 3333)
        XCTAssertEqual(MCPPortPolicy.sanitize(1023), 3333)
        XCTAssertEqual(MCPPortPolicy.sanitize(65_536), 3333)
        XCTAssertEqual(MCPPortPolicy.sanitize(70_000), 3333)
        XCTAssertEqual(MCPPortPolicy.sanitize(Int.max), 3333)
        XCTAssertEqual(MCPPortPolicy.sanitize(Int.min), 3333)
    }

    func testPortSanitizeKeepsValidValues() {
        XCTAssertEqual(MCPPortPolicy.sanitize(1024), 1024)
        XCTAssertEqual(MCPPortPolicy.sanitize(8080), 8080)
        XCTAssertEqual(MCPPortPolicy.sanitize(65_535), 65_535)
    }

    func testPortTextValidation() {
        XCTAssertEqual(MCPPortPolicy.validated(text: "4000"), 4000)
        XCTAssertEqual(MCPPortPolicy.validated(text: " 4000 "), 4000)
        XCTAssertNil(MCPPortPolicy.validated(text: ""))
        XCTAssertNil(MCPPortPolicy.validated(text: "abc"))
        XCTAssertNil(MCPPortPolicy.validated(text: "-4000"))
        XCTAssertNil(MCPPortPolicy.validated(text: "+4000"))
        XCTAssertNil(MCPPortPolicy.validated(text: "40.0"))
        XCTAssertNil(MCPPortPolicy.validated(text: "99999999999999999999999"))
        XCTAssertNil(MCPPortPolicy.validated(text: "100"))
    }

    // MARK: - Parser

    func testParsesCompleteGet() throws {
        let req = try parsed(raw(["GET /sse?token=abc HTTP/1.1", "Host: 127.0.0.1:3333", "X-Thing:  spaced  "]))
        XCTAssertEqual(req.method, "GET")
        XCTAssertEqual(req.target, "/sse?token=abc")
        XCTAssertEqual(req.path, "/sse")
        XCTAssertEqual(req.header("HOST"), "127.0.0.1:3333")
        XCTAssertEqual(req.header("x-thing"), "spaced")
        XCTAssertEqual(req.queryValue("token"), "abc")
        XCTAssertNil(req.queryValue("missing"))
        XCTAssertEqual(req.body, Data())
    }

    func testIncompleteHeadersNeedMoreData() {
        let partial = Data("GET /sse HTTP/1.1\r\nHost: 127.0.0.1:3333\r\n".utf8)
        XCTAssertEqual(MCPHTTPParser.parse(partial), .incomplete)
    }

    func testBodyIsAccumulatedUntilContentLengthArrives() throws {
        let body = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
        let full = raw(["POST /message?sessionId=x HTTP/1.1",
                        "Host: localhost:3333",
                        "Content-Type: application/json",
                        "Content-Length: \(body.utf8.count)"], body: body)

        // Every strict prefix that includes the header terminator is incomplete.
        let headerLength = full.count - body.utf8.count
        for cut in headerLength..<full.count {
            XCTAssertEqual(MCPHTTPParser.parse(full.prefix(cut)), .incomplete, "cut at \(cut)")
        }
        let req = try parsed(full)
        XCTAssertEqual(String(data: req.body, encoding: .utf8), body)
        XCTAssertEqual(req.queryValue("sessionId"), "x")
    }

    func testBodyWithMultibyteCharactersUsesByteCount() throws {
        let body = #"{"title":"Café ☕️"}"#
        let req = try parsed(raw(["POST /message HTTP/1.1", "Content-Length: \(body.utf8.count)"], body: body))
        XCTAssertEqual(String(data: req.body, encoding: .utf8), body)
    }

    func testExtraBytesBeyondContentLengthAreIgnored() throws {
        let req = try parsed(raw(["POST /message HTTP/1.1", "Content-Length: 2"], body: "{}garbage"))
        XCTAssertEqual(req.body, Data("{}".utf8))
    }

    func testOversizedBodyIsRejectedBeforeItArrives() {
        let data = raw(["POST /message HTTP/1.1",
                        "Content-Length: \(MCPHTTPParser.defaultMaxBodyBytes + 1)"])
        XCTAssertEqual(MCPHTTPParser.parse(data), .invalid(.bodyTooLarge))
    }

    func testOversizedHeadersAreRejected() {
        let noTerminator = Data(repeating: UInt8(ascii: "a"), count: 100)
        XCTAssertEqual(MCPHTTPParser.parse(noTerminator, maxHeaderBytes: 50), .invalid(.headersTooLarge))
        let terminated = raw(["GET /sse HTTP/1.1", "X: " + String(repeating: "a", count: 100)])
        XCTAssertEqual(MCPHTTPParser.parse(terminated, maxHeaderBytes: 50), .invalid(.headersTooLarge))
    }

    func testMalformedRequestsAreRejected() {
        XCTAssertEqual(MCPHTTPParser.parse(raw(["GARBAGE"])), .invalid(.malformed))
        XCTAssertEqual(MCPHTTPParser.parse(raw(["GET /sse"])), .invalid(.malformed))
        XCTAssertEqual(MCPHTTPParser.parse(raw(["GET /sse FTP/1.0"])), .invalid(.malformed))
        XCTAssertEqual(MCPHTTPParser.parse(raw(["GET /sse HTTP/1.1", "NoColonHere"])), .invalid(.malformed))
        XCTAssertEqual(MCPHTTPParser.parse(raw(["GET /sse HTTP/1.1", "Host : x"])), .invalid(.malformed))
        XCTAssertEqual(MCPHTTPParser.parse(raw(["POST /m HTTP/1.1", "Content-Length: -1"])), .invalid(.malformed))
        XCTAssertEqual(MCPHTTPParser.parse(raw(["POST /m HTTP/1.1", "Content-Length: abc"])), .invalid(.malformed))
        // Conflicting duplicate Content-Length headers join to "1, 2" → malformed.
        XCTAssertEqual(MCPHTTPParser.parse(raw(["POST /m HTTP/1.1", "Content-Length: 1", "Content-Length: 2"])),
                       .invalid(.malformed))
    }

    func testTransferEncodingIsRefused() {
        XCTAssertEqual(MCPHTTPParser.parse(raw(["POST /m HTTP/1.1", "Transfer-Encoding: chunked"])),
                       .invalid(.unsupportedTransferEncoding))
    }

    func testQueryValueIsPercentDecoded() {
        let req = request(target: "/sse?a=1&token=a%2Bb&token=second", headers: [:])
        XCTAssertEqual(req.queryValue("token"), "a+b")
        XCTAssertEqual(req.queryValue("a"), "1")
    }

    // MARK: - Origin / Host

    func testOriginMustBeAbsent() {
        XCTAssertTrue(MCPRequestGuard.isAllowedOrigin(nil))
        XCTAssertFalse(MCPRequestGuard.isAllowedOrigin("http://evil.example"))
        XCTAssertFalse(MCPRequestGuard.isAllowedOrigin("http://127.0.0.1:3333"))
        XCTAssertFalse(MCPRequestGuard.isAllowedOrigin("null"))
        XCTAssertFalse(MCPRequestGuard.isAllowedOrigin(""))
    }

    func testHostMustBeLoopbackWithPort() {
        XCTAssertTrue(MCPRequestGuard.isAllowedHost("127.0.0.1:3333", port: 3333))
        XCTAssertTrue(MCPRequestGuard.isAllowedHost("localhost:3333", port: 3333))
        XCTAssertTrue(MCPRequestGuard.isAllowedHost("LocalHost:3333", port: 3333))
        XCTAssertFalse(MCPRequestGuard.isAllowedHost(nil, port: 3333))
        XCTAssertFalse(MCPRequestGuard.isAllowedHost("127.0.0.1", port: 3333))
        XCTAssertFalse(MCPRequestGuard.isAllowedHost("localhost:4444", port: 3333))
        XCTAssertFalse(MCPRequestGuard.isAllowedHost("evil.example:3333", port: 3333))
        XCTAssertFalse(MCPRequestGuard.isAllowedHost("127.0.0.1:3333, evil.example", port: 3333))
        XCTAssertFalse(MCPRequestGuard.isAllowedHost("127.0.0.1.evil.example:3333", port: 3333))
    }

    // MARK: - Token

    func testBearerParsing() {
        XCTAssertEqual(MCPRequestGuard.bearerToken(fromAuthorization: "Bearer abc"), "abc")
        XCTAssertEqual(MCPRequestGuard.bearerToken(fromAuthorization: "bearer   abc "), "abc")
        XCTAssertNil(MCPRequestGuard.bearerToken(fromAuthorization: "Basic abc"))
        XCTAssertNil(MCPRequestGuard.bearerToken(fromAuthorization: "Bearer"))
        XCTAssertNil(MCPRequestGuard.bearerToken(fromAuthorization: "Bearer "))
        XCTAssertNil(MCPRequestGuard.bearerToken(fromAuthorization: nil))
    }

    func testTokensMatch() {
        XCTAssertTrue(MCPRequestGuard.tokensMatch("abc", "abc"))
        XCTAssertFalse(MCPRequestGuard.tokensMatch("abd", "abc"))
        XCTAssertFalse(MCPRequestGuard.tokensMatch("ab", "abc"))
        XCTAssertFalse(MCPRequestGuard.tokensMatch("abcd", "abc"))
        // An empty expected token never matches (server not yet initialised).
        XCTAssertFalse(MCPRequestGuard.tokensMatch("", ""))
    }

    func testPresentedTokenPrefersHeaderAndFlagsQuery() {
        let viaHeader = request(target: "/sse?token=other", headers: ["Authorization": "Bearer h"])
        XCTAssertEqual(MCPRequestGuard.presentedToken(in: viaHeader)?.token, "h")
        XCTAssertEqual(MCPRequestGuard.presentedToken(in: viaHeader)?.viaQuery, false)

        let viaQuery = request(target: "/sse?token=q", headers: [:])
        XCTAssertEqual(MCPRequestGuard.presentedToken(in: viaQuery)?.token, "q")
        XCTAssertEqual(MCPRequestGuard.presentedToken(in: viaQuery)?.viaQuery, true)

        // A malformed Authorization header does not fall back to the query.
        let badHeader = request(target: "/sse?token=q", headers: ["Authorization": "Basic x"])
        XCTAssertNil(MCPRequestGuard.presentedToken(in: badHeader))
    }

    func testJSONContentType() {
        XCTAssertTrue(MCPRequestGuard.isJSONContentType("application/json"))
        XCTAssertTrue(MCPRequestGuard.isJSONContentType("Application/JSON; charset=utf-8"))
        XCTAssertFalse(MCPRequestGuard.isJSONContentType(nil))
        XCTAssertFalse(MCPRequestGuard.isJSONContentType("text/plain"))
        XCTAssertFalse(MCPRequestGuard.isJSONContentType("application/x-www-form-urlencoded"))
        XCTAssertFalse(MCPRequestGuard.isJSONContentType("application/jsonp"))
    }

    // MARK: - Full validation

    func testValidRequestsPass() {
        XCTAssertNil(MCPRequestGuard.validate(request(headers: goodHeaders), port: port, expectedToken: token))

        var post = goodHeaders
        post["Content-Type"] = "application/json"
        XCTAssertNil(MCPRequestGuard.validate(request(method: "POST", target: "/message?sessionId=1", headers: post),
                                              port: port, expectedToken: token))

        let queryAuth = request(target: "/sse?token=\(token)", headers: ["Host": "localhost:3333"])
        XCTAssertNil(MCPRequestGuard.validate(queryAuth, port: port, expectedToken: token))
    }

    func testRejections() {
        var withOrigin = goodHeaders
        withOrigin["Origin"] = "https://evil.example"
        XCTAssertEqual(MCPRequestGuard.validate(request(headers: withOrigin), port: port, expectedToken: token),
                       .forbiddenOrigin)

        var badHost = goodHeaders
        badHost["Host"] = "attacker.example:3333"
        XCTAssertEqual(MCPRequestGuard.validate(request(headers: badHost), port: port, expectedToken: token),
                       .invalidHost)

        XCTAssertEqual(MCPRequestGuard.validate(request(headers: ["Host": "127.0.0.1:3333"]),
                                                port: port, expectedToken: token),
                       .unauthorized)

        var wrongToken = goodHeaders
        wrongToken["Authorization"] = "Bearer nope"
        XCTAssertEqual(MCPRequestGuard.validate(request(headers: wrongToken), port: port, expectedToken: token),
                       .unauthorized)

        XCTAssertEqual(MCPRequestGuard.validate(request(headers: goodHeaders), port: port, expectedToken: ""),
                       .unauthorized)

        var formPost = goodHeaders
        formPost["Content-Type"] = "text/plain"
        XCTAssertEqual(MCPRequestGuard.validate(request(method: "POST", target: "/message", headers: formPost),
                                                port: port, expectedToken: token),
                       .unsupportedMediaType)

        XCTAssertEqual(MCPRequestGuard.validate(request(method: "POST", target: "/message", headers: goodHeaders),
                                                port: port, expectedToken: token),
                       .unsupportedMediaType)
    }

    func testParsedRequestRoundTripsThroughGuard() throws {
        let body = "{}"
        let req = try parsed(raw(["POST /message?sessionId=s HTTP/1.1",
                                  "Host: 127.0.0.1:3333",
                                  "Authorization: Bearer \(token)",
                                  "Content-Type: application/json",
                                  "Content-Length: 2"], body: body))
        XCTAssertNil(MCPRequestGuard.validate(req, port: port, expectedToken: token))
    }

    // MARK: - Token generation

    func testGeneratedTokenIsBase64URLAndLongEnough() {
        let generated = MCPTokenGenerator.generate()
        XCTAssertEqual(generated.count, 43) // 32 bytes, unpadded base64url
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        XCTAssertTrue(generated.allSatisfy { allowed.contains($0) })
        XCTAssertNotEqual(generated, MCPTokenGenerator.generate())
    }

    func testBase64URLEncoding() {
        XCTAssertEqual(MCPTokenGenerator.base64URLEncode(Data([0xFB, 0xFF, 0xBF])), "-_-_")
        XCTAssertEqual(MCPTokenGenerator.base64URLEncode(Data([0x01])), "AQ")
        XCTAssertEqual(MCPTokenGenerator.base64URLEncode(Data()), "")
    }

    // MARK: - Client config

    func testClientConfigSnippetContainsURLAndToken() throws {
        let snippet = MCPClientConfig.snippet(port: 4321, token: "tok")
        XCTAssertTrue(snippet.contains("http://127.0.0.1:4321/sse"))
        XCTAssertTrue(snippet.contains("Bearer tok"))
        // The snippet is valid JSON.
        let object = try JSONSerialization.jsonObject(with: Data(snippet.utf8)) as? [String: Any]
        XCTAssertNotNil(object?["mcpServers"])
        XCTAssertEqual(MCPClientConfig.urlWithToken(port: 4321, token: "tok"),
                       "http://127.0.0.1:4321/sse?token=tok")
    }
}
