# AAXtoMP3 — Copilot Instructions

Fork of the archived `KrumpetPirate/AAXtoMP3`. A bash front-end to ffmpeg that
decrypts Audible AAX/AAXC files into MP3/M4A/M4B/FLAC/Opus, plus a Python/bash
toolchain (`openaudible/`) for converting an OpenAudible-managed library.
There is no compiled build — the "source" is the shipped shell/Python scripts
themselves, so CI is syntax-checking + a bash test suite, not a build system.

## Build, test, lint

There is no package manager, build step, or linter config. CI
(`.github/workflows/tests.yml`) is the authority for what "passing" means:

```bash
# Syntax-check (fast; catches typos without running anything)
bash -n AAXtoMP3
bash -n interactiveAAXtoMP3
bash -n tests/test-nested-chapters.sh
bash -n openaudible/flatten-chapters

# The openaudible/oa-* and openaudible-convert tools are Python with no .py
# extension, so they're checked by parsing rather than a linter:
python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" openaudible/oa-verify

# Full test suite (14 checks: chapter flattening + cover-lookup regex escaping)
./tests/test-nested-chapters.sh

# CLI smoke tests
bash AAXtoMP3 --version
bash AAXtoMP3 --help
```

There is no flag to run a single check in `tests/test-nested-chapters.sh` —
it's a single linear script, not a test framework. To exercise one case while
iterating, comment out the other `check "..."` calls temporarily, or copy the
relevant fixture + `check` lines into a throwaway script. Do not add a new
test framework; add more fixtures/`check` calls to the existing file instead.

Release archives (attached to GitHub Releases on `v*` tags) are built with:
```bash
.github/scripts/build-archives.sh --version 2.0.0 --out dist
```
This produces reproducible (`SOURCE_DATE_EPOCH`-pinned) `-slim` (script +
docs) and `-full` (+ `openaudible/`) tarballs/zips. If you add a new top-level
file that should ship in a release, add it to `slim_paths` or `full_paths` in
that script.

## Architecture

**`AAXtoMP3`** (~1100 lines, single file) is the whole converter and runs as
one linear pipeline per input file:
1. Parse args in a `while`/`case` loop (before argument parsing, the script
   must not call any function or external binary — see the comment above the
   loop — or `$1` stops meaning "first CLI arg").
2. Only after parsing does it `set -o errexit -o noclobber -o nounset
   -o pipefail`.
3. Detect GNU grep/sed/find (aliased `$GREP`/`$SED`/`$FIND`; macOS needs
   `ggrep`/`gsed`/`gfind`) and ffmpeg/ffprobe (`$FFMPEG`/`$FFPROBE`,
   overridable via `--ffmpeg-path`/`--ffmpeg-name`/`--ffprobe-name`).
   mp4art/mp4chaps/mediainfo are optional — their absence only disables
   cover/chapter tagging or extra metadata, with a `WARN`, not a hard exit.
4. Resolve the AUTHCODE (`--authcode` > `./.authcode` > `~/.authcode`) unless
   the input is `.aaxc` (uses per-file key/iv instead — see
   `validate_extra_files`).
5. Main loop over `$@`: per file, detect `.aax` vs `.aaxc` by extension,
   `validate_aax`, `save_metadata` (dumps ffprobe output), derive
   artist/title/etc. from metadata, compute `output_directory`/`output_file`
   from the naming-scheme variables (`$genre/$artist/$title` etc., evaluated
   with `eval echo` — this is intentional and documented, not a bug), run the
   ffmpeg transcode, extract/copy cover art, and — if `mode=chaptered` —
   split into per-chapter files and write an `.m3u` playlist.
6. Chapter data with `--use-audible-cli-data` comes from an audible-cli
   `*-chapters.json` file whose chapters can nest (Parts/Books/Discs). The
   flattening logic lives in a single jq filter, `flatten_chapters_jq`
   (heredoc around line 566), which recursively descends `.chapters[]` and
   decides whether to keep or drop a parent node based on whether its own
   span is covered by its children. **This filter is the single source of
   truth — do not duplicate it elsewhere.** `docs/NESTED-CHAPTERS.md` has the
   full bug writeup for why naive top-level-only iteration silently drops
   audio.

**`tests/test-nested-chapters.sh`** extracts `flatten_chapters_jq` directly
out of `AAXtoMP3` with `sed` rather than re-implementing it, specifically so
the tests cannot silently drift from the code they cover. If you change the
filter's heredoc markers (`read -r -d '' flatten_chapters_jq <<'JQEOF'` /
`JQEOF`), update the extraction `sed` pattern in the test file too. Tests
assert flattened chapter spans exactly tile `[0, runtime_length_ms]` (no gap,
no overlap) via the `coverage()` helper.

**`interactiveAAXtoMP3`** is a guided wrapper that prompts for the common
flags and execs `AAXtoMP3`. It persists the previous run's choices in
`.interactivesave` (in the CWD) and pre-fills prompts from it next time.

**`openaudible/`** is a separate toolchain for converting a library that
[OpenAudible](https://openaudible.org) already downloaded, chained as:
`oa-voucher` (fetch AAXC key/iv from Audible, needs `audible` pip package) →
stage `.AAX` as `.aaxc` → `oa-chapters` (regenerate flat, non-nested chapters
from the container's own chapter track) → `AAXtoMP3` → `oa-verify` (duration
check) → `oa-covers`/`oa-cover` (full-res cover art) → `oa-organize`
(`<Author>/<Title>/` foldering). `openaudible-convert` is the orchestrator
that drives this whole pipeline and is resumable. `oa-split-compendium`
splits a multi-work collection using the licence chapter tree. Only
`oa-voucher` and `oa-cover` need network access / the `audible` package; the
rest need only `python3` and `ffmpeg`/`ffprobe`. Full guide:
`docs/OPENAUDIBLE.md`.

## Conventions

- `AAXTOMP3_VERSION` (top of `AAXtoMP3`) must exactly match the pushed `vX.Y.Z`
  git tag — CI's release job (`tests.yml`) fails the build otherwise.
- Loglevel convention throughout: `0` progress only, `1` (default) some info,
  `2` more detail on chapter splitting, `3` (`--debug`) full debug via the
  `debug`/`debug_vars`/`debug_file` helpers.
- Naming-scheme strings (`--dir-naming-scheme`, `--file-naming-scheme`,
  `--chapter-naming-scheme`) are evaluated with `eval echo`, so they can run
  arbitrary command substitutions — this is documented, user-facing behavior,
  not something to "fix" defensively.
- Cover-art/file lookups use GNU `find -regex` against book titles, so any
  code that builds such a pattern from user-controlled metadata must escape
  regex metacharacters first (see `sanitize()`/escaping in
  `openaudible/openaudible-convert` and the "cover lookup regex escaping"
  tests) — this was a real, previously-silent bug.
- Shell scripts here target **bash + GNU coreutils** specifically (not POSIX
  sh, not BSD grep/sed/find); don't introduce GNUisms-avoidance shims without
  reason, but do keep using the `$GREP`/`$SED`/`$FIND` indirection when
  writing new cross-platform-sensitive code.
