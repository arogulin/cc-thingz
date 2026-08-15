---
worth: later
where: plugins/planning/scripts/launch-plan-review.sh:70
added: 2026-08-15
---
# an agtermctl overlay failure is indistinguishable from a review with no annotations

Every agterm overlay call site discards the failure, so "the overlay never opened" and "the user read it
and wrote nothing" reach the caller identically.

- `launch-plan-review.sh:70` runs `agtermctl session overlay open ... --block >/dev/null || true`, then
  `cat "$OUTPUT_FILE"` on an untouched temp file. Empty stdout is the "no annotations" signal.
- `plan-annotate.py:160` and `git-review.py:298` pass `stderr=subprocess.DEVNULL`, never read
  `returncode`, and `open_editor()` returns a literal `0` (`:168` / `:306`).
- `plan-review-hook.py` only inspects the launcher's stdout, never its exit status.

Reproduced with a stub `agtermctl` that exits non-zero: the launcher exits 0 with empty stdout and the
EXIT trap still restores `session status active`. Any overlay failure reports to the agent as a completed
review with no comments. In git-review nothing else gates, so the diff proceeds unreviewed; in plan-review
the hook still emits `permissionDecision: "ask"`, so it degrades to the plain ExitPlanMode dialog rather
than silence.

Deferred because a fix spans the launcher's exit code, the hook's handling of it, and both
`open_editor()` return contracts, across four files and three callers. Any fix has to keep "overlay ran,
user wrote nothing" reporting empty while a non-zero `agtermctl` surfaces as an error the agent sees. A
bare retry-on-nonzero is wrong: `--block` exits with the inner program's status, so it would open a second
overlay whenever the editor itself exits non-zero.

Surfaced reviewing PR #41, which adds new ways to trigger it by passing `--pane`, but the swallowing
itself predates that change.
