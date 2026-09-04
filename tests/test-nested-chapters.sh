#!/usr/bin/env bash
# Tests for the nested-chapter and cover-lookup fixes.
#
# The jq filter is extracted from AAXtoMP3 itself rather than duplicated here,
# so these tests cannot silently drift away from the code they cover.
#
#   ./tests/test-nested-chapters.sh
set -u

cd "$(dirname "$0")/.."
SCRIPT=AAXtoMP3
pass=0; fail=0

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '        expected: %s\n        actual:   %s\n' "$3" "$2"; }; }

# Pull the filter straight out of the script under test.
FILTER=$(sed -n "/read -r -d '' flatten_chapters_jq/,/^JQEOF/p" "$SCRIPT" | sed '1d;$d')
[ -n "$FILTER" ] || { echo "could not extract flatten_chapters from $SCRIPT"; exit 1; }

# Emit "start,end,title" per chapter for a given fixture.
flatten() {
  jq -r "$FILTER"'
    [.content_metadata.chapter_info.chapters[] | flatten_chapters]
    | sort_by(.start_offset_ms) | .[]
    | "\(.start_offset_ms),\(.start_offset_ms + .length_ms),\(.title)"' "$1"
}

# Assert the emitted spans tile [0, runtime] with no gap and no overlap.
coverage() {
  local file=$1 runtime
  runtime=$(jq -r '.content_metadata.chapter_info.runtime_length_ms' "$file")
  flatten "$file" | awk -F, -v rt="$runtime" '
    NR==1 { if ($1 != 0) { print "gap-at-start"; exit } prev=$2; next }
    { if ($1 != prev) { printf "discontinuity at %s (prev end %s)\n", $1, prev; exit } prev=$2 }
    END { if (prev != rt) printf "ends at %s, runtime %s\n", prev, rt; else print "tiled" }'
}

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# ---------------------------------------------------------------- fixtures --
cat > "$tmp/flat.json" <<'EOF'
{"content_metadata":{"chapter_info":{"runtime_length_ms":60000,"chapters":[
 {"start_offset_ms":0,"length_ms":1000,"title":"Opening Credits"},
 {"start_offset_ms":1000,"length_ms":4500,"title":"Chapter 1"},
 {"start_offset_ms":5500,"length_ms":54500,"title":"Chapter 2"}]}}}
EOF

# Parent span COVERS its children: parent must be dropped or audio duplicates.
cat > "$tmp/spanning.json" <<'EOF'
{"content_metadata":{"chapter_info":{"runtime_length_ms":60000,"chapters":[
 {"start_offset_ms":0,"length_ms":1000,"title":"Opening Credits"},
 {"start_offset_ms":1000,"length_ms":4500,"title":"Part One","chapters":[
   {"start_offset_ms":1000,"length_ms":2500,"title":"Chapter 1"},
   {"start_offset_ms":3500,"length_ms":2000,"title":"Chapter 2"}]},
 {"start_offset_ms":5500,"length_ms":54500,"title":"Part Two"}]}}}
EOF

# Parent is a short spoken ANNOUNCEMENT: it must be kept or seconds are lost.
cat > "$tmp/announce.json" <<'EOF'
{"content_metadata":{"chapter_info":{"runtime_length_ms":60000,"chapters":[
 {"start_offset_ms":0,"length_ms":1000,"title":"Opening Credits"},
 {"start_offset_ms":1000,"length_ms":500,"title":"Part One","chapters":[
   {"start_offset_ms":1500,"length_ms":2000,"title":"Chapter 1"},
   {"start_offset_ms":3500,"length_ms":2000,"title":"Chapter 2"}]},
 {"start_offset_ms":5500,"length_ms":54500,"title":"Part Two"}]}}}
EOF

# Three levels: work -> part -> chapter, as used by omnibus collections.
cat > "$tmp/deep.json" <<'EOF'
{"content_metadata":{"chapter_info":{"runtime_length_ms":60000,"chapters":[
 {"start_offset_ms":0,"length_ms":1000,"title":"Opening Credits"},
 {"start_offset_ms":1000,"length_ms":500,"title":"A Novel","chapters":[
   {"start_offset_ms":1500,"length_ms":500,"title":"Part One","chapters":[
     {"start_offset_ms":2000,"length_ms":1500,"title":"Chapter 1"},
     {"start_offset_ms":3500,"length_ms":2000,"title":"Chapter 2"}]}]},
 {"start_offset_ms":5500,"length_ms":54500,"title":"Another Novel"}]}}}
EOF

# ------------------------------------------------------------------- tests --
echo "nested chapter flattening"
check "flat file is unchanged (regression)"        "$(flatten "$tmp/flat.json" | wc -l)" "3"
check "flat file tiles the runtime"                "$(coverage "$tmp/flat.json")" "tiled"

check "spanning parent is dropped, not duplicated" "$(flatten "$tmp/spanning.json" | wc -l)" "4"
check "spanning parent tiles the runtime"          "$(coverage "$tmp/spanning.json")" "tiled"
check "spanning parent title absent"               "$(flatten "$tmp/spanning.json" | grep -c 'Part One')" "0"

check "announcement parent is kept"                "$(flatten "$tmp/announce.json" | wc -l)" "5"
check "announcement parent tiles the runtime"      "$(coverage "$tmp/announce.json")" "tiled"
check "announcement parent title present"          "$(flatten "$tmp/announce.json" | grep -c 'Part One')" "1"

check "three-level nesting is fully descended"     "$(flatten "$tmp/deep.json" | wc -l)" "6"
check "three-level nesting tiles the runtime"      "$(coverage "$tmp/deep.json")" "tiled"

echo
echo "regression: the pre-fix filter loses audio (proves the fixtures are meaningful)"
old=$(jq -r '.content_metadata.chapter_info.chapters[]
      | "\(.start_offset_ms),\(.start_offset_ms + .length_ms),\(.title)"' "$tmp/announce.json" | wc -l)
check "unpatched filter emits only top-level nodes" "$old" "3"

echo
echo "cover lookup regex escaping"
covdir=$(mktemp -d)
title='Collection - Volume One: 20+ Stories'
touch "$covdir/${title}_(1215).jpg"
raw=$(find "$covdir" -maxdepth 1 -regex ".*/${title}_([0-9]+)\.jpg" | wc -l)
esc=$(printf '%s' "$title" | sed 's/[][\\.*^$+?(){}|]/\\&/g')
fix=$(find "$covdir" -maxdepth 1 -regex ".*/${esc}_([0-9]+)\.jpg" | wc -l)
plain='Mostly Harmless'
touch "$covdir/${plain}_(1215).jpg"
pesc=$(printf '%s' "$plain" | sed 's/[][\\.*^$+?(){}|]/\\&/g')
reg=$(find "$covdir" -maxdepth 1 -regex ".*/${pesc}_([0-9]+)\.jpg" | wc -l)
rm -rf "$covdir"
check "unescaped title fails to match (the bug)"   "$raw" "0"
check "escaped title matches"                      "$fix" "1"
check "plain title still matches (regression)"     "$reg" "1"

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
