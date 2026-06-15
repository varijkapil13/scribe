import Foundation

/// Seeds a deterministic dataset for the automated screenshot harness.
///
/// Active ONLY when the app is launched in fixture mode (`--uitest-fixtures`
/// or `SCRIBE_UITEST=1`; see `AppLaunchEnvironment`). In that mode the shared
/// `DatabaseManager` and notes vault have already been redirected to a fresh
/// temp directory, so everything written here is throwaway state that never
/// touches the user's real database or Documents folder.
///
/// The goal is a stable, reproducible picture of every major surface:
///   - a handful of projects,
///   - tasks spread across the Inbox / Today (incl. overdue) / Upcoming buckets,
///   - notes including one rich note with Markdown + a Mermaid diagram,
///   - one finished recording with a short transcript.
///
/// Seeding is best-effort: any individual failure is logged and skipped rather
/// than crashing the harness, because a half-seeded store still yields useful
/// screenshots. The whole thing is a no-op on a production launch.
enum UITestFixtures {

    /// Seeds the fixture dataset if fixture mode is active and the store is
    /// empty. Idempotent: re-running on an already-seeded store is a no-op, so
    /// it is safe to call from `applicationDidFinishLaunching` on every launch.
    static func seedIfNeeded() {
        guard AppLaunchEnvironment.usesUITestFixtures else { return }

        // Make the seeded run deterministic and quiet: pin a vault path is
        // already handled via the redirect, and onboarding / iCloud sync are
        // disabled so neither a first-run wizard nor a CloudKit prompt covers
        // the screens we want to photograph.
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "hasCompletedOnboarding")
        defaults.set(false, forKey: "iCloudSyncEnabled")
        defaults.set(false, forKey: "cloudKitSyncEnabled")
        defaults.set(false, forKey: "mcpEnabled")

        do {
            let existing = try TaskStore.shared.fetchProjects()
            if !existing.isEmpty {
                Log.app.info("UITestFixtures: store already seeded — skipping.")
                return
            }
        } catch {
            Log.app.error("UITestFixtures: project probe failed: \(error.localizedDescription, privacy: .public)")
        }

        seedProjectsAndTasks()
        seedNotes()
        seedTranscript()
        Log.app.info("UITestFixtures: seed complete.")
    }

    // MARK: - Tasks & Projects

    private static func seedProjectsAndTasks() {
        let tasks = TaskStore.shared
        let cal = Calendar.current
        let now = Date()
        func day(_ offset: Int, hour: Int = 9) -> Date {
            let base = cal.date(byAdding: .day, value: offset, to: now) ?? now
            return cal.date(bySettingHour: hour, minute: 0, second: 0, of: base) ?? base
        }

        do {
            let website = try tasks.createProject(name: "Website Relaunch", color: "#4C6FFF", icon: "globe")
            let research = try tasks.createProject(name: "User Research", color: "#34C759", icon: "magnifyingglass")
            _ = try tasks.createProject(name: "Personal", color: "#FF9500", icon: "house")

            // Overdue (yesterday + last week)
            _ = try tasks.createTask(title: "Send Q2 metrics to leadership",
                                     projectId: website.id, priority: .high, dueAt: day(-1),
                                     tags: ["report"])
            _ = try tasks.createTask(title: "Fix broken pricing-page links",
                                     projectId: website.id, priority: .medium, dueAt: day(-4))

            // Today
            _ = try tasks.createTask(title: "Review homepage hero copy",
                                     projectId: website.id, priority: .high, dueAt: day(0, hour: 14))
            _ = try tasks.createTask(title: "Stand-up notes follow-up",
                                     priority: .low, dueAt: day(0, hour: 11))
            _ = try tasks.createTask(title: "Schedule usability sessions",
                                     projectId: research.id, priority: .medium, dueAt: day(0, hour: 16))

            // Upcoming (next 7 days)
            _ = try tasks.createTask(title: "Draft interview script",
                                     projectId: research.id, priority: .medium, dueAt: day(2))
            _ = try tasks.createTask(title: "Recruit 5 participants",
                                     projectId: research.id, priority: .high, dueAt: day(3))
            _ = try tasks.createTask(title: "Finalize launch checklist",
                                     projectId: website.id, priority: .high, dueAt: day(5),
                                     tags: ["launch"])

            // Inbox (no project, no due date)
            _ = try tasks.createTask(title: "Buy domain renewal", tags: ["admin"])
            _ = try tasks.createTask(title: "Read 'Refactoring UI'")
            _ = try tasks.createTask(title: "Try the new transcription model")
        } catch {
            Log.app.error("UITestFixtures: task seed failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Notes

    private static func seedNotes() {
        let notes = NoteStore.shared
        do {
            let welcome = try notes.createNote(
                title: "Welcome to Scribe",
                body: """
                Scribe keeps your meetings, notes, and tasks in one place.

                - Record a meeting and get a searchable transcript.
                - Capture quick notes that link to each other with [[wiki links]].
                - Turn action items into tasks with due dates.
                """,
                tags: ["intro"]
            )
            // Typed frontmatter properties so the Bases feature has content to
            // show (table columns) and a `select` key the board can group by.
            setProperties(on: welcome.id, [
                NoteProperty(key: "status", value: .select("Done")),
                NoteProperty(key: "area", value: .select("Docs")),
                NoteProperty(key: "priority", value: .number(1))
            ])

            let arch = try notes.createNote(
                title: "Architecture Overview",
                body: """
                # Architecture Overview

                Scribe is a **local-first** SwiftUI app backed by SQLite (GRDB).
                Notes are stored as Markdown files on disk; the database keeps
                metadata and a full-text index.

                ## Data flow

                ```mermaid
                graph LR
                    Mic[Microphone] --> Engine[Speech Engine]
                    System[System Audio] --> Engine
                    Engine --> Store[(SQLite)]
                    Store --> Notes[Notes Vault]
                    Store --> Tasks[Task Layer]
                ```

                ## Key tables

                | Table     | Purpose                       |
                |-----------|-------------------------------|
                | sessions  | Recorded meetings             |
                | segments  | Transcript lines (FTS-indexed)|
                | tasks     | Action items                  |
                | notes     | Note metadata + excerpts      |

                See [[Welcome to Scribe]] for the high-level pitch.
                """,
                tags: ["docs", "engineering"]
            )
            setProperties(on: arch.id, [
                NoteProperty(key: "status", value: .select("In Progress")),
                NoteProperty(key: "area", value: .select("Engineering")),
                NoteProperty(key: "priority", value: .number(2))
            ])

            let oneOnOne = try notes.createNote(
                title: "1:1 with Alex",
                body: """
                Talked through the launch timeline and blockers.

                - Pricing page is the long pole.
                - Need design review by Friday.
                """,
                tags: ["meeting"]
            )
            setProperties(on: oneOnOne.id, [
                NoteProperty(key: "status", value: .select("Todo")),
                NoteProperty(key: "area", value: .select("Product")),
                NoteProperty(key: "priority", value: .number(3))
            ])
        } catch {
            Log.app.error("UITestFixtures: note seed failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Writes typed frontmatter properties to a seeded note's `.md` file so the
    /// Bases table/board/card views have content. Best-effort and gated by
    /// fixture mode like the rest of the seed — a write failure just means the
    /// Bases screen shows fewer columns, never a crash.
    private static func setProperties(on noteId: String, _ properties: [NoteProperty]) {
        do {
            try BaseStore.shared.saveProperties(properties, forNoteId: noteId)
        } catch {
            Log.app.error("UITestFixtures: property seed failed for \(noteId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Transcript

    private static func seedTranscript() {
        let notes = NoteStore.shared
        let transcripts = TranscriptStore.shared
        do {
            // Every session must belong to a note.
            let note = try notes.createNote(title: "Weekly Sync — Product", body: "")
            let session = try transcripts.createSession(title: "Weekly Sync — Product", noteId: note.id)

            let lines: [(String, String)] = [
                ("Speaker 1", "Alright, let's kick off the weekly sync. First item is the relaunch."),
                ("Speaker 2", "The homepage is in good shape. We're blocked on the pricing page copy."),
                ("Speaker 1", "Got it. Let's make that the priority for this week."),
                ("Speaker 2", "I'll schedule the usability sessions and recruit participants."),
                ("Speaker 1", "Perfect. Anything else before we wrap?"),
                ("Speaker 2", "That's it from me. Thanks everyone.")
            ]
            var t = 0
            for (speaker, text) in lines {
                _ = try transcripts.addSegment(
                    sessionId: session.id,
                    startMs: t,
                    endMs: t + 4000,
                    speaker: speaker,
                    text: text
                )
                t += 4000
            }
            try transcripts.endSession(id: session.id)
        } catch {
            Log.app.error("UITestFixtures: transcript seed failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
