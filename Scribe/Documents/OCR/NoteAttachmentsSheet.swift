// Scribe/Documents/OCR/NoteAttachmentsSheet.swift
//
// A note's image / PDF attachments in native views: images get Live Text
// (VisionKit's ImageAnalysisOverlayView — select, copy and look up text
// right in the picture), PDFs show in a PDFView, and the text the
// background indexer recognized is listed below with Copy / Recognize Now.

import AppKit
@preconcurrency import PDFKit
import SwiftUI
@preconcurrency import VisionKit

struct NoteAttachmentsSheet: View {
    let noteId: String
    let noteTitle: String

    @Environment(\.dismiss) private var dismiss
    @State private var files: [URL] = []
    @State private var selection: URL?
    @State private var recognizedText: [String: String] = [:]
    @State private var isRecognizing = false

    private var root: URL { AttachmentsDirectory.defaultRoot() }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Attachments in \u{201C}\(noteTitle.isEmpty ? "Untitled" : noteTitle)\u{201D}")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            if files.isEmpty {
                ContentUnavailableView(
                    "No Images or PDFs",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text("Images and PDFs you add to this note appear here, with their recognized text.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    List(files, id: \.self, selection: $selection) { url in
                        Label(url.lastPathComponent,
                              systemImage: url.pathExtension.lowercased() == "pdf" ? "doc.richtext" : "photo")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(minWidth: 180, idealWidth: 200, maxWidth: 260)
                    detail
                        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .onAppear(perform: load)
    }

    @ViewBuilder
    private var detail: some View {
        if let url = selection {
            VSplitView {
                Group {
                    if url.pathExtension.lowercased() == "pdf" {
                        PDFDocumentView(url: url)
                    } else {
                        LiveTextImageView(url: url)
                    }
                }
                .frame(minHeight: 220, maxHeight: .infinity)
                recognizedTextPanel(for: url)
                    .frame(minHeight: 120, idealHeight: 160)
            }
        } else {
            Text("Select an attachment")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func recognizedTextPanel(for url: URL) -> some View {
        let text = recognizedText[relativePath(of: url) ?? ""] ?? ""
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recognized text")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if isRecognizing { ProgressView().controlSize(.small) }
                Button("Recognize Now") { recognize(url) }
                    .disabled(isRecognizing)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .disabled(text.isEmpty)
            }
            ScrollView {
                Text(text.isEmpty ? "No text recognized yet." : text)
                    .font(.callout)
                    .foregroundStyle(text.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
    }

    // MARK: - Data

    private func relativePath(of url: URL) -> String? {
        VaultWriteGuard.relativePath(of: url.path, under: root.path)
    }

    private func load() {
        let folder = root
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(noteId, isDirectory: true)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        files = contents
            .filter { AttachmentTextRecognizer.kind(forPath: $0.path) != nil }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        if selection == nil { selection = files.first }
        reloadText()
    }

    private func reloadText() {
        let records = (try? AttachmentTextStore.shared.records(forNoteId: noteId)) ?? []
        recognizedText = Dictionary(records.map { ($0.path, $0.text) }, uniquingKeysWith: { first, _ in first })
    }

    private func recognize(_ url: URL) {
        guard let relative = relativePath(of: url) else { return }
        isRecognizing = true
        let root = self.root
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let stat = AttachmentFileStat(
            relativePath: relative,
            size: Int64(values?.fileSize ?? 0),
            modifiedAt: values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        )
        Task {
            await Task.detached(priority: .userInitiated) {
                // `existing: nil` forces recognition even for unchanged bytes.
                AttachmentOCRIndexer.index(stat, root: root, existing: nil, store: .shared)
            }.value
            isRecognizing = false
            reloadText()
        }
    }
}

// MARK: - Live Text image

/// An image with Live Text: text in the picture can be selected, copied,
/// translated and looked up (VisionKit image analysis).
struct LiveTextImageView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> LiveTextImageContainer {
        LiveTextImageContainer()
    }

    func updateNSView(_ view: LiveTextImageContainer, context: Context) {
        view.load(url)
    }
}

final class LiveTextImageContainer: NSView {
    private let imageView = NSImageView()
    private let overlay = ImageAnalysisOverlayView()
    private var loadedURL: URL?
    private var analysisTask: Task<Void, Never>?

    init() {
        super.init(frame: .zero)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        overlay.frame = imageView.bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.trackingImageView = imageView
        overlay.preferredInteractionTypes = .automatic
        imageView.addSubview(overlay)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func load(_ url: URL) {
        guard url != loadedURL else { return }
        loadedURL = url
        analysisTask?.cancel()
        overlay.analysis = nil
        let image = NSImage(contentsOf: url)
        imageView.image = image
        guard image != nil, ImageAnalyzer.isSupported else { return }
        analysisTask = Task { [weak self] in
            let analysis = await LiveTextAnalysis.analyze(imageAt: url)
            guard !Task.isCancelled, let self, self.loadedURL == url else { return }
            self.overlay.analysis = analysis
        }
    }
}

/// The one VisionKit analysis call, isolated so an SDK change is a
/// one-function fix.
enum LiveTextAnalysis {
    /// Analyzes the file itself (a `URL` crosses into VisionKit's executor
    /// safely; an `NSImage` would have to be sent).
    @MainActor
    static func analyze(imageAt url: URL) async -> ImageAnalysis? {
        let analyzer = ImageAnalyzer()
        let configuration = ImageAnalyzer.Configuration([.text, .machineReadableCode])
        return try? await analyzer.analyze(imageAt: url, orientation: .up, configuration: configuration)
    }
}

// MARK: - PDF

struct PDFDocumentView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displaysPageBreaks = true
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
    }
}
