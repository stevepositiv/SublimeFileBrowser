# FileBrowser (dired) for Sublime Text — Claude notes

## Current work

Branch `attrs-color`: highlighting items by filesystem attributes and other
flags. The design is in **`PLAN-Invisible-Flags.md`**: zero-width Unicode
characters encode a flags field and column/segment separators in each item
line, so the syntax (not regions) does the highlighting. Follow the plan's
phases; Phase 1 is a prototype/verification step before touching the plugin.

`MODEL.md` describes the view model (`dired_index`, expanded paths), which
this plan deliberately does not change.

## Manual test folder

`C:\Users\steve\dired-toggle-test` holds items for each flag case:

- Naming: `0x` = folders, `1x` = files; the name suffix states the expected
  flags (e.g. `04 SuperHidden Folder - SH`, `05 Junction Folder - L`,
  `16 Hardlink File - not L.txt`). Names containing "Pattern Excluded" are
  meant to match the hidden-files patterns.
- Claude may create and delete items there. Leave added items in place so
  they can be used for manual testing.
- Creating symlinks requires admin rights or Developer Mode; junctions and
  hard links work without. Ask the user to create symlink cases.

## Gotchas

- **Never write literal zero-width/format characters into files** (docs or
  code). Write them as `\u200b`-style escapes in Python source and
  `\x{200B}` in syntax regexes. Tools may turn typed escapes into the real
  characters; check with
  `python -X utf8 -c "import unicodedata,sys; print(sum(unicodedata.category(c)=='Cf' for c in open(sys.argv[1],encoding='utf-8').read()))" FILE`.
- `_do_scandir` is wrapped in `lru_cache`: after changing scanning code,
  restart Sublime or reload the plugin before judging results.
- `dired.hidden-color-scheme` / `dired.hidden-tmTheme` are the shipped
  schemes; scope changes need README updates too.
- Sublime's plugin host may run an older Python than the system one; verify
  APIs like `st_reparse_tag` in Sublime's console, not only with system
  Python.
