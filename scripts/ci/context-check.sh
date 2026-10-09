#!/usr/bin/env bash
# context-check.sh: keep CLAUDE.md and rules lean, real, and the managed files pinned.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
CI_SELF_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common.sh
. "$CI_SELF_DIR/common.sh"

usage() {
  cat <<'USAGE'
Usage: context-check.sh [--root DIR] [--allow-unreleased-lock] [--tags-from FILE]
                        [--standards-dir DIR]
       context-check.sh --standards-self [--root DIR]

Project mode (default; run in the project root or pass --root):
  - CLAUDE.md exists, has at most 150 lines and no @ imports
  - each .claude/rules/**/*.md has at most 80 lines; .claude/rules/team/*.md at most 60
  - everything that loads in every session (CLAUDE.md + rules without `paths:`
    frontmatter) has at most 250 lines in total
  - every file path in backticks in those files exists (checked relative to the
    project root, the file's folder, or a folder named earlier in the same file;
    skipped: skill names (/team:...), home-relative (~/...) and absolute paths,
    gitignored and local-only paths (.team/, .env, .claude/worktrees/), <...>
    placeholders, globs, and words like origin/main or owner/repo whose first
    part isn't a folder)
  - .claude/team-standards.lock pins every managed file: each listed file exists
    with the listed sha256, and no unlisted file sits in .claude/rules/team/
  - the lock's release is a tag in its standards repo (git ls-remote, or the tag
    names in --tags-from FILE); a newer vX.Y.Z only adds a notice
  - --allow-unreleased-lock (dev-standards' own fixture only): release
    "unreleased" passes when the lock lists exactly the files of the standards
    checkout's managed/ (--standards-dir, default TEAM_STANDARDS_DIR) with their hashes

--standards-self (the dev-standards repo root): the same size, import and path
checks for its own CLAUDE.md and rules, and .claude/rules/team/ must be identical
to managed/.claude/rules/team/. No lock check. Paths inside the team rule are
project paths, so they're checked in projects, not here.

Exit 0 when every check passes, 1 when one fails, 2 on usage error.
USAGE
}

root="."
standards_self=0
allow_unreleased=0
tags_from=""
standards_dir="$TEAM_STANDARDS_DIR"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --root) [ "$#" -ge 2 ] || ci_usage_error "--root needs a value"; root="$2"; shift 2 ;;
    --standards-self) standards_self=1; shift ;;
    --allow-unreleased-lock) allow_unreleased=1; shift ;;
    --tags-from) [ "$#" -ge 2 ] || ci_usage_error "--tags-from needs a value"; tags_from="$2"; shift 2 ;;
    --standards-dir) [ "$#" -ge 2 ] || ci_usage_error "--standards-dir needs a value"; standards_dir="$2"; shift 2 ;;
    *) ci_usage_error "unknown argument: $1" ;;
  esac
done
[ -d "$root" ] || ci_usage_error "no such folder: $root"
root=$(cd "$root" && pwd)
ci_require_cmd jq awk

MAX_CLAUDE=150
MAX_RULE=80
MAX_TEAM_RULE=60
MAX_ALWAYS=250

tmp=$(ci_mktemp_dir)
trap 'rm -rf "${tmp:?}"' EXIT

fails=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() {
  fails=$((fails + 1))
  printf 'FAIL  %s\n' "$1"
  ci_error "$1"
  ci_summary "- :x: $1"
}

in_git=0
git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 && in_git=1

count_lines() { awk 'END { print NR }' "$1"; }

# has_paths_frontmatter <file> : 0 when the file opens with --- frontmatter holding `paths:`
has_paths_frontmatter() {
  awk '
    NR == 1 { if ($0 !~ /^---[ \t\r]*$/) exit 1; next }
    /^---[ \t\r]*$/ { exit found ? 0 : 1 }
    /^paths[ \t]*:/ { found = 1 }
    END { if (NR <= 1) exit 1 }
  ' "$1"
}

# rel <abs-path> : path relative to the root, for messages
rel() { printf '%s' "${1#"$root"/}"; }

# --- the context files -------------------------------------------------------
claude="$root/CLAUDE.md"
rules_list="$tmp/rules"
if [ -d "$root/.claude/rules" ]; then
  find "$root/.claude/rules" -type f -name '*.md' | LC_ALL=C sort > "$rules_list"
else
  : > "$rules_list"
fi

always_total=0
if [ -f "$claude" ]; then
  n=$(count_lines "$claude")
  always_total=$n
  if [ "$n" -le "$MAX_CLAUDE" ]; then pass "CLAUDE.md has $n lines (max $MAX_CLAUDE)"
  else fail "CLAUDE.md has $n lines (max $MAX_CLAUDE): move procedures to skills and reference material to docs/"; fi
else
  fail "CLAUDE.md is missing in $(rel "$root")"
fi

while IFS= read -r f; do
  [ -n "$f" ] || continue
  n=$(count_lines "$f")
  case "$f" in
    "$root/.claude/rules/team/"*) max=$MAX_TEAM_RULE ;;
    *) max=$MAX_RULE ;;
  esac
  if [ "$n" -le "$max" ]; then pass "$(rel "$f") has $n lines (max $max)"
  else fail "$(rel "$f") has $n lines (max $max)"; fi
  if ! has_paths_frontmatter "$f"; then always_total=$((always_total + n)); fi
done < "$rules_list"

if [ "$always_total" -le "$MAX_ALWAYS" ]; then pass "always-loaded context is $always_total lines (max $MAX_ALWAYS)"
else fail "always-loaded context (CLAUDE.md + rules without paths: frontmatter) is $always_total lines (max $MAX_ALWAYS)"; fi

# --- no @ imports in CLAUDE.md (outside code spans and fenced blocks) ---------
if [ -f "$claude" ]; then
  awk '
    /^[ \t]*(```|~~~)/ { fence = !fence; next }
    fence { next }
    {
      line = $0
      gsub(/`[^`]*`/, "", line)
      if (match(line, /(^|[[:space:]([])@[A-Za-z0-9_~.\/-]/)) printf "%d: %s\n", NR, $0
    }
  ' "$claude" > "$tmp/imports"
  if [ -s "$tmp/imports" ]; then
    while IFS= read -r l; do fail "CLAUDE.md:$(ci_cut "$l" 120) is an @ import: mention the file as a plain backtick path instead"; done < "$tmp/imports"
  else
    pass "CLAUDE.md has no @ imports"
  fi
fi

# --- every backtick path exists ------------------------------------------------
# extract_spans <file> : "<line>\t<token>" for each inline code span, in order,
# outside fenced blocks, HTML comments and the frontmatter
extract_spans() {
  awk '
    NR == 1 && /^---[ \t\r]*$/ { front = 1; next }
    front { if (/^---[ \t\r]*$/) front = 0; next }
    /^[ \t]*(```|~~~)/ { fence = !fence; next }
    fence { next }
    {
      line = $0
      if (comment) { if (index(line, "-->") == 0) next; line = substr(line, index(line, "-->") + 3); comment = 0 }
      while (index(line, "<!--") > 0) {
        start = index(line, "<!--"); rest = substr(line, start + 4)
        if (index(rest, "-->") > 0) line = substr(line, 1, start - 1) substr(rest, index(rest, "-->") + 3)
        else { line = substr(line, 1, start - 1); comment = 1 }
      }
      while (match(line, /`[^`]+`/)) {
        printf "%d\t%s\n", NR, substr(line, RSTART + 1, RLENGTH - 2)
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' "$1"
}

# path_like <token> : 0 when the token should name a repo file or folder
path_like() {
  local t="$1"
  case "$t" in
    */*) ;;
    *) return 1 ;;
  esac
  case "$t" in
    *[[:space:]]*|*'*'*|*'?'*|*'['*|*']'*|*'{'*|*'}'*|*'<'*|*'>'*|*'$'*|*'|'*) return 1 ;;
    *'('*|*')'*|*'"'*|*"'"*|*'='*|*','*|*';'*|*':'*|*'@'*|*'#'*|*'%'*|*'!'*|*'&'*|*'^'*|*\\*) return 1 ;;
    '~'*|/*|-*|.) return 1 ;;
  esac
  # local-only paths that are never committed (gitignored in every pack repo)
  case "$t" in
    .team|.team/*|.env|.env.*|*/.env|*/.env.*|.claude/worktrees|.claude/worktrees/*|.claude/settings.local.json|*/settings.local.json|.team-standards|.team-standards/*) return 1 ;;
  esac
  return 0
}

# resolve <token> <file-dir> <bases...> : prints the existing absolute path, or fails.
# Bases are the folders named earlier in the same file (repo maps list sub-folders).
resolve() {
  local t="$1" fdir="$2" b p want_dir=0
  shift 2
  case "$t" in */) want_dir=1 ;; esac
  p="${t%/}"
  for b in "$root" "$fdir" "$@"; do
    [ -n "$b" ] || continue
    if [ "$want_dir" = 1 ]; then
      [ -d "$b/$p" ] && { printf '%s' "$b/$p"; return 0; }
    else
      [ -e "$b/$p" ] && { printf '%s' "$b/$p"; return 0; }
    fi
  done
  return 1
}

# worth_checking <token> <file-dir> <bases...> : a trailing /, a dotted last segment,
# or a first segment that exists makes it a path (origin/main, owner/repo are not)
worth_checking() {
  local t="$1" fdir="$2" first last b
  shift 2
  case "$t" in */) return 0 ;; esac
  last="${t##*/}"
  case "$last" in *.[A-Za-z]*) return 0 ;; esac
  first="${t%%/*}"
  [ -n "$first" ] || return 1
  for b in "$root" "$fdir" "$@"; do
    [ -n "$b" ] || continue
    [ -e "$b/$first" ] && return 0
  done
  return 1
}

ignored() {
  [ "$in_git" = 1 ] || return 1
  git -C "$root" check-ignore -q -- "${1%/}" 2>/dev/null
}

check_paths() {
  local f="$1" fdir lineno tok found
  local bases=()
  fdir=$(cd "$(dirname "$f")" && pwd)
  extract_spans "$f" > "$tmp/spans"
  : > "$tmp/missing"
  while IFS="$(printf '\t')" read -r lineno tok; do
    path_like "$tok" || continue
    worth_checking "$tok" "$fdir" ${bases[@]+"${bases[@]}"} || continue
    if found=$(resolve "$tok" "$fdir" ${bases[@]+"${bases[@]}"}); then
      if [ -d "$found" ]; then bases+=("$found"); fi
      continue
    fi
    ignored "$tok" && continue
    printf '%s:%s: %s\n' "$(rel "$f")" "$lineno" "\`$tok\`" >> "$tmp/missing"
  done < "$tmp/spans"
  if [ -s "$tmp/missing" ]; then
    while IFS= read -r m; do fail "path not found: $m (fix the path, or drop the backticks if it isn't a file)"; done < "$tmp/missing"
  else
    pass "every backtick path in $(rel "$f") exists"
  fi
}

[ -f "$claude" ] && check_paths "$claude"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if [ "$standards_self" = 1 ]; then
    case "$f" in "$root/.claude/rules/team/"*) continue ;; esac
  fi
  check_paths "$f"
done < "$rules_list"

# --- standards-self: the repo's own team rule is the managed one ----------------
if [ "$standards_self" = 1 ]; then
  src="$root/managed/.claude/rules/team"
  dst="$root/.claude/rules/team"
  if [ ! -d "$src" ]; then
    fail "managed/.claude/rules/team/ is missing"
  else
    (cd "$src" && find . -type f | LC_ALL=C sort) > "$tmp/src_files"
    if [ -d "$dst" ]; then (cd "$dst" && find . -type f | LC_ALL=C sort) > "$tmp/dst_files"; else : > "$tmp/dst_files"; fi
    if ! cmp -s "$tmp/src_files" "$tmp/dst_files"; then
      fail ".claude/rules/team/ must hold exactly the files of managed/.claude/rules/team/ (copy them over)"
    else
      same=1
      while IFS= read -r p; do
        cmp -s "$src/$p" "$dst/$p" || { same=0; fail ".claude/rules/team/${p#./} differs from managed/.claude/rules/team/${p#./}"; }
      done < "$tmp/src_files"
      [ "$same" = 1 ] && pass ".claude/rules/team/ is identical to managed/.claude/rules/team/"
    fi
  fi
  if [ "$fails" -gt 0 ]; then
    ci_error "context check (standards-self): $fails failure(s)"
    exit 1
  fi
  ci_info "ok: context files are lean and real"
  exit 0
fi

# --- the lock ---------------------------------------------------------------
lock="$root/.claude/team-standards.lock"
if [ ! -f "$lock" ]; then
  fail ".claude/team-standards.lock is missing: run team-sync to pin the managed files"
else
  if ! jq -e '
      (.standards_repo | type == "string") and (.release | type == "string")
      and (.files | type == "object")
      and ([.files[] | type == "string" and test("^sha256:[0-9a-f]{64}$")] | all)
    ' "$lock" >/dev/null 2>&1; then
    fail ".claude/team-standards.lock is not valid: {\"standards_repo\",\"release\",\"files\":{path: \"sha256:<hex>\"}}"
  else
    repo=$(jq -r '.standards_repo' "$lock")
    release=$(jq -r '.release' "$lock")
    jq -r '.files | to_entries[] | "\(.key)\t\(.value)"' "$lock" > "$tmp/lock_files"
    bad_files=0
    while IFS="$(printf '\t')" read -r p h; do
      case "/$p/" in
        *'/../'*|*'/./'*|'//'*) fail "lock path is not a plain repo path: $p"; bad_files=$((bad_files + 1)); continue ;;
      esac
      if [ ! -f "$root/$p" ]; then
        fail "managed file missing: $p (run /team:sync-standards)"; bad_files=$((bad_files + 1)); continue
      fi
      actual="sha256:$(ci_sha256 "$root/$p")"
      if [ "$actual" != "$h" ]; then
        fail "managed file changed: $p does not match .claude/team-standards.lock (managed files are never edited in a project; change them in dev-standards)"
        bad_files=$((bad_files + 1))
      fi
    done < "$tmp/lock_files"
    if [ -d "$root/.claude/rules/team" ]; then
      (cd "$root" && find .claude/rules/team -type f | LC_ALL=C sort) > "$tmp/team_files"
      cut -f1 "$tmp/lock_files" | LC_ALL=C sort > "$tmp/lock_paths"
      while IFS= read -r p; do
        if ! grep -Fxq "$p" "$tmp/lock_paths"; then
          fail "$p is in the managed .claude/rules/team/ but not in the lock (project rules go in .claude/rules/project/)"
          bad_files=$((bad_files + 1))
        fi
      done < "$tmp/team_files"
    fi
    [ "$bad_files" = 0 ] && pass "managed files match .claude/team-standards.lock ($(wc -l < "$tmp/lock_files" | tr -d ' ') files)"

    if [ "$release" = "unreleased" ]; then
      if [ "$allow_unreleased" != 1 ]; then
        fail "lock release is 'unreleased': pin a real dev-standards release with team-sync"
      elif [ ! -d "$standards_dir/managed" ]; then
        fail "--allow-unreleased-lock needs the standards checkout's managed/ ($standards_dir/managed)"
      else
        (cd "$standards_dir/managed" && find . -type f | sed 's|^\./||' | LC_ALL=C sort) > "$tmp/managed_paths"
        cut -f1 "$tmp/lock_files" | LC_ALL=C sort > "$tmp/lock_paths"
        drift=0
        if ! cmp -s "$tmp/managed_paths" "$tmp/lock_paths"; then
          fail "the lock doesn't list exactly the files of managed/ (run tests/ci/sync-fixture.sh)"
          drift=1
        fi
        while IFS="$(printf '\t')" read -r p h; do
          [ -f "$standards_dir/managed/$p" ] || continue
          if [ "sha256:$(ci_sha256 "$standards_dir/managed/$p")" != "$h" ]; then
            fail "lock hash for $p differs from managed/$p (run tests/ci/sync-fixture.sh)"
            drift=1
          fi
        done < "$tmp/lock_files"
        [ "$drift" = 0 ] && pass "unreleased lock matches the standards checkout's managed/"
      fi
    else
      case "$repo" in
        */*) ;;
        *) repo="" ;;
      esac
      case "$repo" in *[!A-Za-z0-9_./-]*) repo="" ;; esac
      if [ -z "$repo" ]; then
        fail "lock standards_repo must be owner/name"
      else
        if [ -n "$tags_from" ]; then
          ci_list "$tags_from" > "$tmp/tags" || true
          tags_ok=1
        elif git ls-remote --tags --refs "https://github.com/$repo.git" > "$tmp/ls" 2>/dev/null; then
          sed 's|.*refs/tags/||' "$tmp/ls" > "$tmp/tags"
          tags_ok=1
        else
          tags_ok=0
        fi
        if [ "$tags_ok" != 1 ]; then
          fail "could not list the tags of $repo (git ls-remote); re-run the job"
        elif grep -Fxq "$release" "$tmp/tags"; then
          pass "lock release $release is a tag in $repo"
          newest=""; nmaj=-1; nmin=-1; npat=-1
          re='^v([0-9]+)\.([0-9]+)\.([0-9]+)$'
          while IFS= read -r t; do
            if [[ "$t" =~ $re ]]; then
              a=${BASH_REMATCH[1]}; b=${BASH_REMATCH[2]}; c=${BASH_REMATCH[3]}
              if [ "$a" -gt "$nmaj" ] || { [ "$a" -eq "$nmaj" ] && { [ "$b" -gt "$nmin" ] || { [ "$b" -eq "$nmin" ] && [ "$c" -gt "$npat" ]; }; }; }; then
                newest="$t"; nmaj=$a; nmin=$b; npat=$c
              fi
            fi
          done < "$tmp/tags"
          if [ -n "$newest" ] && [ "$newest" != "$release" ] && [[ "$release" =~ $re ]]; then
            a=${BASH_REMATCH[1]}; b=${BASH_REMATCH[2]}; c=${BASH_REMATCH[3]}
            if [ "$nmaj" -gt "$a" ] || { [ "$nmaj" -eq "$a" ] && { [ "$nmin" -gt "$b" ] || { [ "$nmin" -eq "$b" ] && [ "$npat" -gt "$c" ]; }; }; }; then
              ci_notice "dev-standards $newest is out (this project pins $release): run /team:sync-standards when convenient"
            fi
          fi
        else
          fail "lock release '$release' is not a tag in $repo: pin a real release with team-sync"
        fi
      fi
    fi
  fi
fi

if [ "$fails" -gt 0 ]; then
  ci_error "context check: $fails failure(s)"
  exit 1
fi
ci_info "ok: context files are lean and real, managed files are pinned"
