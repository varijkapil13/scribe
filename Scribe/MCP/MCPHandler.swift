import Foundation

/// Handles MCP JSON-RPC 2.0 dispatch. All methods run on the main actor so
/// they can safely call TaskStore / TranscriptStore.
@MainActor
enum MCPHandler {

    static func handle(_ json: [String: Any]) async -> [String: Any] {
        let id     = json["id"]
        let method = json["method"] as? String ?? ""
        let params = json["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            return ok(id: id, result: initializeResult)

        case "notifications/initialized":
            return [:]  // fire-and-forget; no response needed

        case "tools/list":
            return ok(id: id, result: ["tools": toolDefinitions])

        case "tools/call":
            let name      = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let result    = await callTool(name: name, arguments: arguments)
            return ok(id: id, result: result)

        case "resources/list":
            return ok(id: id, result: ["resources": resourceDefinitions])

        case "resources/read":
            let uri    = params["uri"] as? String ?? ""
            let result = await readResource(uri: uri)
            return ok(id: id, result: result)

        default:
            return err(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - Initialize

    private static var initializeResult: [String: Any] {
        [
            "protocolVersion": "2024-11-05",
            "capabilities": [
                "tools": ["listChanged": false],
                "resources": ["listChanged": false]
            ],
            "serverInfo": [
                "name": "Scribe",
                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
            ]
        ]
    }

    // MARK: - Tool definitions

    private static var toolDefinitions: [[String: Any]] {
        [
            tool("create_task",
                 description: "Create a new task in Scribe.",
                 properties: [
                    "title":    .init(type: "string",  description: "Task title", required: true),
                    "notes":    .init(type: "string",  description: "Optional notes / description"),
                    "due_date": .init(type: "string",  description: "ISO 8601 date string (e.g. 2025-06-01)"),
                    "priority": .init(type: "string",  description: "none | low | medium | high"),
                    "project":  .init(type: "string",  description: "Project name (created if not found)"),
                    "tags":     .init(type: "array",   description: "Array of tag strings",
                                      items: ["type": "string"])
                 ]),

            tool("list_tasks",
                 description: "List tasks. Optionally filter by scope.",
                 properties: [
                    "filter": .init(type: "string",
                                    description: "today | inbox | upcoming | all | completed — default: all")
                 ]),

            tool("search_tasks",
                 description: "Full-text search across task titles and notes.",
                 properties: [
                    "query": .init(type: "string", description: "Search query", required: true)
                 ]),

            tool("update_task",
                 description: "Update fields of an existing task by its ID.",
                 properties: [
                    "id":       .init(type: "string", description: "Task ID", required: true),
                    "title":    .init(type: "string", description: "New title"),
                    "notes":    .init(type: "string", description: "New notes"),
                    "due_date": .init(type: "string", description: "ISO 8601 date string"),
                    "priority": .init(type: "string", description: "none | low | medium | high"),
                    "completed":.init(type: "boolean", description: "Mark complete / incomplete")
                 ]),

            tool("delete_task",
                 description: "Permanently delete a task by its ID.",
                 properties: [
                    "id": .init(type: "string", description: "Task ID", required: true)
                 ]),

            tool("list_transcripts",
                 description: "List recent recording sessions with their titles and dates.",
                 properties: [
                    "limit": .init(type: "integer", description: "Max results, default 20")
                 ]),

            tool("get_transcript",
                 description: "Get the full transcript text and action items for a session.",
                 properties: [
                    "id": .init(type: "string", description: "Session ID", required: true)
                 ])
        ]
    }

    // MARK: - Tool dispatch

    private static func callTool(name: String, arguments: [String: Any]) async -> [String: Any] {
        do {
            switch name {
            case "create_task":    return try createTask(arguments)
            case "list_tasks":     return try listTasks(arguments)
            case "search_tasks":   return try searchTasks(arguments)
            case "update_task":    return try updateTask(arguments)
            case "delete_task":    return try deleteTask(arguments)
            case "list_transcripts": return try listTranscripts(arguments)
            case "get_transcript": return try getTranscript(arguments)
            default:
                return toolError("Unknown tool: \(name)")
            }
        } catch {
            return toolError(error.localizedDescription)
        }
    }

    // MARK: - Tools: Tasks

    private static func createTask(_ args: [String: Any]) throws -> [String: Any] {
        guard let title = args["title"] as? String, !title.isEmpty else {
            throw MCPError.missingArgument("title")
        }
        let store = TaskStore()
        let dueAt = (args["due_date"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            ?? Calendar.current.startOfDay(for: Date())
        let priority = (args["priority"] as? String).flatMap(TodoTask.Priority.init(rawValue:))
        let tags = args["tags"] as? [String] ?? []
        let notes = args["notes"] as? String ?? ""

        var projectId: String? = nil
        if let name = args["project"] as? String, !name.isEmpty {
            let projects = try store.fetchProjects()
            projectId = projects.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id
            if projectId == nil {
                let p = try store.createProject(name: name)
                projectId = p.id
            }
        }

        let task = try store.createTask(
            title: title, notes: notes, projectId: projectId,
            priority: priority, dueAt: dueAt, tags: tags
        )
        return toolSuccess(taskToDict(task))
    }

    private static func listTasks(_ args: [String: Any]) throws -> [String: Any] {
        let store  = TaskStore()
        let filter = filterFromString(args["filter"] as? String ?? "all")
        let tasks  = try store.fetchTasks(filter: filter)
        return toolSuccess(tasks.map(taskToDict))
    }

    private static func searchTasks(_ args: [String: Any]) throws -> [String: Any] {
        guard let query = args["query"] as? String else { throw MCPError.missingArgument("query") }
        let store = TaskStore()
        let tasks = try store.searchTasks(query: query)
        return toolSuccess(tasks.map(taskToDict))
    }

    private static func updateTask(_ args: [String: Any]) throws -> [String: Any] {
        guard let id = args["id"] as? String else { throw MCPError.missingArgument("id") }
        let store = TaskStore()
        guard var task = try store.fetchTask(id: id) else {
            throw MCPError.notFound("Task \(id)")
        }
        if let title = args["title"] as? String { task.title = title }
        if let notes = args["notes"] as? String { task.notes = notes }
        if let due   = (args["due_date"] as? String).flatMap({ ISO8601DateFormatter().date(from: $0) }) {
            task.dueAt = due
        }
        if let p = args["priority"] as? String {
            task.priority = p == "none" ? nil : TodoTask.Priority(rawValue: p)
        }
        try store.updateTask(task)
        if let completed = args["completed"] as? Bool {
            if completed { try store.completeTask(id: id) }
            else { try store.uncompleteTask(id: id) }
        }
        let updated = try store.fetchTask(id: id) ?? task
        return toolSuccess(taskToDict(updated))
    }

    private static func deleteTask(_ args: [String: Any]) throws -> [String: Any] {
        guard let id = args["id"] as? String else { throw MCPError.missingArgument("id") }
        try TaskStore().deleteTask(id: id)
        return toolSuccess(["deleted": id])
    }

    // MARK: - Tools: Transcripts

    private static func listTranscripts(_ args: [String: Any]) throws -> [String: Any] {
        let limit = args["limit"] as? Int ?? 20
        let store = TranscriptStore()
        let sessions = try store.fetchAllSessions().prefix(limit)
        let dicts = sessions.map { s -> [String: Any] in
            var d: [String: Any] = ["id": s.id, "title": s.title]
            d["started_at"] = ISO8601DateFormatter().string(from: s.createdAt)
            if let ended = s.endedAt { d["ended_at"] = ISO8601DateFormatter().string(from: ended) }
            if let dur = s.durationSeconds { d["duration_seconds"] = dur }
            return d
        }
        return toolSuccess(Array(dicts))
    }

    private static func getTranscript(_ args: [String: Any]) throws -> [String: Any] {
        guard let id = args["id"] as? String else { throw MCPError.missingArgument("id") }
        let store = TranscriptStore()
        guard let session = try store.fetchSession(id: id) else {
            throw MCPError.notFound("Session \(id)")
        }
        let segments = try store.fetchSegments(sessionId: id)
        let text = segments.map(\.text).joined(separator: " ")
        let actions = try store.fetchActionItems(sessionId: id)
        let completedIds = (try? store.fetchCompletedActionItemIds(sessionId: id)) ?? []
        let actionDicts = actions.map { a -> [String: Any] in
            ["id": a.id.uuidString, "text": a.description,
             "assignee": a.assignee as Any,
             "deadline": a.deadline as Any,
             "completed": completedIds.contains(a.id)]
        }
        return toolSuccess([
            "id": session.id,
            "title": session.title,
            "transcript": text,
            "action_items": actionDicts
        ])
    }

    // MARK: - Resources

    private static var resourceDefinitions: [[String: Any]] {
        [
            ["uri": "tasks://today",       "name": "Today's Tasks",    "mimeType": "application/json"],
            ["uri": "tasks://inbox",        "name": "Inbox Tasks",      "mimeType": "application/json"],
            ["uri": "tasks://all",          "name": "All Tasks",        "mimeType": "application/json"],
            ["uri": "transcripts://recent", "name": "Recent Transcripts","mimeType": "application/json"]
        ]
    }

    private static func readResource(uri: String) async -> [String: Any] {
        do {
            let content: Any
            switch uri {
            case "tasks://today":
                content = try TaskStore().fetchTasks(filter: .today).map(taskToDict)
            case "tasks://inbox":
                content = try TaskStore().fetchTasks(filter: .inbox).map(taskToDict)
            case "tasks://all":
                content = try TaskStore().fetchTasks(filter: .all).map(taskToDict)
            case "transcripts://recent":
                content = try TranscriptStore().fetchAllSessions().prefix(10).map { s -> [String: Any] in
                    ["id": s.id, "title": s.title]
                }
            default:
                return err(id: nil, code: -32602, message: "Unknown resource: \(uri)")
            }
            let data = try JSONSerialization.data(withJSONObject: content)
            return ok(id: nil, result: [
                "contents": [["uri": uri, "mimeType": "application/json",
                              "text": String(data: data, encoding: .utf8) ?? "[]"]]
            ])
        } catch {
            return err(id: nil, code: -32603, message: error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private static func taskToDict(_ t: TodoTask) -> [String: Any] {
        var d: [String: Any] = [
            "id": t.id,
            "title": t.title,
            "notes": t.notes,
            "completed": t.isCompleted
        ]
        if let due = t.dueAt { d["due_date"] = ISO8601DateFormatter().string(from: due) }
        if let p = t.priority { d["priority"] = p.rawValue }
        if let pid = t.projectId { d["project_id"] = pid }
        return d
    }

    private static func filterFromString(_ s: String) -> TaskStore.Filter {
        switch s {
        case "today":     return .today
        case "inbox":     return .inbox
        case "upcoming":  return .upcoming
        case "completed": return .completed
        default:          return .all
        }
    }

    private static func toolSuccess(_ value: Any) -> [String: Any] {
        ["content": [["type": "text", "text": jsonString(value)]]]
    }

    private static func toolError(_ message: String) -> [String: Any] {
        ["isError": true, "content": [["type": "text", "text": message]]]
    }

    private static func jsonString(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value,
                                                     options: [.prettyPrinted]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    // MARK: - JSON-RPC envelope

    private static func ok(id: Any?, result: Any) -> [String: Any] {
        var r: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id { r["id"] = id }
        return r
    }

    private static func err(id: Any?, code: Int, message: String) -> [String: Any] {
        var r: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message]
        ]
        if let id { r["id"] = id }
        return r
    }

    // MARK: - Tool builder DSL

    private struct Prop {
        let type: String
        let description: String
        var required: Bool = false
        var items: [String: String]? = nil
        init(type: String, description: String, required: Bool = false, items: [String: String]? = nil) {
            self.type = type; self.description = description
            self.required = required; self.items = items
        }
    }

    private static func tool(_ name: String, description: String,
                              properties: [String: Prop]) -> [String: Any] {
        var props: [String: Any] = [:]
        var required: [String] = []
        for (key, p) in properties {
            var def: [String: Any] = ["type": p.type, "description": p.description]
            if let items = p.items { def["items"] = items }
            props[key] = def
            if p.required { required.append(key) }
        }
        var schema: [String: Any] = ["type": "object", "properties": props]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name, "description": description, "inputSchema": schema]
    }
}

// MARK: - Errors

enum MCPError: LocalizedError {
    case missingArgument(String)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .missingArgument(let k): return "Missing required argument: \(k)"
        case .notFound(let what):     return "Not found: \(what)"
        }
    }
}
