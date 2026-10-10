// Extensions/ScribeiOSShare/ScribeiOSShareViewController.swift
//
// iPhone / iPad Share extension ("Share → Scribe"): accepts text, a web URL,
// images and PDFs, shows a SwiftUI form (title + destination) and hands the
// item to the app through the App Group ShareInbox (ScribeSharePayload).
// iOS doesn't let a Share extension open its app, so Scribe imports the item
// the next time it becomes active (ScribeiOS/System/IOSSystemIntegration).
// Lives outside Scribe/ (SwiftPM compiles all of Scribe/ into the Mac app's
// executable); built only by Xcode as the ScribeiOSShare target.

import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class ScribeiOSShareViewController: UIViewController {

    private lazy var model = ScribeiOSShareFormModel()

    /// Matches the app's attachment limit (EditorAttachmentFiles.maxBytes).
    private static let maxAttachmentBytes = 50 * 1024 * 1024

    override func viewDidLoad() {
        super.viewDidLoad()
        let form = ScribeiOSShareFormView(
            model: model,
            onCancel: { [weak self] in self?.cancel() },
            onSave: { [weak self] in self?.save() }
        )
        let hosting = UIHostingController(rootView: form)
        addChild(hosting)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hosting.didMove(toParent: self)

        // Read the (non-Sendable) input items inside the main-actor task
        // rather than capturing them.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let items = (self.extensionContext?.inputItems as? [NSExtensionItem]) ?? []
            await self.load(items)
        }
    }

    // MARK: - Loading the shared items

    private func load(_ items: [NSExtensionItem]) async {
        var texts: [String] = []
        var urls: [String] = []
        var attachments: [ScribeShareImage] = []
        var skipped = 0
        var suggestedTitle: String?

        for item in items {
            if suggestedTitle == nil, let title = item.attributedTitle?.string, !title.isEmpty {
                suggestedTitle = title
            }
            if let content = item.attributedContentText?.string,
               !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !texts.contains(content) {
                texts.append(content)
            }
            for provider in item.attachments ?? [] {
                if let fileType = Self.attachmentTypeIdentifier(of: provider) {
                    guard let data = await Self.loadData(provider, typeIdentifier: fileType) else { continue }
                    guard data.count <= Self.maxAttachmentBytes else {
                        skipped += 1
                        continue
                    }
                    let ext = UTType(fileType)?.preferredFilenameExtension ?? "png"
                    attachments.append(ScribeShareImage(data: data, fileExtension: ext))
                } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    if let url = await Self.loadURL(provider) {
                        if url.isFileURL {
                            texts.append(url.lastPathComponent)
                        } else if !urls.contains(url.absoluteString) {
                            urls.append(url.absoluteString)
                        }
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    if let text = await Self.loadText(provider),
                       !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       !texts.contains(text) {
                        texts.append(text)
                    }
                }
            }
        }

        model.didLoad(
            suggestedTitle: suggestedTitle,
            text: texts.joined(separator: "\n\n"),
            urls: urls,
            attachments: attachments,
            skippedCount: skipped
        )
    }

    /// The first registered type of `provider` that is an image or a PDF.
    private static func attachmentTypeIdentifier(of provider: NSItemProvider) -> String? {
        provider.registeredTypeIdentifiers.first { identifier in
            guard let type = UTType(identifier) else { return false }
            return type.conforms(to: .image) || type.conforms(to: .pdf)
        }
    }

    // Loading: the async wrappers run on the main actor; the NSItemProvider
    // requests start from `nonisolated` helpers so their completion closures
    // (called on a background queue) are never main-actor-isolated. Only
    // Sendable values (Data / URL / String) cross back.

    private static func loadData(_ provider: NSItemProvider, typeIdentifier: String) async -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            startLoadingData(provider, typeIdentifier: typeIdentifier) { data in
                continuation.resume(returning: data)
            }
        }
    }

    private static func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            startLoadingURL(provider) { url in
                continuation.resume(returning: url)
            }
        }
    }

    private static func loadText(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            startLoadingText(provider) { text in
                continuation.resume(returning: text)
            }
        }
    }

    nonisolated private static func startLoadingData(
        _ provider: NSItemProvider,
        typeIdentifier: String,
        completion: @escaping @Sendable (Data?) -> Void
    ) {
        _ = provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
            completion(data)
        }
    }

    nonisolated private static func startLoadingURL(
        _ provider: NSItemProvider,
        completion: @escaping @Sendable (URL?) -> Void
    ) {
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            completion(url)
        }
    }

    nonisolated private static func startLoadingText(
        _ provider: NSItemProvider,
        completion: @escaping @Sendable (String?) -> Void
    ) {
        _ = provider.loadObject(ofClass: String.self) { text, _ in
            completion(text)
        }
    }

    // MARK: - Actions

    private func save() {
        guard let inbox = ScribeShareInbox.appGroup() else {
            model.errorMessage = "Scribe's shared folder isn't available. Make sure Scribe is installed and signed."
            return
        }
        let payload = model.makePayload(now: Date())
        do {
            try inbox.write(payload, images: model.attachments)
        } catch {
            model.errorMessage = "Couldn't hand the item to Scribe: \(error.localizedDescription)"
            return
        }
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    private func cancel() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        extensionContext?.cancelRequest(withError: error)
    }
}
