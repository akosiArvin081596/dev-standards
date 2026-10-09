#!/usr/bin/env bash
# test-guard.sh: fail on deleted tests or added skip/focus markers; flag changed assertions.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
CI_SELF_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common.sh
. "$CI_SELF_DIR/common.sh"

usage() {
  cat <<'USAGE'
Usage: test-guard.sh --base <sha> [--head <sha>] [--pr <number> --label]

Run in the ci working directory, inside the git checkout. Compares <base>...<head>
(default head: HEAD; env BASE_SHA, HEAD_SHA, PR_NUMBER work too) for files under
the current directory that match config/test-globs.txt, and:
  - fails when a test file is deleted, or renamed out of the test paths
  - fails when an added line in a test file matches config/test-markers.txt
    (skip/focus markers), unless the identical line was removed in that file
  - reports tests_changed=true when a removed line of an existing test file
    matches config/assertion-patterns.txt and wasn't re-added unchanged
With --label and a PR number, adds the tests-changed label (a read-only token
only prints a notice). Step outputs: tests_changed=true|false, violations=<n>.
Exit 0, 1 on a violation, 2 on usage error, 5 outside a git repo.
USAGE
}

base="${BASE_SHA:-}"
head="${HEAD_SHA:-HEAD}"
pr="${PR_NUMBER:-}"
label=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --base) [ "$#" -ge 2 ] || ci_usage_error "--base needs a value"; base="$2"; shift 2 ;;
    --head) [ "$#" -ge 2 ] || ci_usage_error "--head needs a value"; head="$2"; shift 2 ;;
    --pr) [ "$#" -ge 2 ] || ci_usage_error "--pr needs a value"; pr="$2"; shift 2 ;;
    --label) label=1; shift ;;
    *) ci_usage_error "unknown argument: $1" ;;
  esac
done
[ -n "$base" ] || ci_usage_error "missing --base (or BASE_SHA)"
[ -z "$head" ] && head=HEAD
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || ci_die "$CI_EXIT_PREREQ" "not inside a git checkout: $(pwd)"
git rev-parse --verify --quiet "$base^{commit}" >/dev/null || ci_die "$CI_EXIT_PREREQ" "base commit not found: $base (fetch-depth 0?)"
git rev-parse --verify --quiet "$head^{commit}" >/dev/null || ci_die "$CI_EXIT_PREREQ" "head commit not found: $head"

tmp=$(ci_mktemp_dir)
trap 'rm -rf "${tmp:?}"' EXIT

globs=()
while IFS= read -r g; do globs+=("$g"); done <<EOF
$(ci_list "$CI_CONFIG_DIR/test-globs.txt")
EOF
ci_globs_regex_file "$tmp/test.re" ${globs[@]+"${globs[@]}"}
ci_patterns_file "$CI_CONFIG_DIR/test-markers.txt" "$tmp/markers.re"
ci_patterns_file "$CI_CONFIG_DIR/assertion-patterns.txt" "$tmp/assert.re"

is_test() { printf '%s\n' "$1" | grep -Eq -f "$tmp/test.re"; }

violations=0
changed_files=""
violation() {
  violations=$((violations + 1))
  ci_error "$1"
  ci_summary "- :x: $1"
}

# check_markers <path...> : added skip/focus markers (diff limited to the given paths)
check_markers() {
  local shown="${*: -1}"
  git diff --no-color --no-ext-diff -M -U0 "$base...$head" -- "$@" \
    | awk '/^\+\+\+ /{next} /^\+/{print substr($0, 2)}' > "$tmp/added"
  git diff --no-color --no-ext-diff -M -U0 "$base...$head" -- "$@" \
    | awk '/^--- /{next} /^-/{print substr($0, 2)}' > "$tmp/removed"
  grep -E -f "$tmp/markers.re" "$tmp/added" > "$tmp/added_m" || true
  grep -E -f "$tmp/markers.re" "$tmp/removed" > "$tmp/removed_m" || true
  ci_unmatched_lines "$tmp/added_m" "$tmp/removed_m" > "$tmp/new_m"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    violation "skip/focus marker added in $shown: $(ci_cut "$(ci_trim "$line")" 120)"
  done < "$tmp/new_m"
}

# check_assertions <path...> : removed assertion lines that weren't re-added unchanged
check_assertions() {
  local shown="${*: -1}"
  git diff --no-color --no-ext-diff -M -U0 "$base...$head" -- "$@" \
    | awk '/^\+\+\+ /{next} /^\+/{print substr($0, 2)}' > "$tmp/added"
  git diff --no-color --no-ext-diff -M -U0 "$base...$head" -- "$@" \
    | awk '/^--- /{next} /^-/{print substr($0, 2)}' > "$tmp/removed"
  grep -E -f "$tmp/assert.re" "$tmp/removed" > "$tmp/removed_a" || true
  ci_unmatched_lines "$tmp/removed_a" "$tmp/added" > "$tmp/changed_a"
  if [ -s "$tmp/changed_a" ]; then
    changed_files="${changed_files:+$changed_files, }$shown"
  fi
}

git diff -z --no-color --no-ext-diff --relative --name-status -M "$base...$head" > "$tmp/status"
n_test=0
while IFS= read -r -d '' status; do
  case "$status" in
    R*|C*)
      IFS= read -r -d '' old
      IFS= read -r -d '' new
      if is_test "$old" && ! is_test "$new" && [ "${status#C}" = "$status" ]; then
        violation "test file moved out of the test paths: $old -> $new"
      elif is_test "$new"; then
        n_test=$((n_test + 1))
        check_markers "$old" "$new"
        [ "${status#C}" = "$status" ] && check_assertions "$old" "$new"
      fi
      ;;
    D)
      IFS= read -r -d '' path
      if is_test "$path"; then violation "test file deleted: $path"; fi
      ;;
    A)
      IFS= read -r -d '' path
      if is_test "$path"; then n_test=$((n_test + 1)); check_markers "$path"; fi
      ;;
    *)
      IFS= read -r -d '' path
      if is_test "$path"; then
        n_test=$((n_test + 1))
        check_markers "$path"
        check_assertions "$path"
      fi
      ;;
  esac
done < "$tmp/status"

ci_info "checked $n_test changed test file(s) in $(pwd)"
if [ -n "$changed_files" ]; then
  ci_output tests_changed true
  ci_notice "assertions changed in: $changed_files. The reviewer must confirm each change is a correction, not a weaker test (label tests-changed)."
  ci_summary "- :warning: assertions changed in: $changed_files (tests-changed)"
  if [ "$label" = 1 ]; then
    if [ -n "$pr" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
      ci_add_label "$pr" tests-changed || true
    else
      ci_notice "no PR number or repository: tests-changed label not added"
    fi
  fi
else
  ci_output tests_changed false
fi
ci_output violations "$violations"

if [ "$violations" -gt 0 ]; then
  ci_error "test guard: $violations violation(s). Never delete tests or add skip/focus markers to make a change pass."
  exit 1
fi
ci_info "ok: no deleted tests, no added skip/focus markers"
