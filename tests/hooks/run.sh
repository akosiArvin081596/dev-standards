#!/bin/bash
# shellcheck source-path=SCRIPTDIR
# tests/hooks/run.sh — table-driven tests for the PreToolUse hook plugins/team/hooks/fence.
#
# Usage: /bin/bash tests/hooks/run.sh [filter]
#   filter: optional substring; only cases whose file name or row text contains it run.
#
# Encodes the SPEC (build-spec "Fences", docs/rules.md §13, fence-interface.md, fence-rules.md),
# not the implementation. Every case only FEEDS hook JSON to the fence; no case command is executed.
# Fixtures, fake HOME and fake TEAM_CONFIG_DIR live in one mktemp -d, removed at exit.
#
# Exit: 0 all pass; 1 any failure; 2 hook missing / setup problem.
set -u
export LC_ALL=C TZ=UTC
REAL_HOME=$HOME   # captured before anything fakes HOME (net-guard refuses the owner's real config)

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
HOOK=${FENCE_HOOK:-"$REPO/plugins/team/hooks/fence"}   # FENCE_HOOK: only for testing this runner
PLUGIN="$REPO/plugins/team"
FILTER=${1:-}

if [ ! -f "$HOOK" ]; then
  echo "run.sh: the fence hook does not exist yet: $HOOK" >&2
  exit 2
fi
for tool in jq git; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "run.sh: '$tool' is required to build fixtures and check output" >&2
    exit 2
  fi
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fence-tests.XXXXXX") || { echo "run.sh: mktemp failed" >&2; exit 2; }
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() { rm -rf "${TMP:?}"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

# Network guard (mandatory in every runner): fake ssh/scp/sftp/rsync/... first on PATH, each
# refusing (exit 255) and logging. Installed before the fixtures are built.
# shellcheck source=../lib/net-guard.sh
. "$REPO/tests/lib/net-guard.sh"
NET_GUARD_REAL_HOME="$REAL_HOME"
net_guard_install "$TMP/net-guard"

# shellcheck source=fixtures.sh
. "$HERE/fixtures.sh"
build_fixtures "$TMP" || { echo "run.sh: building fixtures failed" >&2; exit 2; }
# build_fixtures sets: FX (fixture root), FAKE_HOME, FAKE_CFG, CFG_EMPTY, CFG_NOBYPASS

export TEAM_CONFIG_DIR="$FAKE_CFG"   # the runner's own env too, so net_guard_assert can check it is fake
if ! net_guard_assert; then
  echo "FAIL  net-guard  fakes are not in place; refusing to run any test" >&2
  exit 1
fi
echo "PASS  net-guard                fakes first on PATH ($NET_GUARD_DIR), refusing and logging; fake TEAM_CONFIG_DIR"
NET_GUARD_BASELINE=$(wc -l <"$NET_GUARD_LOG" | tr -d ' ')
# The hook's PATH: the guard dir first, then the interface's /usr/bin:/bin.
HOOK_PATH="$NET_GUARD_DIR:/usr/bin:/bin"

# {ECHO500}: 500 x "echo a && " for the long-command cases
ECHO500=""
i=0
while [ "$i" -lt 500 ]; do ECHO500="${ECHO500}echo a && "; i=$((i + 1)); done

PASS=0
FAIL=0
FAILED_LIST=""
TIMES="$TMP/times.txt"
: >"$TIMES"
OUT="$TMP/out.txt"
ERR="$TMP/err.txt"
RCF="$TMP/rc.txt"
PGF="$TMP/pg.txt"
TF="$TMP/time.txt"
KILLED="$TMP/killed"
CALL_LIMIT=${FENCE_TEST_CALL_LIMIT:-20}   # seconds; above hooks.json's 15 s timeout

# --- helpers -------------------------------------------------------------------------------------

# expand <text>: replace placeholders with fixture paths
expand() {
  local s=$1
  s=${s//"{MAIN}"/"$FX/main-repo"}
  s=${s//"{FEAT}"/"$FX/feat-repo"}
  s=${s//"{STD}"/"$FX/standards-repo"}
  s=${s//"{PROJ}"/"$FX/project"}
  s=${s//"{PLAIN}"/"$FX/plain"}
  s=${s//"{FX}"/"$FX"}
  s=${s//"{HOME}"/"$FAKE_HOME"}
  s=${s//"{CFG}"/"$FAKE_CFG"}
  s=${s//"{CFG_EMPTY}"/"$CFG_EMPTY"}
  s=${s//"{CFG_NOBYPASS}"/"$CFG_NOBYPASS"}
  s=${s//"{PLUGIN}"/"$PLUGIN"}
  s=${s//"{NL}"/$'\n'}
  s=${s//"{TAB}"/$'\t'}
  s=${s//"{EMPTY}"/}
  s=${s//"{ECHO500}"/"$ECHO500"}
  printf '%s' "$s"
}

# build_json <tool> <agent> <cwd> <input> -> stdout
build_json() {
  local tool=$1 agent=$2 cwd=$3 input=$4
  if [ "$tool" = RAW ]; then
    printf '%s' "$input"
    return 0
  fi
  # MCP tools are written as <tool>@<field>, e.g. mcp__playwright__browser_navigate@url
  local field=""
  case "$tool" in *@*) field=${tool#*@}; tool=${tool%%@*} ;; esac
  jq -cn --arg tool "$tool" --arg agent "$agent" --arg cwd "$cwd" --arg in "$input" --arg field "$field" '
    {session_id:"t", hook_event_name:"PreToolUse", permission_mode:"bypassPermissions",
     cwd:$cwd, tool_name:$tool,
     tool_input:(
       if   $field != ""          then {($field): $in}
       elif $tool=="Bash"         then {command:$in, description:"fence test"}
       elif $tool=="Monitor"      then {command:$in, description:"fence test"}
       elif $tool=="Write"        then {file_path:$in, content:"x\n"}
       elif $tool=="Edit"         then {file_path:$in, old_string:"a", new_string:"b"}
       elif $tool=="MultiEdit"    then {file_path:$in, edits:[{old_string:"a", new_string:"b"}]}
       elif $tool=="NotebookEdit" then {notebook_path:$in, new_source:"x"}
       elif $tool=="Read"         then {file_path:$in}
       elif $tool=="Glob"         then {pattern:$in}
       elif $tool=="Grep"         then {pattern:$in}
       elif $tool=="Agent"        then {description:"x", prompt:$in, subagent_type:"general-purpose"}
       elif $tool=="Task"         then {description:"x", prompt:$in, subagent_type:"general-purpose"}
       elif $tool=="WebFetch"     then {url:$in, prompt:"x"}
       else {input:$in} end)}
    + (if $agent=="main" then {} else {agent_id:"a1", agent_type:$agent} end)'
}

# rule_ok <expected-alternatives a|b> <actual>
rule_ok() {
  local alts="|$1|"
  case "$alts" in *"|$2|"*) return 0 ;; esac
  return 1
}

# one_line <file>: first line, trimmed to 160 chars, for messages
one_line() {
  local l=""
  if [ -s "$1" ]; then IFS= read -r l <"$1" || true; fi
  printf '%s' "${l:0:160}"
}

log_lines() {
  if [ -f "$1" ]; then wc -l <"$1" | tr -d ' '; else echo 0; fi
}

# --- one case ------------------------------------------------------------------------------------

run_case() {
  local where=$1 expect=$2 rule=$3 agent=$4 tool=$5 cwdname=$6 input=$7 note=$8 envs=$9
  local cwd json cfg rc got_outcome got_rule reason="" first="" msg="" ok=1 t
  local -a extra
  extra=()

  case "$cwdname" in
    /*) cwd=$cwdname ;;
    *) cwd="$FX/$cwdname" ;;
  esac
  input=$(expand "$input")
  cwd=$(expand "$cwd")
  cfg=$FAKE_CFG
  local delay_case=0 watchdog="" e
  if [ "$envs" != "" ] && [ "$envs" != "-" ]; then
    for e in $envs; do
      e=$(expand "$e")
      case "$e" in
        TEAM_CONFIG_DIR=*) cfg=${e#TEAM_CONFIG_DIR=} ;;
        TEAM_FENCE_WATCHDOG=*) watchdog=${e#TEAM_FENCE_WATCHDOG=}; extra+=("$e") ;;
        TEAM_FENCE_TEST_DELAY=*) delay_case=1; extra+=("$e") ;;
        *) extra+=("$e") ;;
      esac
    done
  fi

  json=$(build_json "$tool" "$agent" "$cwd" "$input") || { json=""; }
  local before after
  before=$(log_lines "$cfg/fence.log")

  rm -f "$OUT" "$ERR" "$RCF" "$PGF" "$TF" "$KILLED"
  # Run the probe as its own job (own process group) so leftovers can be found by pgid.
  TIMEFORMAT=%3R
  {
    time (
      set -m
      {
        printf '%s' "$json" | env -i PATH="$HOOK_PATH" HOME="$FAKE_HOME" TEAM_CONFIG_DIR="$cfg" \
          CLAUDE_PLUGIN_ROOT="$PLUGIN" ${extra[@]+"${extra[@]}"} /bin/bash "$HOOK" >"$OUT" 2>"$ERR"
        echo $? >"$RCF"
      } &
      pg=$!
      echo "$pg" >"$PGF"
      # Outer limit: if the hook outlives CALL_LIMIT, kill only this probe's own process group.
      ( sleep "$CALL_LIMIT"; : >"$KILLED"; kill -9 -- "-$pg" ) </dev/null >/dev/null 2>&1 &
      w=$!
      wait "$pg"
      kill -- "-$w" 2>/dev/null
      wait "$w" 2>/dev/null
    )
  } 2>"$TF"
  t=$(tr -d ' \n' <"$TF")
  rc=$(cat "$RCF" 2>/dev/null || echo "?")
  if [ -f "$KILLED" ]; then
    rc=killed
    rm -f "$KILLED"
  fi

  # classify
  got_outcome=other
  got_rule=-
  if [ "$rc" = 0 ] && [ ! -s "$OUT" ]; then
    got_outcome=allow
  elif [ "$rc" = 0 ]; then
    if jq -e '.hookSpecificOutput.hookEventName=="PreToolUse" and .hookSpecificOutput.permissionDecision=="deny"' "$OUT" >/dev/null 2>&1; then
      reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason // ""' "$OUT" 2>/dev/null)
      case "$reason" in
        "[fence:"*"] "*)
          got_rule=${reason#\[fence:}
          got_rule=${got_rule%%]*}
          got_outcome=deny
          ;;
        *) msg="deny reason lacks '[fence:<id>] ' prefix: ${reason:0:120}" ;;
      esac
    else
      msg="exit 0 with stdout that is not a deny decision (allow must print nothing): $(one_line "$OUT")"
    fi
  elif [ "$rc" = 2 ]; then
    first=$(one_line "$ERR")
    case "$first" in
      "[fence:"*"] "*)
        got_rule=${first#\[fence:}
        got_rule=${got_rule%%]*}
        got_outcome=error
        ;;
      *) msg="exit 2 but stderr first line lacks '[fence:<id>] ': $first" ;;
    esac
  elif [ "$rc" = killed ]; then
    msg="hook still running after ${CALL_LIMIT}s, killed (Claude Code would fail open at its 15 s hook timeout)"
  else
    msg="exit $rc (fails open); stderr: $(one_line "$ERR")"
  fi

  # compare ("block" = deny or error-deny, both fail closed)
  local want=$expect
  if [ "$expect" = block ] && { [ "$got_outcome" = deny ] || [ "$got_outcome" = error ]; }; then want=$got_outcome; fi
  if [ "$got_outcome" != "$want" ]; then
    ok=0
    [ -n "$msg" ] || msg="expected $expect${rule:+ $rule}, got $got_outcome $got_rule"
    if [ "$got_outcome" = allow ] && [ "$expect" != allow ]; then msg="$msg (FAILS OPEN)"; fi
    if [ "$got_outcome" = deny ]; then msg="$msg: ${reason:0:110}"; fi
    if [ "$got_outcome" = error ]; then msg="$msg: ${first:0:110}"; fi
  elif [ "$expect" != allow ] && ! rule_ok "$rule" "$got_rule"; then
    ok=0
    msg="expected $expect $rule, got $got_outcome $got_rule"
    if [ "$got_outcome" = deny ]; then msg="$msg: ${reason:0:110}"; else msg="$msg: ${first:0:110}"; fi
  fi
  if [ "$got_outcome" = error ] && [ "$ok" = 1 ]; then
    case "$got_rule" in internal-error|malformed-input|timeout) ;; *) ok=0; msg="error-deny with non-error rule id $got_rule" ;; esac
  fi

  # log check for deny / error-deny
  if [ "$ok" = 1 ] && [ "$got_outcome" != allow ]; then
    after=$(log_lines "$cfg/fence.log")
    if [ "$((after - before))" != 1 ]; then
      ok=0
      msg="expected exactly 1 new fence.log line, got $((after - before))"
    else
      local line ts lrule lagent ltext rest
      line=$(tail -n 1 "$cfg/fence.log")
      ts=${line%%$'\t'*}; rest=${line#*$'\t'}
      lrule=${rest%%$'\t'*}; rest=${rest#*$'\t'}
      lagent=${rest%%$'\t'*}; ltext=${rest#*$'\t'}
      if ! printf '%s' "$ts" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+]00:?00)$'; then
        ok=0; msg="fence.log timestamp not UTC ISO-8601: ${ts:0:40}"
      elif [ "$lrule" != "$got_rule" ]; then
        ok=0; msg="fence.log rule '$lrule' != reported '$got_rule'"
      elif [ "$tool" != RAW ] && [ "$lagent" != "$agent" ]; then
        ok=0; msg="fence.log agent '$lagent' != '$agent'"
      elif [ "${#ltext}" -gt 300 ]; then
        ok=0; msg="fence.log text longer than 300 chars (${#ltext})"
      elif printf '%s' "$line" | grep -Eq 's3cr3t|gh[opusr]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{16,}'; then
        ok=0; msg="fence.log leaks secret text: ${line:0:160}"
      fi
    fi
  fi

  # watchdog / orphan checks for delay cases
  if [ "$delay_case" = 1 ]; then
    if [ -n "$watchdog" ]; then
      local limit=$((watchdog + 1))
      if ! awk -v t="$t" -v l="$limit" 'BEGIN{exit !(t<=l)}'; then
        ok=0; msg="${msg:+$msg; }took ${t}s, limit WATCHDOG+1=${limit}s"
      fi
    fi
    sleep 0.3
    local pg left
    pg=$(cat "$PGF" 2>/dev/null || echo "")
    if [ -n "$pg" ]; then
      left=$(ps -A -o pid=,pgid=,command= | awk -v g="$pg" '$2==g {print $1" "$3" "$4}' | tr '\n' ';')
      if [ -n "$left" ]; then
        ok=0; msg="${msg:+$msg; }processes left behind in the hook's process group: $left"
      fi
    fi
  else
    echo "$t" >>"$TIMES"
  fi

  if [ "$ok" = 1 ]; then
    PASS=$((PASS + 1))
    printf 'PASS  %-24s %-5s %-20s %s\n' "$where" "$expect" "$rule" "$note"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL  %-24s %-5s %-20s %s\n      -> %s\n' "$where" "$expect" "$rule" "$note" "$msg"
    FAILED_LIST="$FAILED_LIST$where $expect $rule :: $note :: $msg"$'\n'
  fi
  if [ -n "${FENCE_TEST_SHOW_TIME:-}" ]; then echo "      time: ${t}s"; fi
  return 0
}

# --- main loop -----------------------------------------------------------------------------------

total_rows=0
for file in "$HERE"/cases/*.tsv; do
  [ -f "$file" ] || continue
  base=${file##*/}
  n=0
  while IFS= read -r row || [ -n "$row" ]; do
    n=$((n + 1))
    case "$row" in ''|'#'*) continue ;; esac
    if [ -n "$FILTER" ]; then
      case "$base $row" in *"$FILTER"*) ;; *) continue ;; esac
    fi
    IFS=$'\t' read -r c_expect c_rule c_agent c_tool c_cwd c_input c_note c_env <<EOF_ROW
$row
EOF_ROW
    if [ -z "${c_note:-}" ]; then
      echo "BAD ROW $base:$n (need 7 tab-separated fields): $row" >&2
      FAIL=$((FAIL + 1))
      FAILED_LIST="$FAILED_LIST$base:$n malformed row"$'\n'
      continue
    fi
    case "$c_expect" in allow|deny|error|block) ;; *)
      echo "BAD ROW $base:$n (expect must be allow|deny|error|block): $row" >&2
      FAIL=$((FAIL + 1)); FAILED_LIST="$FAILED_LIST$base:$n malformed row"$'\n'; continue ;;
    esac
    total_rows=$((total_rows + 1))
    run_case "$base:$n" "$c_expect" "$c_rule" "$c_agent" "$c_tool" "$c_cwd" "$c_input" "$c_note" "${c_env:-}"
  done <"$file"
done

# Coverage: every rule id needs at least one allowed and one denied case (unfiltered runs only).
# For allow rows the rule column names the rule the case exercises; for the rest it lists the ids.
RULE_IDS="push-main push-release-branch force-push push-tags tag-write release-write skip-hooks hooks-path git-config merge-admin merge-no-auto owner-approved gh-write gh-api-write gh-credential curl-github-write credential-read workflow-edit fence-file prod-action nested-claude ssh-dest ssh-form disguised script-scan agent-bash agent-tool post-check-agent internal-error malformed-input timeout"
if [ -z "$FILTER" ]; then
  echo
  echo "Coverage (cases per rule id: allowed / denied):"
  cov_line=""
  for rid in $RULE_IDS; do
    counts=$(cat "$HERE"/cases/*.tsv | awk -F'\t' -v r="$rid" '
      /^#/ || NF < 7 { next }
      { n = split($2, a, "|"); hit = 0; for (i = 1; i <= n; i++) if (a[i] == r) hit = 1
        if (!hit) next
        if ($1 == "allow") al++; else de++ }
      END { printf "%d %d", al, de }')
    al=${counts% *}; de=${counts#* }
    cov_line="$cov_line$(printf '  %-20s %3s / %-4s' "$rid" "$al" "$de")"
    if [ "$al" = 0 ] || [ "$de" = 0 ]; then
      FAIL=$((FAIL + 1))
      FAILED_LIST="${FAILED_LIST}coverage :: rule $rid has $al allowed and $de denied cases"$'\n'
      cov_line="$cov_line  <- MISSING"
    fi
    cov_line="$cov_line"$'\n'
  done
  printf '%s' "$cov_line"
fi

# The hook must never run a network tool: any call beyond the guard's self-test is a failure.
net_calls=$(wc -l <"$NET_GUARD_LOG" | tr -d ' ')
if [ "$net_calls" -gt "$NET_GUARD_BASELINE" ]; then
  FAIL=$((FAIL + 1))
  echo "FAIL  net-guard  the hook ran $((net_calls - NET_GUARD_BASELINE)) network tool call(s):"
  tail -n "$((net_calls - NET_GUARD_BASELINE))" "$NET_GUARD_LOG" | sed 's/^/      /'
  FAILED_LIST="${FAILED_LIST}net-guard :: network tool called during the run"$'\n'
else
  echo "PASS  net-guard                no network tool was called during the run"
fi

echo
echo "== fence tests: $PASS passed, $FAIL failed, $total_rows cases =="
if [ -s "$TIMES" ]; then
  sort -n "$TIMES" | awk '{a[NR]=$1} END{
    if (NR%2) m=a[(NR+1)/2]; else m=(a[NR/2]+a[NR/2+1])/2;
    printf "timing per call (excluding delay/watchdog cases, n=%d): median %.3fs, worst %.3fs\n", NR, m, a[NR]}'
fi
if [ "$FAIL" -gt 0 ]; then
  echo
  echo "Failures:"
  printf '%s' "$FAILED_LIST"
  exit 1
fi
exit 0
