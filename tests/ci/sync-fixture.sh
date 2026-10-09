#!/usr/bin/env bash
# sync-fixture.sh: copy managed/** into tests/fixture-project and regenerate its lock.
set -euo pipefail
export LC_ALL=C

usage() {
  cat <<'USAGE'
Usage: tests/ci/sync-fixture.sh [--check]

Makes tests/fixture-project carry exact copies of managed/** (same paths, same
file modes), removes copies of files managed/ no longer has (those the old lock
listed), and rewrites tests/fixture-project/.claude/team-standards.lock:
  {"standards_repo": "akosiArvin081596/dev-standards", "release": "unreleased",
   "files": {"<path>": "sha256:<hex>", ...}}
Run it whenever managed/ changes; the self-test's `ci / ci` fails until you do.
--check changes nothing and exits 1 when the fixture is out of sync.
Exit 0, 1 (out of sync with --check, or an error), 2 on usage error.
USAGE
}

check=0
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --check) check=1 ;;
  '') ;;
  *) usage >&2; exit 2 ;;
esac

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SRC="$ROOT/managed"
DST="$ROOT/tests/fixture-project"
LOCK="$DST/.claude/team-standards.lock"
[ -d "$SRC" ] || { echo "sync-fixture.sh: no managed/ folder" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "sync-fixture.sh: jq is required" >&2; exit 5; }

sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }

work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT

(cd "$SRC" && find . -type f ! -name .DS_Store | sed 's|^\./||' | sort) > "$work/paths"
[ -s "$work/paths" ] || { echo "sync-fixture.sh: managed/ has no files yet" >&2; exit 1; }

: > "$work/entries"
while IFS= read -r p; do
  printf '%s\tsha256:%s\n' "$p" "$(sha256 "$SRC/$p")" >> "$work/entries"
done < "$work/paths"
jq -Rn --arg repo "akosiArvin081596/dev-standards" '
  [inputs | split("\t") | {(.[0]): .[1]}] | add // {}
  | {standards_repo: $repo, release: "unreleased", files: .}' < "$work/entries" > "$work/lock"

# Files the old lock listed that managed/ no longer has
: > "$work/stale"
if [ -f "$LOCK" ]; then
  jq -r '.files // {} | keys[]' "$LOCK" 2>/dev/null | while IFS= read -r p; do
    grep -Fxq "$p" "$work/paths" || printf '%s\n' "$p"
  done > "$work/stale"
fi

changes=0
while IFS= read -r p; do
  if [ ! -f "$DST/$p" ] || ! cmp -s "$SRC/$p" "$DST/$p"; then
    changes=$((changes + 1))
    if [ "$check" = 1 ]; then echo "out of sync: $p"; else
      mkdir -p "$(dirname "$DST/$p")"
      cp -p "$SRC/$p" "$DST/$p"
      echo "copied: $p"
    fi
  elif [ -x "$SRC/$p" ] && [ ! -x "$DST/$p" ]; then
    changes=$((changes + 1))
    if [ "$check" = 1 ]; then echo "mode differs: $p"; else chmod +x "$DST/$p"; echo "mode fixed: $p"; fi
  fi
done < "$work/paths"

while IFS= read -r p; do
  [ -n "$p" ] || continue
  case "/$p/" in *'/../'*|*'/./'*|'//'*) echo "sync-fixture.sh: refusing odd lock path: $p" >&2; exit 1 ;; esac
  [ -e "$DST/$p" ] || continue
  changes=$((changes + 1))
  if [ "$check" = 1 ]; then echo "no longer managed: $p"; else rm -f "${DST:?}/$p"; echo "removed: $p"; fi
done < "$work/stale"

if [ ! -f "$LOCK" ] || ! cmp -s "$work/lock" "$LOCK"; then
  changes=$((changes + 1))
  if [ "$check" = 1 ]; then echo "out of sync: .claude/team-standards.lock"; else
    mkdir -p "$(dirname "$LOCK")"
    cp "$work/lock" "$LOCK"
    echo "wrote: .claude/team-standards.lock ($(wc -l < "$work/paths" | tr -d ' ') files)"
  fi
fi

if [ "$check" = 1 ]; then
  [ "$changes" -eq 0 ] && { echo "fixture is in sync with managed/"; exit 0; }
  echo "fixture is out of sync: run tests/ci/sync-fixture.sh"
  exit 1
fi
echo "sync-fixture.sh: $changes change(s)"
