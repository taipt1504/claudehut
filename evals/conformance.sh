#!/usr/bin/env bash
# T1 structural conformance eval for ClaudeHut (no Claude, free, deterministic).
# Measures the static guarantees behind P2 (coherent roster, one-skill-per-phase, phase-bound)
# and P6 (native manifest integration): component counts, frontmatter, the REQUIRED-NEXT phase
# chain, agent spawn wiring, rule path-scoping, and a clean manifest (no MCP/userConfig).
# Run: evals/conformance.sh   (exit 0 iff all checks pass)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }
fm()  { awk 'NR==1&&/^---/{f=1;next} /^---/{exit} f' "$1"; }   # print frontmatter block

echo "== P2/P6 conformance =="

# C1 — exactly 9 skills (workflow + init + discover + 6 phases: brainstorm/spec/plan/implement/review/learn)
SK=$(ls -1d "$ROOT"/skills/*/ 2>/dev/null | wc -l | tr -d ' ')
[ "$SK" = "9" ] && ok "9 skills present" || bad "expected 9 skills, found $SK"

# C2 — every skill has name + description frontmatter
for d in "$ROOT"/skills/*/; do n=$(basename "$d"); f="$d/SKILL.md"
  if [ -f "$f" ] && fm "$f" | grep -q '^name:' && fm "$f" | grep -q '^description:'; then
    ok "skill frontmatter: $n"; else bad "skill frontmatter missing: $n"; fi
done

# C3 — REQUIRED-NEXT phase chain is complete (one skill per phase, self-sequencing)
chain() { grep -q "claudehut:$2" "$ROOT/skills/$1/SKILL.md" && ok "chain $1 → $2" || bad "chain $1 → $2 (missing)"; }
chain claudehut-workflow discover
chain discover brainstorm
chain brainstorm write-spec
chain write-spec write-plan
chain write-plan implement
chain implement review
chain review capture-learnings

# C4 — exactly 12 agents, each with name + description (v0.7 adds claudehut-plan-reviewer)
AG=$(ls -1 "$ROOT"/agents/*.md 2>/dev/null | wc -l | tr -d ' ')
[ "$AG" = "12" ] && ok "12 agents present" || bad "expected 12 agents, found $AG"
for f in "$ROOT"/agents/*.md; do n=$(basename "$f" .md)
  if fm "$f" | grep -q '^name:' && fm "$f" | grep -q -E '^description:'; then ok "agent frontmatter: $n"; else bad "agent frontmatter: $n"; fi
done

# C5 — implementer preloads [implement]; brainstorm+review dispatch existing agents
fm "$ROOT/agents/claudehut-implementer.md" | grep -A2 '^skills:' | grep -q 'implement' \
  && ok "implementer preloads implement skill" || bad "implementer skills: [implement] missing"
for a in claudehut-explorer claudehut-reuse-scanner claudehut-brainstormer \
         claudehut-test-runner claudehut-reviewer claudehut-security-auditor \
         claudehut-perf-reviewer claudehut-db-reviewer claudehut-planner claudehut-learner; do
  [ -f "$ROOT/agents/$a.md" ] && ok "agent exists: $a" || bad "agent missing: $a"
done

# C6 — rule layer: 2 always-on + 51 domain; every domain rule path-scoped
# (v0.4 Issue-4 additions: transaction-propagation, virtual-threads, postgres-locking, jwt-validation)
RT=$(find "$ROOT/templates/rules" -name '*.md' | wc -l | tr -d ' ')
[ "$RT" = "53" ] && ok "53 rule templates (51 domain + 2 always-on)" || bad "expected 53 rule templates, found $RT"
nopaths=0
for f in $(find "$ROOT/templates/rules" -mindepth 2 -name '*.md'); do
  fm "$f" | grep -q '^paths:' || { nopaths=$((nopaths+1)); echo "      (no paths: $f)"; }
done
[ "$nopaths" = "0" ] && ok "all domain rules path-scoped (paths:)" || bad "$nopaths domain rules missing paths:"
for r in project-structure vocabulary; do
  [ -f "$ROOT/templates/rules/$r.md" ] && ok "always-on rule: $r" || bad "always-on rule missing: $r"; done

# C7 — manifest correctness: valid JSON; must NOT re-declare default-location component keys
# (re-declaring agents/ or hooks/hooks.json makes `--plugin-dir` reject the manifest / throw a
#  duplicate-hooks load error — the standard locations are auto-discovered). MCP fully removed.
PJ="$ROOT/.claude-plugin/plugin.json"
if jq -e . "$PJ" >/dev/null 2>&1; then ok "plugin.json valid JSON"; else bad "plugin.json invalid JSON"; fi
jq -e '(has("agents")|not) and (has("hooks")|not)' "$PJ" >/dev/null 2>&1 \
  && ok "manifest does not re-declare default agents/ or hooks/ (avoids runtime load failure)" \
  || bad "manifest re-declares agents/hooks — runtime --plugin-dir load WILL fail (see EVAL-REPORT P6)"
jq -e '(has("mcpServers")|not) and (has("userConfig")|not)' "$PJ" >/dev/null 2>&1 \
  && ok "manifest has no mcpServers/userConfig (MCP opt-in)" || bad "manifest still declares mcpServers/userConfig"
# default component locations exist (auto-discovered at load)
[ -f "$ROOT/hooks/hooks.json" ] && ok "default hooks/hooks.json present (auto-discovered)" || bad "hooks/hooks.json missing"
[ -d "$ROOT/agents" ] && ok "default agents/ present (auto-discovered)" || bad "agents/ missing"
[ ! -f "$ROOT/.mcp.json" ] && ok "no shipped .mcp.json" || bad ".mcp.json should not be shipped"
[ -f "$ROOT/templates/mcp-recommendations.md" ] && ok "MCP recommendation catalog present" || bad "mcp-recommendations.md missing"

# C8 — Implement orchestrates PHASE BY PHASE (Issue 1 fix: no single-implementer collapse on multi-task plans)
IMP="$ROOT/skills/implement/SKILL.md"
grep -qi 'PHASE BY PHASE' "$IMP" \
  && ok "implement: phase-by-phase orchestration is the default" \
  || bad "implement: missing phase-by-phase orchestration default (Issue 1 regression risk)"
grep -qi 'phase-batch boundaries' "$IMP" \
  && ok "implement: native task list updated at phase boundaries (main-thread only)" \
  || bad "implement: missing phase-boundary task-update rule"
# planner must mark EVERY intra-phase-independent task [P], not just one (avoids serialized Implement)
grep -qi 'EVERY task that has no dependency' "$ROOT/agents/claudehut-planner.md" \
  && ok "planner: marks every intra-phase-independent task [P]" \
  || bad "planner: missing 'mark every intra-phase-independent task [P]' rule (under-marking serializes Implement)"
# plan template MUST use interleaved ### Phase headings (a trailing phase list collapses check-disjoint's
# per-phase grouping → cross-phase false-positive → serialized Implement; verified in worktree-tests plan5)
PT="$ROOT/skills/write-plan/references/plan-template.md"
[ "$(grep -cE '^### Phase [0-9]' "$PT")" -ge 2 ] \
  && ok "plan template: interleaved ### Phase headings (check-disjoint groups correctly)" \
  || bad "plan template: not using interleaved ### Phase headings — collapses per-phase dispatch"
# C9 — worktree base: init sets baseRef=head; skill/agent say worktrees carry committed prior-phase work
# (v0.5.0: default origin/HEAD base forced dependent later phases inline). No stale 'branches from origin/HEAD'.
grep -q 'worktree.baseRef' "$ROOT/bin/claudehut-init" && grep -q '"head"' "$ROOT/bin/claudehut-init" \
  && ok "init writes worktree.baseRef=head (worktrees fork from current HEAD)" \
  || bad "init does not set worktree.baseRef=head — dependent phases will be forced inline"
grep -qi 'baseRef=head' "$IMP" && grep -qi 'commit-before-dependent-dispatch' "$IMP" \
  && ok "implement: baseRef=head + commit-before-dependent-dispatch documented" \
  || bad "implement: missing baseRef=head / commit-before-dependent-dispatch (v0.5.0 fan-out fix)"
if grep -rqn 'branches from `origin/HEAD`' "$ROOT/skills" "$ROOT/agents" 2>/dev/null; then
  bad "stale 'branches from origin/HEAD' in skills/agents — model will preemptively inline dependent phases"
else ok "no stale 'branches from origin/HEAD' in skills/agents"; fi

# C10 — MCP tool names in agent frontmatter match real server tool names.
# postgres MCP (@modelcontextprotocol/server-postgres v0.6.2) exposes exactly ONE tool: "query".
# mysql MCP (mcp-server-mysql v1.0.42) exposes exactly ONE tool: "mysql_query".
# list_tables and describe_table are MCP Resources (ListResourcesRequestSchema), NOT Tools —
# referencing them as tool names in the allowlist silently fails at runtime (tool calls rejected).
# perf-reviewer and security-auditor must declare kafka tools (they are the Kafka primary reviewers).
for f in "$ROOT"/agents/*.md; do n=$(basename "$f" .md)
  if fm "$f" | grep -q 'mcp__postgres__list_tables\|mcp__postgres__describe_table'; then
    bad "agent $n: mcp__postgres__list_tables/describe_table are MCP Resources not Tools — use mcp__postgres__query with SQL"
  else ok "agent $n: no bogus postgres resource-as-tool names"; fi
  if fm "$f" | grep -q 'mcp__mysql__list_tables\|mcp__mysql__describe_table'; then
    bad "agent $n: mcp__mysql__list_tables/describe_table are MCP Resources not Tools — use mcp__mysql__mysql_query with SQL"
  else ok "agent $n: no bogus mysql resource-as-tool names"; fi
done
for a in claudehut-perf-reviewer claudehut-security-auditor; do
  fm "$ROOT/agents/$a.md" | grep -q 'mcp__kafka__consumer_group_lag' \
    && ok "$a: kafka tool allowlist present" \
    || bad "$a: missing mcp__kafka__consumer_group_lag — Kafka review is zero at runtime when server connected"
done
# bootstrap.sh must use .id field (not .name) for understand-anything detection
grep -q 'startswith("understand-anything@")' "$ROOT/scripts/bootstrap.sh" \
  && ok "bootstrap.sh: understand-anything detection uses .id field (correct)" \
  || bad "bootstrap.sh: understand-anything detection uses .name field which does not exist in plugin list JSON"

# C11 — v0.6.0 upgrade wiring (slash skill-rail, failure capture, minimalism layer, distribution)
HJ="$ROOT/hooks/hooks.json"
jq -e '[.hooks.UserPromptExpansion[]?.hooks[]?.command] | any(test("record-skill-expansion"))' "$HJ" >/dev/null 2>&1 \
  && ok "P1-3: UserPromptExpansion → record-skill-expansion.sh wired (slash skill-rail bypass closed)" \
  || bad "P1-3: no UserPromptExpansion recorder — /claudehut:implement bypasses the skill rail"
jq -e '[.hooks.PostToolUseFailure[]?.hooks[]?.command] | any(test("record-failure"))' "$HJ" >/dev/null 2>&1 \
  && ok "C3: PostToolUseFailure → record-failure.sh wired (failure signal capture)" \
  || bad "C3: PostToolUseFailure not wired to record-failure.sh"
for s in record-skill-expansion.sh record-failure.sh load-probe.sh; do
  [ -x "$ROOT/scripts/$s" ] && ok "script present+exec: $s" || bad "missing or non-exec: scripts/$s"
done
{ [ -f "$ROOT/skills/implement/references/minimalism.md" ] && grep -q 'minimalism.md' "$IMP"; } \
  && ok "D3: minimalism playbook present + wired into implement table" \
  || bad "D3: minimalism playbook missing or not referenced in implement skill"
{ grep -q 'framework' "$ROOT/agents/claudehut-reuse-scanner.md" && grep -qiE 'decision ladder|need-to-exist|YAGNI' "$ROOT/agents/claudehut-reuse-scanner.md"; } \
  && ok "D1: reuse-scanner carries the necessity+framework decision ladder" \
  || bad "D1: reuse-scanner missing the decision ladder"
grep -qiE 'over-engineering|minimalism' "$ROOT/agents/claudehut-reviewer.md" \
  && ok "D2: reviewer carries the minimalism/over-engineering lens" \
  || bad "D2: reviewer missing the minimalism lens"
grep -q 'worktreeinclude' "$ROOT/bin/claudehut-init" \
  && ok "C1: init emits .worktreeinclude (native gitignored-config copy into agent worktrees)" \
  || bad "C1: init does not emit .worktreeinclude"
{ grep -q 'taipt1504/claudehut' "$ROOT/.claude-plugin/plugin.json" \
  && ! grep -q 'github.com/claudehut/claudehut' "$ROOT/.claude-plugin/plugin.json"; } \
  && ok "P0-1: plugin.json repository points to the real repo (not the 404 mirror)" \
  || bad "P0-1: plugin.json repository still the 404 mirror"

# C12 — v0.7 Spine (Doc-as-Contract, Issue 4): plan carries HOW (Implementation Flow + per-task Sketch)
# and an adversarial doc-reviewer gates it before the user approval gate.
grep -q '## 3. Implementation Flow' "$PT" \
  && ok "S1: plan template has §3 Implementation Flow (the HOW a reviewer reads)" \
  || bad "S1: plan template missing §3 Implementation Flow — plan lists files but not HOW (Issue 4)"
grep -qi 'per-task Sketch' "$PT" && grep -qi 'no.placeholder' "$PT" \
  && ok "S2: plan template requires per-task Sketch with no-placeholder rule" \
  || bad "S2: plan template missing per-task Sketch / no-placeholder rule"
[ -f "$ROOT/agents/claudehut-plan-reviewer.md" ] \
  && fm "$ROOT/agents/claudehut-plan-reviewer.md" | grep -q '^name: claudehut-plan-reviewer' \
  && ok "S3: claudehut-plan-reviewer agent present" \
  || bad "S3: claudehut-plan-reviewer agent missing"
grep -q 'claudehut-plan-reviewer' "$ROOT/skills/write-plan/SKILL.md" \
  && ok "S4: write-plan dispatches plan-reviewer before the approval gate" \
  || bad "S4: write-plan does not wire the plan-reviewer doc gate"
grep -qi 'right-size' "$PT" \
  && ok "S5: plan template right-sizes detail by tier (token discipline preserved)" \
  || bad "S5: plan template missing right-size-by-tier rule (token regression risk)"

# C13 — v0.7 Enforcement (Issue 6): Review's Standards axis catches semantic-convention defects a lenient
# review drops (FQN-in-declaration, cross-file duplication) — NOT dismissed as "style nits".
RVA="$ROOT/agents/claudehut-reviewer.md"; RVS="$ROOT/skills/review/SKILL.md"
{ grep -qi 'fully-qualified' "$RVA" && grep -qi 'duplicat' "$RVA"; } \
  && ok "E1: reviewer agent checks FQN-in-declaration + cross-file duplication (Standards axis)" \
  || bad "E1: reviewer missing FQN/duplication Standards-axis checks (Issue 6)"
{ grep -qi 'two axes' "$RVA" || grep -qi 'Standards axis' "$RVA"; } \
  && ok "E2: reviewer scores both Spec/Enforcement and Standards axes" \
  || bad "E2: reviewer missing the two-axis split"
{ grep -qi 'Standards' "$RVS" && grep -qi 'duplicat' "$RVS"; } \
  && ok "E3: review skill rigor contract binds the Standards axis (FQN/duplication/naming)" \
  || bad "E3: review skill still drops semantic convention as 'style nits'"

# C14 — v0.7 Cognition (Issue 2): reuse-scan judges Fit + Impact (semantic), not just existence; scanner
# reasons (ultrathink) at higher effort instead of grep-matching signatures.
RST="$ROOT/skills/discover/references/reuse-scan-template.md"; RSC="$ROOT/agents/claudehut-reuse-scanner.md"
{ grep -qi '| Fit |' "$RST" && grep -qi 'Impact' "$RST"; } \
  && ok "G1: reuse-scan template scores Fit + Impact (semantic suitability, not just existence)" \
  || bad "G1: reuse-scan template missing Fit/Impact columns (Issue 2)"
{ grep -qi 'ultrathink' "$RSC" && grep -qi 'Fit' "$RSC"; } \
  && ok "G2: reuse-scanner reasons (ultrathink) about Fit before deciding" \
  || bad "G2: reuse-scanner missing ultrathink/Fit reasoning"
fm "$RSC" | grep -q 'effort: high' \
  && ok "G3: reuse-scanner runs at effort:high (reuse is judgment, not grep)" \
  || bad "G3: reuse-scanner still at low/medium effort — too shallow for fit/impact judgment"

# C15 — v0.7 Cognition (Issue 1): Implement reasons before coding (ultrathink + design beat: reuse?
# simplest shape? don't duplicate?) instead of writing rote first-thing-that-compiles code.
{ grep -qi 'ultrathink' "$IMP" && grep -qi 'design beat' "$IMP"; } \
  && ok "G4: implement skill has the ultrathink design beat (reuse/simplest/don't-duplicate before GREEN)" \
  || bad "G4: implement skill missing the design beat (Issue 1 — rote code risk)"
{ grep -qi 'ultrathink' "$ROOT/agents/claudehut-implementer.md" && grep -qi 'design beat' "$ROOT/agents/claudehut-implementer.md"; } \
  && ok "G5: implementer agent has the ultrathink design beat" \
  || bad "G5: implementer agent missing the design beat"

# C16 — v0.7 Memory-Loop (Issue 7): measurable learning. Quality-gate + recurrence (effectiveness) in the
# engine; a deterministic scoreboard script + an on-demand command surface the metrics.
ML="$ROOT/scripts/merge-learnings.sh"
{ grep -qi 'QUALITY GATE' "$ML" && grep -qi 'recurrence' "$ML"; } \
  && ok "M1: merge-learnings quality-gates candidates + counts recurrence (effectiveness signal)" \
  || bad "M1: merge-learnings missing quality-gate / recurrence (Issue 7)"
grep -q 'rejected' "$ML" && grep -q 'recurred' "$ML" \
  && ok "M2: merge report includes {rejected, recurred}" \
  || bad "M2: merge report missing rejected/recurred fields"
# M3/M4 BEHAVIORAL (v0.7 de-vacuum): run learning-score.sh over a KNOWN fixture store and assert it
# COMPUTES the right metrics — not that the file exists / contains the word 'HONESTY'.
if [ -x "$ROOT/scripts/learning-score.sh" ]; then
  MT="$(mktemp -d)"; mkdir -p "$MT/.claude/claudehut"
  printf '%s\n' \
    '{"id":"L-0001","category":"pitfall","trigger":"jpa","learning":"X @EntityGraph","evidence":"A.java:1","confidence":0.9,"hits":6,"promoted":true,"recurrence":2}' \
    '{"id":"L-0002","category":"convention","trigger":"naming","learning":"Y","evidence":"B.java:2","confidence":0.7,"hits":2}' \
    > "$MT/.claude/claudehut/learnings.jsonl"
  MOUT="$(CLAUDE_PROJECT_DIR="$MT" bash "$ROOT/scripts/learning-score.sh" 2>/dev/null || true)"
  printf '%s' "$MOUT" | grep -qE 'Store size +2' \
    && ok "M3: learning-score COMPUTES store size from the real store (behavioral, not grep)" \
    || bad "M3: learning-score did not compute store size=2 from fixture"
  printf '%s' "$MOUT" | grep -qE 'recurred 2' \
    && ok "M4: learning-score COMPUTES effectiveness/recurrence total from the store (behavioral)" \
    || bad "M4: learning-score did not compute recurrence total=2"
  rm -rf "$MT"
else bad "M3/M4: learning-score.sh missing or non-exec"; fi
[ -f "$ROOT/commands/claudehut-learning-report.md" ] \
  && grep -q 'learning-score.sh' "$ROOT/commands/claudehut-learning-report.md" \
  && ok "M5: /claudehut:claudehut-learning-report command wired to the scoreboard" \
  || bad "M5: learning-report command missing or not wired"

# C17 — v0.7 Enforcement (Issue 5): semantic reuse/duplication has an auditor (review) AND a Tier-A signal
# (PostToolUse lint-reuse advisory) — "a rule with neither gate nor auditor doesn't exist".
[ -x "$ROOT/scripts/lint-reuse.sh" ] \
  && ok "N1: lint-reuse.sh present + executable" || bad "N1: lint-reuse.sh missing or non-exec"
jq -e '[.hooks.PostToolUse[]?.hooks[]?.command] | any(test("lint-reuse"))' "$HJ" >/dev/null 2>&1 \
  && ok "N2: lint-reuse.sh wired as PostToolUse(Write|Edit) advisory" \
  || bad "N2: lint-reuse.sh not wired into PostToolUse"
{ grep -qi 'reinvented-stdlib' "$ROOT/scripts/lint-reuse.sh" && grep -qi 'duplicate' "$ROOT/scripts/lint-reuse.sh"; } \
  && ok "N3: lint-reuse flags reinvented-stdlib + cross-file duplicate" \
  || bad "N3: lint-reuse missing duplicate/reinvented-stdlib detection"
grep -qi 'reuse suspects' "$RVS" \
  && ok "N4: review pastes reuse-suspects into the auditor prompt (confirm/clear each)" \
  || bad "N4: review does not consume lint-reuse suspects"
grep -qi 'Completion criterion' "$IMP" \
  && ok "N5: implement makes create-time playbook-read a completion criterion" \
  || bad "N5: implement create-time playbook-read not a binding criterion"

# C18 — v0.7 BENCHMARK FIX (textual→behavioral): artifact oracles parse PRODUCED artifacts and fail on
# vacuous output, making the Cognition/Standards guarantees regression-catchable (the merge-learnings pattern
# extended per the advisor's central recommendation). The self-test proves the oracles discriminate.
[ -f "$ROOT/evals/lib/artifact-checks.sh" ] \
  && ok "O1: artifact-checks.sh oracle library present" || bad "O1: artifact-checks.sh missing"
if bash "$ROOT/evals/artifact-oracle-tests.sh" >/dev/null 2>&1; then
  ok "O2: artifact-oracle self-test passes — oracles DISCRIMINATE good vs vacuous (reuse-scan Fit, plan placeholders, brainstorm persistence, review Standards-axis)"
else bad "O2: artifact-oracle self-test FAILED — cognition oracles do not discriminate"; fi
{ [ -f "$ROOT/evals/tasks/review-standards-axis/oracle.sh" ] && [ -f "$ROOT/evals/tasks/review-standards-axis/task.md" ]; } \
  && ok "O3: live review-standards-axis fixture present (R6 headline: FQN + cross-file duplication)" \
  || bad "O3: review-standards-axis fixture missing"
grep -q 'artifact-checks.sh' "$ROOT/evals/tasks/review-standards-axis/oracle.sh" \
  && ok "O4: R6 fixture oracle reuses the artifact-check library" \
  || bad "O4: R6 fixture oracle does not source artifact-checks.sh"

# C19 — v0.7 reuse-suspect review-loop GATE (R5 AC4, BEHAVIORAL): set-review pass must REFUSE while a
# lint-reuse-staged suspect is unaddressed in review.md, and ALLOW once addressed. Advisory→real gate.
grep -q 'reuse-suspect loop gate' "$ROOT/bin/claudehut-state" \
  && ok "R1: set-review carries the reuse-suspect loop gate" || bad "R1: suspect loop gate missing from set-review"
RT="$(mktemp -d)"; RSD="$RT/.claude/claudehut"; mkdir -p "$RSD/state" "$RSD/tasks/0001-x"
RV="$RSD/tasks/0001-x/review.md"
printf '%s\n' '| item | status | evidence |' '| N+1 | ✓ satisfied | A.java:1 |' './gradlew test — 5 passed' > "$RV"
printf '%s\n' '{"file":"src/main/java/com/x/Dup.java","kind":"duplicate","detail":"d"}' > "$RSD/state/ses-x.suspects.jsonl"
printf '%s' '{"session":"ses-x","review":"pending"}' > "$RSD/state/ses-x.json"
if CLAUDE_PROJECT_DIR="$RT" "$ROOT/bin/claudehut-state" --session ses-x set-review pass --evidence .claude/claudehut/tasks/0001-x/review.md >/dev/null 2>&1; then
  bad "R2: set-review pass ALLOWED with an unaddressed suspect (gate not firing)"
else ok "R2: set-review pass REFUSED while a staged suspect is unaddressed"; fi
printf '%s\n' '| duplication | ✗ violated | src/main/java/com/x/Dup.java:3 dup |' >> "$RV"
if CLAUDE_PROJECT_DIR="$RT" "$ROOT/bin/claudehut-state" --session ses-x set-review pass --evidence .claude/claudehut/tasks/0001-x/review.md >/dev/null 2>&1; then
  ok "R3: set-review pass ALLOWED once the suspect is addressed in review.md"
else bad "R3: set-review pass still refused after addressing the suspect"; fi
rm -rf "$RT"

# C20 — v0.7 P2 LLM-judge tier (money-gated): verifies the cognition claim artifact-grep can't (reuse-scanner
# REASONS about contract fit, not surface keyword). Infra + a FREE parser self-test prove the plumbing; the
# live judge spend is opt-in.
[ -f "$ROOT/evals/judge/rubric-reuse-reasoning.md" ] && [ -x "$ROOT/evals/llm-judge.sh" ] \
  && [ -d "$ROOT/evals/tasks/reuse-semantic-judgment/repo" ] \
  && ok "J1: LLM-judge tier present (rubric + runner + held-out fixture)" \
  || bad "J1: LLM-judge tier incomplete (rubric/runner/fixture)"
if bash "$ROOT/evals/llm-judge.sh" --self-test >/dev/null 2>&1; then
  ok "J2: LLM-judge verdict-parser self-test passes (threshold + prose-tolerant + fails-safe)" \
  ; else bad "J2: LLM-judge parser self-test FAILED"; fi

# C12 — score.sh credits the CANONICAL per-task store (regression for the false-fail #5:
# artifacts in tasks/NNNN-<slug>/ were scored as misses because score.sh read only flat paths)
SW="$(mktemp -d)"; mkdir -p "$SW/.claude/claudehut/tasks/0001-x"
printf '{"id":"L-1"}\n' > "$SW/.claude/claudehut/learnings.jsonl"
for a in reuse-scan spec plan; do echo x > "$SW/.claude/claudehut/tasks/0001-x/$a.md"; done
TD="$(mktemp -d)"   # empty task dir → score.sh skips the optional oracle
if bash "$ROOT/evals/score.sh" "$SW" "$TD" >/dev/null 2>&1; then
  ok "score.sh credits canonical tasks/*/{reuse-scan,spec,plan}.md (false-fail #5 fixed)"
else bad "score.sh does not credit the canonical tasks/*/ store"; fi
rm -rf "$SW" "$TD"

# C13 — run.sh dry-run with NO args must exit 0 (regression: "${args[@]}" on an empty array
# under `set -u` is an unbound-variable error on bash 3.2 / macOS — broke the run-all default)
if bash "$ROOT/evals/run.sh" >/dev/null 2>&1; then ok "run.sh dry-run (no args) exits 0 (bash-3.2 empty-array safe)"
else bad "run.sh dry-run errors with no args (empty-array under set -u — bash 3.2)"; fi

echo
echo "CONFORMANCE: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
