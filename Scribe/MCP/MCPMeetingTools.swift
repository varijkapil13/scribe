import Foundation

/// MCP tools for cross-meeting questions and people: `ask_meetings`,
/// `search_meetings`, `list_people`, `get_person`. Kept out of
/// `MCPHandler` so the handler only needs a two-line hook (definitions +
/// dispatch fallback).
@MainActor
enum MCPMeetingTools {

    static let toolNames: [String] = ["ask_meetings", "search_meetings", "list_people", "get_person"]

    // MARK: - Definitions

    static var definitions: [[String: Any]] {
        [
            definition(
                "ask_meetings",
                description: "Ask a question across meeting transcripts, summaries and notes. Returns the retrieved source snippets and, when on-device Apple Intelligence is available, a short answer citing sources as [[Note Title]].",
                properties: [
                    "question": ["type": "string", "description": "Natural-language question"],
                    "scope": ["type": "string",
                              "description": "all (default) | last_7_days | last_30_days | notebook:<name or id> | person:<name>"],
                    "answer": ["type": "boolean",
                               "description": "Generate an answer with the on-device model (default true). False returns snippets only."]
                ],
                required: ["question"]),

            definition(
                "search_meetings",
                description: "Full-text search across meeting transcripts, summaries and notes. Returns ranked snippets with session/note references.",
                properties: [
                    "query": ["type": "string", "description": "Search query"],
                    "scope": ["type": "string",
                              "description": "all (default) | last_7_days | last_30_days | notebook:<name or id> | person:<name>"],
                    "limit": ["type": "integer", "description": "Max snippets, default 20"]
                ],
                required: ["query"]),

            definition(
                "list_people",
                description: "List people who appear in meetings (from extracted names, named speakers and action-item assignees), with meeting and open-task counts.",
                properties: [
                    "limit": ["type": "integer", "description": "Max results, default 50"]
                ],
                required: []),

            definition(
                "get_person",
                description: "Get one person's meetings (session + meeting note) and open tasks that mention them.",
                properties: [
                    "name": ["type": "string", "description": "Person's name (full or unique first name)"]
                ],
                required: ["name"])
        ]
    }

    private static func definition(_ name: String,
                                   description: String,
                                   properties: [String: [String: String]],
                                   required: [String]) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name, "description": description, "inputSchema": schema]
    }

    // MARK: - Dispatch

    /// Runs `name` if it is one of these tools. Returns nil for unknown
    /// names so the caller can fall through to its own error.
    static func call(name: String, arguments: [String: Any]) async throws -> Any? {
        switch name {
        case "ask_meetings":    return try await askMeetings(arguments)
        case "search_meetings": return try searchMeetings(arguments)
        case "list_people":     return try listPeople(arguments)
        case "get_person":      return try getPerson(arguments)
        default:                return nil
        }
    }

    // MARK: - Tools

    private static func askMeetings(_ args: [String: Any]) async throws -> Any {
        guard let question = args["question"] as? String,
              !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPError.missingArgument("question")
        }
        let scope = try resolveScope(args["scope"] as? String)
        let wantsAnswer = args["answer"] as? Bool ?? true
        let result = await MeetingAsker.ask(question: question, scope: scope,
                                            generateAnswer: wantsAnswer)
        var out: [String: Any] = [
            "question": question,
            "scope": scope.label,
            "snippets": result.retrieval.snippets.map(snippetDict),
            "answer_generated": result.usedModel
        ]
        if result.usedModel { out["answer"] = result.answer }
        if let notice = result.notice { out["notice"] = notice }
        return out
    }

    private static func searchMeetings(_ args: [String: Any]) throws -> Any {
        guard let query = args["query"] as? String,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPError.missingArgument("query")
        }
        let scope = try resolveScope(args["scope"] as? String)
        let limit = max(1, args["limit"] as? Int ?? 20)
        // Larger budget than the model context — MCP clients can take more.
        let retriever = MeetingRetriever(budget: 24_000)
        let result = try retriever.retrieve(question: query, scope: scope)
        return [
            "query": query,
            "scope": scope.label,
            "terms": result.terms,
            "snippets": result.snippets.prefix(limit).map(snippetDict)
        ] as [String: Any]
    }

    private static func listPeople(_ args: [String: Any]) throws -> Any {
        let limit = max(1, args["limit"] as? Int ?? 50)
        let people = try PeopleRepository().loadPeople()
        return people.prefix(limit).map { person -> [String: Any] in
            [
                "id": person.id,
                "name": person.name,
                "meeting_count": person.meetingCount,
                "open_task_count": person.openTasks.count
            ]
        }
    }

    private static func getPerson(_ args: [String: Any]) throws -> Any {
        guard let name = args["name"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPError.missingArgument("name")
        }
        guard let person = try PeopleRepository().person(named: name) else {
            throw MCPError.notFound("Person \(name)")
        }
        return personDict(person)
    }

    // MARK: - Helpers

    /// Parses the `scope` argument. Unknown notebooks/people are errors so
    /// the client doesn't silently get an unscoped answer.
    static func resolveScope(_ raw: String?) throws -> AskScope {
        let value = (raw ?? "all").trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = value.lowercased()
        switch lower {
        case "", "all":                         return .all
        case "last_7_days", "7d", "week":       return .lastDays(7)
        case "last_30_days", "30d", "month":    return .lastDays(30)
        default: break
        }
        if lower.hasPrefix("notebook:") {
            let name = String(value.dropFirst("notebook:".count)).trimmingCharacters(in: .whitespaces)
            let notebooks = try NoteStore.shared.fetchAllNotebooks()
            if let nb = notebooks.first(where: { $0.id == name })
                ?? notebooks.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                return .notebook(id: nb.id, name: nb.name)
            }
            throw MCPError.notFound("Notebook \(name)")
        }
        if lower.hasPrefix("person:") {
            let name = String(value.dropFirst("person:".count)).trimmingCharacters(in: .whitespaces)
            if let person = try PeopleRepository().person(named: name) {
                return .person(key: person.id, name: person.name)
            }
            throw MCPError.notFound("Person \(name)")
        }
        throw MCPError.missingArgument("scope (expected all | last_7_days | last_30_days | notebook:<name> | person:<name>)")
    }

    private static func snippetDict(_ s: RetrievedSnippet) -> [String: Any] {
        var d: [String: Any] = [
            "kind": s.kind.rawValue,
            "text": s.text,
            "date": ISO8601DateFormatter().string(from: s.date),
            "citation": "[[\(s.citationTitle)]]"
        ]
        if let sessionId = s.sessionId { d["session_id"] = sessionId }
        if let title = s.sessionTitle { d["session_title"] = title }
        if let noteId = s.noteId { d["note_id"] = noteId }
        if !s.noteTitle.isEmpty { d["note_title"] = s.noteTitle }
        if let speaker = s.speaker { d["speaker"] = speaker }
        return d
    }

    private static func personDict(_ p: Person) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        let meetings = p.meetings.map { m -> [String: Any] in
            var d: [String: Any] = [
                "session_id": m.sessionId,
                "session_title": m.sessionTitle,
                "date": iso.string(from: m.date)
            ]
            if let noteId = m.noteId { d["note_id"] = noteId }
            if let noteTitle = m.noteTitle { d["note_title"] = noteTitle }
            return d
        }
        let tasks = p.openTasks.map { t -> [String: Any] in
            var d: [String: Any] = ["id": t.id, "title": t.title]
            if let due = t.dueAt { d["due_date"] = iso.string(from: due) }
            if !t.tags.isEmpty { d["tags"] = t.tags }
            return d
        }
        return [
            "id": p.id,
            "name": p.name,
            "aliases": p.aliases,
            "meetings": meetings,
            "open_tasks": tasks
        ]
    }
}
