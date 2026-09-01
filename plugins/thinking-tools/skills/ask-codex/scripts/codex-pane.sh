#!/usr/bin/env bash
# Drive a long-lived interactive codex session in the split (right) pane of THIS agterm session.
#
#   codex-pane.sh ensure [repo_dir]   -> start codex in the split pane unless it is already there
#   codex-pane.sh ask <prompt-file>   -> send one round, wait for the sentinel, print the answer
#   codex-pane.sh status              -> reused | absent
#
# Environment:
#   CODEX_PANE_MODEL    model passed to codex (default gpt-5.6-sol)
#   CODEX_PANE_TIMEOUT  seconds to wait for one round (default 900)
#
set -euo pipefail

: "${AGTERM_SESSION_ID:?not running inside an agterm session}"
TARGET="$AGTERM_SESSION_ID"
PANE=right
MODEL="${CODEX_PANE_MODEL:-gpt-5.6-sol}"
TIMEOUT="${CODEX_PANE_TIMEOUT:-900}"
POLL=10

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

screen() { agtermctl session text --pane "$PANE" --target "$TARGET"; }
buffer() { agtermctl session text --pane "$PANE" --target "$TARGET" --all; }
has_codex() { node_field splitForeground | grep -q codex; }
is_ready()  { screen | grep -q '· Ready ·'; }

submit() {  # type one line, then Enter as a separate injection
  agtermctl session type --pane "$PANE" --target "$TARGET" "$1" >/dev/null
  sleep 1
  printf '\n' | agtermctl session type --pane "$PANE" --target "$TARGET" --stdin >/dev/null
}

wait_ready() {  # answer the directory-trust prompt if it shows up, then wait for the composer
  local n=0
  while [ "$n" -lt 60 ]; do
    if is_ready; then return 0; fi
    if screen | grep -q 'Do you trust'; then
      printf '1\n' | agtermctl session type --pane "$PANE" --target "$TARGET" --stdin >/dev/null
    fi
    sleep 2; n=$((n+1))
  done
  echo "codex never reached its 'Ready' state in the split pane" >&2
  return 1
}

cmd_ensure() {
  local repo="${1:-$PWD}"
  if has_codex; then wait_ready; echo reused; return 0; fi
  agtermctl session split visibility on --axis vertical --target "$TARGET" >/dev/null
  sleep 1
  submit "codex --no-alt-screen -m $MODEL -s read-only -a never -c model_reasoning_effort=\"high\" -C \"$repo\""
  local n=0
  until has_codex; do
    n=$((n+1)); [ "$n" -gt 30 ] && { echo "codex did not start in the split pane" >&2; return 1; }
    sleep 2
  done
  wait_ready
  echo started
}

cmd_ask() {
  local pf="${1:?prompt file required}"
  [ -f "$pf" ] || { echo "no such prompt file: $pf" >&2; exit 1; }
  has_codex || { echo "no codex in the split pane — run 'ensure' first" >&2; exit 1; }
  wait_ready

  local marker before
  marker="CODEX-DONE-$(date +%s)"
  before=$(( $(buffer | wc -l) + 1 ))

  submit "Read the file $pf and do exactly what it says. End your reply with the line $marker"

  local waited=0
  while [ "$waited" -lt "$TIMEOUT" ]; do
    sleep "$POLL"; waited=$((waited+POLL))
    if buffer | tail -n +"$before" | grep -q "$marker" && is_ready; then
      buffer | tail -n +"$before"
      return 0
    fi
  done
  echo "TIMEOUT after ${TIMEOUT}s. Last 80 lines of the codex pane:" >&2
  buffer | tail -80 >&2
  return 2
}

case "${1:-}" in
  ensure) shift; cmd_ensure "$@" ;;
  ask)    shift; cmd_ask "$@" ;;
  status) has_codex && echo reused || echo absent ;;
  *) echo "usage: codex-pane.sh {ensure [repo]|ask <prompt-file>|status}" >&2; exit 64 ;;
esac
