import SwiftUI

/// Settings → Documents: text recognition in attachments, locked notes,
/// importers and exports.
struct DocumentsSettingsPane: View {
    @ObservedObject private var indexer: AttachmentOCRIndexer = .shared
    @ObservedObject private var lockSession: LockedNoteSession = .shared

    @AppStorage(DocumentsPreferences.ocrEnabledKey) private var ocrEnabled: Bool = true
    @AppStorage(LockedNoteRelockPolicy.idleMinutesKey) private var idleMinutes: Int = LockedNoteRelockPolicy.defaultIdleMinutes

    var body: some View {
        Form {
            Section("Text in images and PDFs") {
                Toggle("Recognize text in attachments", isOn: $ocrEnabled)
                    .onChange(of: ocrEnabled) { _, enabled in
                        if enabled { indexer.requestPass(after: 1) }
                    }
                LabeledContent("Indexed attachments") {
                    HStack {
                        if indexer.isRunning { ProgressView().controlSize(.small) }
                        Text("\(indexer.indexedCount)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Recognize Now") { indexer.runPass() }
                    .disabled(!ocrEnabled || indexer.isRunning)
                Text("Scribe reads the text in images and scanned PDFs in your notes on this Mac, in the background and a few files at a time, so searching finds it. Open a note's Document menu › Attachments to use Live Text on its images.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Locked notes") {
                Picker("Lock again after", selection: $idleMinutes) {
                    ForEach(LockedNoteRelockPolicy.idleMinuteChoices, id: \.self) { minutes in
                        Text(minutes == 60 ? "1 hour" : "\(minutes) minute\(minutes == 1 ? "" : "s")")
                            .tag(minutes)
                    }
                }
                Button("Lock All Notes Now") { lockSession.lock() }
                    .disabled(!lockSession.isUnlocked)
                Text("Lock a note from its Document menu. Locked notes are encrypted (AES-GCM) with a key kept in this Mac's Keychain and unlocked with Touch ID or your login password. They lock again when you close the window, the Mac sleeps or after the time above. Locked notes can't be opened on another Mac, and their contents are left out of search, Spotlight and the MCP server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Import") {
                ForEach(NoteImportKind.allCases) { kind in
                    Button(kind.menuTitle) { DocumentImportController.shared.beginImport(kind) }
                }
                Text("Imports never change existing notes: imported notes get new files, and a title that's already taken gets a number added.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Export") {
                Button("Export Notes Vault as ZIP…") { VaultZipExporter.exportInteractively() }
                Text("A zip of every note as Markdown with its attachments. To export one note as HTML or PDF, use its Document menu or File › Export.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}
