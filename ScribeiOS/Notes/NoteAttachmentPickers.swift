// ScribeiOS/Notes/NoteAttachmentPickers.swift
//
// Device sources for note attachments on iPhone / iPad: the camera
// (UIImagePickerController) and the VisionKit document scanner
// (VNDocumentCameraViewController). The photo library uses SwiftUI's
// PhotosPicker directly in NoteEditorScreen. Every source ends in
// `WebEditorCoordinator.importDeviceFiles`, which saves into the note's
// `attachments/<noteId>/` folder (EditorAttachmentFiles — same naming and
// size rules as the Mac) and inserts `![name](attachments/…)` at the caret;
// the editor renders it inline via `scribe-asset://vault/…`.

import PhotosUI
import SwiftUI
import UIKit
import VisionKit

/// JPEG quality for camera photos and scanned pages.
private let captureJPEGQuality: CGFloat = 0.85

@MainActor
enum NoteAttachmentSources {
    static var isCameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    static var isScannerAvailable: Bool {
        VNDocumentCameraViewController.isSupported
    }

    /// Loads picked photo-library items as attachment files (in pick order).
    static func files(from items: [PhotosPickerItem]) async -> [EditorImportedFile] {
        let date = Date()
        var files: [EditorImportedFile] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty else { continue }
            let format = EditorCaptureNaming.imageFormat(of: data)
            let name = EditorCaptureNaming.filename(
                kind: .photo, date: date, ext: format.ext,
                page: files.count + 1, pageCount: items.count
            )
            files.append(EditorImportedFile(data: data, filename: name, mimeType: format.mimeType))
        }
        return files
    }

    /// A camera photo as an attachment file.
    static func file(fromCameraImage image: UIImage) -> EditorImportedFile? {
        let date = Date()
        guard let data = image.jpegData(compressionQuality: captureJPEGQuality) else { return nil }
        let name = EditorCaptureNaming.filename(kind: .camera, date: date, ext: "jpg")
        return EditorImportedFile(data: data, filename: name, mimeType: "image/jpeg")
    }

    /// Scanned pages as attachment files (one JPEG per page, in order).
    static func files(fromScanPages pages: [UIImage]) -> [EditorImportedFile] {
        let date = Date()
        return pages.enumerated().compactMap { index, image -> EditorImportedFile? in
            guard let data = image.jpegData(compressionQuality: captureJPEGQuality) else { return nil }
            let name = EditorCaptureNaming.filename(
                kind: .scan, date: date, ext: "jpg", page: index + 1, pageCount: pages.count
            )
            return EditorImportedFile(data: data, filename: name, mimeType: "image/jpeg")
        }
    }
}

// MARK: - Camera

/// Takes one photo with the camera.
struct NoteCameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = ["public.image"]
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {
        context.coordinator.parent = self
    }

    @MainActor
    // @preconcurrency: tolerates either isolation of the delegate protocols
    // across SDKs (they are main-thread callbacks either way).
    final class Coordinator: NSObject, @preconcurrency UIImagePickerControllerDelegate,
                             @preconcurrency UINavigationControllerDelegate {
        var parent: NoteCameraPicker

        init(parent: NoteCameraPicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImage(image)
            } else {
                parent.onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCancel()
        }
    }
}

// MARK: - Document scanner

/// Scans one or more pages with VisionKit.
struct NoteDocumentScanner: UIViewControllerRepresentable {
    var onPages: ([UIImage]) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {
        context.coordinator.parent = self
    }

    @MainActor
    // @preconcurrency: see NoteCameraPicker.Coordinator.
    final class Coordinator: NSObject, @preconcurrency VNDocumentCameraViewControllerDelegate {
        var parent: NoteDocumentScanner

        init(parent: NoteDocumentScanner) {
            self.parent = parent
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            var pages: [UIImage] = []
            for index in 0..<scan.pageCount {
                pages.append(scan.imageOfPage(at: index))
            }
            parent.onPages(pages)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.onCancel()
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: any Error
        ) {
            parent.onCancel()
        }
    }
}
