# Review rigor contract

The rules every code-review lane follows: `claudehut-reviewer`, `claudehut-security-auditor`,
`claudehut-db-reviewer` (persistence + performance) and `claudehut-contract-reviewer` (contracts +
observability). `scripts/review-pack.sh` copies this file verbatim into the `## Rigor` section of each lane's
pack, so the agent bodies do not restate it. `claudehut-test-runner` returns raw test output and is exempt.

1. **Read the pack, then the code.** The pack header pins `base_sha` and `reviewed_tree`; `## Diff` holds the
   hunks of your lane's files. A file listed past the pack cap: `git diff <base_sha> <reviewed_tree> -- <file>`. Do not run a
   whole-scope `git diff`. Bash is read-only: `git show`, `git log`, `git diff -- <file>`.
2. **Refute, don't confirm — on two axes.** Treat the change as unproven until you cite evidence. Judge code,
   diff and rules only, not the author's summary or commit message.
   - **(a) Spec/Enforcement** — correctness, requirements, the pack's `## Enforcement` items for your lane,
     `## Known pitfalls`. Every lane.
   - **(b) Standards** — reviewer lane only: fully-qualified names where the project imports the type, the
     same helper/converter duplicated across files in the diff, naming drift against `## Vocabulary`, dead
     code the change introduced. `format-java.sh` owns only whitespace and import order; semantic convention
     is a real finding.
   - Do not manufacture findings. If you are not certain an issue is real, do not flag it: put it under
     Suspected with the check that settles it.
3. **Evidence per claim, both directions.** Every finding and every `✓` cites `file:line` and quotes the
   deciding code. A behavioral claim ("uses @EntityGraph", "input is validated") needs a cited line, not a
   name. A bare "looks good" is not an answer.
4. **Output, in this order:**
   1. **Findings** — `✗` only: `SEVERITY | file:line | quote | reason`. At most 5 LOW; count the rest.
   2. **Suspected** — at most 3, each with one concrete read-only check (a SELECT, a `git show`, a grep). The
      main thread runs live DB/MCP queries; you do not.
   3. **Coverage** — one row per `## Enforcement` item in your pack: `item | ✓/✗ | file:line + quote`. No
      `n-a` rows for items outside your lane. The reviewer adds the five floor rows (Correctness,
      Conventions, Duplication, Dead code, Minimalism) and is the only lane that writes Standards rows.
   4. **escalate** — reviewer only: `escalate: <lane> — File.java:NN <why>` for a concern owned by a lane not
      in the run list, instead of reviewing it yourself. Otherwise `none`.
   5. **Tests** — only when the pack has a `## Test command` section: the command and pass/fail counts from
      this turn.
   6. **Verdict** — `PASS` or `OUTSTANDING (n)`.
5. **Pre-existing** is a verdict, not a filter: mark a finding `pre-existing` only when
   `git show <base_sha>:<path>` shows the same defect. A guard the diff removes or loosens (`@PreAuthorize`,
   a filter-chain rule) is a finding of this change.
6. **Severity (drives blocking):**

   | Severity | Meaning | Gate |
   |---|---|---|
   | **CRITICAL** | correctness / security / data-integrity defect | blocks |
   | **HIGH** | rule violation, real bug, perf regression on a hot path | blocks |
   | **MED** | should-fix; risk or smell | blocks unless justified and deferred in `review.md` |
   | **LOW** | advisory polish | non-blocking |

   Confidence is not severity: a proven N+1 on a request path is HIGH, not LOW. An unproven one is Suspected.
