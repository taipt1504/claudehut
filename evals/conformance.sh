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

# C6 — rule layer: 2 always-on + 47 domain; every domain rule path-scoped
RT=$(find "$ROOT/templates/rules" -name '*.md' | wc -l | tr -d ' ')
[ "$RT" = "49" ] && ok "49 rule templates (47 domain + 2 always-on)" || bad "expected 49 rule templates, found $RT"
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

echo
echo "CONFORMANCE: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
