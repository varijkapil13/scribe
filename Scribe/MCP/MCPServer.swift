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
/// Security model (see MCPRequestGuard for the pure checks):
///   - The listener binds to 127.0.0.1 on the loopback interface only.
///   - Every request must carry the bearer token stored in the Keychain
///     (`Authorization: Bearer <token>`, or `?token=` for SSE clients that
///     cannot set headers).
///   - Requests with an Origin header (browsers) are refused, as are Host
///     headers other than 127.0.0.1:<port> / localhost:<port> (DNS rebinding).
///   - No CORS headers are ever sent.
@MainActor
final class MCPServer: ObservableObject {

    static let shared = MCPServer()

    /// Maximum simultaneously open SSE sessions.
    static let maxSessions = 16
    /// Maximum simultaneously open TCP connections (SSE + in-flight POSTs).
    static let maxConnections = 64
    /// A connection must deliver a complete request within this time.
    static let requestTimeout: Duration = .seconds(15)

    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?
    /// The bearer token clients must present. Loaded lazily from the Keychain.
    @Published private(set) var token: String = ""
    /// The port the listener was last asked to bind.
    @Published private(set) var port: UInt16 = MCPPortPolicy.defaultPort

    /// Per-connection key. A monotonically increasing counter rather than
    /// `ObjectIdentifier(conn)`: a deallocated connection's address can be
    /// reused by a new one, and late callbacks (the request timeout, a
    /// `.cancelled` state update after `closeAllConnections`) would then act
    /// on the wrong connection.
    private typealias ConnectionID = UInt64

    // Active SSE sessions keyed by sessionId.
    private var sessions: [String: NWConnection] = [:]
    private var sessionIdByConnection: [ConnectionID: String] = [:]
    // Every open connection, so stop() can tear them all down and the
    // connection cap can be enforced.
    private var connections: [ConnectionID: NWConnection] = [:]
    // Connections that have not yet delivered a complete request.
    private var awaitingRequest: Set<ConnectionID> = []
    private var nextConnectionID: ConnectionID = 0

    private var listener: NWListener?
    /// Bumped on every start/stop so callbacks from a previous listener
    /// (which arrive asynchronously) can't flip `isRunning` for the new one.
    private var generation = 0

    // MARK: - Token

    /// Ensures `token` is populated (creating one in the Keychain if needed).
    func loadToken() {
        if token.isEmpty { token = MCPTokenStore.loadOrCreate() }
    }

    /// Rotates the token and drops every open session, so clients holding
    /// the old token must reconnect with the new one.
    func regenerateToken() {
        token = MCPTokenStore.regenerate()
        closeAllConnections()
    }

    // MARK: - Lifecycle

    func start(port: UInt16) {
        guard !isRunning, listener == nil else { return }
        lastError = nil
        loadToken()
        self.port = port

        guard MCPPortPolicy.validated(Int(port)) != nil,
              let nwPort = NWEndpoint.Port(rawValue: port) else {
            lastError = "Invalid port \(port). Choose a port between 1024 and 65535."
            return
        }

        generation += 1
        let gen = generation
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            // Bind to loopback only — both constraints, so the socket can
            // neither be bound to another address nor routed over a
            // non-loopback interface.
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
            params.requiredInterfaceType = .loopback

            let newListener = try NWListener(using: params)
            newListener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    Task { @MainActor [weak self] in self?.listenerStateChanged(gen: gen, running: true, error: nil) }
                case .failed(let err):
                    let message = err.localizedDescription
                    Task { @MainActor [weak self] in self?.listenerStateChanged(gen: gen, running: false, error: message) }
                case .cancelled:
                    Task { @MainActor [weak self] in self?.listenerStateChanged(gen: gen, running: false, error: nil) }
                default:
                    break
                }
            }
            newListener.newConnectionHandler = { [weak self] conn in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == gen else { conn.cancel(); return }
                    self.accept(conn)
                }
            }
            listener = newListener
            newListener.start(queue: .global(qos: .userInitiated))
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() {
        generation += 1
        listener?.cancel()
        listener = nil
        closeAllConnections()
        isRunning = false
    }

    /// Stops and starts again (e.g. after a port change).
    func restart(port: UInt16) {
        stop()
        start(port: port)
    }

    private func listenerStateChanged(gen: Int, running: Bool, error: String?) {
        guard gen == generation else { return }
        isRunning = running
        if let error {
            lastError = error
            listener?.cancel()
            listener = nil
        }
    }

    private func closeAllConnections() {
        let open = Array(connections.values)
        connections.removeAll()
        sessions.removeAll()
        sessionIdByConnection.removeAll()
        awaitingRequest.removeAll()
        open.forEach { $0.cancel() }
    }

    // MARK: - Accept

    private func accept(_ conn: NWConnection) {
        guard connections.count < Self.maxConnections else {
            conn.cancel()
            return
        }
        nextConnectionID &+= 1
        let id = nextConnectionID
        connections[id] = conn
        awaitingRequest.insert(id)

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor [weak self] in self?.connectionClosed(id) }
            default:
                break
            }
        }
        conn.start(queue: .global(qos: .userInitiated))
        read(conn: conn, id: id, buffer: Data())

        // Drop connections that never finish sending a request.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.requestTimeout)
            guard let self, self.awaitingRequest.contains(id) else { return }
            self.connections[id]?.cancel()
        }
    }

    /// Called (via stateUpdateHandler) when a connection fails or is
    /// cancelled — removes it and any SSE session it backed.
    private func connectionClosed(_ id: ConnectionID) {
        connections.removeValue(forKey: id)
        awaitingRequest.remove(id)
        if let sessionId = sessionIdByConnection.removeValue(forKey: id) {
            sessions.removeValue(forKey: sessionId)
        }
    }

    private func read(conn: NWConnection, id: ConnectionID, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            let failed = error != nil
            Task { @MainActor [weak self] in
                guard let self else { conn.cancel(); return }
                self.handleReceived(conn: conn, id: id, buffer: buffer, data: data,
                                    isComplete: isComplete, failed: failed)
            }
        }
    }

    private func handleReceived(conn: NWConnection, id: ConnectionID, buffer: Data, data: Data?,
                                isComplete: Bool, failed: Bool) {
        if failed { conn.cancel(); return }
        var accumulated = buffer
        if let data { accumulated.append(data) }

        switch MCPHTTPParser.parse(accumulated) {
        case .complete(let req):
            awaitingRequest.remove(id)
            route(req: req, conn: conn, id: id)
        case .invalid(let parseError):
            awaitingRequest.remove(id)
            respond(conn: conn, status: parseError.status, body: Data("bad request".utf8), close: true)
        case .incomplete:
            // Peer closed before sending the whole request.
            if isComplete { conn.cancel(); return }
            read(conn: conn, id: id, buffer: accumulated)
        }
    }

    // MARK: - Routing

    private func route(req: MCPHTTPRequest, conn: NWConnection, id: ConnectionID) {
        if let rejection = MCPRequestGuard.validate(req, port: port, expectedToken: token) {
            var extra: [(String, String)] = []
            if rejection == .unauthorized { extra.append(("WWW-Authenticate", "Bearer")) }
            respond(conn: conn, status: rejection.status, headers: extra,
                    body: Data(rejection.message.utf8), close: true)
            return
        }

        switch (req.method, req.path) {
        case ("GET", "/sse"):
            let viaQuery = MCPRequestGuard.presentedToken(in: req)?.viaQuery ?? false
            openSSE(conn: conn, id: id, echoTokenInEndpoint: viaQuery)
        case ("POST", "/message"):
            let sessionId = req.queryValue("sessionId") ?? ""
            receiveMessage(body: req.body, sessionId: sessionId, reqConn: conn)
        case ("GET", "/health"):
            respond(conn: conn, status: "200 OK", body: Data("ok".utf8), close: true)
        case (_, "/sse"), (_, "/message"), (_, "/health"):
            respond(conn: conn, status: "405 Method Not Allowed", body: Data("method not allowed".utf8), close: true)
        default:
            respond(conn: conn, status: "404 Not Found", body: Data("not found".utf8), close: true)
        }
    }

    // MARK: - SSE session

    private func openSSE(conn: NWConnection, id: ConnectionID, echoTokenInEndpoint: Bool) {
        guard sessions.count < Self.maxSessions else {
            respond(conn: conn, status: "503 Service Unavailable",
                    body: Data("too many sessions".utf8), close: true)
            return
        }
        let sessionId = UUID().uuidString
        sessions[sessionId] = conn
        sessionIdByConnection[id] = sessionId

        let headerBlock = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: text/event-stream\r\n"
            + "Cache-Control: no-cache\r\n"
            + "Connection: keep-alive\r\n"
            + "X-Content-Type-Options: nosniff\r\n"
            + "\r\n"
        send(string: headerBlock, on: conn)

        // Per MCP spec: first event tells the client where to POST messages.
        // A client that could only authenticate via the query string can't
        // set headers on the POST either, so hand the token back in the URL.
        var endpoint = "/message?sessionId=\(sessionId)"
        if echoTokenInEndpoint { endpoint += "&token=\(token)" }
        emit(event: "endpoint", data: endpoint, on: conn)

        watchForClose(conn: conn)
    }

    /// Keeps a receive pending on an SSE stream so a client disconnect is
    /// noticed promptly (the connection is then cancelled and the session
    /// removed by `connectionClosed`).
    private func watchForClose(conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] _, _, isComplete, error in
            let closed = isComplete || error != nil
            Task { @MainActor [weak self] in
                guard let self else { conn.cancel(); return }
                if closed { conn.cancel() } else { self.watchForClose(conn: conn) }
            }
        }
    }

    private func emit(event: String, data: String, on conn: NWConnection) {
        send(string: "event: \(event)\ndata: \(data)\n\n", on: conn)
    }

    private func send(string: String, on conn: NWConnection) {
        conn.send(content: Data(string.utf8), completion: .contentProcessed { error in
            if error != nil { conn.cancel() }
        })
    }

    // MARK: - Message handling

    private func receiveMessage(body: Data, sessionId: String, reqConn: NWConnection) {
        guard let sseConn = sessions[sessionId] else {
            respond(conn: reqConn, status: "404 Not Found", body: Data("unknown session".utf8), close: true)
            return
        }
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            respond(conn: reqConn, status: "400 Bad Request", body: Data("invalid JSON-RPC body".utf8), close: true)
            return
        }

        // Acknowledge the POST immediately so the client doesn't time out.
        respond(conn: reqConn, status: "202 Accepted", body: Data(), close: true)

        Task { @MainActor in
            let response = await MCPHandler.handle(json)
            // Notifications produce no response.
            guard !response.isEmpty,
                  self.sessions[sessionId] === sseConn,
                  let responseData = try? JSONSerialization.data(withJSONObject: response),
                  let responseStr = String(data: responseData, encoding: .utf8)
            else { return }
            self.emit(event: "message", data: responseStr, on: sseConn)
        }
    }

    // MARK: - HTTP helpers

    private func respond(conn: NWConnection, status: String,
                         headers: [(String, String)] = [], body: Data, close: Bool) {
        var lines = ["HTTP/1.1 \(status)"]
        for (name, value) in headers { lines.append("\(name): \(value)") }
        lines.append("Content-Type: text/plain; charset=utf-8")
        lines.append("Content-Length: \(body.count)")
        lines.append("Cache-Control: no-store")
        lines.append("X-Content-Type-Options: nosniff")
        if close { lines.append("Connection: close") }

        var data = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        data.append(body)
        conn.send(content: data, completion: .contentProcessed { _ in
            if close { conn.cancel() }
        })
    }
}
