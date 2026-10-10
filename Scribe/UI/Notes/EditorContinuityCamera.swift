// Scribe/UI/Notes/EditorContinuityCamera.swift
//
// Continuity Camera for the note editor: "Import from iPhone or iPad" →
// Take Photo / Scan Documents / Add Sketch.
//
// How AppKit wires it: a menu item whose identifier is
// `NSMenuItem.importFromDeviceIdentifier` is filled in by AppKit with the
// nearby devices, and is only enabled when something in the responder chain
// returns a requestor from `validRequestor(forSendType:returnType:)` for an
// image return type. When the user finishes on the device, AppKit calls the
// requestor's `NSServicesMenuRequestor.readSelection(from:)` with the image on
// a pasteboard.
//
// `ScribeEditorWebView` (the editor's WKWebView, which is first responder
// while editing) adds the menu item to its context menu and returns an
// `EditorContinuityImportRequestor`; the image is then saved like a pasted
// attachment and inserted at the caret.
//
// This file is the only place touching these AppKit services APIs, so an SDK
// change surfaces here alone.

import AppKit
import UniformTypeIdentifiers

@MainActor
enum EditorContinuityCamera {

    /// Return types we accept from the device, in preference order.
    static let acceptedTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType(UTType.jpeg.identifier),
        .png,
        NSPasteboard.PasteboardType(UTType.heic.identifier),
        .tiff,
        .pdf,
    ]

    /// Whether the editor can receive this services request (import only:
    /// nothing is sent from the editor).
    static func canImport(sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Bool {
        guard sendType == nil, let returnType else { return false }
        return acceptedTypes.contains(returnType)
    }

    /// Adds "Import from iPhone or iPad" to the editor's context menu (once).
    static func addImportItem(to menu: NSMenu) {
        let identifier = NSMenuItem.importFromDeviceIdentifier
        guard !menu.items.contains(where: { $0.identifier == identifier }) else { return }
        let item = NSMenuItem(title: "Import from iPhone or iPad", action: nil, keyEquivalent: "")
        item.identifier = identifier
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(item)
    }

    /// Pulls the imported image (or scanned PDF) off the pasteboard as
    /// (bytes, file name, MIME type). TIFF is converted to JPEG to keep
    /// photos a sensible size.
    static func extract(from pasteboard: NSPasteboard) -> (Data, String, String)? {
        let jpeg = NSPasteboard.PasteboardType(UTType.jpeg.identifier)
        let heic = NSPasteboard.PasteboardType(UTType.heic.identifier)
        if let data = pasteboard.data(forType: jpeg), !data.isEmpty {
            return (data, "Photo.jpg", "image/jpeg")
        }
        if let data = pasteboard.data(forType: .png), !data.isEmpty {
            return (data, "Image.png", "image/png")
        }
        if let data = pasteboard.data(forType: heic), !data.isEmpty {
            return (data, "Photo.heic", "image/heic")
        }
        if let data = pasteboard.data(forType: .pdf), !data.isEmpty {
            return (data, "Scan.pdf", "application/pdf")
        }
        if let tiff = pasteboard.data(forType: .tiff), !tiff.isEmpty {
            if let rep = NSBitmapImageRep(data: tiff),
               let jpegData = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
                return (jpegData, "Photo.jpg", "image/jpeg")
            }
            return (tiff, "Photo.tiff", "image/tiff")
        }
        return nil
    }
}

/// The services requestor AppKit hands the imported image to. A separate
/// object (rather than the WKWebView itself) so we never collide with
/// WKWebView's own services handling.
@MainActor
final class EditorContinuityImportRequestor: NSObject {
    private let onImport: (Data, String, String) -> Void

    init(onImport: @escaping (Data, String, String) -> Void) {
        self.onImport = onImport
        super.init()
    }
}

// `@preconcurrency`: if the SDK's NSServicesMenuRequestor isn't main-actor
// annotated, this still lets the main-actor class conform (AppKit calls it on
// the main thread).
extension EditorContinuityImportRequestor: @preconcurrency NSServicesMenuRequestor {
    func readSelection(from pboard: NSPasteboard) -> Bool {
        guard let imported = EditorContinuityCamera.extract(from: pboard) else { return false }
        onImport(imported.0, imported.1, imported.2)
        return true
    }
}
