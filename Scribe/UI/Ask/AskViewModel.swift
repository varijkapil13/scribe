// Scribe/UI/Ask/AskViewModel.swift
import Foundation
import Combine

/// One turn in the Ask Scribe conversation.
struct AskMessage: Identifiable, Equatable {
    enum Role: Equatable { case user, assistant }

    let id: UUID
    var role: Role
    var text: String
    var snippets: [RetrievedSnippet]
    var notice: String?
    var usedModel: Bool
    var isPending: Bool
    var scopeLabel: String?

    init(id: UUID = UUID(),
         role: Role,
         text: String,
         snippets: [RetrievedSnippet] = [],
         notice: String? = nil,
         usedModel: Bool = false,
         isPending: Bool = false,
         scopeLabel: String? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.snippets = snippets
        self.notice = notice
        self.usedModel = usedModel
        self.isPending = isPending
        self.scopeLabel = scopeLabel
    }
}

/// Drives the "Ask Scribe" chat: scope selection, sending a question,
/// and resolving `[[citations]]` to navigation destinations.
@MainActor
final class AskViewModel: ObservableObject {

    @Published var messages: [AskMessage] = []
    @Published var draft: String = ""
    @Published var scope: AskScope = .all
    @Published private(set) var isAnswering = false
    @Published private(set) var notebooks: [Notebook] = []
    @Published private(set) var people: [Person] = []
    @Published private(set) var availability: AppleIntelligenceAvailability = .available

    private let noteStore: NoteStore
    private var answerTask: Task<Void, Never>?

    init(noteStore: NoteStore = .shared) {
        self.noteStore = noteStore
    }

    /// Refreshes scope options and the Apple Intelligence state.
    func onAppear() {
        availability = AppleIntelligenceAvailability.current
        notebooks = (try? noteStore.fetchAllNotebooks()) ?? []
        Task {
            let loaded = await Task.detached(priority: .utility) {
                (try? PeopleRepository().loadPeople()) ?? []
            }.value
            self.people = loaded
        }
    }

    var canSend: Bool {
        !isAnswering && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAnswering else { return }
        draft = ""
        let scope = self.scope
        messages.append(AskMessage(role: .user, text: question, scopeLabel: scope.label))
        let pending = AskMessage(role: .assistant, text: "", isPending: true)
        messages.append(pending)
        isAnswering = true

        answerTask = Task { [weak self] in
            let result = await MeetingAsker.ask(question: question, scope: scope)
            guard let self else { return }
            if let index = self.messages.firstIndex(where: { $0.id == pending.id }) {
                self.messages[index] = AskMessage(
                    id: pending.id,
                    role: .assistant,
                    text: result.answer,
                    snippets: result.retrieval.snippets,
                    notice: result.notice,
                    usedModel: result.usedModel,
                    isPending: false
                )
            }
            self.isAnswering = false
            self.availability = AppleIntelligenceAvailability.current
        }
    }

    func clear() {
        answerTask?.cancel()
        answerTask = nil
        messages.removeAll()
        isAnswering = false
    }

    /// Where a `[[title]]` citation in `message` should navigate.
    func destination(forCitation title: String, in message: AskMessage) -> MainSelection? {
        if let local = Self.destination(forCitation: title, snippets: message.snippets) {
            return local
        }
        if let note = try? noteStore.resolveTitle(title) {
            return .note(note.id)
        }
        return nil
    }

    /// Prefers the snippet the model was shown: its note, else its session.
    nonisolated static func destination(forCitation title: String,
                                        snippets: [RetrievedSnippet]) -> MainSelection? {
        let wanted = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        guard let snippet = snippets.first(where: {
            $0.citationTitle.caseInsensitiveCompare(wanted) == .orderedSame
        }) else { return nil }
        return destination(for: snippet)
    }

    /// Navigation target for a source snippet: transcripts/summaries open the
    /// recording, notes open the note.
    nonisolated static func destination(for snippet: RetrievedSnippet) -> MainSelection? {
        switch snippet.kind {
        case .note:
            return snippet.noteId.map { MainSelection.note($0) }
        case .transcript, .summary:
            if let noteId = snippet.noteId { return .note(noteId) }
            return snippet.sessionId.map { MainSelection.session($0) }
        }
    }
}

// MARK: - Citation links

extension Notification.Name {
    /// Posted (object: the citation `URL`) when a `[[citation]]` link in an
    /// Ask Scribe answer is clicked. `AskView` resolves and navigates.
    static let scribeAskCitationTapped = Notification.Name("scribe.ask.citationTapped")
}

/// Encodes / decodes the private URL used to make `[[citations]]` clickable
/// in SwiftUI `Text`.
enum AskCitationLink {
    static let scheme = "scribe-ask"

    nonisolated static func url(forTitle title: String, messageId: UUID? = nil) -> URL? {
        // Percent-encode by hand against a strict ASCII set: `queryItems`
        // leaves `&`, `+` and `=` alone, which would break titles like
        // "Plan & Budget".
        let unreserved = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let encoded = title.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        var query = "title=\(encoded)"
        if let messageId {
            query += "&message=\(messageId.uuidString)"
        }
        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = "cite"
        comps.percentEncodedQuery = query
        return comps.url
    }

    nonisolated static func title(from url: URL) -> String? {
        queryValue("title", in: url)
    }

    nonisolated static func messageId(from url: URL) -> UUID? {
        queryValue("message", in: url).flatMap { UUID(uuidString: $0) }
    }

    private static func queryValue(_ name: String, in url: URL) -> String? {
        guard url.scheme == scheme,
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        return comps.queryItems?.first(where: { $0.name == name })?.value
    }

    /// The answer as an attributed string with citations rendered as links.
    nonisolated static func attributed(_ answer: String, messageId: UUID? = nil) -> AttributedString {
        var out = AttributedString()
        for part in MeetingRetrieval.citationParts(in: answer) {
            switch part {
            case .text(let text):
                out += AttributedString(text)
            case .citation(let title, let display):
                var piece = AttributedString(display)
                piece.link = url(forTitle: title, messageId: messageId)
                out += piece
            }
        }
        return out
    }
}
