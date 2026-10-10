// Scribe/Documents/OCR/AttachmentTextRecognizer.swift
//
// Extracts text from vault attachments: Vision text recognition (accurate,
// with language correction) for images, and for PDFs the text layer via
// PDFKit plus Vision OCR of pages that have no text layer (scans).
//
// This file is the only place touching Vision / PDFKit rendering, so an SDK
// change surfaces here alone. Everything is synchronous and nonisolated —
// callers run it on a background task.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
@preconcurrency import PDFKit
@preconcurrency import Vision

enum AttachmentTextKind: String, Sendable {
    case image
    case pdf
}

enum AttachmentTextRecognizerError: Error, LocalizedError {
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): return "\(name) couldn't be read."
        }
    }
}

enum AttachmentTextRecognizer {

    /// Image types Vision can read through ImageIO. (SVG is vector text
    /// already and isn't OCR'd.)
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp",
    ]

    /// Pages with at least this many characters in their text layer are
    /// taken as-is; others are rendered and OCR'd.
    static let minimumTextLayerCharacters = 16

    /// Upper bound of OCR'd pages per PDF, so one huge scan can't pin the
    /// CPU for minutes.
    static let maximumOCRPagesPerPDF = 40

    /// The kind of attachment at `path`, or nil when it isn't indexed.
    nonisolated static func kind(forPath path: String) -> AttachmentTextKind? {
        let ext = (path as NSString).pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if imageExtensions.contains(ext) { return .image }
        return nil
    }

    /// Recognized text of the file at `url` (empty when there is none).
    nonisolated static func recognizeText(at url: URL) throws -> String {
        switch kind(forPath: url.path) {
        case .pdf:
            return try recognizePDF(at: url)
        case .image:
            return try recognizeImage(at: url)
        case nil:
            return ""
        }
    }

    // MARK: - Images

    nonisolated static func recognizeImage(at url: URL) throws -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AttachmentTextRecognizerError.unreadable(url.lastPathComponent)
        }
        var orientation = CGImagePropertyOrientation.up
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
           let raw = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.uint32Value,
           let parsed = CGImagePropertyOrientation(rawValue: raw) {
            orientation = parsed
        }
        return try recognize(cgImage: image, orientation: orientation)
    }

    /// Vision text recognition on one image. Isolated here so a Vision API
    /// change is a one-function fix.
    nonisolated static func recognize(cgImage: CGImage, orientation: CGImagePropertyOrientation = .up) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        try handler.perform([request])
        let observations = request.results ?? []
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    // MARK: - PDFs

    nonisolated static func recognizePDF(at url: URL) throws -> String {
        guard let document = PDFDocument(url: url) else {
            throw AttachmentTextRecognizerError.unreadable(url.lastPathComponent)
        }
        // Encrypted PDFs without a password yield no pages.
        guard !document.isLocked else { return "" }
        var parts: [String] = []
        var ocrPages = 0
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let layer = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if layer.count >= minimumTextLayerCharacters {
                parts.append(layer)
                continue
            }
            guard ocrPages < maximumOCRPagesPerPDF, let image = renderedImage(of: page) else {
                if !layer.isEmpty { parts.append(layer) }
                continue
            }
            ocrPages += 1
            let recognized = (try? recognize(cgImage: image)) ?? ""
            let text = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
            parts.append(text.isEmpty ? layer : text)
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Renders a PDF page at roughly 2× (capped at 2400 px on the long side)
    /// for OCR.
    nonisolated static func renderedImage(of page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let longSide = max(bounds.width, bounds.height)
        guard longSide > 0 else { return nil }
        let scale = min(2.0, 2400 / longSide)
        let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
        let image = page.thumbnail(of: size, for: .mediaBox)
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    // MARK: - Text layer only (fast path for PDF import)

    /// Concatenated PDF text layer, without OCR.
    nonisolated static func pdfTextLayer(at url: URL) -> String {
        guard let document = PDFDocument(url: url) else { return "" }
        return (document.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
