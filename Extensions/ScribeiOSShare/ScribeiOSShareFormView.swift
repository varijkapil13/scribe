// Extensions/ScribeiOSShare/ScribeiOSShareFormView.swift
//
// The iOS Share sheet's form: a title, where the item goes (new note / append
// to the Inbox note / new task) and a summary of what was shared (text, a
// link, images, PDFs).

import Observation
import SwiftUI

@MainActor
@Observable
final class ScribeiOSShareFormModel {

    var title: String = ""
    var destination: ScribeSharePayload.Destination = .newNote
    var errorMessage: String?

    private(set) var isLoading = true
    private(set) var text: String = ""
    private(set) var urls: [String] = []
    /// Images and PDFs, in the order shared.
    private(set) var attachments: [ScribeShareImage] = []
    /// Files that were too large to hand over.
    private(set) var skippedCount = 0

    init() {}

    var canSave: Bool {
        !isLoading && (
            !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !urls.isEmpty
                || !attachments.isEmpty
        )
    }

    func didLoad(suggestedTitle: String?, text: String, urls: [String], attachments: [ScribeShareImage], skippedCount: Int) {
        self.text = text
        self.urls = urls
        self.attachments = attachments
        self.skippedCount = skippedCount
        if title.isEmpty, let suggestedTitle {
            title = suggestedTitle
        }
        isLoading = false
    }

    func makePayload(now: Date) -> ScribeSharePayload {
        ScribeSharePayload(
            createdAt: now,
            destination: destination,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            text: text,
            urls: urls,
            imageFileNames: []
        )
    }

    private var documentCount: Int {
        attachments.filter { ScribeShareInbox.isDocumentExtension($0.fileExtension) }.count
    }

    /// Lines describing the shared content.
    var summaryLines: [String] {
        var lines: [String] = []
        if !text.isEmpty {
            let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            lines.append(firstLine)
        }
        lines.append(contentsOf: urls)
        let images = attachments.count - documentCount
        if images > 0 { lines.append(images == 1 ? "1 image" : "\(images) images") }
        if documentCount > 0 { lines.append(documentCount == 1 ? "1 PDF" : "\(documentCount) PDFs") }
        if skippedCount > 0 {
            lines.append(skippedCount == 1 ? "1 file is too large to save" : "\(skippedCount) files are too large to save")
        }
        return lines.isEmpty ? ["Nothing to share"] : lines
    }
}

struct ScribeiOSShareFormView: View {

    @Bindable var model: ScribeiOSShareFormModel
    let onCancel: @MainActor () -> Void
    let onSave: @MainActor () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $model.title, prompt: Text("Title (optional)"))
                }

                Section {
                    Picker("Save as", selection: $model.destination) {
                        ForEach(ScribeSharePayload.Destination.allCases, id: \.self) { destination in
                            Text(destination.label).tag(destination)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Save as")
                } footer: {
                    if model.destination == .newTask, !model.attachments.isEmpty {
                        Text("Images and PDFs can only be saved to notes; the task keeps the text and links.")
                    }
                }

                Section {
                    if model.isLoading {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Reading shared items…")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(Array(model.summaryLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .lineLimit(2)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Shared")
                } footer: {
                    Text("Scribe adds it the next time you open the app.")
                }

                if let error = model.errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Save to Scribe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave() }
                        .disabled(!model.canSave)
                }
            }
        }
    }
}
