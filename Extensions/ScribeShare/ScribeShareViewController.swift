// Extensions/ScribeShare/ScribeShareViewController.swift
//
// macOS Share extension ("Share → Scribe"): accepts text, a web URL and
// images, shows a small SwiftUI form (title + destination) and hands the
// item to the app through the App Group ShareInbox (ScribeSharePayload), then
// opens scribe://import-share so the app imports it right away. Lives outside
// Scribe/ (SwiftPM compiles all of Scribe/ into the app executable); built
// only by Xcode as the ScribeShare target and embedded in the app.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class ScribeShareViewController: NSViewController {

    private lazy var model = ScribeShareFormModel()

    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        let model = self.model
        let form = ScribeShareFormView(
            model: model,
            onCancel: { [weak self] in self?.cancel() },
            onSave: { [weak self] in self?.save() }
        )
        let hosting = NSHostingView(rootView: form)
        hosting.frame = NSRect(x: 0, y: 0, width: 420, height: 320)
        view = hosting
        preferredContentSize = NSSize(width: 420, height: 320)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Read the (non-Sendable) input items inside the main-actor task
        // rather than capturing them, so nothing non-Sendable is sent into it.
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
        var images: [ScribeShareImage] = []
        var suggestedTitle: String?

        for item in items {
            if suggestedTitle == nil, let title = item.attributedTitle?.string, !title.isEmpty {
                suggestedTitle = title
            }
            if let content = item.attributedContentText?.string,
               !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                texts.append(content)
            }
            for provider in item.attachments ?? [] {
                if let imageType = Self.imageTypeIdentifier(of: provider) {
                    if let data = await Self.loadData(provider, typeIdentifier: imageType) {
                        let ext = UTType(imageType)?.preferredFilenameExtension ?? "png"
                        images.append(ScribeShareImage(data: data, fileExtension: ext))
                    }
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
            images: images
        )
    }

    /// The first registered type of `provider` that is an image.
    private static func imageTypeIdentifier(of provider: NSItemProvider) -> String? {
        provider.registeredTypeIdentifiers.first { identifier in
            UTType(identifier)?.conforms(to: .image) ?? false
        }
    }

    // Loading: the async wrappers run on the main actor; the NSItemProvider
    // requests are started from `nonisolated` helpers so the completion
    // closures are never main-actor-isolated (they're called on a background
    // queue). Only Sendable values (Data / URL / String) cross back.

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
            try inbox.write(payload, images: model.images)
        } catch {
            model.errorMessage = "Couldn't hand the item to Scribe: \(error.localizedDescription)"
            return
        }
        Self.openScribeImport()
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    private func cancel() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        extensionContext?.cancelRequest(withError: error)
    }

    /// Asks Scribe to import now (launching it if needed). If this fails the
    /// item stays in the inbox and is imported on Scribe's next launch.
    private static func openScribeImport() {
        NSWorkspace.shared.open(ScribeAppGroup.importShareURL)
    }
}
