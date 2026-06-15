import Foundation
import Network

/// Minimal HTTP server that speaks MCP (Model Context Protocol) over the
/// HTTP+SSE transport described in the MCP spec.
///
/// Transport flow:
///   1. Client GETs  /sse          → receives SSE stream; first event gives them
///                                   their per-session POST endpoint URL.
///   2. Client POSTs /message?sessionId=<uuid>  with a JSON-RPC 2.0 body.
///   3. Server dispatches to MCPHandler and emits the response as an SSE
///      "message" event on the matching session's open stream.
///
/// Binding is always 127.0.0.1 only — the server is local-only by design.
@MainActor
final class MCPServer: ObservableObject {

    static let shared = MCPServer()

    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?

    // Active SSE sessions keyed by sessionId.
    private var sessions: [String: NWConnection] = [:]
    private var listener: NWListener?

    // MARK: - Lifecycle

    func start(port: UInt16) {
        guard !isRunning else { return }
        lastError = nil
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            // Bind to loopback only.
            let endpoint = NWEndpoint.hostPort(
                host: "127.0.0.1",
                port: NWEndpoint.Port(rawValue: port)!
            )
            _ = endpoint // params already constrain to TCP; listener binds via port arg below
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            listener?.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    switch state {
                    case .ready:
                        self?.isRunning = true
                    case .failed(let err):
                        self?.isRunning = false
                        self?.lastError = err.localizedDescription
                    case .cancelled:
                        self?.isRunning = false
                    default: break
                    }
                }
            }
            listener?.newConnectionHandler = { [weak self] conn in
                Task { @MainActor [weak self] in self?.accept(conn) }
            }
            listener?.start(queue: .global(qos: .userInitiated))
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        sessions.values.forEach { $0.cancel() }
        sessions.removeAll()
        isRunning = false
    }

    // MARK: - Accept

    private func accept(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .userInitiated))
        read(conn: conn, buffer: Data())
    }

    private func read(conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, error in
            guard let self else { return }
            if error != nil { conn.cancel(); return }
            let accumulated = buffer + (data ?? Data())
            Task { @MainActor in
                if let req = HTTPRequest(data: accumulated) {
                    self.route(req: req, conn: conn)
                } else {
                    self.read(conn: conn, buffer: accumulated)
                }
            }
        }
    }

    // MARK: - Routing

    private func route(req: HTTPRequest, conn: NWConnection) {
        // Handle CORS preflight
        if req.method == "OPTIONS" {
            respond(conn: conn, status: "204 No Content", headers: corsHeaders(), body: Data(), close: true)
            return
        }

        let path = req.path.components(separatedBy: "?").first ?? req.path

        switch (req.method, path) {
        case ("GET", "/sse"):
            openSSE(conn: conn)
        case ("POST", "/message"):
            let sessionId = queryValue("sessionId", in: req.path) ?? ""
            receiveMessage(body: req.body, sessionId: sessionId, reqConn: conn)
        case ("GET", "/health"):
            respond(conn: conn, status: "200 OK", headers: corsHeaders(), body: Data("ok".utf8), close: true)
        default:
            respond(conn: conn, status: "404 Not Found", headers: corsHeaders(), body: Data("not found".utf8), close: true)
        }
    }

    // MARK: - SSE session

    private func openSSE(conn: NWConnection) {
        let sessionId = UUID().uuidString
        sessions[sessionId] = conn

        var headers = corsHeaders()
        headers["Content-Type"] = "text/event-stream"
        headers["Cache-Control"] = "no-cache"
        headers["Connection"] = "keep-alive"

        let headerBlock = "HTTP/1.1 200 OK\r\n"
            + headers.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n")
            + "\r\n\r\n"
        send(string: headerBlock, on: conn)

        // Per MCP spec: first event tells the client where to POST messages.
        emit(event: "endpoint", data: "/message?sessionId=\(sessionId)", on: conn)
    }

    private func emit(event: String, data: String, on conn: NWConnection) {
        send(string: "event: \(event)\ndata: \(data)\n\n", on: conn)
    }

    private func send(string: String, on conn: NWConnection) {
        conn.send(content: Data(string.utf8), completion: .idempotent)
    }

    // MARK: - Message handling

    private func receiveMessage(body: Data, sessionId: String, reqConn: NWConnection) {
        // Acknowledge the POST immediately so the client doesn't time out.
        respond(conn: reqConn, status: "202 Accepted",
                headers: corsHeaders() + ["Content-Type": "application/json"],
                body: Data(), close: true)

        guard let sseConn = sessions[sessionId],
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return }

        Task { @MainActor in
            let response = await MCPHandler.handle(json)
            if let responseData = try? JSONSerialization.data(withJSONObject: response),
               let responseStr = String(data: responseData, encoding: .utf8) {
                self.emit(event: "message", data: responseStr, on: sseConn)
            }
        }
    }

    // MARK: - HTTP helpers

    private func respond(conn: NWConnection, status: String,
                         headers: [String: String], body: Data, close: Bool) {
        var allHeaders = headers
        allHeaders["Content-Length"] = "\(body.count)"
        if close { allHeaders["Connection"] = "close" }

        let headerStr = "HTTP/1.1 \(status)\r\n"
            + allHeaders.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n")
            + "\r\n\r\n"
        var data = Data(headerStr.utf8)
        data.append(body)
        conn.send(content: data, completion: .contentProcessed { _ in
            if close { conn.cancel() }
        })
    }

    private func corsHeaders() -> [String: String] {
        [
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Headers": "Content-Type, Authorization",
            "Access-Control-Allow-Methods": "GET, POST, OPTIONS"
        ]
    }

    private func queryValue(_ key: String, in path: String) -> String? {
        guard let q = path.components(separatedBy: "?").last,
              q != path else { return nil }
        for pair in q.components(separatedBy: "&") {
            let kv = pair.components(separatedBy: "=")
            if kv.count == 2, kv[0] == key {
                return kv[1].removingPercentEncoding ?? kv[1]
            }
        }
        return nil
    }
}

// MARK: - HTTP request parser

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    /// Returns nil if the request is incomplete (headers not yet fully received).
    init?(data: Data) {
        guard let raw = String(data: data, encoding: .utf8),
              let separatorRange = raw.range(of: "\r\n\r\n") else { return nil }

        let headerSection = String(raw[..<separatorRange.lowerBound])
        let bodyStr = String(raw[separatorRange.upperBound...])

        let lines = headerSection.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }

        method = parts[0]
        path   = parts[1]

        var hdrs: [String: String] = [:]
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2 { hdrs[kv[0].lowercased()] = kv[1] }
        }
        headers = hdrs

        let contentLength = Int(hdrs["content-length"] ?? "0") ?? 0
        body = Data((bodyStr.data(using: .utf8) ?? Data()).prefix(contentLength))
    }
}

// MARK: - Dictionary + operator for convenience

private func + (lhs: [String: String], rhs: [String: String]) -> [String: String] {
    lhs.merging(rhs) { _, new in new }
}
