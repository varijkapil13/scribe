import SwiftUI
import AppKit

// MARK: - MCP Server

/// Settings → MCP. Starts/stops the local MCP server, validates the port
/// before storing it, and shows the bearer token clients must present plus a
/// copy-ready client config snippet.
struct MCPSettingsPane: View {

    @AppStorage("mcpEnabled") var mcpEnabled: Bool = false
    @AppStorage("mcpPort")    var mcpPort: Int = Int(MCPPortPolicy.defaultPort)
    @ObservedObject private var server = MCPServer.shared

    @State private var portText: String = ""
    @State private var portError: String?
    @State private var revealToken = false
    @State private var confirmRegenerate = false

    /// The stored port, sanitised: an out-of-range value never traps.
    private var effectivePort: UInt16 { MCPPortPolicy.sanitize(mcpPort) }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    Toggle("Enable MCP Server", isOn: Binding(
                        get: { mcpEnabled },
                        set: { enabled in
                            mcpEnabled = enabled
                            if enabled { server.start(port: effectivePort) }
                            else       { server.stop() }
                        }
                    ))
                    Text("Exposes tasks and transcripts to LLM agents via the Model Context Protocol (HTTP+SSE on 127.0.0.1).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if mcpEnabled {
                    LabeledContent("Status") {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(server.isRunning ? Color.green : Color.orange)
                                .frame(width: 8, height: 8)
                            Text(server.isRunning ? "Running on port \(server.port)" : "Starting…")
                                .foregroundStyle(.secondary)
                        }
                    }

                    LabeledContent("Port") {
                        VStack(alignment: .trailing, spacing: 2) {
                            HStack {
                                TextField("", text: $portText)
                                    .frame(width: 80)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit { commitPort() }
                                Button("Apply") { commitPort() }
                                    .disabled(portText == String(effectivePort))
                                Text("(1024–65535)")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            if let portError {
                                Text(portError)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                    }

                    if let error = server.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
                }
            } header: {
                Text("MCP Server")
            } footer: {
                Text("Only reachable from this Mac (127.0.0.1). Every request must carry the bearer token below; browser requests are refused.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if mcpEnabled {
                Section {
                    LabeledContent("Token") {
                        Text(revealToken ? server.token : maskedToken)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    HStack {
                        Button(revealToken ? "Hide" : "Show") { revealToken.toggle() }
                        Button("Copy Token") { copyToPasteboard(server.token) }
                        Spacer()
                        Button("Regenerate Token…", role: .destructive) { confirmRegenerate = true }
                    }
                } header: {
                    Text("Authentication")
                } footer: {
                    Text("Stored in your Keychain. Regenerating disconnects every connected agent; update their configs with the new token.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .confirmationDialog("Regenerate the MCP token?",
                                    isPresented: $confirmRegenerate) {
                    Button("Regenerate", role: .destructive) { server.regenerateToken() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Agents using the current token will be disconnected.")
                }

                Section("Connect an Agent") {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                        Text("Add this to your MCP client config:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(MCPClientConfig.snippet(port: effectivePort,
                                                     token: revealToken ? server.token : maskedToken))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(DesignTokens.Spacing.sm)
                            .background(DesignTokens.Palette.fill(.hover))
                            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm))
                        HStack {
                            Button("Copy Config") {
                                copyToPasteboard(MCPClientConfig.snippet(port: effectivePort, token: server.token))
                            }
                            Button("Copy URL with Token") {
                                copyToPasteboard(MCPClientConfig.urlWithToken(port: effectivePort, token: server.token))
                            }
                        }
                        Text("Clients that can't send an Authorization header may use the URL with ?token= instead.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if server.isRunning {
                    Section("Available Tools") {
                        ForEach(toolList, id: \.0) { name, desc in
                            LabeledContent(name) {
                                Text(desc)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            // Repair a corrupt stored value instead of trapping on it.
            if MCPPortPolicy.validated(mcpPort) == nil {
                mcpPort = Int(MCPPortPolicy.defaultPort)
            }
            portText = String(effectivePort)
            server.loadToken()
            if mcpEnabled && !server.isRunning {
                server.start(port: effectivePort)
            }
        }
    }

    private var maskedToken: String {
        String(repeating: "•", count: 24)
    }

    /// Validates the typed port before storing it; restarts the server on
    /// the new port when it is enabled.
    private func commitPort() {
        guard let newPort = MCPPortPolicy.validated(text: portText) else {
            portError = "Enter a whole number between 1024 and 65535."
            return
        }
        portError = nil
        portText = String(newPort)
        guard Int(newPort) != mcpPort || !server.isRunning else { return }
        mcpPort = Int(newPort)
        if mcpEnabled { server.restart(port: newPort) }
    }

    private func copyToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    private var toolList: [(String, String)] {
        [
            ("create_task",       "Create a task with title, notes, due date, priority"),
            ("list_tasks",        "List tasks by filter (today, inbox, all, …)"),
            ("search_tasks",      "Full-text search across tasks"),
            ("update_task",       "Update title, notes, due date, priority, or completion"),
            ("delete_task",       "Delete a task by ID"),
            ("list_transcripts",  "List recent recording sessions"),
            ("get_transcript",    "Get full transcript text and action items"),
        ]
    }
}
