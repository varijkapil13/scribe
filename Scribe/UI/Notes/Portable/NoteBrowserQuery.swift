// Scribe/UI/Notes/Portable/NoteBrowserQuery.swift
//
// Pure list logic for the iPhone / iPad notes browser (ScribeiOS/Notes/):
// which notes a sidebar destination shows, search matching, and sorting.
// Foundation-only; compiled into the iOS target and unit-tested by the
// macOS `swift test` job (NoteBrowserQueryTests).

import Foundation

/// A destination in the notes sidebar.
enum NotesSidebarItem: Hashable, Sendable, Identifiable {
    /// Notes not filed in a notebook (daily notes excluded) — matches
    /// `NoteStore.fetchInboxNotes`.
    case inbox
    /// Every non-daily note.
    case all
    /// Daily notes, newest day first.
    case daily
    /// Notes filed in the notebook with this id.
    case notebook(String)
    /// Notes carrying this (normalized) tag.
    case tag(String)

    var id: String {
        switch self {
        case .inbox: return "inbox"
        case .all: return "all"
        case .daily: return "daily"
        case .notebook(let id): return "notebook:\(id)"
        case .tag(let tag): return "tag:\(tag)"
        }
    }

    /// The notebook a note created while this destination is shown goes to.
    var notebookIdForNewNotes: String? {
        if case .notebook(let id) = self { return id }
        return nil
    }

    /// The tag a note created while this destination is shown gets.
    var tagForNewNotes: String? {
        if case .tag(let tag) = self { return tag }
        return nil
    }
}

/// Sort orders offered by the note list.
enum NoteSortOrder: String, CaseIterable, Sendable, Identifiable {
    case updated
    case created
    case title

    var id: String { rawValue }

    var label: String {
        switch self {
        case .updated: return "Date Modified"
        case .created: return "Date Created"
        case .title: return "Title"
        }
    }
}

enum NoteBrowserQuery {

    /// The notes `item` shows, sorted by `sort`.
    ///
    /// - Parameters:
    ///   - all: every note (bodies may be empty — only metadata is used).
    ///   - tagMembers: ids of notes carrying the tag when `item` is `.tag`
    ///     (ignored otherwise; nil shows nothing for a tag).
    ///   - searchMatches: ids matching the search (full-text search
    ///     results); nil = no search active.
    nonisolated static func notes(
        _ all: [Note],
        for item: NotesSidebarItem,
        tagMembers: Set<String>? = nil,
        searchMatches: Set<String>? = nil,
        sort: NoteSortOrder
    ) -> [Note] {
        var result = all.filter { includes($0, in: item, tagMembers: tagMembers) }
        if let searchMatches {
            result = result.filter { searchMatches.contains($0.id) }
        }
        // Daily notes read best newest-day first, whatever the sort.
        if item == .daily, sort != .title {
            return result.sorted { lhs, rhs in
                let l = lhs.dailyDate ?? "", r = rhs.dailyDate ?? ""
                if l != r { return l > r }
                return lhs.id < rhs.id
            }
        }
        return sorted(result, by: sort)
    }

    /// Whether `note` belongs to the sidebar destination `item`.
    nonisolated static func includes(_ note: Note, in item: NotesSidebarItem, tagMembers: Set<String>?) -> Bool {
        switch item {
        case .inbox: return note.notebookId == nil && !note.isDailyNote
        case .all: return !note.isDailyNote
        case .daily: return note.isDailyNote
        case .notebook(let id): return note.notebookId == id
        case .tag: return tagMembers?.contains(note.id) ?? false
        }
    }

    /// Stable sort: ties fall back to the id so rows never jump around.
    nonisolated static func sorted(_ notes: [Note], by order: NoteSortOrder) -> [Note] {
        notes.sorted { lhs, rhs in
            switch order {
            case .updated:
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            case .created:
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            case .title:
                let l = displayTitle(lhs), r = displayTitle(rhs)
                let c = l.localizedStandardCompare(r)
                if c != .orderedSame { return c == .orderedAscending }
            }
            return lhs.id < rhs.id
        }
    }

    /// Plain substring search over title + excerpt (case/diacritic
    /// insensitive). The fallback when full-text search isn't available,
    /// and what an empty FTS result is never replaced with.
    nonisolated static func matches(_ note: Note, search raw: String) -> Bool {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return note.title.range(of: query, options: options) != nil
            || (note.bodyExcerpt ?? "").range(of: query, options: options) != nil
    }

    /// The title a row shows.
    nonisolated static func displayTitle(_ note: Note) -> String {
        let trimmed = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    /// A non-clashing title for a new / renamed note: `base`, else
    /// `base 2`, `base 3`, … (case-insensitive against `existing`).
    nonisolated static func uniqueTitle(_ base: String, existing: [String]) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        for n in 2...9_999 {
            let candidate = "\(base) \(n)"
            if !taken.contains(candidate.lowercased()) { return candidate }
        }
        return "\(base) \(UUID().uuidString.prefix(4))"
    }
}
