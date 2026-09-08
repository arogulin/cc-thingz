---
name: ask-codex
description: Consult OpenAI Codex for investigation, debugging, or code review. Inside agterm it runs as a persistent session in the split pane, so it keeps context across many review rounds. Use when user explicitly asks to "ask codex", "check with codex", "codex review", or as a last resort when stuck after 4+ failed attempts at debugging, investigation, or bug fix and completely out of ideas. Codex is slow (2-5 min), so only escalate when truly stuck. Codex gets full repo access and network so it can use every tool a good review needs — it reports and proposes, we implement.
allowed-tools: Bash, Read, Grep, Glob
---

# Ask Codex

Consult OpenAI Codex (GPT-5.5) as a second opinion for investigation, debugging, or review tasks.

Two transports, same prompting discipline:

- **Pane mode (preferred, requires agterm)** — codex runs as a live TUI in the split pane of the current
  session and stays there between rounds. Review cycles are routinely 7-9 rounds; a fresh process per
  round throws away everything codex already learned about the change and re-pays the reading cost each
  time. The user can also read, scroll, or take the conversation over by hand. The answer comes back
  from codex's own rollout journal, so nothing is scraped and nothing is truncated.
- **Exec mode (fallback)** — one `codex exec` per question, for when there is no agterm session.

## Activation Triggers

**Explicit:**
- "ask codex", "check with codex", "codex review"
- "what does codex think", "get codex opinion"
- "consult codex", "run codex on this"

**Automatic (last resort — stuck detection):**
- 4+ failed attempts at the same bug fix or investigation
- completely out of ideas, all reasonable approaches exhausted
- going in circles with no progress despite multiple different strategies

## Workflow

### Step 1: Check Availability

Run `which codex` to verify the CLI is installed. If not found, inform the user and stop.

Then pick the transport: `echo $AGTERM_ENABLED` — `1` means pane mode, empty means exec mode.

### Step 2: Build Context

**Reviewing a PR.** In pane mode codex has network, so tell it the PR number and repo and let it run
`gh pr view` / `gh pr diff` itself — the PR body, the CI rollup, and existing comments are all part of
the review and it should read them. In exec mode the sandbox has no shell network, so fetch them
yourself and put the paths in the prompt:

```bash
gh pr view <N> --repo <slug> --json number,title,body,reviewDecision,statusCheckRollup,comments,files > $S/pr-<N>.json
gh pr diff <N> --repo <slug> > $S/pr-<N>.diff
```

Codex's built-in web search works in both modes regardless of sandbox — only shell network is gated.


Gather context from the current conversation:

1. **What's the problem/question** — summarize in 2-3 sentences
2. **What we know** — relevant files, error messages, behavior observed
3. **What we tried** — approaches attempted and why they failed (if applicable)
4. **Specific question** — what exactly codex should analyze or answer

In pane mode, do this only for the first round. Later rounds inherit everything — state just what is
new: "Round 3: I applied your finding 2 as follows … re-check that path and tell me whether it holds."

### Step 3: Construct Prompt

Build a focused prompt. Do NOT dump entire files — codex has full project access and can read them
itself. Provide file paths and line references so codex knows where to look.

**Prepend a memory-load preamble** (first round only). Codex auto-loads only `AGENTS.md`; it does NOT
read Claude Code's project memory files (`CLAUDE.md`, `CLAUDE.local.md`, `.claude/rules/`), so the
project conventions Claude follows are invisible to Codex unless you tell it to read them. Prepend this
line to the prompt:

```
First read these project guidance files if present: CLAUDE.md, CLAUDE.local.md, .claude/rules/
```

- Project-level files only. Never point Codex at the user-level `~/.claude/CLAUDE.md` — that file is
  Claude's own operating instructions, and Codex has `AGENTS.md` for its user-facing conventions.
- No `@` prefix — `@file` is inert in `codex exec` (literal text, not an import).
- The paths resolve against Codex's working directory; Codex skips any that don't exist.

**Template for investigation/debug:**

```
# [Investigation/Debug] Request

## Problem
[2-3 sentence description]

## Context
- Files: [path/to/file.go:lineNumber, ...]
- Observed: [what's happening]
- Expected: [what should happen]

## What We Tried
[List approaches and outcomes, or "First consultation" if fresh question]

## Question
[Specific, focused question for codex to answer]

Provide:
1. Root cause analysis (if debugging)
2. Concrete recommendation with file:line references
3. Why previous approaches failed (if applicable)

Keep response focused and actionable.
```

**Template for code review (adversarial):**

When asked for a code review, use this adversarial prompt:

```
<role>
You are performing an adversarial code review.
Your job is to break confidence in the change, not to validate it.
</role>

<task>
Review the provided changes as if you are trying to find the strongest reasons
this change should not ship yet.
Scope: [files and changes to review — paths, branch diff, or description]
Focus: [specific area if user specified one, otherwise "general"]
</task>

<working_rules>
Do this analysis yourself in this turn. Do not spawn subagents, do not invoke other skills or
slash commands, and do not wait on background agents. A pass you delegate and never receive is
worse than no pass, because the verdict looks reviewed when it is not.

You have full access to the repository and to the network. Use whatever you need: run the tests,
run the linters, check out refs, query the API. Creating scratch files and deleting them again is
fine.

Do NOT fix anything. Report each issue and propose the change you would make; leave the code as
you found it. Applying fixes is the caller's job, and a review that edits what it reviews cannot
be checked.
</working_rules>

<operating_stance>
Default to skepticism.
Assume the change can fail in subtle, high-cost, or user-visible ways until
the evidence says otherwise. Do not give credit for good intent or partial fixes.
If something only works on the happy path, treat that as a real weakness.
</operating_stance>

<attack_surfaces>
Prioritize failures that are expensive, dangerous, or hard to detect:
- auth, permissions, tenant isolation, and trust boundaries
- data loss, corruption, duplication, and irreversible state changes
- rollback safety, retries, partial failure, and idempotency gaps
- race conditions, ordering assumptions, stale state, and re-entrancy
- empty-state, nil, timeout, and degraded dependency behavior
- version skew, schema drift, migration hazards, and compatibility regressions
- observability gaps that would hide failure or make recovery harder
</attack_surfaces>

<finding_bar>
Report only material findings. No style feedback, naming nitpicks, or speculative
concerns without evidence. Each finding must answer:
1. What can go wrong?
2. Why is this code path vulnerable?
3. What is the likely impact?
4. What concrete change would reduce the risk?
Prefer one strong finding over several weak ones.
</finding_bar>

<grounding_rules>
Every finding must be defensible from actual code you can see.
Do not invent files, lines, code paths, or runtime behavior you cannot support.
If a conclusion depends on an inference, state that explicitly and keep the
confidence score honest.
</grounding_rules>

<output_format>
[PANE MODE: use this block]
Plain markdown, no JSON — this is read back off a terminal pane, so keep lines short
and the structure flat.

VERDICT: approve | needs-attention
SUMMARY: one line

Then one block per finding:

### [severity] title (confidence 0.0-1.0)
file: path/to/file.go:42-55
what: what goes wrong
why: why this path is vulnerable
impact: consequence
fix: concrete change

severity is critical | high | medium | low.
Use needs-attention if any material risk is worth blocking on; approve only if you
cannot support a substantive finding.

[EXEC MODE: use this block instead]
Return ONLY valid JSON. Example with concrete values:
{
  "verdict": "needs-attention",
  "summary": "auth middleware skips token validation on retry paths",
  "findings": [
    {
      "severity": "high",
      "title": "token validation bypassed on retry",
      "body": "retryHandler re-enters serveHTTP without revalidating the bearer token, allowing expired tokens through on transient failures",
      "file": "internal/auth/middleware.go",
      "line_start": 42,
      "line_end": 55,
      "confidence": 0.85,
      "recommendation": "move token validation before the retry loop entry point"
    }
  ],
  "next_steps": ["add test for expired-token retry scenario"]
}

Allowed values:
- verdict: "approve" or "needs-attention"
- severity: "critical", "high", "medium", or "low"
- confidence: 0.0 to 1.0
</output_format>
```

Keep only the block matching the transport you are using — a TUI wraps long lines, which mangles JSON.

### Step 4a: Execute — pane mode

Ensure the pane, then send rounds:

```bash
"${CLAUDE_PLUGIN_ROOT}/skills/ask-codex/scripts/codex-pane.sh" ensure "$PWD"
```

Prints `reused` if codex was already running in the split pane, `started` if it just launched one.
**If it prints `reused`, do not re-brief codex from scratch** — it already has the project context and
the earlier rounds. Ask the follow-up directly.

The script:
- opens a vertical split on `$AGTERM_SESSION_ID` if there is none (never on `active` — that is the
  session the user has selected, not yours), and leaves the divider where the user has it;
- launches `codex --no-alt-screen -m gpt-6-astra -c model_reasoning_effort="medium" --approve-for-me -c sandbox_workspace_write.network_access=true -C <repo>`
  by typing it at the split pane's shell prompt;
- answers codex's "Do you trust the contents of this directory?" prompt with `1` when it appears
  (unanswered, it swallows the next round's prompt and quits);
- waits for an idle composer before typing, and records the rollout journal codex is writing.

Codex is a child of that pane's shell, so `/quit` drops the user back at a prompt in the right directory
and the pane survives — they can restart codex there by hand.

Write the round's prompt to a file and send it:

```bash
"${CLAUDE_PLUGIN_ROOT}/skills/ask-codex/scripts/codex-pane.sh" ask /path/to/codex-round-3.md
```

Never type a multi-line prompt into the pane yourself: every newline submits, so a 30-line brief becomes
30 premature Enters. The script types one line pointing codex at the file.

**`ask` is the only supported way to send a round — including after `ensure` has failed.** A failed
`ensure` means the pane is not in a state the script recognises; fix that (read the pane, clear the
blocker, quit codex and re-run `ensure`) rather than driving the pane with your own `agtermctl session
type` calls. Two things go wrong every time someone hand-rolls it:

- `agtermctl session type` returns `ok` once the keystrokes are injected, which is not evidence codex
  accepted them. The Enter can land before the typed line reaches the composer, leaving the prompt
  unsubmitted while you wait on a pane where nothing is running. `ask` verifies the turn actually
  started (`esc to interrupt` present) and re-sends Enter once before giving up with exit 5.
- Sentinel counting is not how completion is detected here, and a hand-rolled `grep -c SENTINEL >= 2`
  silently depends on the sentinel instruction being in the *typed line* rather than the brief file.
  Put the instruction in the file and the count never reaches 2, so the loop spins forever after codex
  has finished. `ask` reads the rollout journal instead and needs no sentinel at all.

**Run `ask` once with `run_in_background: true` and do nothing until it wakes you.** It blocks until the
turn actually ends and then exits, which is your signal. Do NOT poll it with BashOutput on a timer, and
do not "check on" the pane while it runs — every check is a model call, and a 20-minute review checked
every 30 seconds costs 40 of them for no information. The script's own wait loop costs nothing.

Exit codes: `0` answer on stdout, `2` timeout (default 1800s, raise with `CODEX_PANE_TIMEOUT`), `3` codex
aborted the turn, `4` codex is stuck on a human approval prompt that nothing here can answer, `5` the
prompt was typed but codex never started the turn.

**How completion is detected.** Codex appends a `task_complete` event to its rollout journal at
`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`, and that event's `last_agent_message` holds the complete
reply. The script watches for it and prints it verbatim. This is why there is no sentinel and no pane
scraping for the answer: the pane collapses long tool transcripts to `… +N lines (ctrl + t to view
transcript)` and that loss is unrecoverable, while the journal keeps the full text.

Do not key anything on the status line. `[tui] status_line` is user-configurable, and its `run-state`
component — the one that printed `Ready` / `Working` — is often switched off to keep the line short. The
script's idle check uses the transcript area (`esc to interrupt` present or absent, plus the composer
row), which no config setting removes.

### Step 4b: Execute — exec mode (no agterm)

Run codex in background (it takes 2-5 minutes for complex analysis):

```bash
codex exec -m gpt-6-astra \
  --sandbox read-only \
  -c model_reasoning_effort="medium" \
  -c stream_idle_timeout_ms=600000 \
  "prompt here" < /dev/null
```

**Execution rules:**
- Always end the invocation with `< /dev/null` (as shown). `codex exec` reads stdin to append a `<stdin>`
  block even when the prompt is a positional arg, so an inherited open pipe (common under a background
  launch) never closes and codex blocks forever on "Reading additional input from stdin…"; `/dev/null`
  gives immediate EOF.
- Always use `run_in_background: true` in Bash tool
- Monitor with BashOutput every 15-20 seconds
- Be patient during reasoning phase (1-3 minutes of silence is normal)
- Total timeout: 10 minutes for standard, 15 for complex

**Flags:**
- `--sandbox read-only` — codex can read all project files but cannot modify anything
- `-m gpt-6-astra` — latest model (adjust as newer versions become available)
- `model_reasoning_effort="medium"` — medium reasoning tier

### Step 5: Present Results

0. **Check stderr first.** If the round printed `WARNING: codex delegated part of this round to
   subagents that never completed`, do not report the verdict as a review result — say the independent
   pass never landed and re-run with the working_rules block. If it printed a network-failure warning,
   say which state codex could not fetch. If the script exited `3` or `4`, report that instead of an
   answer: `4` means codex is sitting on an approval prompt in the pane and needs a human.
1. **Extract codex's analysis** — the pane-mode answer arrives verbatim from the rollout journal, so no
   chrome-stripping is needed; in exec mode skip session info, token counts, and the prompt echo
2. **Parse structured output** — markdown findings in pane mode, JSON in exec mode
3. **Add your assessment** — agree, disagree, or note caveats
4. **STOP and ask** — do NOT apply any fixes or changes without explicit user approval

**For investigation/debug responses** (unstructured):

```
**Codex Analysis:**

[Codex's response — cleaned up and formatted]

---

**Assessment:** [Your 2-3 sentence evaluation]

**Proposed action:** [What codex suggests — awaiting approval]
```

**For review responses:**

Present findings sorted by severity, filtered by confidence:

```
**Codex Review: [verdict]**
[summary]

**Findings** (N issues):

1. **[critical]** title (confidence: 0.9)
   file.go:42-55
   [body]
   → [recommendation]

2. **[high]** title (confidence: 0.8)
   ...

**Next steps:** [list]

---

**Assessment:** [Your evaluation — which findings are valid, which are false positives]
```

- skip findings with confidence < 0.3 (likely noise)
- group by severity: critical → high → medium → low
- if verdict is "approve" and no findings, just say "codex found no material issues"

**CRITICAL: After presenting findings, STOP. Do not apply fixes, do not touch files, do not start implementing suggestions. Explicitly ask the user what to do next. Codex findings are input for discussion, not automatic work orders.**

## Important Rules

- **Codex reports, it does not fix** — it has full repo access and may create and delete scratch
  files, run tests, and use the network. It must not apply fixes to the code under review. Say so in
  every prompt; the working_rules block in the review template already does.
- **Don't duplicate files** — codex has full project access. Provide paths, not content.
- **Focused prompts** — specific questions get better answers than broad "review everything".
- **Background execution, then wait** — one `run_in_background` call per round, and no polling while
  it runs. The script blocks until the turn ends; checking on it costs a model call each time and
  tells you nothing the exit does not.
- **One question at a time** — if multiple concerns, run separate rounds. In pane mode this costs
  nothing, since the session keeps the context.
- **Reuse beats restart** — a `reused` pane already knows the change. Re-briefing wastes the point.
- **Always `--target "$AGTERM_SESSION_ID"`** for any manual agtermctl call — `active` is whatever
  session the user has selected. `session text` takes `--all` or `--lines N`, never both; combining
  them is rejected.
- **A wait loop needs a positive liveness check.** A predicate that is empty both when the work is
  unfinished and when the question was wrong will report success. Assert the thing is still running
  alongside the done-condition.
- **Critical thinking** — codex can be wrong. Evaluate its suggestions before implementing.

## When NOT to Use

- Simple questions you already know the answer to
- Tasks where the solution is clear and just needs implementation
- File searches or codebase navigation (use Grep/Glob instead)

## Troubleshooting

- **Codex not found**: `which codex` — install via `npm install -g @openai/codex`
- **Authentication**: `codex login` if getting auth errors
- **Timeout (exec mode)**: increase `stream_idle_timeout_ms` for complex analyses; in pane mode raise
  `CODEX_PANE_TIMEOUT` instead
- **Off-target response**: refine prompt with more specific file:line references
- **Hangs on "Reading additional input from stdin…"**: the exec invocation is missing the `< /dev/null`
  stdin redirect — add it (see Step 4b).
- **Script says the split never came up**: check `agtermctl tree --json`; if the split pane exists but
  sits at a shell prompt, codex failed to start. Read it with
  `agtermctl session text --pane right --target "$AGTERM_SESSION_ID" --all | tail -40`.
- **`ask` exits 5 ("never started the turn")**: the line was typed but codex did not accept it, so the
  prompt is sitting unsubmitted in the composer. Look at the pane, clear whatever is in the way (a
  leftover approval selector, a modal), and re-run `ask`.
- **`ask` exits 4**: codex is waiting on a human approval prompt. `ensure` clears the directory-trust
  prompt and `--approve-for-me` suppresses the rest, so this is rare; clear it in the pane by hand.
- **`ask` fails with "no codex in the split pane"**: the user quit codex. That is supported — the pane
  drops to a shell. Run `ensure` again; it starts a fresh session, so context from earlier rounds is
  gone. Say so before re-briefing.
- **Output looks wrapped or garbled**: the pane is narrow. Widen the split with
  `agtermctl session resize --target "$AGTERM_SESSION_ID" …` before the next round.
- **User wants their own conversation with codex**: they already have it — the pane is a normal
  interactive codex. Tell them to click into it and type.
