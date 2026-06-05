# Parallel-vs-sequential benchmark — measured report

Date: 2026-06-04 · harness `evals/bench/parallel-bench.sh` · rows in `evals/results/bench-parallel*.jsonl`
Method: identical fixtures (self-origin so `origin/HEAD` exists), 2 worktree agents per run, **epoch-file
ground truth** written by the agents themselves (stream-json carries no subagent timestamps), **overlap-gated**
— an arm gets a timing comparison only if its epoch intervals intersect. Spend ≈ $6.5, 15 live runs.

## Step 0 — `background: true` semantics probe (the load-bearing unknown)

PASS: in headless `-p`, the main thread dispatched 2 background worktree agents, **waited for both results,
then acted** (wrote the post-join artifact) — wait-then-reconcile is viable. Epochs overlapped 24s/25s (true
concurrency). Bash (sleep/date/commit) ran inside background agents under `acceptEdits`.

## T1 — controlled workload (sleep 45), 3 arms × 3 trials

| Arm | Lever | Concurrent (epoch overlap) | Orchestration overhead (wall − agent span) | Orphans |
|---|---|---|---|---|
| A0 | sequential, one-at-a-time | 0/3 (correctly serial) | 31–37s | 0 (+1 by-design dirty-keep) |
| A1 | single-message multi-dispatch (what the plugin ships) | **3/3** | **25–27s (consistent — the lever's true cost)** | 0 |
| A2 | `background: true` | **3/3** | **55–58s (~2× A1)** | 0 |

**Variance attribution (supersedes the first read of this table):** A1's raw walls (44–164s) varied because the
*agents'* work durations varied (one agent did 135–137s of work; others skipped the prescribed sleep — soft
instruction); wall ≈ max-agent-duration + ~26s in every A1 trial. A2's "tight" walls (64–66s) were a
**confound** — all its agents happened to skip the work (8–10s durations); with equal agent durations A1 would
have been ~30s *faster* per fan-out. **The lever-attributable difference is overhead: A1 ≈ 26s, A2 ≈ 56s.**
A2 cost column omitted: 2 of 3 rows look like double-counted result events `[uncertain]`.

## T2 — real work (2 disjoint Spring services + tests), directional (n=2/arm)

| Arm | Wall | Shape (msg-id-grouped) | Overlap | Both services merged | Orphans | Cost |
|---|---|---|---|---|---|---|
| A0 sequential | 83s, 89s | 1/msg | 0 (serial) | 2/2 | 0 | ~$0.22 |
| A1 parallel | **48s, 49s** | **2 calls in 1 msg** | 18–21s | 2/2 | 0 | ~$0.22 |

**Directional speedup ≈ 1.77× on 2 parallelizable tasks (max 2×), with clean serialized reconcile + zero
orphans in every trial.** Cost parity held **on these T2 runs (n=2)** — not claimed as a general property
(T1's A2 cost column was unusable). n=2 — directionally consistent, not a precise multiple.

## Corrections this benchmark forced

- **Previous verdict overturned:** "single-message dispatch did not reproduce headless" was a **detector
  artifact** — stream-json emits each tool_use as its own assistant event sharing one `message.id`; counting
  per event undercounts. The corrected (message-id-grouped) detector + epoch overlap show the plugin's
  instruction **fires and parallelizes: 6/6 concurrent across T1+T2.** Doc 11 §6 record updated.
- One T1 agent died mid-task: `sweep` correctly **kept** its dirty worktree (retain-evidence-by-design) and
  removed nothing else — the lifecycle behaved exactly as designed under failure.

## Evaluation — mistakes & completeness

1. **Plugin parallel design: VALIDATED.** The shipped lever works; reconciliation held under 15 runs incl. an
   agent failure. The real defect this round was in the *eval tooling* (shape detector), not the plugin.
2. **Soft-instruction ceiling confirmed (again):** agents skipped prescribed work blocks; instruction
   compliance is probabilistic. The plugin's posture — correctness on deterministic rails (gates,
   check-disjoint, state-CLI validation, reconcile/sweep), speed as best-effort — is the right architecture.
3. **Stability headroom:** A2 (`background: true`) is shape-independent and had the tightest walls. Candidate
   improvement, NOT built (needs approval): an optional background-dispatch mode for `[P]` fan-out
   (requires `background: true` implementer variant; note background agents auto-deny permission prompts).
4. **Unmeasured residuals:** review-phase 5-auditor fan-out (same lever class, read-only — low risk, cheap to
   measure); Gradle-build-in-worktree hang (mitigated by design: `--no-daemon` + content-in-prompt; never
   reproduced); interactive approval gates (headless-untestable).

## Recommended next improvements (gated on approval)

## DECISION (deep-dive research + advisor, 2026-06-04) — **APPROVED by user 2026-06-04**

**A1 (single-message multi-dispatch) is the lever for write/implementation fan-out. A2 (`background: true`)
is REJECTED for write tasks.** Basis:
- **Measured:** A1 overhead ≈26s consistent vs A2 ≈56s (2×); A1 6/6 concurrent; the earlier "A2 more stable"
  read was a confound (agent-duration variance, not the lever).
- **Ecosystem (all closed "not planned"):** background agents silently lose output (#17011), silently
  auto-deny Write/Edit/Bash with false success (#32402/#34095/#30693), and a parallel-worktree cleanup race
  destroyed a repo's `.git` (#48927). Docs confirm auto-deny is designed behavior with no user surfacing.
- **Zero official Anthropic plugins** use `background: true` for write agents — background is reserved for
  read-only fan-out across the ecosystem.

**The genuine open risk of A1 — stated, not waved off:** the model silently *not batching* the Agent calls
into one message under heavy real-workflow context. Our 6/6 came from clean bench prompts; this session's own
history (the skipped write-plan skill; the originally-serial review screenshot) shows soft instructions degrade
in full context, and Opus 4.7 is documented as more conservative about autonomous parallel dispatch. **Unmeasured:
batching survival in a full brainstorm→plan→implement context.**

**A2 for READ-ONLY fan-out stays OPEN (not rejected):** auto-deny/output-loss bugs mostly target writes; A2's
real property — concurrency independent of the model's batching choice — sidesteps exactly A1's open risk. A
scoped read-only test on the 5-auditor review fan-out is the data-suggested follow-up.

## Heavy-context batching check (2026-06-04) — risk DOWNGRADED

One qualitative run (advisor-designed: no underpowered before/after): ~65k input tokens of real context (nine
playbooks read in full), then the review skill's 5-auditor dispatch. **Result: 5 Agent calls in ONE message —
twice — at 64,748 input tokens.** Batching held under heavy context; nothing reproduced; risk downgraded from
"open" to "not reproduced (single qualitative run; cannot be hard-guaranteed — serial fallback stays correct)."

**Side-finding (fixed in v0.3.0):** the first 5-call batch used unqualified agent names
(`claudehut-db-reviewer`) and had to be re-issued with qualified types (`claudehut:claudehut-…`) — one wasted
dispatch round. Skills now name agents by qualified type at every dispatch point.

**Insurance shipped (best-effort by nature, not a guarantee):** the official parallel-tool-call guidance
(measured phrasing, no MUST/CRITICAL — Opus 4.x overtriggers on aggressive prompts) now lives on the two
always-loaded surfaces: the `claudehut-workflow` skill (injected each session) and the generated `MEMORY.md`
@import slice. A plugin cannot set the system prompt, so the docs' "~100%" system-prompt number does NOT
transfer — propensity maximized, effectiveness under all conditions unverified, correctness never depends on it.

## Scoped A2 read-only test — auditor fan-out (2026-06-04) — CLOSED

One run per arm (qualitative, n=1), identical review task with a planted SQL-injection controller; A2 = the 5
auditors given `background: true` in a throwaway sanitized copy (shipped tree untouched).

| | A1 foreground (shipped) | A2 background |
|---|---|---|
| Reports returned (parent-side, id-matched) | **5/5** (2.1–6.9k chars) | **5/5** (2.5–8.4k chars) — no silent loss on the text channel |
| test-runner survived (needs Bash, auto-deny risk) | ✓ | ✓ (2.5k report) |
| Dispatch shape | 5 calls in ONE message | 5 calls in ONE message |
| Planted SQLi found in final verdict | ✓ | ✓ |
| Wall | 174s | 189s (slightly slower — background overhead, no batching benefit to offset) |

**Verdict: A2 read-only works (no silent loss; auto-deny didn't bite) but provides NO advantage when A1
batching fires — and A1 batching held in every measurement including 65k-token context. A2's only residual
value is insurance against a batching failure we could not reproduce. CLOSED: keep A1 everywhere; do not ship
background auditors.** (n=1 per arm — qualitative, consistent with all prior measurements.)

| # | Remaining | Basis |
|---|---|---|
| 1 | Adopt the corrected msg-id-grouped shape detector in any future eval (already in `parallel-bench.sh`; note the verbose stream also interleaves subagent transcripts — filter parent-side events by `subagent_type==null`) | artifact post-mortem |
