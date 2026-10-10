// Scribe/UI/Notes/Portable/EditorCaptureNaming.swift
//
// File names for attachments captured on iPhone / iPad (photo library,
// camera, document scanner) before they go through
// `EditorAttachmentFiles.save` (which sanitizes and de-duplicates them into
// `attachments/<noteId>/`). Pure; unit-tested in EditorCaptureNamingTests.

import Foundation

enum EditorCaptureKind: String, Sendable, CaseIterable {
    case photo
    case camera
    case scan

    /// Base name prefix (`photo-…`, `camera-…`, `scan-…`).
    var prefix: String { rawValue }
}

enum EditorCaptureNaming {

    /// `<kind>-yyyyMMdd-HHmmss[-page<n>].<ext>` in the given time zone, e.g.
    /// `scan-20261010-143005-page2.jpg`. `page` is 1-based and only added for
    /// multi-page scans (`pageCount > 1`). `ext` is lowercased and stripped of
    /// a leading dot; empty falls back to `jpg`.
    nonisolated static func filename(
        kind: EditorCaptureKind,
        date: Date,
        ext: String,
        page: Int? = nil,
        pageCount: Int = 1,
        timeZone: TimeZone = .current
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let stamp = String(format: "%04d%02d%02d-%02d%02d%02d",
                           c.year ?? 0, c.month ?? 0, c.day ?? 0,
                           c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        var cleanedExt = ext.trimmingCharacters(in: .whitespaces).lowercased()
        while cleanedExt.hasPrefix(".") { cleanedExt.removeFirst() }
        if cleanedExt.isEmpty { cleanedExt = "jpg" }
        var base = "\(kind.prefix)-\(stamp)"
        if let page, pageCount > 1 { base += "-page\(max(1, page))" }
        return "\(base).\(cleanedExt)"
    }

    /// File extension + MIME type for image data picked from the photo
    /// library, sniffed from its leading bytes (PNG, JPEG, GIF, HEIC/HEIF,
    /// WebP). Unknown data is reported as JPEG — the pickers' default export.
    nonisolated static func imageFormat(of data: Data) -> (ext: String, mimeType: String) {
        let bytes = [UInt8](data.prefix(12))
        if bytes.count >= 8, bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 {
            return ("png", "image/png")
        }
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
            return ("jpg", "image/jpeg")
        }
        if bytes.count >= 4, bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x38 {
            return ("gif", "image/gif")
        }
        if bytes.count >= 12, bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
           bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50 {
            return ("webp", "image/webp")
        }
        if bytes.count >= 12, bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 {
            // ISO-BMFF `ftyp` box: heic / heix / mif1 brands.
            let brand = String(decoding: bytes[8..<12], as: UTF8.self)
            if brand == "heic" || brand == "heix" || brand == "hevc" || brand == "heim" {
                return ("heic", "image/heic")
            }
            if brand == "mif1" || brand == "msf1" {
                return ("heif", "image/heif")
            }
        }
        return ("jpg", "image/jpeg")
    }
}
