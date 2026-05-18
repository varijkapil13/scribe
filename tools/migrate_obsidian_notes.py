#!/usr/bin/env python3
"""
Migrate Obsidian vault notes into Scribe with a proper nested-notebook hierarchy.

Safe to re-run: deletes all notebooks + non-session notes first, then recreates
everything with correct parentId nesting. Session-owned notes are preserved.
"""

import os
import re
import sqlite3
import uuid
from datetime import datetime, timezone
from pathlib import Path

VAULT = Path("/Users/kapil/Library/Mobile Documents/iCloud~md~obsidian/Documents/Varij-local")
DB    = Path.home() / "Library/Application Support/Scribe/scribe.db"
NOW   = datetime.now(timezone.utc).isoformat()

# ── Skip lists ────────────────────────────────────────────────────────────────
SKIP_FILES = {"_index.md", "_MOC.md", "README.md", "Untitled.base", "_Notion Tokens.md"}
SKIP_DIRS  = {".obsidian"}
SPARSE_RE  = re.compile(r"^\s*(---[\s\S]*?---\s*)?\s*(##\s+Related[\s\S]*)?\s*$")

# ── Frontmatter ───────────────────────────────────────────────────────────────
FM_RE = re.compile(r"^---\s*\n([\s\S]*?\n)---\s*\n?", re.MULTILINE)

def strip_frontmatter(text: str) -> tuple[str, list[str]]:
    tags: list[str] = []
    m = FM_RE.match(text)
    if m:
        fm = m.group(1)
        tb = re.search(r"^tags:\s*\n((?:  - .+\n)+)", fm, re.MULTILINE)
        if tb:
            tags = [t.strip().lstrip("- ") for t in tb.group(1).splitlines()]
        text = text[m.end():]
    return text.strip(), tags

def extract_title(body: str, filename: str) -> str:
    m = re.match(r"^#\s+(.+)", body)
    return m.group(1).strip() if m else Path(filename).stem.replace("_", " ").strip()

# ── Nested notebook hierarchy ─────────────────────────────────────────────────
# Each entry: (vault_path_prefix, notebook_name, parent_notebook_name_or_None, extra_tags)
# Order matters: more-specific prefixes first.
NOTEBOOK_HIERARCHY = [
    # Projects
    ("01_Projects",                    "Projects",       None,          ["project"]),
    # Areas
    ("02_Areas",                       "Areas",          None,          []),
    ("02_Areas/Goals",                 "Goals",          "Areas",       ["goals"]),
    ("02_Areas/Leadership",            "Leadership",     "Areas",       ["leadership"]),
    ("02_Areas/People",                "People",         "Areas",       ["people"]),
    ("02_Areas/People/Backend",        "Backend",        "People",      ["people", "backend"]),
    ("02_Areas/People/Operations",     "Ops People",     "People",      ["people", "operations"]),
    ("02_Areas/Team",                  "Team",           "Areas",       ["team"]),
    # Resources
    ("03_Resources",                   "Resources",      None,          ["resources"]),
    ("03_Resources/Engineering",       "Engineering",    "Resources",   ["engineering"]),
    ("03_Resources/Leadership",        "Leadership Ref", "Resources",   ["leadership"]),
    ("03_Resources/Onboarding",        "Onboarding",     "Resources",   ["onboarding"]),
    ("03_Resources/Operations",        "Operations Ref", "Resources",   ["operations"]),
    ("03_Resources/Setup",             "Setup",          "Resources",   ["setup"]),
    # Archive
    ("04_Archive",                     "Archive",        None,          ["archive"]),
    ("04_Archive/Daily Notes",         "Daily Notes",    "Archive",     ["daily"]),
    # Top-level
    ("Hiring",                         "Hiring",         None,          ["hiring"]),
    ("Journal",                        "Journal",        None,          ["journal"]),
]

# Build lookup: prefix → (notebook_name, parent_name, extra_tags)
# We want the MOST specific match, so sort by prefix length descending.
SORTED_MAP = sorted(NOTEBOOK_HIERARCHY, key=lambda x: len(x[0]), reverse=True)

def notebook_for(rel: str) -> tuple[str, str | None, list[str]]:
    for prefix, name, parent, tags in SORTED_MAP:
        if rel.startswith(prefix):
            return name, parent, tags
    return "Notes", None, []

# ── Daily notes ───────────────────────────────────────────────────────────────
DAILY_RE = re.compile(r"^(\d{2})\.(\d{2})\.(\d{4})$")

def daily_date(filename: str) -> str | None:
    m = DAILY_RE.match(Path(filename).stem)
    if m:
        dd, mm, yyyy = m.groups()
        return f"{yyyy}-{mm}-{dd}"
    return None

# ── Main ─────────────────────────────────────────────────────────────────────
def main():
    con = sqlite3.connect(str(DB))
    cur = con.cursor()

    # ── 1. Wipe previous migration data ──────────────────────────────────────
    # Delete all notes that have no sessions linked to them (= migration-created).
    cur.execute("""
        DELETE FROM notes
        WHERE id NOT IN (SELECT DISTINCT noteId FROM sessions WHERE noteId IS NOT NULL)
    """)
    deleted_notes = cur.rowcount

    # Delete all notebooks (safe: FK on notes is manual, already cleaned above).
    cur.execute("DELETE FROM notebooks")
    deleted_nb = cur.rowcount

    print(f"  [CLEAN] Removed {deleted_nb} old notebooks, {deleted_notes} old notes")

    # ── 2. Create notebooks with parentId ────────────────────────────────────
    # Two-pass: first create all notebooks, then set parentId references.
    nb_by_name: dict[str, str] = {}   # name → id
    sort_counter = 0

    def ensure_notebook(name: str, parent_name: str | None) -> str:
        if name in nb_by_name:
            return nb_by_name[name]
        nonlocal sort_counter
        parent_id = nb_by_name.get(parent_name) if parent_name else None
        nid = str(uuid.uuid4()).upper()
        cur.execute(
            "INSERT INTO notebooks (id, name, sortOrder, parentId) VALUES (?, ?, ?, ?)",
            (nid, name, sort_counter, parent_id)
        )
        nb_by_name[name] = nid
        sort_counter += 1
        return nid

    # Create in declaration order so parents exist before children.
    for _, name, parent_name, _ in NOTEBOOK_HIERARCHY:
        if parent_name and parent_name not in nb_by_name:
            # Parent might not be in map yet — create it first (should not happen
            # if NOTEBOOK_HIERARCHY is properly ordered, but guard anyway).
            ensure_notebook(parent_name, None)
        ensure_notebook(name, parent_name)

    print(f"  [NOTEBOOKS] Created {len(nb_by_name)} notebooks")

    # ── 3. Import notes ───────────────────────────────────────────────────────
    notes_ok = 0
    notes_skip = 0

    for root, dirs, files in os.walk(VAULT):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)

        for filename in sorted(files):
            if not filename.endswith(".md") or filename in SKIP_FILES:
                continue

            filepath = Path(root) / filename
            rel = str(filepath.relative_to(VAULT))

            raw = filepath.read_text(encoding="utf-8")
            body, fm_tags = strip_frontmatter(raw)

            if SPARSE_RE.fullmatch(body) or len(body.strip()) < 30:
                print(f"  [SKIP] {rel}")
                notes_skip += 1
                continue

            title = extract_title(body, filename)
            nb_name, parent_name, extra_tags = notebook_for(rel)
            nb_id = ensure_notebook(nb_name, parent_name)

            dd       = daily_date(filename)
            is_daily = 1 if dd else 0
            all_tags = list(dict.fromkeys(fm_tags + extra_tags))
            note_id  = str(uuid.uuid4()).upper()

            cur.execute(
                """INSERT INTO notes
                   (id, title, body, createdAt, updatedAt, isDailyNote, dailyDate, notebookId)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
                (note_id, title, body, NOW, NOW, is_daily, dd, nb_id)
            )
            for tag in all_tags:
                if tag:
                    cur.execute(
                        "INSERT OR IGNORE INTO note_tags (noteId, tag) VALUES (?, ?)",
                        (note_id, tag.lower().replace("/", "-"))
                    )

            path_display = f"{nb_name}" if not parent_name else f"{parent_name} › {nb_name}"
            print(f"  [OK] {rel}  →  {path_display} / {title!r}")
            notes_ok += 1

    con.commit()
    con.close()
    print(f"\n✓ Notes: {notes_ok} created, {notes_skip} skipped.")


if __name__ == "__main__":
    main()
