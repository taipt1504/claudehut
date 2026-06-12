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

# C4 — exactly 11 agents, each with name + description
AG=$(ls -1 "$ROOT"/agents/*.md 2>/dev/null | wc -l | tr -d ' ')
[ "$AG" = "11" ] && ok "11 agents present" || bad "expected 11 agents, found $AG"
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
# (v0.4.0: default origin/HEAD base forced dependent later phases inline). No stale 'branches from origin/HEAD'.
grep -q 'worktree.baseRef' "$ROOT/bin/claudehut-init" && grep -q '"head"' "$ROOT/bin/claudehut-init" \
  && ok "init writes worktree.baseRef=head (worktrees fork from current HEAD)" \
  || bad "init does not set worktree.baseRef=head — dependent phases will be forced inline"
grep -qi 'baseRef=head' "$IMP" && grep -qi 'commit-before-dependent-dispatch' "$IMP" \
  && ok "implement: baseRef=head + commit-before-dependent-dispatch documented" \
  || bad "implement: missing baseRef=head / commit-before-dependent-dispatch (v0.4.0 fan-out fix)"
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

echo
echo "CONFORMANCE: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
