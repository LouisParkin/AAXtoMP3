# OpenAudible helper tools

Glue that lets AAXtoMP3 convert books that
[OpenAudible](https://openaudible.org) has already downloaded, without
re-downloading anything and without OpenAudible's paid converter.

**Full guide with worked examples: [`../docs/OPENAUDIBLE.md`](../docs/OPENAUDIBLE.md)**

## Install

```bash
install -m 0755 oa-* openaudible-convert flatten-chapters ~/.local/bin/
pip install audible          # only needed for vouchers and cover art
```

## The tools

| Tool | Purpose |
|---|---|
| **`openaudible-convert`** | The one you actually run. Walks `~/OpenAudible`, requests a voucher per book, stages the AAXC correctly, regenerates flat chapters, calls AAXtoMP3, and records progress so it is resumable. |
| **`oa-voucher`** | Requests an AAXC licence from Audible and decrypts it to `{key, iv, chapters}` JSON. The chapter tree it returns is authoritative (`is_accurate`), unlike some container chapter tracks. |
| **`oa-chapters`** | Reads a media file's own chapter track and writes a flat audible-cli-shaped chapters JSON. Used to sidestep nesting entirely. |
| **`oa-verify`** | Compares each converted book's total duration against the source AAX. Catches truncation, dropped chapters and failed splits. |
| **`oa-cover`** | Fetches one book's full-resolution cover from the catalog API. |
| **`oa-covers`** | Bulk cover upgrade — replaces OpenAudible's 500 px thumbnails across a whole library. |
| **`oa-organize`** | Files converted books into `<Author>/<Title>/`, with primary-author collapsing and per-ASIN overrides. |
| **`oa-split-compendium`** | Splits a multi-work collection into one book per contained work, using the licence chapter tree. |
| **`flatten-chapters`** | Standalone repair for a nested `*-chapters.json` from `audible-cli`. Only needed on unpatched AAXtoMP3. |

Every tool takes `--help`. `openaudible-convert`, `oa-covers`, `oa-organize` and
`oa-split-compendium` take `--dry-run`.

## Offline vs online

Only `oa-voucher` and `oa-cover` contact Audible (and therefore need the
`audible` Python package and an auth file). `oa-chapters`, `oa-verify`,
`oa-organize`, `oa-covers`, `oa-split-compendium` and `flatten-chapters` need
nothing but `python3` and `ffmpeg`/`ffprobe`.

## Typical run

```bash
openaudible-convert --dry-run
openaudible-convert
oa-verify
oa-covers
oa-organize --primary-author
```

## `examples/`

* `british-classics.works.json` — the real work-mapping used to split a 224-hour,
  22-work collection into separate books. A complete, non-trivial example of the
  `--works` file format for `oa-split-compendium`.
