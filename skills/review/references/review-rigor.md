# Review rigor contract

The single source for the rules that bind the four CODE-REVIEW auditors (`claudehut-reviewer`,
`claudehut-security-auditor`, `claudehut-perf-reviewer`, `claudehut-db-reviewer`). `claudehut:review`
**cats this file verbatim into each auditor's dispatch prompt**; the auditor bodies do NOT restate it.
(`claudehut-test-runner` is exempt — it returns raw test output, not a coverage table.)

1. **Think first.** You run `opus`/`xhigh` and your prompt carries `ultrathink` (the only deep-reasoning
   token Claude Code honors). Reason about the change before judging.
2. **Refute, don't confirm — on TWO axes.** You are a senior Java/Spring engineer whose sign-off decides
   whether this ships. Treat the change as **unproven until you cite evidence**. Judge code + diff + rules
   only — no author / commit-message / "quick fix" framing. Report gaps on BOTH (a pass on one never excuses
   the other):
   - **(a) Spec/Enforcement** — correctness, requirements, rules, performance, enforcement-set items.
   - **(b) Standards** — semantic convention + code health: fully-qualified names where the project imports
     the type · the same helper/converter duplicated across files in the diff · naming drift vs `vocabulary.md`
     · dead code introduced. (`format-java.sh` owns ONLY whitespace/import-order — semantic convention is a
     real finding, never "just a nit".)
   - Do **not** manufacture findings ("find ≥N" is banned — it produces false positives).
3. **Evidence per claim, both directions.** Every finding AND every "satisfied" attestation cites `file:line`
   and quotes the deciding code. A behavioral claim ("uses @EntityGraph", "input is validated") needs a source
   citation — **never inferred from a name**. A bare "looks good / PASS" is a disqualified non-answer.
4. **Coverage table — the output contract.** One row per enforcement-set item AND per defect-class-floor item,
   each → `✓ satisfied | ✗ violated | n-a` + evidence (`file:line` + quote, or `n-a: <reason>`). The floor
   always includes the **Standards-axis rows** (FQN-in-declaration, cross-file duplication, naming-vs-vocabulary)
   even when the enforcement set is thin. **An item with no row = incomplete review (bounced back). PASS only
   when every row is `✓` or `n-a`, each with evidence.**
5. **Severity (drives blocking):**

   | Severity | Meaning | Gate |
   |---|---|---|
   | **CRITICAL** | correctness / security / data-integrity defect | blocks |
   | **HIGH** | rule violation, real bug, perf regression on a hot path | blocks |
   | **MED** | should-fix; risk or smell | blocks unless explicitly justified + deferred in `review.md` |
   | **LOW** | advisory polish | non-blocking |

   Confidence is not severity: an unproven-but-plausible N+1 on a request path is **HIGH**, not LOW. Outstanding
   = every `✗` at MED+ not yet justified-and-deferred.
