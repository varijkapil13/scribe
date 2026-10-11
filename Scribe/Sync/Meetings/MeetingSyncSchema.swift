import Foundation
import GRDB

/// Schema for CloudKit meeting sync (migration `v28_meeting_sync`).
///
/// Bookkeeping only — the meeting data itself stays in the existing
/// `sessions` / `segments` / `session_speakers` / `session_bookmarks` /
/// `meeting_summaries` tables:
///
/// - `meeting_sync_state` — one row per local session: a change counter
///   (`changeSeq`, bumped by triggers on every write to the session or its
///   children) and the counter value last pushed (`pushedSeq`); a session is
///   dirty while `changeSeq > pushedSeq`. `updatedAt` is the session's
///   last-writer-wins clock (stamped by the triggers for local edits, set to
///   the remote value on import). `originDevice` / `originDeviceId` are NULL
///   for recordings made on this device and name the recording device for
///   imported ones. `transcriptHash` is the hash of the transcript payload
///   last uploaded / imported (so a metadata-only change doesn't re-upload
///   the transcript), `audioPushed` / `remoteAudio` track audio sync.
/// - `meeting_sync_tombstones` — sessions deleted here (or remotely), so the
///   deletion propagates and a stale copy can't resurrect them.
/// - `meeting_sync_meta` — key/value: the zone change token and this
///   device's sync id.
///
/// Change tracking uses SQLite triggers so no writer elsewhere in the app has
/// to remember to mark a meeting dirty. The trigger timestamps use the same
/// text format GRDB stores `Date`s in (`yyyy-MM-dd HH:mm:ss.SSS`, UTC).
///
/// Foundation + GRDB only: compiled into the iOS target too.
enum MeetingSyncSchema {

    nonisolated static let migrationName = "v28_meeting_sync"

    nonisolated static let stateTable = "meeting_sync_state"
    nonisolated static let tombstoneTable = "meeting_sync_tombstones"
    nonisolated static let metaTable = "meeting_sync_meta"

    /// Registers the additive `v28_meeting_sync` migration.
    nonisolated static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration(migrationName) { db in
            try db.create(table: stateTable) { t in
                t.column("sessionId", .text).notNull().primaryKey()
                t.column("changeSeq", .integer).notNull().defaults(to: 1)
                t.column("pushedSeq", .integer).notNull().defaults(to: 0)
                t.column("updatedAt", .datetime).notNull()
                t.column("transcriptHash", .text)
                t.column("originDevice", .text)
                t.column("originDeviceId", .text)
                t.column("audioPushed", .integer).notNull().defaults(to: 0)
                t.column("remoteAudio", .text)
            }
            try db.create(table: tombstoneTable) { t in
                t.column("sessionId", .text).notNull().primaryKey()
                t.column("deletedAt", .datetime).notNull()
                t.column("pushed", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: metaTable) { t in
                t.column("key", .text).notNull().primaryKey()
                t.column("value", .blob)
            }
            // Existing sessions: never pushed (dirty), clocked at their end
            // (or start) so a first sync uploads the meeting history.
            try db.execute(sql: """
                INSERT INTO meeting_sync_state (sessionId, changeSeq, pushedSeq, updatedAt)
                SELECT id, 1, 0, COALESCE(endedAt, createdAt) FROM sessions
                """)
            for sql in triggerStatements {
                try db.execute(sql: sql)
            }
        }
    }

    /// The SQL clock a local edit stamps (`updatedAt` / `deletedAt`): now,
    /// but never earlier than the version being edited. An import sets
    /// `updatedAt` to the remote device's clock; if this device's clock runs
    /// behind, a plain "now" would make an edit right after the import older
    /// than its own base, so last-writer-wins would drop it on every other
    /// device (and a deletion would be undone by the next pull). So the
    /// first edit after a push / import (`changeSeq = pushedSeq`) lands at
    /// least 5 ms past the base (clearing
    /// `MeetingSyncMergePolicy.clockTolerance`); later unpushed edits just
    /// never go backwards, so a burst of writes (a recording, a bulk delete)
    /// doesn't push the clock into the future. Evaluated against the
    /// `meeting_sync_state` row's old values; the COALESCE keeps a malformed
    /// stored value from turning the clock into NULL.
    nonisolated static let bumpedClock = """
        MAX(strftime('%Y-%m-%d %H:%M:%f', 'now'), \
        COALESCE(strftime('%Y-%m-%d %H:%M:%f', updatedAt, \
        CASE WHEN changeSeq > pushedSeq THEN '+0 seconds' ELSE '+0.005 seconds' END), \
        strftime('%Y-%m-%d %H:%M:%f', 'now')))
        """

    /// The change-tracking triggers. A child-table trigger only creates a
    /// state row while the session row exists, so the cascade deletes that
    /// follow a session delete don't leave orphan state behind. Deleting a
    /// session that was ever synced (pushed, or imported from another device)
    /// records a tombstone; a never-synced one just disappears.
    nonisolated static let triggerStatements: [String] = [
        """
        CREATE TRIGGER meeting_sync_sessions_ai AFTER INSERT ON sessions BEGIN
            INSERT OR IGNORE INTO meeting_sync_state (sessionId, updatedAt)
                SELECT id, strftime('%Y-%m-%d %H:%M:%f', 'now') FROM sessions WHERE id = NEW.id;
            UPDATE meeting_sync_state SET changeSeq = changeSeq + 1, updatedAt = \(MeetingSyncSchema.bumpedClock)
                WHERE sessionId = NEW.id;
        END
        """,
        """
        CREATE TRIGGER meeting_sync_sessions_au
        AFTER UPDATE OF title, createdAt, endedAt, durationSeconds, language, tags, noteId, calendarEventId, calendarEventTitle, attendees ON sessions
        WHEN OLD.title IS NOT NEW.title
            OR OLD.createdAt IS NOT NEW.createdAt
            OR OLD.endedAt IS NOT NEW.endedAt
            OR OLD.durationSeconds IS NOT NEW.durationSeconds
            OR OLD.language IS NOT NEW.language
            OR OLD.tags IS NOT NEW.tags
            OR OLD.noteId IS NOT NEW.noteId
            OR OLD.calendarEventId IS NOT NEW.calendarEventId
            OR OLD.calendarEventTitle IS NOT NEW.calendarEventTitle
            OR OLD.attendees IS NOT NEW.attendees
        BEGIN
            INSERT OR IGNORE INTO meeting_sync_state (sessionId, updatedAt)
                SELECT id, strftime('%Y-%m-%d %H:%M:%f', 'now') FROM sessions WHERE id = NEW.id;
            UPDATE meeting_sync_state SET changeSeq = changeSeq + 1, updatedAt = \(MeetingSyncSchema.bumpedClock)
                WHERE sessionId = NEW.id;
        END
        """,
        """
        CREATE TRIGGER meeting_sync_sessions_ad AFTER DELETE ON sessions BEGIN
            INSERT OR REPLACE INTO meeting_sync_tombstones (sessionId, deletedAt, pushed)
                SELECT OLD.id, \(MeetingSyncSchema.bumpedClock), 0 FROM meeting_sync_state
                WHERE sessionId = OLD.id AND (pushedSeq > 0 OR originDeviceId IS NOT NULL);
            DELETE FROM meeting_sync_state WHERE sessionId = OLD.id;
        END
        """,
        """
        CREATE TRIGGER meeting_sync_segments_ai AFTER INSERT ON segments BEGIN
            INSERT OR IGNORE INTO meeting_sync_state (sessionId, updatedAt)
                SELECT id, strftime('%Y-%m-%d %H:%M:%f', 'now') FROM sessions WHERE id = NEW.sessionId;
            UPDATE meeting_sync_state SET changeSeq = changeSeq + 1, updatedAt = \(MeetingSyncSchema.bumpedClock)
                WHERE sessionId = NEW.sessionId;
        END
        """,
        """
        CREATE TRIGGER meeting_sync_segments_au AFTER UPDATE ON segments BEGIN
            INSERT OR IGNORE INTO meeting_sync_state (sessionId, updatedAt)
                SELECT id, strftime('%Y-%m-%d %H:%M:%f', 'now') FROM sessions WHERE id = NEW.sessionId;
            UPDATE meeting_sync_state SET changeSeq = changeSeq + 1, updatedAt = \(MeetingSyncSchema.bumpedClock)
                WHERE sessionId = NEW.sessionId;
            INSERT OR IGNORE INTO meeting_sync_state (sessionId, updatedAt)
                SELECT id, strftime('%Y-%m-%d %H:%M:%f', 'now') FROM sessions WHERE id = OLD.sessionId;
            UPDATE meeting_sync_state SET changeSeq = changeSeq + 1, updatedAt = \(MeetingSyncSchema.bumpedClock)
                WHERE sessionId = OLD.sessionId;
        END
        """,
        """
        CREATE TRIGGER meeting_sync_segments_ad AFTER DELETE ON segments BEGIN
            INSERT OR IGNORE INTO meeting_sync_state (sessionId, updatedAt)
                SELECT id, strftime('%Y-%m-%d %H:%M:%f', 'now') FROM sessions WHERE id = OLD.sessionId;
            UPDATE meeting_sync_state SET changeSeq = changeSeq + 1, updatedAt = \(MeetingSyncSchema.bumpedClock)
                WHERE sessionId = OLD.sessionId;
        END
        """,
        """
        CREATE TRIGGER meeting_sync_session_speakers_ai AFTER INSERT ON session_speakers BEGIN
            INSERT OR IGNORE INTO meeting_sync_state (sessionId, updatedAt)
                SELECT id, strftime('%Y-%m-%d %H:%M:%f', 'now') FROM sessions WHERE id = NEW.sessionId;
            UPDATE meeting_sync_state SET changeSeq = changeSeq + 1, updatedAt = \(MeetingSyncSchema.bumpedClock)
                WHERE sessionId = NEW.sessionId;
        END
        """,
        """
        CREATE TRIGGER meeting_sync_session_speakers_au AFTER UPDATE ON session_speakers BEGIN
            INSERT OR IGNORE INTO meeting_sync_state (sessionId, updatedAt)
                SELECT id, strftime('%Y-%m-%d %H:%M:%f', 'now') FROM sessions WHERE id = NEW.sessionId;
            UPDATE meeting_sync_state SET changeSeq = changeSeq + 1, updatedAt = \(MeetingSyncSchema.bumpedClock)
                WHERE sessionId = NEW.sessionId;
            INSERT OR IGNORE INTO meeting_sync_state (sessionId, updatedAt)
                SELECT id, strftime('%Y-%m-%d %H:%M:%f', 'now') FROM sessions WHERE id = OLD.sessionId;
            UPDATE meeting_sync_state SET changeSeq = changeSeq + 1, updatedAt = \(MeetingSyncSchema.bumpedClock)
                WHERE sessionId = OLD.sessionId;
        END
        """,
        """
        CREATE TRIGGER meeting_sync_session_speakers_ad AFTER DELETE ON session_speakers BEGIN
            INSERT OR IGNORE INTO meeting_sync_state (sessionId, updatedAt)
                SELECT id, strftime('%Y-%m-%d %H:%M:%f', 'now') FROM sessions WHERE id = OLD.sessionId;
            UPDATE meeting_sync_state SET changeSeq = changeSeq + 1, updatedAt = \(MeetingSyncSchema.bumpedClock)
                WHERE sessionId = OLD.sessionId;
        END
        """,
        """
        CREATE TRIGGER meeting_sync_session_bookmarks_ai AFTER INSERT ON session_bookmarks BEGIN
            INSERT OR IGNORE INTO meeting_sync_state (sessionId, updatedAt)
                SELECT id, strftime('%Y-%m-%d %H:%M:%f', 'now') FROM sessions WHERE id = NEW.sessionId;
            UPDATE meeting_sync_state SET changeSeq = changeSeq + 1, updatedAt = \(MeetingSyncSchema.bumpedClock)
                WHERE sessionId = NEW.sessionId;
        END
        """,
        """
        CREATE TRIGGER meeting_sync_session_bookmarks_au AFTER UPDATE ON session_bookmarks BEGIN
            INSERT OR IGNORE INTO meeting_sync_state (sessionId, updatedAt)
                SELECT id, strftime('%Y-%m-%d %H:%M:%f', 'now') FROM sessions WHERE id = NEW.sessionId;
            UPDATE meeting_sync_state SET changeSeq = changeSeq + 1, updatedAt = \(MeetingSyncSchema.bumpedClock)
                WHERE sessionId = NEW.sessionId;
            INSERT OR IGNORE INTO meeting_sync_state (sessionId, updatedAt)
                SELECT id, strftime('%Y-%m-%d %H:%M:%f', 'now') FROM sessions WHERE id = OLD.sessionId;
            UPDATE meeting_sync_state SET changeSeq = changeSeq + 1, updatedAt = \(MeetingSyncSchema.bumpedClock)
                WHERE sessionId = OLD.sessionId;
        END
        """,
        """
        CREATE TRIGGER meeting_sync_session_bookmarks_ad AFTER DELETE ON session_bookmarks BEGIN
            INSERT OR IGNORE INTO meeting_sync_state (sessionId, updatedAt)
                SELECT id, strftime('%Y-%m-%d %H:%M:%f', 'now') FROM sessions WHERE id = OLD.sessionId;
            UPDATE meeting_sync_state SET changeSeq = changeSeq + 1, updatedAt = \(MeetingSyncSchema.bumpedClock)
                WHERE sessionId = OLD.sessionId;
        END
        """,
        """
        CREATE TRIGGER meeting_sync_meeting_summaries_ai AFTER INSERT ON meeting_summaries BEGIN
            INSERT OR IGNORE INTO meeting_sync_state (sessionId, updatedAt)
                SELECT id, strftime('%Y-%m-%d %H:%M:%f', 'now') FROM sessions WHERE id = NEW.session_id;
            UPDATE meeting_sync_state SET changeSeq = changeSeq + 1, updatedAt = \(MeetingSyncSchema.bumpedClock)
                WHERE sessionId = NEW.session_id;
        END
        """,
        """
        CREATE TRIGGER meeting_sync_meeting_summaries_au AFTER UPDATE ON meeting_summaries BEGIN
            INSERT OR IGNORE INTO meeting_sync_state (sessionId, updatedAt)
                SELECT id, strftime('%Y-%m-%d %H:%M:%f', 'now') FROM sessions WHERE id = NEW.session_id;
            UPDATE meeting_sync_state SET changeSeq = changeSeq + 1, updatedAt = \(MeetingSyncSchema.bumpedClock)
                WHERE sessionId = NEW.session_id;
            INSERT OR IGNORE INTO meeting_sync_state (sessionId, updatedAt)
                SELECT id, strftime('%Y-%m-%d %H:%M:%f', 'now') FROM sessions WHERE id = OLD.session_id;
            UPDATE meeting_sync_state SET changeSeq = changeSeq + 1, updatedAt = \(MeetingSyncSchema.bumpedClock)
                WHERE sessionId = OLD.session_id;
        END
        """,
        """
        CREATE TRIGGER meeting_sync_meeting_summaries_ad AFTER DELETE ON meeting_summaries BEGIN
            INSERT OR IGNORE INTO meeting_sync_state (sessionId, updatedAt)
                SELECT id, strftime('%Y-%m-%d %H:%M:%f', 'now') FROM sessions WHERE id = OLD.session_id;
            UPDATE meeting_sync_state SET changeSeq = changeSeq + 1, updatedAt = \(MeetingSyncSchema.bumpedClock)
                WHERE sessionId = OLD.session_id;
        END
        """
    ]
}
