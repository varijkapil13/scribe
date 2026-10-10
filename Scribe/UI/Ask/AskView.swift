// Scribe/UI/Ask/AskView.swift
import SwiftUI

/// "Ask Scribe" — a chat surface that answers questions across meetings,
/// summaries and notes, citing sources as clickable `[[Note Title]]` links.
struct AskView: View {

    let onNavigate: (MainSelection) -> Void

    @StateObject private var viewModel = AskViewModel()
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !viewModel.availability.isAvailable {
                unavailableBanner
            }
            conversation
            Divider()
            inputBar
        }
        .background(DesignTokens.Palette.surface)
        .onAppear {
            viewModel.onAppear()
            inputFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .scribeAskCitationTapped)) { note in
            guard let url = note.object as? URL,
                  let title = AskCitationLink.title(from: url) else { return }
            let messageId = AskCitationLink.messageId(from: url)
            let message = viewModel.messages.first(where: { $0.id == messageId })
                ?? AskMessage(role: .assistant, text: "")
            if let dest = viewModel.destination(forCitation: title, in: message) {
                onNavigate(dest)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text("Ask Scribe")
                    .font(DesignTokens.Typography.title2)
                Text("Questions across your meetings, summaries and notes. Answered on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            scopeMenu
            if !viewModel.messages.isEmpty {
                Button {
                    viewModel.clear()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .help("Clear the conversation")
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.xl)
        .padding(.vertical, DesignTokens.Spacing.lg)
    }

    private var scopeMenu: some View {
        Menu {
            Button("All meetings") { viewModel.scope = .all }
            Button("Last 7 days") { viewModel.scope = .lastDays(7) }
            Button("Last 30 days") { viewModel.scope = .lastDays(30) }
            Menu("Notebook") {
                if viewModel.notebooks.isEmpty {
                    Text("No notebooks")
                } else {
                    ForEach(viewModel.notebooks) { notebook in
                        Button(notebook.name) {
                            viewModel.scope = .notebook(id: notebook.id, name: notebook.name)
                        }
                    }
                }
            }
            Menu("Person") {
                if viewModel.people.isEmpty {
                    Text("No people found yet")
                } else {
                    ForEach(Array(viewModel.people.prefix(40))) { person in
                        Button(person.name) {
                            viewModel.scope = .person(key: person.id, name: person.name)
                        }
                    }
                }
            }
        } label: {
            Label(viewModel.scope.label, systemImage: "scope")
        }
        .fixedSize()
        .help("Limit which meetings the answer draws from")
        .accessibilityLabel("Scope: \(viewModel.scope.label)")
    }

    private var unavailableBanner: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "sparkles")
                .foregroundStyle(.secondary)
            Text(unavailableText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignTokens.Spacing.xl)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background(DesignTokens.Palette.surfaceSunken)
    }

    private var unavailableText: String {
        var reason = "Apple Intelligence isn't available."
        if case .unavailable(let detail) = viewModel.availability { reason = detail }
        return "\(reason) Scribe will show the most relevant passages from your meetings instead of a written answer."
    }

    // MARK: - Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                    if viewModel.messages.isEmpty {
                        emptyState
                    }
                    ForEach(viewModel.messages) { message in
                        AskMessageView(
                            message: message,
                            onOpenSnippet: { snippet in
                                if let dest = AskViewModel.destination(for: snippet) {
                                    onNavigate(dest)
                                }
                            }
                        )
                        .id(message.id)
                    }
                }
                .padding(.horizontal, DesignTokens.Spacing.xl)
                .padding(.vertical, DesignTokens.Spacing.lg)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: viewModel.messages) { _, newValue in
                if let last = newValue.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            Text("Try asking")
                .eyebrowStyle()
            ForEach(Self.examples, id: \.self) { example in
                Button {
                    viewModel.draft = example
                    inputFocused = true
                } label: {
                    Label(example, systemImage: "text.bubble")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.top, DesignTokens.Spacing.xl)
    }

    private static let examples: [String] = [
        "What did we decide about the launch date?",
        "What are the open questions on the budget?",
        "What has been said about hiring recently?"
    ]

    // MARK: - Input

    private var inputBar: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            TextField("Ask about your meetings…", text: $viewModel.draft)
                .textFieldStyle(.roundedBorder)
                .focused($inputFocused)
                .onSubmit { viewModel.send() }
                .disabled(viewModel.isAnswering)
            if viewModel.isAnswering {
                ProgressView().controlSize(.small)
            }
            Button {
                viewModel.send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20))
            }
            .buttonStyle(.plain)
            .foregroundStyle(viewModel.canSend ? Color.accentColor : Color.secondary)
            .disabled(!viewModel.canSend)
            .keyboardShortcut(.return, modifiers: [.command])
            .help("Send (⌘↩)")
            .accessibilityLabel("Send question")
        }
        .padding(.horizontal, DesignTokens.Spacing.xl)
        .padding(.vertical, DesignTokens.Spacing.md)
    }
}

// MARK: - Message

private struct AskMessageView: View {
    let message: AskMessage
    let onOpenSnippet: (RetrievedSnippet) -> Void

    @State private var showSources = false

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: DesignTokens.Spacing.xxxl)
                VStack(alignment: .trailing, spacing: DesignTokens.Spacing.xxs) {
                    Text(message.text)
                        .textSelection(.enabled)
                        .padding(.horizontal, DesignTokens.Spacing.md)
                        .padding(.vertical, DesignTokens.Spacing.sm)
                        .background(Color.accentColor.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
                    if let scope = message.scopeLabel {
                        Text(scope)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        case .assistant:
            assistantBody
        }
    }

    @ViewBuilder
    private var assistantBody: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            if message.isPending {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("Searching your meetings…")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(AskCitationLink.attributed(message.text, messageId: message.id))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .environment(\.openURL, OpenURLAction { url in
                        // Captures nothing: hand the click to AskView, which
                        // knows the conversation and the navigator.
                        guard AskCitationLink.title(from: url) != nil else { return .systemAction }
                        NotificationCenter.default.post(name: .scribeAskCitationTapped, object: url)
                        return .handled
                    })

                if let notice = message.notice {
                    Label(notice, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !message.snippets.isEmpty {
                    DisclosureGroup(isExpanded: $showSources) {
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                            ForEach(message.snippets) { snippet in
                                AskSnippetRow(snippet: snippet) { onOpenSnippet(snippet) }
                            }
                        }
                        .padding(.top, DesignTokens.Spacing.xs)
                    } label: {
                        Text("Sources (\(message.snippets.count))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(DesignTokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.Palette.surfaceElevated,
                    in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .strokeBorder(DesignTokens.Palette.cardBorder, lineWidth: 1)
        )
        .onAppear {
            // Without a written answer, the sources ARE the answer.
            if !message.usedModel && !message.snippets.isEmpty { showSources = true }
        }
    }
}

private struct AskSnippetRow: View {
    let snippet: RetrievedSnippet
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        Text(snippet.citationTitle)
                            .font(.caption.weight(.semibold))
                        Text(snippet.date, style: .date)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        if let speaker = snippet.speaker, !speaker.isEmpty {
                            Text("· \(speaker)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Text(snippet.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(snippet.kind == .note ? "Open note" : "Open meeting")
    }

    private var icon: String {
        switch snippet.kind {
        case .transcript: return "waveform"
        case .summary:    return "text.alignleft"
        case .note:       return "doc.text"
        }
    }
}
