# Converting an OpenAudible library with AAXtoMP3

[OpenAudible](https://openaudible.org) is a good downloader. Its free/demo build
will happily fetch your `.aax`/`.aaxc` files, but conversion is a paid feature —
and even when licensed it does not split a book into per-chapter files with real
chapter titles.

This directory holds the glue that lets **AAXtoMP3 convert what OpenAudible has
already downloaded**, without re-downloading a single byte of audio.

Everything here was built and run against a real 97-book, 61 GiB library.

---

## Contents

| Tool | What it does | Needs `audible`? |
|---|---|---|
| `openaudible-convert` | the orchestrator — converts a whole library | yes (via `oa-voucher`) |
| `oa-voucher` | fetches + decrypts one book's AAXC key/iv | **yes** |
| `oa-cover` / `oa-covers` | fetch full-resolution cover art | **yes** (`oa-cover`) |
| `oa-chapters` | build a flat chapters JSON from the file's own chapter track | no |
| `oa-verify` | check every converted book against the source | no |
| `oa-organize` | file books into `<Author>/<Title>/` | no |
| `oa-split-compendium` | split a multi-work collection into separate books | no |
| `flatten-chapters` | repair nested `*-chapters.json` from `audible-cli` | no |

Only `oa-voucher` and `oa-cover` talk to Audible. The rest are offline tools.

---

## Why the glue is needed

OpenAudible's layout and AAXtoMP3's expectations differ in three ways. All three
are handled for you by `openaudible-convert`; they are documented here so you
know what it is doing.

**1. The file says `.AAX` but the bytes are AAXC.**
OpenAudible writes AAXC content into a `.AAX` filename. AAXtoMP3 decides which
decryption path to use purely from the *extension*, so it picks
`-activation_bytes` (AAX) instead of `-audible_key`/`-audible_iv` (AAXC) and
fails. The fix is to stage the file under an `.aaxc` name — a symlink is enough.

**2. There is no voucher.**
AAXC uses a per-file key/iv issued by Audible's licence endpoint. OpenAudible
does not persist it, and rainbow-table `activation_bytes` do not apply to AAXC.
So a licence must be requested. **A freshly requested licence decrypts a file
that was downloaded earlier** — verified across a whole library — so this costs
one small API call per book, not a re-download.

**3. Chapter data is nested.**
Both `books.json` and `audible-cli`'s JSON nest `Part -> chapters`. Upstream
AAXtoMP3 read only the top level and silently dropped the rest.
*This fork fixes that* (see [NESTED-CHAPTERS.md](NESTED-CHAPTERS.md)), but
`openaudible-convert` sidesteps it anyway by regenerating chapters from the
container's own chapter track via `oa-chapters`, which cannot nest.

Nothing is ever written into your OpenAudible directory.

---

## Install

### 1. AAXtoMP3 and its usual dependencies

```bash
git clone https://github.com/LouisParkin/AAXtoMP3.git
cd AAXtoMP3
sudo install -m 0755 AAXtoMP3 /usr/local/bin/AAXtoMP3
```

You need `ffmpeg`, `jq`, `mediainfo`, and `grep`/`sed`/`find` (GNU versions on
macOS: `brew install grep gnu-sed findutils`). For m4b output you also want
`mp4v2` (`mp4chaps`).

```bash
# Debian/Ubuntu/Mint
sudo apt install ffmpeg jq mediainfo
```

### 2. The helper scripts

```bash
install -m 0755 openaudible/oa-* openaudible/openaudible-convert \
                openaudible/flatten-chapters ~/.local/bin/
```

Make sure `~/.local/bin` is on your `PATH`.

### 3. The Audible library (only for vouchers and cover art)

```bash
pip install audible
```

`audible` is a standalone library. You do **not** need `audible-cli` — but it is
by far the easiest way to create the auth file in the next step.

---

## One-time setup: an Audible auth file

`oa-voucher` needs credentials for the marketplace each book was bought in.

```bash
pip install audible-cli
audible quickstart
```

Answer the prompts. Two things trip people up:

* **`CVF Code:`** — Amazon has emailed or texted you a one-time verification
  code. Paste it in. It is not your password.
* **Country code** — this must match the marketplace the books were bought from.

The result is `~/.audible/config.toml` plus an auth file per profile.

### Several marketplaces

If your library spans regions, add one profile per region. A licence can only be
issued by the marketplace the book was bought in.

```bash
audible manage auth-file add       # repeat per region
```

`~/.audible/config.toml` ends up looking like:

```toml
[APP]
primary_profile = "audible_au"

[profile.audible_au]
auth_file = "audible_au.json"
country_code = "au"

[profile.audible_us]
auth_file = "audible-us.json"
country_code = "us"
```

`openaudible-convert` reads `country_code` from each profile and picks the right
one **per book**, based on that book's region in `books.json`. You do not have to
do anything else.

> Note the auth file name need not match the profile name — `quickstart` writes
> profile `audible_us` pointing at `audible-us.json`. The tools resolve the name
> through `config.toml`, so this mismatch is handled.

---

## Quick start

Convert the entire library to chaptered m4b:

```bash
openaudible-convert --dry-run          # see what would happen
openaudible-convert                    # do it
oa-verify                              # prove nothing was truncated
```

Defaults: reads `~/OpenAudible`, writes `~/OpenAudible/Converted`.

It is **resumable** — completed books are recorded by ASIN, so you can stop it
and re-run it freely.

---

## Worked examples

### Convert one book first

Always sanity-check a single book before committing to a whole library.

```bash
openaudible-convert --match "Hitchhiker" --limit 1
```

### Convert everything, to a different destination

```bash
openaudible-convert --root ~/OpenAudible --out /mnt/media/AudioBooks
```

If `--out` is a network mount, a local scratch directory is used automatically:
AAXtoMP3 writes the whole book, reads it back to split it, then writes every
chapter — roughly 3x the traffic. Building locally and moving once is much
faster. Override with `--no-scratch` or point it elsewhere with `--scratch`.

### One file per book instead of per chapter

```bash
openaudible-convert --single --format m4b
```

### MP3 instead of m4b

```bash
openaudible-convert --format mp3
```

### Force a single marketplace

```bash
openaudible-convert --profile audible_uk
```

Only needed if per-book region detection gets it wrong.

### Verify the results

`oa-verify` compares each converted book's total duration against the **source
AAX file**, not against `books.json` — whose durations are rounded to the minute
and will produce false alarms.

```bash
oa-verify
oa-verify --source-tolerance 10
```

### Fix low-resolution cover art

OpenAudible stores only a 500 px thumbnail, and that image is natively 500x500 —
URL resize tokens cannot enlarge it. The real art is behind the catalog API.

```bash
oa-covers --dry-run
oa-covers                      # upgrade everything under 501 px
oa-covers --min-width 1500     # be stricter
oa-covers --match "Dune"       # just one book
```

### File books into `<Author>/<Title>/`

```bash
oa-organize --dry-run
oa-organize --primary-author
```

`--primary-author` collapses `"Brandon Sanderson, Michael Kramer - narrator"`
down to `Brandon Sanderson`, which is almost always what you want for Plex.

Fix individual books with an overrides file keyed by ASIN:

```bash
cat > ~/.config/oa-authors.json <<'EOF'
{ "1529143500": "Douglas Adams" }
EOF
oa-organize --primary-author --overrides ~/.config/oa-authors.json
```

Skip a book entirely:

```bash
oa-organize --primary-author --exclude "British Classics"
```

---

## Splitting a collection into separate books

Some Audible products bundle many complete works into one enormous file. Filing
that as a single "album" is unhelpful, and its container chapter track may be
unreliable — one real 224-hour collection had a corrupt track that silently
dropped 21.4 hours of audio.

`oa-split-compendium` cuts the file using the **licence response's** chapter
tree, which is authoritative (`is_accurate: true`), and writes one book folder
per contained work.

```bash
# 1. Get a voucher. Because oa-voucher requests chapter_info, this file
#    contains the full chapter tree as well as the key/iv.
oa-voucher B0DD5RG4CJ ~/collection.voucher.json --profile audible_au

# 2. See what is inside, without writing anything
oa-split-compendium \
  --voucher ~/collection.voucher.json \
  --aax "~/OpenAudible/aax/The British Classics Collection.AAX" \
  --out ~/OpenAudible/Converted \
  --dry-run
```

Audible usually names works `"<Title>, by <Author>"`, which is derived
automatically. Anything it cannot parse is reported as a ready-to-paste stub:

```
ERROR: cannot derive an author for these works. Audible only spells some of
them '<Title>, by <Author>'; add the rest to a --works file:
  "The Diary of a Nobody": {"author": "?", "title": "?"},
```

Fill those in — this is also where you fix Audible's typos or match an author
spelling you already use:

```json
{
  "The Diary of a Nobody": { "author": "George Grossmith", "title": "The Diary of a Nobody" },
  "Lady Chatterly's Lover, by D.H. Lawrence": { "author": "D. H. Lawrence", "title": "Lady Chatterley's Lover" },
  "The Time Machine, by H.G. Wells": { "author": "H. G. Wells", "title": "The Time Machine" }
}
```

A complete real example ships as
[`examples/british-classics.works.json`](../openaudible/examples/british-classics.works.json).

```bash
# 3. Do it, skipping works you already own standalone
oa-split-compendium \
  --voucher ~/collection.voucher.json \
  --aax "~/OpenAudible/aax/The British Classics Collection.AAX" \
  --out ~/OpenAudible/Converted \
  --cover ~/covers/collection.jpg \
  --works ~/british-classics.works.json \
  --skip "1984, by George Orwell" \
  --skip "Animal Farm, by George Orwell" \
  --jobs 4
```

Useful extras:

* `--decrypted PATH` — keep the decrypted intermediate so re-runs skip it.
* `--only "Jane Eyre"` — process a single work.
* `--retitle "Jane Eyre=Jane Eyre (2024)"` — disambiguate an edition you already
  own under the same name.

Each book gets its own `cover.jpg`, an `.m3u` playlist, and per-chapter tags
(`album`, `artist`, `album_artist`, `track`, `genre`, `date`).

### Result from the real run

224.23 h collection → 22 separate books, 680 chapters, filed under 18 authors.
Total drift across all 680 files was **+16.3 s — exactly one 24 ms AAC packet
per file**, from input-seek snapping. Chapters start at most 24 ms early, so no
audio is lost.

---

## Using `audible-cli` downloads instead

If you download with `audible-cli` rather than OpenAudible, you do not need any
of the `oa-*` tools — but you *do* need this fork, or a nested chapter file will
silently cost you most of the book.

```bash
audible download --asin B002V1CB62 --aaxc --chapter --cover --cover-size 1215
AAXtoMP3 --use-audible-cli-data --aaxc -e:m4b *.aaxc
```

To check a chapter file for nesting before converting:

```bash
jq -r '(.content_metadata.chapter_info.chapters | length) as $top
       | ([.content_metadata.chapter_info.chapters[] | recurse(.chapters[]?)] | length) as $all
       | "top-level: \($top)   total nodes: \($all)   " +
         (if $all > $top then "NESTED" else "flat" end)' *-chapters.json
```

On older/unpatched AAXtoMP3 you can pre-flatten the file instead:

```bash
flatten-chapters *-chapters.json
```

`flatten-chapters` refuses to write unless the chapter spans sum to the declared
runtime, so it cannot quietly make things worse.

---

## Troubleshooting

**`ERROR: no auth file ...`**
The profile has no auth file. Check `~/.audible/config.toml` — remember the
`auth_file` value can differ from the profile name.

**`licence request failed ... 403`**
Wrong marketplace. A licence can only be issued by the region the book was
bought in. Add that region's profile, or force it with `--profile`.

**Converted book is far shorter than it should be**
Nested chapters. Confirm with the `jq` snippet above. This fork fixes it; on
stock AAXtoMP3, run `flatten-chapters` first.

**Book converts with no cover art**
A regex metacharacter in the title (`+`, `[`, `(`, `^`, `$`) breaks upstream's
`find -regex` cover lookup. Fixed in this fork.

**Chapter splitting fails on some books**
A `/` in a chapter title. Handled by this fork's sanitising, and by
`openaudible-convert` when it stages names.

**`rsync` fails copying results to a NAS**
`rsync -a` tries to preserve ownership, which cifs/sshfs refuse. Use:

```bash
rsync -rltD --no-perms --no-owner --no-group SRC DST
```

SMB also resets mtimes on rename, so newly created files get the wrong time. A
cheap second pass fixes it without moving any data:

```bash
rsync -rltD --no-perms --no-owner --no-group --size-only --inplace SRC DST
```

**Plex shows one book as several albums**
Plex scanned the directory while it was being rewritten. Stop Plex during large
syncs. To repair, merge the surplus album entities:

```
PUT /library/metadata/{keepThisRatingKey}/merge?ids={otherKey1,otherKey2}
```

---

## A note on licensing and ethics

These tools only decrypt books **you have bought**, using **your own** Audible
credentials, and they do not bypass OpenAudible's paid licence — OpenAudible's
converter is never invoked. If you use OpenAudible regularly, buy a licence; it
is good software.
