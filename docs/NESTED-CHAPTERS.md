# Nested chapters: `--use-audible-cli-data` silently drops audio

> **Status in this fork: fixed.** This document is the full analysis — what the
> bug is, how to detect it, how it is fixed here, and the evidence. It is
> written as a bug report because it was originally drafted as one; upstream was
> archived on 23 Apr 2023, so it could never be filed. See
> [Upstream status](#upstream-status).

## Summary

When `--use-audible-cli-data` is used, `AAXtoMP3` reads chapter markers from the
audible-cli `*-chapters.json` file. Upstream's jq expression iterates
**only the top level** of `content_metadata.chapter_info.chapters[]` and never
descends into `.chapters[].chapters[]`.

Audible nests chapter data for any title that has Parts, Books, Discs, or (worst
case) bundles several complete works into one file. For those titles AAXtoMP3
emits one output file per *top-level* node and **silently discards the audio of
every nested chapter**. There is no warning, no non-zero exit, and the run
reports success.

## Impact

Severity: **silent data loss**. The output looks plausible — correct filenames,
correct tags, playable files — so it is easy to miss until you notice the
runtime is wrong.

Two real cases from a 97-book library:

| Title | Declared runtime | Produced by AAXtoMP3 | Files | Audio lost |
|---|---|---|---|---|
| *A Short History of Nearly Everything* | 18.99 h | **0.29 h** | 8 | 98.5 % |
| *The British Classics Collection, Vol. 1* | 224.23 h | **202.83 h** | 425 | 21.4 h |

In the first case only the 8 top-level Part markers existed, each a few seconds
of spoken "Part One" announcement — so 18.7 hours of the book vanished. The
correct output is 38 files / 18.99 h.

## Root cause

`AAXtoMP3` line 540 (final `master`, `1c1bd7f`-era; line 511 in the v1.3 release):

```bash
jq -r '.content_metadata.chapter_info.chapters[] | "Chapter # start: \(.start_offset_ms/1000), end: \((.start_offset_ms+.length_ms)/1000) \n#\n# Title: \(.title)"' "${extra_chapter_file}" \
  | $SED 's@[:/]@@g' >> "$metadata_file"
```

`.chapters[]` is a single-level iteration.

### This is an internal inconsistency, not an oversight about the data format

Thirteen lines later, in the **same function**, the `--single` mode path parses
the **same file** and *does* descend into nested chapters when building
`chapter.txt` for `mp4chaps`:

```jq
.content_metadata.chapter_info.chapters |
reduce .[] as $c ([]; if $c.chapters? then .+[$c | del(.chapters)]+[$c.chapters] else .+[$c] end) | flatten |
```

So the nested shape was known and handled for single-file m4b output, but the
same handling was never applied to the chaptered-split path. Users of
`--single` get correct chapter markers; users of the default `chaptered` mode
silently lose the audio.

Note also that the `--single` implementation only descends **one** level
(`$c.chapters` is spliced in, but grandchildren are not), so it is also
incorrect for titles nested two deep — such as the 224 h collection below,
which nests work → part → chapter. And by always emitting the parent alongside
its children it assumes one of the two `length_ms` conventions described in the
fix section.

A nested `*-chapters.json` looks like:

```json
{"content_metadata": {"chapter_info": {
  "is_accurate": true,
  "runtime_length_ms": 68371000,
  "chapters": [
    {"start_offset_ms": 0,      "length_ms": 23757, "title": "Opening Credits"},
    {"start_offset_ms": 23757,  "length_ms": 9148,  "title": "Part One",
     "chapters": [
       {"start_offset_ms": 32905, "length_ms": 1421313, "title": "Chapter 1"},
       {"start_offset_ms": 1454218, "length_ms": 1355002, "title": "Chapter 2"}
     ]}
  ]}}}
```

Only `Opening Credits` and the 9-second `Part One` announcement are emitted.
Chapters 1 and 2 — the actual book — are dropped.

## Reproduction

```bash
audible download --asin B002V1CB62 --aaxc --chapter --cover --cover-size 1215
AAXtoMP3 --use-audible-cli-data --aaxc -e:m4b *.aaxc
# compare the sum of output durations with
jq '.content_metadata.chapter_info.runtime_length_ms/3600000' *-chapters.json
```

## Detection one-liner

Users can check any chapter file for nesting before converting:

```bash
jq -r '(.content_metadata.chapter_info.chapters | length) as $top
       | ([.content_metadata.chapter_info.chapters[] | recurse(.chapters[]?)] | length) as $all
       | "top-level: \($top)   total nodes: \($all)   " +
         (if $all > $top then "NESTED - current AAXtoMP3 will lose audio" else "flat - safe" end)' \
   book-chapters.json
```

On a nested file this prints:

```
top-level: 3   total nodes: 5   NESTED - current AAXtoMP3 will lose audio
```

If `total nodes` exceeds `top-level`, the current code will lose audio.

## Proposed fix (applied in this fork)

A plain `recurse` is **not** sufficient. Audible uses two different conventions
for a parent node's `length_ms`, and they need different handling:

* **Shape A** — the parent's span *covers* its children (`Part One` = 1000→5500,
  children fill 1000→5500). Emitting the parent as well as the children would
  duplicate that audio.
* **Shape B** — the parent is a short spoken *title announcement* that sits
  immediately before its children (`Part One` = 1000→1500, first child starts at
  1500). Here the parent must be kept or those seconds are lost.

Emitting a parent only when its span ends at or before its first child handles
both:

```diff
-    jq -r '.content_metadata.chapter_info.chapters[] | "Chapter # start: \(.start_offset_ms/1000), end: \((.start_offset_ms+.length_ms)/1000) \n#\n# Title: \(.title)"' "${extra_chapter_file}" \
+    jq -r 'def flatten_chapters:
+             . as $n
+             | (($n.chapters // []) | sort_by(.start_offset_ms)) as $kids
+             | if ($kids | length) == 0 then $n
+               else
+                 (if ($n.start_offset_ms + $n.length_ms) <= $kids[0].start_offset_ms
+                  then $n else empty end),
+                 ($kids[] | flatten_chapters)
+               end;
+           [.content_metadata.chapter_info.chapters[] | flatten_chapters]
+           | sort_by(.start_offset_ms)
+           | .[]
+           | "Chapter # start: \(.start_offset_ms/1000), end: \((.start_offset_ms+.length_ms)/1000) \n#\n# Title: \(.title)"' "${extra_chapter_file}" \
       | $SED 's@[:/]@@g' >> "$metadata_file"
```

The same `flatten_chapters` definition should also replace the one-level
`reduce` used by the `--single` path 13 lines below, so both modes derive
chapters identically.

### Test evidence

Both shapes tile the full runtime with no gap and no overlap:

```
### SHAPE A: parent length SPANS its children (must not duplicate)
start: 0, end: 1 | Opening Credits
start: 1, end: 3.5 | Chapter 1
start: 3.5, end: 5.5 | Chapter 2
start: 5.5, end: 60 | Part Two
  covers 0 -> 60

### SHAPE B: parent is a short title ANNOUNCEMENT
start: 0, end: 1 | Opening Credits
start: 1, end: 1.5 | Part One
start: 1.5, end: 3.5 | Chapter 1
start: 3.5, end: 5.5 | Chapter 2
start: 5.5, end: 60 | Part Two
  covers 0 -> 60
```

Applied to the real 224 h collection, this yields 718 chapter nodes covering
0.00 h → 224.23 h, exactly matching `runtime_length_ms` (807 223 288 ms, delta 0).

### Suggested extra safety net (applied in this fork)

Because the failure is silent, coverage is asserted after parsing and a warning
is printed on mismatch:

```bash
declared=$(jq -r '.content_metadata.chapter_info.runtime_length_ms/1000' "${extra_chapter_file}")
parsed=$($GREP -Po 'end: \K[0-9.]+' "$metadata_file" | tail -1)
# warn if they differ by more than a couple of seconds
```

---

## Secondary bug: regex metacharacters in the title break cover-art lookup

*(Also fixed in this fork.)*

Line 449:

```bash
extra_find_command='$FIND "${extra_dirname}" -maxdepth 1 -regex ".*/${extra_title##*/}_([0-9]+)\.jpg"'
```

`${extra_title}` is interpolated **raw** into a `find -regex` pattern, so any
regex metacharacter in the book title is interpreted rather than matched.

Real example — *The British Classics Collection - Volume One: 20+ Stories from
Dickens, Brontë, Austen, Orwell, & More*. The `+` in `20+` becomes a
one-or-more quantifier, the pattern no longer matches the file on disk, `find`
returns nothing, and the book is converted **with no cover art** — again with no
warning.

Affected characters under findutils' default regex type: `+ ? . * [ ] ^ $ \ ( ) { }`.

Suggested fix: escape the interpolated title before use, e.g.

```bash
esc_title=$(printf '%s' "${extra_title##*/}" | $SED 's/[][\\.*^$+?(){}|]/\\&/g')
extra_find_command='$FIND "${extra_dirname}" -maxdepth 1 -regex ".*/${esc_title}_([0-9]+)\.jpg"'
```

or avoid regex entirely with `-name "${extra_title##*/}_*.jpg"`.

### Test evidence

With a real file `The British Classics Collection - Volume One: 20+ Stories_(1215).jpg`
on disk:

```
--- CURRENT behaviour (raw interpolation) ---
  matches: 0                      <- cover silently lost

--- escaped title: The British Classics Collection - Volume One: 20\+ Stories
--- PROPOSED behaviour ---
  ./The British Classics Collection - Volume One: 20+ Stories_(1215).jpg
  matches: 1

--- plain title 'Mostly Harmless' (regression check) ---
  matches: 1
```

Note the `([0-9]+)` in the pattern is intentional and must **not** be escaped:
under findutils' default regex type the parentheses are literal and match the
literal parentheses in `_(1215).jpg`, while `+` is a quantifier for the digits.
Only the interpolated title needs escaping.

---

## Environment

* Reproduced against `AAXtoMP3` v1.3 (`/usr/bin/AAXtoMP3`, installed manually,
  not via a package) and confirmed by inspection against final `master`.
* Linux, bash, GNU findutils, jq
* Source files obtained with `audible-cli` (`--aaxc --chapter --cover`)

## Upstream status

`KrumpetPirate/AAXtoMP3` was **archived on 23 Apr 2023** and is read-only, so
this cannot be filed as an issue there. At the time of writing:

* 1288 stars, 199 forks, last push 2023-03-27.
* No fork has meaningful traction — the most-starred is 3 stars, and the
  handful with 2024 activity are unmodified mirrors.
* The defect is present **unchanged in every fork checked**
  (`Nicko98`, `saratrajput`, `fabh2o`), all still carrying the single-level
  `.chapters[]` at line 540.

This fork applies both fixes, plus the coverage guard, and adds
`tests/test-nested-chapters.sh` (14 cases) to keep them honest. The tests
extract the jq filter directly out of `AAXtoMP3`, so they cannot drift from the
implementation.

```bash
./tests/test-nested-chapters.sh
```

