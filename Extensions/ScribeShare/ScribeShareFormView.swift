// Extensions/ScribeShare/ScribeShareFormView.swift
//
// The Share sheet's form: a title, where the item should go (new note /
// append to the Inbox note / new task) and a preview of what was shared.

import Observation
import SwiftUI

@MainActor
@Observable
final class ScribeShareFormModel {

    var title: String = ""
    var destination: ScribeSharePayload.Destination = .newNote
    var errorMessage: String?

    private(set) var isLoading = true
    private(set) var text: String = ""
    private(set) var urls: [String] = []
    private(set) var images: [ScribeShareImage] = []

    init() {}

    var canSave: Bool {
        !isLoading && (
            !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !urls.isEmpty
                || !images.isEmpty
        )
    }

    func didLoad(suggestedTitle: String?, text: String, urls: [String], images: [ScribeShareImage]) {
        self.text = text
        self.urls = urls
        self.images = images
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

    /// One-line description of the shared content for the form.
    var summary: String {
        var parts: [String] = []
        if !text.isEmpty {
            let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            parts.append(firstLine)
        }
        parts.append(contentsOf: urls)
        if !images.isEmpty {
            parts.append(images.count == 1 ? "1 image" : "\(images.count) images")
        }
        return parts.isEmpty ? "Nothing to share" : parts.joined(separator: " · ")
    }
}

struct ScribeShareFormView: View {

    @Bindable var model: ScribeShareFormModel
    let onCancel: @MainActor () -> Void
    let onSave: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Save to Scribe", systemImage: "square.and.arrow.down")
                .font(.headline)

            Form {
                TextField("Title", text: $model.title, prompt: Text("Optional"))
                Picker("Save as", selection: $model.destination) {
                    ForEach(ScribeSharePayload.Destination.allCases, id: \.self) { destination in
                        Text(destination.label).tag(destination)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            GroupBox {
                if model.isLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading shared items…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(model.summary)
                        .lineLimit(3)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if model.destination == .newTask, !model.images.isEmpty {
                Text("Images can only be saved to notes; the task keeps the text and links.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSave)
            }
        }
        .padding(20)
        .frame(width: 420, height: 320)
    }
}
