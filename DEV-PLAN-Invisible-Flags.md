# Plan: Invisible Flags and Structure Characters

## Goal

Encode what an item line *is* (flags, later the item type) and how it is
*structured* (columns, segments) with zero-width Unicode characters, so that

- highlighting is done purely by the syntax (no region hacks), on every
  platform and independent of `dired_show_stats`,
- the Python side parses lines exactly instead of guessing by spaces or
  visible symbols,
- everything visible (icons, padding, the `--`/`H-`/`HS` attrs column) is
  presentation only and free to change.

The view model (`dired_index`, see `MODEL.md`) is **not** changed in this
plan. See "Future: Richer Model" at the end.

## Character Allocation

| Role               | Char     | Name                    |
|--------------------|----------|-------------------------|
| Bit 1 (on)         | `U+200D` | ZERO WIDTH JOINER       |
| Bit 0 (off)        | `U+200C` | ZERO WIDTH NON-JOINER   |
| Column separator   | `U+2063` | INVISIBLE SEPARATOR     |
| Segment separator  | `U+200B` | ZERO WIDTH SPACE        |
| Spare              | `U+2060` | WORD JOINER             |
| Spare              | `U+2061` | FUNCTION APPLICATION    |
| Spare              | `U+2062` | INVISIBLE TIMES         |
| Spare              | `U+2064` | INVISIBLE PLUS          |

- Bits (`200C`/`200D`) and structure characters (`200B`, `2060`–`2064`) are
  disjoint sets, so a stray character can never be mistaken for the other
  kind.
- Joiner / non-joiner map naturally to on / off. They only affect shaping
  between joinable neighbours; in the flags field they only touch each other
  and the surrounding `SEG`s, so they are inert there. They are also the
  best-supported zero-width characters in renderers (emoji sequences).
- `U+2063` INVISIBLE SEPARATOR and `U+200B` ZERO WIDTH SPACE are used for
  what they are meant for: column boundary and word-level boundary.
- `U+200B` changes role (today: column separator, new: segment separator).
  Deleting the old `SEPARATOR` constants makes every forgotten use fail
  loudly instead of silently splitting at the wrong place.
- None of these characters is whitespace for Python's `str.isspace()`/
  `strip()` or for `\s` in syntax regexes.

Avoid entirely: bidi controls (`200E/F`, `202A–E`, `2066–9`), `FEFF` (BOM),
C0/C1 controls and NUL (rendered as `<0x..>`), Private Use Area (icon fonts),
variation selectors and tag characters (modify neighbours), soft hyphen,
Hangul fillers (have width), `180E` (whitespace status changed between
Unicode versions).

## Line Layout

```
[indent][SEG][flags][SEG][icon][SEG][name][SEG][note][COL][size][COL][mtime][COL][attrs]
```

- `COL` marks the start of an **aligned** column. `SEG` separates the parts
  of the name column, which are not aligned with each other.
- Parsing is two-level: `line.split(COL)` → `[name column, size, mtime,
  attrs]`, then `name_col.split(SEG)` → `[indent, flags, icon, name, note]`.
- The name column always has all five fields (note empty if none). Stats are
  either absent entirely (stats off: no `COL` at all) or all present.
- Padding (spaces/tabs) goes *before* a separator and belongs to the
  preceding field; content starts directly after a separator. Parsers
  `strip()` each field. The tab before a note goes before its `SEG`, only
  when there is a note.
- Header, help and other non-item lines carry no flags or separators. The
  parent line (`⠤`) gets the item layout once the type field exists
  (Phase 3); until then it has none.

Why this shape:
- **Flags after the indent:** the plugin relies on Sublime's indentation
  APIs, which only count leading whitespace: `view.indentation_level()` in
  `dired_expand`, `view.indented_region()` in `dired_fold` (collapsing
  deletes the child lines; it does not use Sublime's folding, and
  `fold_buttons` is off), and the syntax's `indent` scope in
  `_get_name_point`. Flags at column 0 would make every line look
  unindented. Flags at the end of the line would need lookaheads in the
  syntax, because the name is scoped before the flags are reached.
- **`SEG` before the flags:** `^\t*\x{200B}` identifies item lines without
  depending on the icons, and the indent arrives as its own field.
- **`SEG` after the icon:** the name starts after the third `SEG`,
  independent of icon width (needed once icons are configurable).
- **No `COL` after the flags:** they are not a visual column, and it would
  break "one `COL` per aligned column".

Example (hidden directory with a note, stats on; `‹…›` = invisible):

```
\t\t‹SEG›‹1›‹0›‹0›‹0›‹SEG›▸‹SEG›.cache/\t‹SEG›<empty>    ‹COL›     DIR‹COL›  13.11.2025 00:04‹COL›  H-
```

## Flags Field

Fixed width: exactly `FLAG_WIDTH` bit characters on every item line, also
when all bits are 0. Positions are only ever appended, never reordered.

| Bit | Meaning    | Source | Platforms |
|-----|------------|--------|-----------|
| 0   | hidden     | `FILE_ATTRIBUTE_HIDDEN` | Windows (else 0) |
| 1   | system     | `FILE_ATTRIBUTE_SYSTEM` | Windows (else 0) |
| 2   | excluded   | name matches `dired_hidden_files_patterns` or `folder_exclude_patterns` | all |
| 3   | link       | symlink, junction, mount point (see below) | all |
| 4   | executable | placeholder (always 0) in Phase 2; later files only: exec bits in `st_mode` / extension in `PATHEXT` on Windows | all |
| 5–6 | type       | placeholder (always 0) in Phase 2; Phase 3: file, dir collapsed, dir expanded, parent | all |

All of bits 0–4 come from the stat result `_do_scandir` already has
(`entry.stat(follow_symlinks=False)`); no extra system calls.

Details:
- **excluded:** today the patterns are only loaded when `show_hidden` is off,
  and then used to filter. New: always evaluate them; filter when hiding,
  otherwise set the bit, so excluded items can be shown dimmed.
- **link:**
  ```python
  IO_REPARSE_TAG_SYMLINK     = 0xA000000C
  IO_REPARSE_TAG_MOUNT_POINT = 0xA0000003   # junctions and mount points

  link = entry.is_symlink() or (
      NT and stat_res is not None
      and getattr(stat_res, 'st_reparse_tag', 0)
          in (IO_REPARSE_TAG_SYMLINK, IO_REPARSE_TAG_MOUNT_POINT))
  ```
  - `is_symlink()` returns `False` for junctions, so the tag check is
    required (verified with Python 3.14: `DirEntry.stat()` fills
    `st_reparse_tag` without an extra `lstat`). Verify once in Sublime's
    plugin host Python.
  - Do **not** use `FILE_ATTRIBUTE_REPARSE_POINT` alone: OneDrive
    placeholders, deduplicated files, app execution aliases and WSL symlinks
    are reparse points too.
  - Hard links are **not** links: every name is equal, there is no target.
    Detectable only via `st_nlink > 1`, which `DirEntry.stat()` leaves at 0
    on Windows and which is always ≥ 2 for directories on Linux. Not a flag.
- **executable:** files only. Directories always have exec bits (Windows:
  Python sets them; POSIX: "search" permission), so they must never get the
  flag.
  - Linux/macOS: `st_mode & (S_IXUSR | S_IXGRP | S_IXOTH)`.
  - Windows: extension in `PATHEXT` (`.COM;.EXE;.BAT;.CMD;.VBS;…`). Verified
    in the test folder: `DirEntry.stat()` does **not** set exec bits for a
    `.bat` (only `os.stat()` does, with a hardcoded extension list), and an
    extra `os.stat()` per entry isn't worth it. `PATHEXT` is also what the
    shell itself uses.
- **No read-only flag** (decided): on Windows the read-only attribute on
  folders is ignored by Explorer and used to mark customized folders
  (`desktop.ini`; e.g. `Documents`, `Pictures`), so it would be wrong and
  noisy; on Linux/macOS the owner `w` bit says little about whether the
  current user can write, and `os.access` costs a system call per entry.
  If wanted later, it belongs in an attributes/permissions stats column.
- **Not flags:** permissions (`rwxr-xr-x`) and ownership are display
  information. They belong in stats columns, where the syntax can color the
  visible characters directly.
- **The executable bit (4) is a placeholder in Phase 2:** the position is
  reserved and always written as 0, and the syntax reader/scope context for
  it exists, but it is not computed yet. Computing it (rules above), coloring
  it and the "run" command come later together.
- **The type bits (5–6) are placeholders in Phase 2 too:** reserved and
  always written as 0, so `FLAG_WIDTH` is 7 from the start and Phase 3
  doesn't change the line width. The syntax only consumes them (plain
  readers, no scope contexts yet); the type is a 2-bit value, not two
  independent flags, so its scopes are designed in Phase 3. Nothing may
  read them before Phase 3 (`00` is not a valid "file" type yet).

## Syntax Design

A `variables:` section holds all structure characters and the field pattern,
so the syntax stays readable and moving the flags field means changing one
variable:

```yaml
variables:
  seg: '\x{200B}'
  col: '\x{2063}'
  on:  '\x{200D}'
  off: '\x{200C}'
  field: '[^\x{200B}\x{2063}\n]*'
  to_flags: '^\t*{{seg}}'        # indent + first SEG
```

Flags are read sequentially with one reader and one scope context per bit.
Each set bit leaves its scope context on the stack, so everything after the
flags (icon, name, note, stats) is inside all of them. No lookaheads; the
number of contexts grows linearly with the number of bits:

```yaml
main:
  - match: '({{to_flags}})'
    captures:
      1: indent                  # keep: _get_name_point relies on it today
    push: flag-0
  - include: non-item-lines      # header, parent, help, ...

flag-0:                          # bit 0 (hidden)
  - match: '{{on}}'
    set: [scope-0, flag-1]       # keep scope-0 on the stack, read next bit
  - match: '{{off}}'
    set: flag-1

scope-0:
  - meta_content_scope: dired.fileattr.hidden
  - match: '(?=\n)'
    pop: true

# flag-1/scope-1 ... flag-4/scope-4: same pattern

type-0:                          # type bits (placeholders): consume only
  - match: '{{on}}|{{off}}'
    set: type-1
type-1:
  - match: '{{on}}|{{off}}'
    set: fields

fields:                          # after the flags field: the item fields
  - include: item-fields         # SEG icon SEG name SEG note (COL stat)*
  - match: '(?=\n)'
    pop: true
```

- The stack depth varies (number of set bits + 1), so every context pops on
  `(?=\n)` in a chain instead of one fixed `pop: N`.
- Item fields are scoped by position using `{{field}}` and the separators,
  not by hand-written guesses like today's `(<.*>)?` for notes (which
  mis-scopes Linux/macOS names containing `<…>`).

Scopes:
- One scope per set bit: `dired.fileattr.hidden`, `dired.fileattr.system`,
  `dired.excluded`, `dired.link`, `dired.executable`.
- **Combinations are never spelled out in the syntax.** They are color-scheme
  selectors, e.g. `dired.fileattr.system - dired.fileattr.hidden` for
  "system only" and `dired.fileattr.hidden dired.fileattr.system` for both.
  This replaces the current `dired.fileattr.system.only` scope.
- Per-field scopes: `…note.dired`, `…stats.size.dired`, `…stats.mtime.dired`,
  `…stats.attrs.dired`.

Color schemes: `meta_content_scope` puts the flag scopes *before*
`string.name.*` in the scope stack, so a broad `string` rule would win the
foreground. Rules must use descendant selectors, e.g.
`dired.fileattr.hidden string.name`, to be more specific. Update
`dired.hidden-color-scheme`, `dired.hidden-tmTheme` and the README.

## Python Changes

### Constants and helpers (`common.py`)
- `BIT_ON`, `BIT_OFF`, `COLUMN_SEP`, `SEGMENT_SEP` (code points as in the
  allocation table, written as `\u` escapes in source), `FLAG_WIDTH`.
- `encode_flags(...) -> str` / `decode_flags(str) -> Flags`.
- `split_line(line) -> (name_fields, stat_fields)`: `split(COLUMN_SEP)`, then
  `split(SEGMENT_SEP)` on the name column. The one helper all parsers use.
- `visible_len(text, tab_size) -> int`: removes all zero-width structure
  characters, then `expandtabs`. Every width/alignment calculation uses it
  (`format_items`' `display_len`, `render_items` padding, `dynamic_width`).
- Delete `SEPARATOR` from `dired.py:23` and the local copy in
  `dired_file_operations.py:236`.

### Scanning (`common.py`)
- `EntryInfo` / `ListingItem`: add `excluded`, `link` (or one
  `flags` field). Executable is not computed yet.
- `_our_scandir`: always load `dired_hidden_files_patterns` and
  `folder_exclude_patterns`; pass `show_hidden` so `_do_scandir` filters or
  flags. Keep the `lru_cache` key consistent.
- `_do_scandir`: compute all flags from the existing stat result; drive
  entries get all zeros.
- `dired_expand`'s root entry (`dired.py:939`): compute its flags the same
  way (one shared helper, not a copy).

### Rendering (`dired.py`)
- `format_items` / `render_items`: build lines per the layout: name column
  fields joined with `SEGMENT_SEP`, each stats field introduced by
  `COLUMN_SEP`.
- The visible `--`/`H-`/`HS` attrs column stays (display only); the syntax no
  longer depends on it.
- `common.py:532-535` (`prepare_filelist`, builds `▸ `/`≡ ` lines by hand):
  use the shared formatter.

### Parsers to update

| Location | Today | New |
|---|---|---|
| `dired.py:905` | `lstrip().startswith('▾')` | icon field via `split_line` |
| `dired.py:927-937` (`dired_expand`) | split on `\u200b`, then two spaces, `[:-4]` for HS | drop the parsing: root mtime from `os.stat(path)` |
| `dired_file_operations.py:233-238` (rename) | `os.sep` heuristic, split on `\u200b` | `split_line`, name field; structure check first |
| `common.py:319` `_get_name_point` | `indent` scope, then `+2` for icon | point after the third `SEG` on the line |
| `common.py:661`, `dired_file_operations.py:316` | `find_all(r'^\s*▾')` | `^\t*\x{200B}[\x{200C}\x{200D}]*\x{200B}▾` |
| `common.py:721-727` (`_find_in_view`) | `^\s*[▸▾] ` / `^\s*≡ ` | same prefix pattern, then icon, `SEG`, name |
| `dired_file_operations.py:433` | `'▾' in line_content` | icon field via `split_line` |
| `dired.py:1195-1199` (`dired_fold`) | replaces icon at `name_point - 2` | icon field position via the separators |
| `dired_misc.py:635` (VCS marker) | `_get_name_point(r) - 2` | icon position via the separators |
| `common.py:164` `dynamic_width` | `len()` of last line minus 14 | `visible_len`, mtime column via `split_line` |

Before calling the phase done, grep for `200b`, `\x{200B}`, `▸`, `▾`, `≡`,
`SEPARATOR`, `- 2`/`+ 2` around name points.

### Rename mode
- The editable region is the name field (after the third `SEG`); indent,
  flags, icon and the separators must not be deletable or typed in front of.
- Structure check per line: exactly 4 `SEG` in the name column, and 0 or
  "number of stats" `COL`. Lines that don't match are refused with a status
  message instead of being renamed.

## Separator Characters in Filenames (accepted risk)

All allocated characters are format characters (category Cf) and can
legally occur in filenames on all platforms; no filesystem strips them.
Names are **not** escaped, consistent with other file explorers (Explorer,
Finder, Nautilus).

- Bits are only read at fixed positions in the flags field, so a name can
  never be misread as flags.
- A name containing `COL` or `SEG` is allowed to break the layout and
  highlighting of its line. That is intended: the user sees that something
  is off with that name. No defensive splitting.
- **Exception, rename mode:** it parses the name back from the buffer, so a
  separator inside a name would silently rename the file to a truncated
  name. The structure check (see Rename mode) refuses such lines.

## Phases

1. **Prototype / verification** (scratch view, no plugin changes):
   - insert flag and separator sequences and check that nothing renders,
   - how Left/Right/Home move over the flags field (grapheme clustering may
     make it one caret step) and that a selection starting in the name does
     not extend into it,
   - whether Sublime counts zero-width characters for tab stops (affects the
     note tab and `visible_len`),
   - `set` with a list of contexts, chained `(?=\n)` pops and
     `meta_content_scope` in a minimal syntax,
   - `st_reparse_tag` in Sublime's plugin host Python.
   **Results (done, Sublime with plugin host Python 3.14.6):**
   - **Rendering depends on `"draw_unicode_white_space": "none"`**, which
     `dired.sublime-settings` already sets for dired views. Without it,
     Sublime draws ZWSP/ZWJ/ZWNJ as visible `<0x200b>`-style boxes
     (~8 em wide each); only `U+2063` is invisible regardless. With it, all
     of them measure 0 px. Document this in the README: users must not
     override the setting for dired views.
   - **Tab stops ignore zero-width characters:** the note and stats columns
     land at exactly the same x position as on a line without them, so
     `visible_len` (strip, then `expandtabs`) matches Sublime.
   - **Caret:** invisible characters are separate caret stops, except that a
     bit following the first `SEG` merged into one step (grapheme
     clustering). Moving Right from the icon to the name takes two presses
     with no visible movement. Home (`bol`) goes to the first `SEG` (after
     the indent), `hardbol` to column 0. Extending a selection is plain
     character by character. Normal navigation places the caret via
     `_get_name_point`, so this mainly matters in rename mode, where the
     structure check catches text typed into the wrong place. Confirmed by
     the user in real dired views: Ctrl+Left/Right, Home and End behave
     normally (dired's own key bindings); no issue.
   - **Syntax:** the context chain works as designed: hidden, system, both,
     system only and excluded scopes apply to name and stats, chained
     `(?=\n)` pops leave nothing behind for the next line, `indent` is still
     scoped, `view.indentation_level()` returns the real depth, and the
     `^\t*\x{200B}[\x{200C}\x{200D}]*\x{200B}` regex finds all item lines.
   - **Python:** `DirEntry.stat()` returns `st_reparse_tag` in the plugin
     host (junction `0xa0000003`, symlinks `0xa000000c`).

2. **Layout and flags:** constants and helpers, `visible_len`, scanning
   (bits 0–3; bit 4 and type bits 5–6 reserved as 0), rendering, syntax with variables and the context chain,
   color schemes with descendant and subtraction selectors, all parsers in
   the table, rename mode with the structure check, README scope docs.
   Removes the `[:-4]`/two-space-split hack and the triplicated syntax rules.
   **Status (implemented, uncommitted):** verified in Sublime on the test
   folder with an automated check: layout and scopes for every test item
   (excluded, hidden, link incl. junction and broken symlink; hard link and
   read-only unflagged), stats on/off, nested expansion incl. the symlinked
   folder, refresh keeping expanded folders, expand/fold of a hidden folder
   (flags kept, `<empty>` note), and a rename round trip (file and folder,
   stats on). Unit tests: `tests/test_line_layout.py` (10 tests, run outside
   Sublime with a stub; UnitTesting isn't installed). Not tested
   automatically: the rename structure-check error (modal dialog), VCS
   markers, fuzzy search. Side findings, unchanged: `prepare_filelist` in
   `common.py` is dead code still building old-format lines; `show(...,
   expanded=...)` on a new root drops `expanded` because `reset_sels` is set.

3. **Item type in the flags field:** fill bits 5–6; the syntax stops matching
   `▸▾≡⠤`; Python asks `dired_index` (directories end with `os.sep`) or the
   type bits, never the icon; icons become a setting; the parent line gets
   the item layout.
4. **Optional:** per-field stats scopes in the shipped schemes, permissions
   column (`rwx…`) colored by the syntax.

## Testing

- Unit tests (`tests/`): `encode_flags`/`decode_flags` round trip,
  `visible_len`, `split_line` with empty fields and stats on/off, link
  detection (symlink, junction, OneDrive-style reparse point excluded),
  rename parsing with notes and stats present, rename refusing lines with
  extra separators.
- Update existing tests that construct or compare raw lines (`test_dired.py`,
  `test_horizontal_navigation.py`, `test_header_navigation.py`).
- Manual: Windows with H/S/HS/-S items, junctions and symlinks;
  Linux/macOS dotfiles with `dired_show_hidden_files` on (excluded
  dimming); stats on and off; tree expansion/collapse; rename
  mode; fuzzy search and jump list; mark/copy/cut/VCS regions still aligned.

## Open Questions

- Whether the parent line gets the item layout before Phase 3.
- Separate existing bug, not part of this plan: `_do_scandir` uses
  `entry.is_dir(follow_symlinks=False)`, so symlinked folders show up as
  files (`06 Symlink Folder - L` in the test folder) while junctions show as
  folders. Fixing it (`is_dir()`) needs a loop guard for recursive walks
  (fuzzy search, re-expanding remembered paths), which junctions already
  need today.

## Future: Richer Model (not part of this plan)

The plugin still rereads its own buffer in a few places (expanded state via
`▾`, the root timestamp in `dired_expand`, "is directory" via the icon).
Long term, `dired_index` entries could become records (path, flags,
expanded, size, mtime) with an in-memory cache per `view.id()` (validated by
`view.change_count()`), keeping view settings as the persisted copy. Then
Python never parses the buffer except in rename mode, and the line encoding
exists only for the syntax.

Related feature idea (separate from this plan): a "run" command for
executable items, enabled by a keymap `selector` context on
`dired.executable`, using Sublime's `exec` command for output.
