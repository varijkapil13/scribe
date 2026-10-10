import SwiftUI

/// Settings → Intelligence → "Semantic search": the on-device embedding index
/// that powers "Related notes" in search and hybrid retrieval in Ask Scribe
/// (see `Scribe/Intelligence/Semantic`).
struct SemanticSearchSettingsSection: View {
    @AppStorage(SemanticSearchSettings.enabledKey) private var enabled = false
    @State private var indexedChunks: Int?
    @State private var isRebuilding = false

    var body: some View {
        Section("Semantic search") {
            Toggle("Semantic search (on-device)", isOn: $enabled)
            Text("Finds notes and meetings by meaning, not just matching words: adds a “Related notes” section to search and blends meaning-based matches into Ask Scribe. Scribe builds the index slowly in the background on your Mac; nothing leaves your device.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if enabled {
                HStack {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Rebuild Index") { rebuild() }
                        .disabled(isRebuilding)
                }
            }
        }
        .task(id: enabled) { await refreshCount() }
    }

    private var statusText: String {
        guard let indexedChunks else { return "Checking the index…" }
        if indexedChunks == 0 { return "The index is being built." }
        return "\(indexedChunks.formatted()) passages indexed."
    }

    private func refreshCount() async {
        let count = await Task.detached(priority: .utility) {
            (try? SemanticEmbeddingStore(dbManager: .shared).chunkCount()) ?? 0
        }.value
        indexedChunks = count
    }

    private func rebuild() {
        isRebuilding = true
        Task {
            await Task.detached(priority: .utility) {
                try? SemanticEmbeddingStore(dbManager: .shared).deleteAll()
                SemanticSearchService.shared.invalidate()
            }.value
            SemanticIndexScheduler.shared.kick()
            await refreshCount()
            isRebuilding = false
        }
    }
}
