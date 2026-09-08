#!/usr/bin/env bash
# Drive a long-lived interactive codex session in the split (right) pane of THIS agterm session.
#
#   codex-pane.sh ensure [repo_dir]   -> start codex in the split pane unless it is already there
#   codex-pane.sh ask <prompt-file>   -> send one round, BLOCK until the turn ends, print the answer
#   codex-pane.sh status              -> reused | absent
#
# The answer is read from codex's own rollout journal, not scraped off the pane. A finished turn
# appends {"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"..."}} to
# ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl, and last_agent_message holds the complete reply.
# The pane collapses long tool transcripts to "… +N lines (ctrl + t to view transcript)"; the
# journal does not, so nothing is lost and no sentinel is needed.
#
# `ask` BLOCKS until the turn ends. Run it once in the background and let it wake you when it
# exits. Never poll it from the model side - a check every N seconds costs a model call every N
# seconds, while this loop costs nothing at all.
#
# Exit codes: 0 answer printed | 2 timeout | 3 turn aborted | 4 codex is blocked on a human
#             5 the prompt was typed but codex never started the turn
#
# Environment:
#   CODEX_PANE_MODEL    model passed to codex (default gpt-6-astra)
#   CODEX_PANE_EFFORT   reasoning effort (default medium)
#   CODEX_PANE_TIMEOUT  seconds to wait for one round (default 1800)
#
set -uo pipefail

: "${AGTERM_SESSION_ID:?not running inside an agterm session}"
TARGET="$AGTERM_SESSION_ID"
PANE=right
MODEL="${CODEX_PANE_MODEL:-gpt-6-astra}"
EFFORT="${CODEX_PANE_EFFORT:-medium}"
TIMEOUT="${CODEX_PANE_TIMEOUT:-1800}"
SESSIONS="$HOME/.codex/sessions"
STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/codex-pane"

# codex prompts a human for these; nothing in this script can answer them
BLOCKED_RE='Would you like to run the following command|Would you like to make the following edits|Would you like to grant these permissions|Action required'

node_field() {
  agtermctl tree --json | python3 -c '
import json,sys,os
t=json.load(sys.stdin)["result"]["tree"]
sid=os.environ["AGTERM_SESSION_ID"]; key=sys.argv[1]
def walk(n):
    for s in n.get("sessions",[]) or []:
        if s["id"]==sid: print(s.get(key) or ""); return True
    for w in n.get("workspaces",[]) or []:
        if walk(w): return True
    return False
walk(t) or print("")
' "$1"
}

screen()    { agtermctl session text --pane "$PANE" --target "$TARGET"; }
buffer()    { agtermctl session text --pane "$PANE" --target "$TARGET" --all; }
has_codex() { node_field splitForeground | grep -q codex; }

# Busy/idle from the transcript area, not the status line: [tui] status_line is user-configurable
# and its run-state component (the one that printed "Ready"/"Working") is often turned off.
is_busy()      { screen | grep -q 'esc to interrupt'; }
has_composer() { screen | grep -q 'Ask Codex to do anything'; }
is_idle()      { ! is_busy && has_composer; }

# A real approval prompt is a live selector at the bottom of the screen, so match only the last few
# rows AND require the numbered choice list. Matching the phrases alone anywhere on screen is a
# false positive waiting to happen: codex's own answers quote them (a round that explained these
# very prompts tripped exactly that).
is_blocked() {
  local t; t=$(screen | tail -15)
  grep -qE "$BLOCKED_RE" <<<"$t" && grep -qE '^[[:space:]]*[›>]?[[:space:]]*[0-9]+\.' <<<"$t"
}

submit() {  # type one line, then Enter as a separate injection
  agtermctl session type --pane "$PANE" --target "$TARGET" "$1" >/dev/null
  sleep 2
  printf '\n' | agtermctl session type --pane "$PANE" --target "$TARGET" --stdin >/dev/null
}

# `agtermctl session type` returns ok once the keystrokes are injected, which says nothing about
# whether codex accepted them: the Enter can land before the typed line is in the composer, leaving
# the prompt sitting there unsubmitted. Waiting on a pane where nothing is running then burns the
# whole timeout. Confirm the turn actually started, and re-send Enter once if it did not.
submit_verified() {
  local roll="$2" base="$3" n
  submit "$1"
  for n in 1 2 3 4 5; do
    is_busy && return 0
    [ -f "$roll" ] && [ "$(count_event "$roll" task_complete)" -gt "$base" ] && return 0
    [ "$n" = 3 ] && printf '\n' | agtermctl session type --pane "$PANE" --target "$TARGET" --stdin >/dev/null
    sleep 2
  done
  is_busy && return 0
  echo "codex never started the turn - the prompt was typed but not submitted. Last 10 lines:" >&2
  screen | tail -10 >&2
  return 5
}

state_file() { echo "$STATE_DIR/${TARGET}.$1"; }

# Newest rollout journal whose session_meta cwd matches the repo AND whose session started at or
# after $2 (the moment this pane's codex was launched). The epoch filter is what keeps a previous
# codex in the same directory - one the user just quit - from being mistaken for the live one.
find_rollout() {
  python3 - "$SESSIONS" "$1" "$2" <<'PY'
import json,os,sys,glob,datetime
sessions,repo,since=sys.argv[1],os.path.realpath(os.path.expanduser(sys.argv[2])),float(sys.argv[3])
best=(0,None)
for p in glob.glob(os.path.join(sessions,"*","*","*","rollout-*.jsonl")):
    try:
        st=os.stat(p)
        if st.st_mtime < best[0]: continue
        with open(p) as fh: meta=json.loads(fh.readline())
        if meta.get("type")!="session_meta": continue
        pay=meta.get("payload",{})
        # only the pane's own interactive session: `codex exec` runs and auto-review's reviewer
        # thread write their own journals, and one of those would never log a task_complete we care about
        if pay.get("originator")!="codex-tui": continue
        cwd=pay.get("cwd","")
        if not cwd or os.path.realpath(cwd)!=repo: continue
        ts=pay.get("timestamp","")
        started=datetime.datetime.fromisoformat(ts.replace("Z","+00:00")).timestamp() if ts else st.st_mtime
        if started + 5 < since: continue
        best=(st.st_mtime,p)
    except Exception: continue
print(best[1] or "")
PY
}

# Diagnostic for a timeout: what cwd does the newest live codex-tui journal actually claim? If it
# differs from the recorded repo, find_rollout was filtering out the journal that held the answer.
newest_tui_cwd() {
  python3 - "$SESSIONS" <<'PY'
import json,os,sys,glob
best=(0,None,None)
for p in glob.glob(os.path.join(sys.argv[1],"*","*","*","rollout-*.jsonl")):
    try:
        st=os.stat(p)
        if st.st_mtime < best[0]: continue
        with open(p) as fh: meta=json.loads(fh.readline())
        if meta.get("type")!="session_meta": continue
        pay=meta.get("payload",{})
        if pay.get("originator")!="codex-tui": continue
        best=(st.st_mtime,pay.get("cwd",""),p)
    except Exception: continue
if best[2]: print("%s\t%s" % (best[1], best[2]))
PY
}

# grep -c prints its count AND exits 1 when the count is zero, so `|| echo 0` would print a second
# line and every arithmetic test downstream would fail on "0\n0".
count_event() {
  local c=0
  [ -f "$1" ] && c=$(grep -c "\"type\":\"$2\"" "$1" 2>/dev/null)
  echo "${c:-0}"
}

last_message() {
  python3 - "$1" <<'PY'
import json,sys
msgs=[]
for line in open(sys.argv[1], errors="replace"):
    if '"task_complete"' not in line: continue
    try: msgs.append(json.loads(line)["payload"]["last_agent_message"])
    except Exception: pass
print(msgs[-1] if msgs else "")
PY
}

# Conditions that silently degrade a review. The caller must not report a verdict from a round
# that hit either of these without saying so.
warn_round() {
  local w; w=$(buffer | tail -n +"$1")
  if grep -qE 'No agents completed yet|Waiting for agents' <<<"$w"; then
    echo "WARNING: codex delegated part of this round to subagents that never completed - the verdict is unverified, re-run with the inline-only instruction" >&2
  fi
  if grep -qE 'error connecting to|Could not resolve host' <<<"$w"; then
    echo "WARNING: a network call failed during this round - codex may have reviewed without PR state it tried to fetch" >&2
  fi
}

cmd_ensure() {
  local repo="${1:-$PWD}"
  repo=$(cd "$repo" && pwd)
  mkdir -p "$STATE_DIR"
  if has_codex; then
    # The pane's codex was started with -C <its own repo> and keeps that cwd for its whole life.
    # Overwriting the recorded repo with the caller's cwd here would make `ask` look for a journal
    # whose session_meta cwd can never match, and it would then wait out the entire timeout.
    local recorded; recorded=$(cat "$(state_file repo)" 2>/dev/null)
    if [ -z "$recorded" ]; then
      echo "$repo" > "$(state_file repo)"
    elif [ "$recorded" != "$repo" ]; then
      echo "note: reusing the codex already running in $recorded; this call asked for $repo. Answers are read from that pane's journal. Quit codex in the split pane and re-run ensure to move it." >&2
    fi
    echo reused; return 0
  fi
  echo "$repo" > "$(state_file repo)"
  date +%s > "$(state_file since)"
  agtermctl session split visibility on --axis vertical --target "$TARGET" >/dev/null
  sleep 1
  # --approve-for-me already selects workspace-write + auto-review; network_access makes ordinary
  # network commands (gh, curl) run directly instead of going through a reviewer escalation.
  submit "codex --no-alt-screen -m $MODEL -c model_reasoning_effort=\"$EFFORT\" --approve-for-me -c sandbox_workspace_write.network_access=true -C \"$repo\""
  local n=0
  until has_codex; do
    n=$((n+1)); [ "$n" -gt 30 ] && { echo "codex did not start in the split pane" >&2; return 1; }
    sleep 2
  done
  # answer the directory-trust prompt, then wait for the composer
  n=0
  while [ "$n" -lt 60 ]; do
    is_idle && break
    if screen | grep -q 'Do you trust'; then
      printf '1\n' | agtermctl session type --pane "$PANE" --target "$TARGET" --stdin >/dev/null
    fi
    sleep 2; n=$((n+1))
  done
  is_idle || { echo "codex never reached an idle composer in the split pane" >&2; return 1; }
  # The rollout journal does not exist until the first turn runs, so it is resolved lazily in `ask`.
  echo started
}

cmd_ask() {
  local pf="${1:?prompt file required}"
  [ -f "$pf" ] || { echo "no such prompt file: $pf" >&2; exit 1; }
  has_codex || { echo "no codex in the split pane - run 'ensure' first" >&2; exit 1; }

  local repo since roll base_done base_abort before
  repo=$(cat "$(state_file repo)" 2>/dev/null) || repo="$PWD"
  since=$(cat "$(state_file since)" 2>/dev/null) || since=0
  roll=$(find_rollout "$repo" "$since")
  base_done=$(count_event "$roll" task_complete)
  base_abort=$(count_event "$roll" turn_aborted)
  before=$(( $(buffer | wc -l) + 1 ))

  submit_verified "Read the file $pf and do exactly what it says." "$roll" "$base_done" || return 5

  # Block here. Every check is a file read and a terminal query - no model call, no tokens.
  local waited=0
  while [ "$waited" -lt "$TIMEOUT" ]; do
    sleep 3; waited=$((waited+3))
    # the journal is created when the first turn starts, so keep looking until it shows up
    if [ ! -f "$roll" ]; then
      roll=$(find_rollout "$repo" "$since")
      [ -f "$roll" ] || { is_blocked && { echo "codex is waiting on a human approval prompt:" >&2; screen | grep -E "$BLOCKED_RE" | head -3 >&2; return 4; }; continue; }
    fi
    if [ "$(count_event "$roll" task_complete)" -gt "$base_done" ]; then
      last_message "$roll"
      warn_round "$before"
      return 0
    fi
    if [ "$(count_event "$roll" turn_aborted)" -gt "$base_abort" ]; then
      echo "codex aborted the turn (interrupted, crashed, or refused)" >&2
      return 3
    fi
    if is_blocked; then
      echo "codex is waiting on a human approval prompt - nothing here can answer it:" >&2
      screen | grep -E "$BLOCKED_RE" | head -3 >&2
      return 4
    fi
  done
  echo "TIMEOUT after ${TIMEOUT}s." >&2
  echo "  recorded repo: $repo (state file: $(state_file repo))" >&2
  local newest ncwd njournal
  newest=$(newest_tui_cwd)
  if [ -n "$newest" ]; then
    ncwd=${newest%%$'\t'*}
    njournal=${newest#*$'\t'}
    echo "  newest codex-tui journal: $njournal (cwd: $ncwd)" >&2
    if [ "$(cd "$ncwd" 2>/dev/null && pwd -P)" != "$(cd "$repo" 2>/dev/null && pwd -P)" ]; then
      echo "  MISMATCH: no journal matches the recorded repo, so no answer could ever be seen. Re-run ensure from $ncwd, or quit codex in the split pane and start it in $repo." >&2
    fi
  else
    echo "  no codex-tui journal found at all under $SESSIONS" >&2
  fi
  [ -n "$roll" ] && echo "  journal being watched: $roll" >&2
  echo "Last 40 lines of the codex pane:" >&2
  buffer | tail -40 >&2
  return 2
}

case "${1:-}" in
  ensure) shift; cmd_ensure "$@" ;;
  ask)    shift; cmd_ask "$@" ;;
  status) has_codex && echo reused || echo absent ;;
  *) echo "usage: codex-pane.sh {ensure [repo]|ask <prompt-file>|status}" >&2; exit 64 ;;
esac
