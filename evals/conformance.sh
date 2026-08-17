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

# C1 — exactly 10 skills (workflow + init + discover + 6 phases: brainstorm/spec/plan/implement/review/learn,
# + summer-kb-setup). Counts what the plugin SHIPS (git-tracked), not whatever happens to sit in the working
# tree: an untracked work-in-progress skill is not part of the package, and reddening the whole suite over one
# is a false failure. Untracked dirs are still surfaced below as a notice, so a forgotten `git add` is visible.
# Falls back to the filesystem glob when git is unavailable (sanitized copies, tarball installs).
# Falls back to the glob whenever git yields NOTHING, not merely when git is absent: if the plugin sits
# inside an enclosing repo that does not track skills/, `rev-parse` succeeds while `ls-files` returns empty,
# which would both fail C1 spuriously and silently drop every mermaid assertion (they share this list).
skill_dirs() {
  local d out=""
  if command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    out="$(git -C "$ROOT" ls-files skills/ 2>/dev/null | awk -F/ 'NF>1 {print $2}' | sort -u)"
  fi
  if [ -z "$out" ]; then
    out="$(for d in "$ROOT"/skills/*/; do [ -d "$d" ] && basename "$d"; done | sort -u)"
  fi
  printf '%s\n' "$out" | grep -v '^$' || true
}
SK=$(skill_dirs | grep -c . | tr -d ' ')
[ "$SK" = "10" ] && ok "10 skills present (tracked)" || bad "expected 10 tracked skills, found $SK"
UNTRACKED_SKILLS="$(comm -13 <(skill_dirs) <(for d in "$ROOT"/skills/*/; do [ -d "$d" ] && basename "$d"; done | sort -u) 2>/dev/null | tr '\n' ' ')"
[ -z "${UNTRACKED_SKILLS// /}" ] \
  && ok "no untracked skill directories" \
  || echo "  note - untracked skill dir(s) present, not part of the package: ${UNTRACKED_SKILLS}"

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

# C4 — exactly 14 agents, each with name + description
# (v0.9 Rec 3 adds claudehut-observability-reviewer; Rec 2 adds claudehut-contract-reviewer)
AG=$(ls -1 "$ROOT"/agents/*.md 2>/dev/null | wc -l | tr -d ' ')
[ "$AG" = "14" ] && ok "14 agents present" || bad "expected 14 agents, found $AG"
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
# MEM-1 mode 2 — the learner is the ONLY writer of MEMORY.md, and inlining facts under "## Topics" instead
# of a one-line pointer is what put three real installs 9-36 KB over budget while passing any line count.
# The contract has to be stated where the writer reads it, and it is worth an assertion because there is no
# other mechanism: no script writes this file, so nothing else can enforce the shape.
LRN="$ROOT/agents/claudehut-learner.md"
grep -q '8192 bytes' "$LRN" && grep -q 'Never write the facts here' "$LRN" \
  && ok "MEM-1: learner carries the MEMORY.md byte budget + one-line-pointer contract" \
  || bad "MEM-1: learner may re-inline facts into the always-loaded index"
grep -q 'MEMORY-history.md' "$LRN" \
  && ok "MEM-1: learner is told to append per-task blocks to MEMORY-history.md" \
  || bad "MEM-1: learner still appends per-task blocks to the always-loaded index"
# RES-K5 — a plugin skill is invoked as <plugin>:<skill-dir>, so the skills in skills/claudehut-init/ and
# skills/claudehut-workflow/ are /claudehut:claudehut-init and /claudehut:claudehut-workflow. The short
# forms were printed in a SessionStart systemMessage and in the always-loaded digest, i.e. told to the user
# and to the model as if they worked. Same plugin-scoping defect the v0.10 agent_type fix closed.
if grep -rn '/claudehut:workflow\b\|/claudehut:init\b' "$ROOT/skills" "$ROOT/scripts" "$ROOT/README.md" >/dev/null 2>&1; then
  bad "RES-K5: an unscoped /claudehut:workflow or /claudehut:init survives in model- or user-facing text"
else
  ok "RES-K5: slash commands are plugin-scoped (/claudehut:claudehut-<skill>)"
fi
# SKILL-F5 — digest.md is what SessionStart injects, so when it and SKILL.md disagree the model is told the
# WRONG rule and the fuller SKILL.md is never read. Law 4 diverged exactly that way: the digest said entering
# Discover closes the skill rail, omitting Brainstorm. bin/claudehut-state:400 resets implement_skill_ok on
# `discover|brainstorm`, so the digest was the one that was wrong. Pin the digest to the CLI, then pin the two
# documents to each other so the next divergence is caught rather than shipped.
DG="$ROOT/skills/claudehut-workflow/references/digest.md"; WF="$ROOT/skills/claudehut-workflow/SKILL.md"
if grep -qE 'discover\|brainstorm\) STATE=.*implement_skill_ok=false' "$ROOT/bin/claudehut-state"; then
  grep -q 'Discover/Brainstorm' "$DG" \
    && ok "SKILL-F5: digest law 4 matches claudehut-state (both Discover and Brainstorm close the rail)" \
    || bad "SKILL-F5: digest law 4 omits a phase that claudehut-state:400 actually resets on"
else
  bad "SKILL-F5: claudehut-state no longer resets implement_skill_ok on discover|brainstorm — digest prose is now unpinned"
fi
# law HEADINGS must be the same set in both documents (normalised: number + bold title, punctuation stripped)
# Normalise hard: SKILL.md writes "**Canonical store — one dir per task.**" where the digest writes
# "**Canonical store**". Same law, more room. So compare the number plus the title's leading clause only,
# cut at the first '.' or em-dash, lowercased, alphanumerics only. What must not drift is the SET and the
# ORDER of the laws — a renumbered or dropped law, not a longer subtitle.
# Strip the "N. " numbering FIRST — otherwise the cut-at-first-period eats the whole title and the check
# degrades to "both files have 7 numbered items", which a renamed law would sail straight through.
laws_of(){ grep -oE '^[0-9]+\. \*\*[^*]+\*\*' "$1" \
             | sed -E -e 's/^([0-9]+)\. \*\*/\1|/' -e 's/\*\*.*$//' -e 's/[.—].*$//' \
             | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]|\n'; }
if [ "$(laws_of "$DG")" = "$(laws_of "$WF")" ]; then
  ok "SKILL-F5: digest and claudehut-workflow/SKILL.md carry the same law headings"
else
  bad "SKILL-F5: law headings diverged between the injected digest and SKILL.md"
fi

# RULE-09/10/11/12/18 — a rule that never matches a real filename is indistinguishable from a rule that is
# absent, and nothing in the corpus checks. These four pin the glob classes that were dead or over-broad.
if grep -rn '^  - "\*\*/\*"$' "$ROOT/templates/rules" >/dev/null 2>&1; then
  bad "RULE-09: a rule still globs \"**/*\" — it matches binaries, images and build output, not just code"
else
  ok "RULE-09: no rule globs bare \"**/*\""
fi
# JUnit5 + Spring convention is FooTests.java as often as FooTest.java (Spring's own codebase uses Tests),
# so a testing rule that omits it silently skips half the suites it exists to govern.
miss_t=0; for f in "$ROOT"/templates/rules/testing/*.md; do grep -q 'Tests\.java' "$f" || miss_t=$((miss_t+1)); done
[ "$miss_t" = "0" ] \
  && ok "RULE-18: every testing rule matches **/*Tests.java as well as *Test.java" \
  || bad "RULE-18: $miss_t testing rule(s) never fire on a *Tests.java suite"
# jpa.md governs entities; lombok-jpa-safety.md governs the same entities and already knew they live in
# entity/ and domain/ packages without an *Entity.java suffix. jpa.md must cover at least as much.
jp="$ROOT/templates/rules/framework/jpa.md"; lj="$ROOT/templates/rules/framework/lombok-jpa-safety.md"
missing_glob=0
while IFS= read -r g; do grep -qF "$g" "$jp" || missing_glob=$((missing_glob+1)); done < <(grep -E '^  - "' "$lj")
[ "$missing_glob" = "0" ] \
  && ok "RULE-12: jpa.md covers every entity path lombok-jpa-safety.md covers" \
  || bad "RULE-12: $missing_glob entity path(s) governed by lombok-jpa-safety but not by jpa.md"
# JSR-305 is unmaintained and its javax package is wrong on a Jakarta baseline; Hibernate 6 renamed the
# lock-timeout hint to jakarta.persistence.*. Allow the one line that names javax in order to forbid it.
# A rule may NAME javax in order to forbid it; the allow-list is the prohibition phrasing, so a line that
# teaches the API still has no excuse. Widened once, when jpa-locking.md legitimately warned about the
# Hibernate 5 hint key by name.
# `javax.money` (JSR-354) is carved out on purpose: it is not a Jakarta EE API, was never migrated, and
# the Moneta reference implementation still ships that exact package. The premise of this check —
# "javax.* is the pre-Jakarta name" — is simply false for it.
if grep -rn 'javax\.' "$ROOT/templates/rules" \
   | grep -qvE 'unmaintained|wrong package|Hibernate 5 name|silently ignored|no effect, no error|javax\.money'; then
  bad "RULE-18: a rule still teaches a javax.* API on a Jakarta/Boot-3 baseline"
else
  ok "RULE-18: rules name javax.* only to forbid it"
fi

# RULE-13 — @MockBean and @SpyBean are deprecated since Boot 3.4.0 and REMOVED in 4.0.0 in favour of
# Spring Framework's MockitoBean/MockitoSpyBean (verified against the Boot 3.4 API docs). A rule that teaches
# the removed annotation ages into a compile error rather than a style nit.
# Checked per FILE, not per line: the deprecation note legitimately wraps onto the following line, and a
# line-based check would demand the words share a line — a shape constraint, not a correctness one.
mb_bad=0
for f in $(grep -rl '@MockBean\|@SpyBean' "$ROOT/templates/rules" 2>/dev/null); do
  grep -q 'deprecated since Boot 3.4' "$f" || mb_bad=$((mb_bad+1))
done
[ "$mb_bad" = "0" ] \
  && ok "RULE-13: rules teach @MockitoBean; any @MockBean mention carries the 3.4 deprecation" \
  || bad "RULE-13: $mb_bad rule file(s) teach @MockBean/@SpyBean with no deprecation note"

# SKILL-F11 — two cross-cutting Spring conventions lived only in skills/implement/SKILL.md's always-loaded
# floor, so they were never enforced at edit time. Appended as ungated rows to an existing always-active rule
# rather than as a new file, which would force an RT bump for two bullets.
pl="$ROOT/templates/rules/architecture/package-layout.md"
grep -q 'Thin controllers' "$pl" && grep -q 'ConfigurationProperties' "$pl" \
  && ok "SKILL-F11: thin-controller + externalised-config rows present in an always-active rule" \
  || bad "SKILL-F11: the two cross-cutting conventions still exist only in the skill body"
grep -q '^stack:' "$pl" \
  && bad "SKILL-F11: package-layout.md became stack-gated — the two rows would stop being universal" \
  || ok "SKILL-F11: package-layout.md is still ungated (reaches every project)"

# RULE-02/07/08 — the three rules added in v0.11. Each is asserted on the property that made it worth
# adding, not merely on existence: money-arithmetic must be ungated (it applies to any Java), jpa-locking
# must be orm-gated (its annotations do not exist in R2DBC), outbound-resilience must be ungated.
mg="$ROOT/templates/rules/coding/money-arithmetic.md"
jl="$ROOT/templates/rules/performance/jpa-locking.md"
orl="$ROOT/templates/rules/framework/outbound-resilience.md"
{ [ -f "$mg" ] && ! grep -q '^stack:' "$mg" && grep -q 'RoundingMode' "$mg"; } \
  && ok "RULE-07: money-arithmetic present, ungated, names RoundingMode" \
  || bad "RULE-07: money-arithmetic missing, stack-gated, or silent on RoundingMode"
{ [ -f "$orl" ] && ! grep -q '^stack:' "$orl" && grep -q 'idempot' "$orl"; } \
  && ok "RULE-08: outbound-resilience present, ungated, ties retry to idempotency" \
  || bad "RULE-08: outbound-resilience missing, stack-gated, or silent on idempotent retry"
grep -q 'stack: "orm=jpa"' "$jl" \
  && ok "RULE-02: jpa-locking is gated orm=jpa (its annotations do not exist in R2DBC)" \
  || bad "RULE-02: jpa-locking is not orm-gated — it would install into R2DBC projects"
grep -qE '@Lock|@QueryHint|entityManager' "$ROOT/templates/rules/performance/postgres-locking.md" \
  && bad "RULE-02: JPA annotations still in postgres-locking.md, which is gated only on db=postgresql" \
  || ok "RULE-02: postgres-locking.md is client-agnostic (no JPA annotations)"

# C6 — rule layer: 2 always-on + 56 domain; every domain rule path-scoped
# (v0.4 Issue-4 additions: transaction-propagation, virtual-threads, postgres-locking, jwt-validation;
#  v0.9 Rec 3 adds observability/instrumentation, Rec 2 adds framework/contract-compat;
#  v0.11 adds coding/money-arithmetic, framework/outbound-resilience, performance/jpa-locking)
RT=$(find "$ROOT/templates/rules" -name '*.md' | wc -l | tr -d ' ')
[ "$RT" = "58" ] && ok "58 rule templates (56 domain + 2 always-on)" || bad "expected 58 rule templates, found $RT"
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
# LSP: the manifest may point at .lsp.json, which must carry the two REQUIRED fields — Claude Code silently
# SKIPS a server missing `command` or `extensionToLanguage`, visible only under `claude --debug`. It must also
# NOT set restartOnCrash/shutdownTimeout: those need v2.1.205+, and on older versions setting either makes
# Claude Code skip the server entirely, again silently.
if [ -f "$ROOT/.lsp.json" ]; then
  jq -e 'to_entries | all(.value | has("command") and has("extensionToLanguage"))' "$ROOT/.lsp.json" >/dev/null 2>&1 \
    && ok "LSP: every server declares command + extensionToLanguage (else silently skipped)" \
    || bad "LSP: a server in .lsp.json is missing command/extensionToLanguage"
  jq -e 'to_entries | all(.value | (has("restartOnCrash") or has("shutdownTimeout")) | not)' "$ROOT/.lsp.json" >/dev/null 2>&1 \
    && ok "LSP: no restartOnCrash/shutdownTimeout (pre-2.1.205 would skip the server)" \
    || bad "LSP: restartOnCrash/shutdownTimeout set — skipped entirely before CC v2.1.205"
  [ "$(jq -r '.lspServers // empty' "$PJ" 2>/dev/null)" = "./.lsp.json" ] \
    && ok "LSP: plugin.json points at ./.lsp.json" || bad "LSP: .lsp.json shipped but manifest does not reference it"
fi
[ -f "$ROOT/templates/mcp-recommendations.md" ] && ok "MCP recommendation catalog present" || bad "mcp-recommendations.md missing"

# C8 — Implement orchestrates PHASE BY PHASE (Issue 1 fix: no single-implementer collapse on multi-task plans)
IMP="$ROOT/skills/implement/SKILL.md"
grep -qi 'PHASE BY PHASE' "$IMP" \
  && ok "implement: phase-by-phase orchestration is the default" \
  || bad "implement: missing phase-by-phase orchestration default (Issue 1 regression risk)"
grep -qi 'phase-batch boundaries' "$IMP" \
  && ok "implement: native task list updated at phase boundaries (main-thread only)" \
  || bad "implement: missing phase-boundary task-update rule"
# C8b — the orchestration mechanism moved to references/orchestration.md so it stops being preloaded into
# every implementer (which has no Agent or task tools and cannot act on it). The greps above then match a
# SUMMARY, so they would stay green even if the skill degraded into a bare pointer. These three assertions are
# what keep that from happening: the reference must exist, carry the mechanism, and be reachable by a hard
# precondition in the skill body — not an optional "see also".
# C8c — shipped rule templates must not cite plugin files that do not exist. bin/claudehut-init copies these
# into every initialized project, so a dangling path is advice the reader cannot follow, and three of them
# described enforcement (a validate-migration.sh, a lombok.config.tmpl) that was never built. Only
# plugin-root-relative prefixes are checked; .claude/** and src/** are project paths, not plugin paths.
# C8d — background-subagent tool allowlist. Subagents run in the background by default, and a background
# subagent keeps only a fixed set of built-in tools; Claude Code removes any other built-in from the `tools:`
# list SILENTLY (no error unless the list resolves to nothing). So a declared tool outside this set is a
# capability the agent quietly does not have. MCP tools (mcp__*) are always kept. Encodes
# https://code.claude.com/docs/en/sub-agents as fetched 2026-08-10 — re-check when that page changes.
BG_OK=" Read Grep Glob Bash PowerShell Edit Write NotebookEdit WebFetch WebSearch TodoWrite Skill ToolSearch EnterWorktree ExitWorktree Monitor TaskStop SendMessage Artifact Agent ExitPlanMode "
BAD_TOOLS=""
for f in "$ROOT"/agents/*.md; do
  [ -f "$f" ] || continue
  fm "$f" | grep -q '^background: *true' && continue          # foreground agents keep the full set
  tl="$(fm "$f" | sed -n 's/^tools: *//p' | head -1)"
  [ -n "$tl" ] || continue
  for tool in $(printf '%s' "$tl" | tr ',' ' '); do
    case "$tool" in mcp__*|'') continue ;; esac
    case "$BG_OK" in *" $tool "*) : ;; *) BAD_TOOLS="$BAD_TOOLS $(basename "$f" .md):$tool" ;; esac
  done
done
[ -z "${BAD_TOOLS// /}" ] && ok "agent tools: are all kept for background subagents" \
  || bad "agent declares a tool silently dropped in the background:$BAD_TOOLS"

DANGLING=""
for f in "$ROOT"/templates/rules/*/*.md "$ROOT"/templates/rules/*.md; do
  [ -f "$f" ] || continue
  for ref in $(grep -oE '`(scripts|skills|bin|agents|hooks|commands|evals|templates)/[A-Za-z0-9._/-]+`' "$f" 2>/dev/null | tr -d '`' | sort -u); do
    [ -e "$ROOT/$ref" ] || DANGLING="$DANGLING ${f#"$ROOT"/}:$ref"
  done
done
[ -z "${DANGLING// /}" ] && ok "rule templates cite no missing plugin files" \
  || bad "rule template cites a nonexistent plugin path:$DANGLING"

ORCH="$ROOT/skills/implement/references/orchestration.md"
{ [ -f "$ORCH" ] && grep -qi 'check-disjoint' "$ORCH" && grep -qi 'reconcile' "$ORCH"; } \
  && ok "implement: references/orchestration.md exists and carries the phase-walk mechanism" \
  || bad "implement: orchestration.md missing or does not carry the mechanism"
grep -qi 'Read `references/orchestration.md` BEFORE dispatching' "$IMP" \
  && ok "implement: skill body states the HARD precondition to read orchestration.md before dispatch" \
  || bad "implement: precondition to read orchestration.md is missing — the stub is a bare pointer"
grep -qi 'never hand a whole plan to one implementer' "$IMP" \
  && ok "implement: single-implementer collapse still forbidden in the always-loaded body" \
  || bad "implement: the no-collapse rule was lost in the extraction (Issue 1 regression)"
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

# C10 — MCP tool names in agent frontmatter must match the REAL tool names of the recommended servers.
# A wrong name is not an error anyone sees: the call is rejected at runtime, so the reviewer silently
# degrades to a static review while appearing configured. Verified against tagged releases:
#   postgres  crystaldba/postgres-mcp v0.3.0 — there is NO tool named "query"; it is execute_sql. The
#             previously recommended @modelcontextprotocol/server-postgres is DEPRECATED on npm.
#   kafka     @confluentinc/mcp-confluent v1.5.0 — tool names are HYPHENATED and survive into the
#             mcp__kafka__<tool> string. No describe-topic equivalent exists on a self-managed cluster.
#   mysql     mcp-server-mysql v1.0.42 — exactly one tool: mysql_query.
# list_tables/describe_table are MCP Resources, not Tools, under either postgres server.
for f in "$ROOT"/agents/*.md; do n=$(basename "$f" .md)
  if fm "$f" | grep -q 'mcp__postgres__list_tables\|mcp__postgres__describe_table'; then
    bad "agent $n: mcp__postgres__list_tables/describe_table are MCP Resources not Tools — use mcp__postgres__execute_sql"
  else ok "agent $n: no bogus postgres resource-as-tool names"; fi
  if fm "$f" | grep -q 'mcp__mysql__list_tables\|mcp__mysql__describe_table'; then
    bad "agent $n: mcp__mysql__list_tables/describe_table are MCP Resources not Tools — use mcp__mysql__mysql_query with SQL"
  else ok "agent $n: no bogus mysql resource-as-tool names"; fi
done
for a in claudehut-perf-reviewer claudehut-security-auditor; do
  fm "$ROOT/agents/$a.md" | grep -q 'mcp__kafka__get-consumer-group-lag' \
    && ok "$a: kafka tool allowlist present (consumer-group lag)" \
    || bad "$a: missing mcp__kafka__get-consumer-group-lag — Kafka review is zero at runtime when connected"
done
# No agent may declare a kafka tool the recommended server does not expose: describe-topic has no
# self-managed equivalent (get-topic-config is Confluent Cloud only and returns config, not partition
# layout), and get-partition-offsets appears in neither availability table.
if grep -rq 'mcp__kafka__[a-z]*_' "$ROOT"/agents/*.md 2>/dev/null; then
  bad "agent declares an underscored mcp__kafka__ tool — mcp-confluent tool names are hyphenated"
else ok "kafka tool names are hyphenated (match mcp-confluent v1.5.0)"; fi
if grep -rqE 'mcp__kafka__describe-topic|mcp__kafka__get-partition-offsets|mcp__postgres__query([^_-]|$)' "$ROOT"/agents/*.md 2>/dev/null; then
  bad "agent declares an MCP tool the recommended server does not expose"
else ok "no agent declares a nonexistent MCP tool"; fi
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
# C3b/C3c — the two observation hooks. Both are advisory recorders that inject nothing and never block, so a
# wiring mistake is otherwise invisible: the sidecar just stays empty while every eval still passes.
# C3d/C3e — schema-drift self-report. record-failure.sh reads .tool_error.{exit_code,type,stderr}; in
# production 682/682 staged records came back with all three empty, so the recorder was writing hollow
# rows and the harvest downstream had nothing to work with. Nothing detected that. When all three are
# empty the recorder now names the payload's actual top-level keys, so the next real failure identifies
# the correct fields itself. C3e pins the other half: a healthy payload must stay byte-identical, or
# every existing consumer of the sidecar sees a new field.
CFT="$(mktemp -d)"
printf '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"mvn test"},"unexpected_error_shape":{"code":2}}' \
  | CLAUDE_PROJECT_DIR="$CFT" bash "$ROOT/scripts/record-failure.sh" >/dev/null 2>&1
jq -e '.schema_keys | test("unexpected_error_shape")' "$CFT/.claude/claudehut/state/s1.failures.jsonl" >/dev/null 2>&1 \
  && ok "C3d: record-failure names the real payload keys when every known error path is empty" \
  || bad "C3d: schema drift stays silent — record-failure wrote a hollow row with no schema_keys"
printf '{"session_id":"s2","tool_name":"Bash","tool_input":{"command":"mvn test"},"tool_error":{"exit_code":1,"type":"x","stderr":"boom"}}' \
  | CLAUDE_PROJECT_DIR="$CFT" bash "$ROOT/scripts/record-failure.sh" >/dev/null 2>&1
jq -e 'has("schema_keys") | not' "$CFT/.claude/claudehut/state/s2.failures.jsonl" >/dev/null 2>&1 \
  && ok "C3e: a healthy failure payload records no schema_keys (sidecar shape unchanged)" \
  || bad "C3e: schema_keys leaked into a healthy record — downstream consumers see a new field"
rm -rf "$CFT"
jq -e '[.hooks.SubagentStart[]?.hooks[]?.command] | any(test("record-dispatch"))' "$HJ" >/dev/null 2>&1 \
  && ok "C3b: SubagentStart → record-dispatch.sh wired (dispatch observation)" \
  || bad "C3b: SubagentStart not wired to record-dispatch.sh"
jq -e '[.hooks.InstructionsLoaded[]?.hooks[]?.command] | any(test("record-rules-loaded"))' "$HJ" >/dev/null 2>&1 \
  && ok "C3c: InstructionsLoaded → record-rules-loaded.sh wired (rule-load ledger)" \
  || bad "C3c: InstructionsLoaded not wired to record-rules-loaded.sh"
for s in record-skill-expansion.sh record-failure.sh load-probe.sh record-dispatch.sh record-rules-loaded.sh; do
  [ -x "$ROOT/scripts/$s" ] && ok "script present+exec: $s" || bad "missing or non-exec: scripts/$s"
done
# ...and the two recorders must actually RECORD. Asserting only on wiring + [ -x ] left them unfalsifiable:
# replacing either body with `exit 0` kept every assertion green, while the sidecar they exist to produce
# stayed empty. These drive the real scripts and check the line lands.
HKT="$(mktemp -d)"
echo '{"session_id":"h","agent_type":"claudehut:claudehut-reviewer"}' \
  | CLAUDE_PROJECT_DIR="$HKT" bash "$ROOT/scripts/record-dispatch.sh" >/dev/null 2>&1
jq -e '.agent_type=="claudehut:claudehut-reviewer"' "$HKT/.claude/claudehut/state/h.dispatches.jsonl" >/dev/null 2>&1 \
  && ok "record-dispatch.sh writes the observed agent_type to its sidecar" \
  || bad "record-dispatch.sh produced no usable dispatch record"
echo '{"session_id":"h","file_path":".claude/rules/framework/jpa.md","load_reason":"path_glob_match"}' \
  | CLAUDE_PROJECT_DIR="$HKT" bash "$ROOT/scripts/record-rules-loaded.sh" >/dev/null 2>&1
jq -e '.file_path==".claude/rules/framework/jpa.md" and .load_reason=="path_glob_match"' \
  "$HKT/.claude/claudehut/state/h.rules-loaded.jsonl" >/dev/null 2>&1 \
  && ok "record-rules-loaded.sh writes file_path + load_reason to its sidecar" \
  || bad "record-rules-loaded.sh produced no usable rule-load record"
rm -rf "$HKT"
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
RVS="$ROOT/skills/review/SKILL.md"; RR="$ROOT/skills/review/references/review-rigor.md"
# WS-9: the rigor contract is the SINGLE SOURCE (references/review-rigor.md), cat into each dispatch prompt;
# the auditor bodies + the SKILL no longer restate it. Assert the content lives there + is referenced.
{ grep -qi 'fully-qualified' "$RR" && grep -qi 'duplicat' "$RR"; } \
  && ok "E1: rigor contract checks FQN-in-declaration + cross-file duplication (Standards axis)" \
  || bad "E1: rigor contract missing FQN/duplication Standards-axis checks (Issue 6)"
{ grep -qi 'two axes' "$RR" || grep -qi 'Standards' "$RR"; } \
  && ok "E2: rigor contract scores both Spec/Enforcement and Standards axes" \
  || bad "E2: rigor contract missing the two-axis split"
{ grep -q 'review-rigor' "$RVS" && grep -qi 'verbatim' "$RVS" && grep -qi 'Standards' "$RR"; } \
  && ok "E3: review skill BINDS the rigor contract into each dispatch (cat verbatim) + Standards axis present" \
  || bad "E3: review skill no longer binds the rigor contract verbatim into dispatch prompts"

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
# WS-5: "addressed" now means a RESOLUTION token on the suspect's row, not a bare mention.
printf '%s\n' '| duplication | ✗ violated | src/main/java/com/x/Dup.java:3 — resolved: extracted shared util |' >> "$RV"
if CLAUDE_PROJECT_DIR="$RT" "$ROOT/bin/claudehut-state" --session ses-x set-review pass --evidence .claude/claudehut/tasks/0001-x/review.md >/dev/null 2>&1; then
  ok "R3: set-review pass ALLOWED once the suspect is RESOLVED (WS-5 resolution token)"
else bad "R3: set-review pass still refused after resolving the suspect"; fi
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

# ============================================================================
# v0.8 P0 — enforcement teeth (each rich behavior bound to a gate OR auditor). BEHAVIORAL.
# Closes the meta root cause: gates checked structure-of-a-file, never quality-of-thinking.
# ============================================================================
echo "== v0.8 P0 gates =="
P0="$(mktemp -d)"; PD="$P0/.claude/claudehut/tasks/0001-demo"; mkdir -p "$PD" "$P0/.claude/claudehut/state"
ST="$ROOT/bin/claudehut-state"
runp() { CLAUDE_PROJECT_DIR="$P0" "$ST" --session p "$@" >/dev/null 2>&1; }

# WS-4 reuse-scan Fit/Impact content gate (the 0011 legacy 4-col scan would now be rejected)
printf '%s\n' '| Dimension | Existing | Decision | Effort |' '| slug | none | new | M |' > "$PD/reuse-scan.md"
runp set-reuse-scan --artifact .claude/claudehut/tasks/0001-demo/reuse-scan.md \
  && bad "P0/WS-4: reuse-scan ACCEPTED legacy 4-col (no Fit/Impact)" || ok "P0/WS-4: reuse-scan REJECTS legacy format (Fit/Impact required)"
printf '%s\n' '| Dimension | Existing | Decision | Fit | Impact | Effort |' '|---|---|---|---|---|---|' '| slug | TextUtils.slugify | adopt | 5 | low | S |' > "$PD/reuse-scan.md"
runp set-reuse-scan --artifact .claude/claudehut/tasks/0001-demo/reuse-scan.md \
  && ok "P0/WS-4: reuse-scan ACCEPTS v0.7 Fit/Impact format" || bad "P0/WS-4: reuse-scan rejected valid Fit/Impact"

# WS-3 brainstorm content gate (fixes "brainstorm follows no format")
printf '%s\n' '# B' '| Option | Score |' '|---|---|' '| A | 4 |' '## Premortem' 'x' '## Recommendation' 'A' > "$PD/brainstorm.md"
runp set-brainstorm .claude/claudehut/tasks/0001-demo/brainstorm.md \
  && bad "P0/WS-3: brainstorm ACCEPTED <2 options" || ok "P0/WS-3: brainstorm REJECTS <2 scored options"
printf '%s\n' '# B' '| Option | Score |' '|---|---|' '| A | 4 |' '| B | 3 |' '## Premortem' 'both' '## Recommendation' 'A' > "$PD/brainstorm.md"
runp set-brainstorm .claude/claudehut/tasks/0001-demo/brainstorm.md \
  && ok "P0/WS-3: brainstorm ACCEPTS ≥2 options + premortem + recommendation" || bad "P0/WS-3: brainstorm rejected valid deliberation"

# WS-4 spec acceptance-criteria gate
printf '%s\n' '# S' '## 1. Problem' 'x' '## 9. Decision' 'A' > "$PD/spec.md"
runp set-spec .claude/claudehut/tasks/0001-demo/spec.md \
  && bad "P0/WS-4: spec ACCEPTED with no AC-xxx" || ok "P0/WS-4: spec REJECTS missing acceptance criteria"
printf '%s\n' '# S' '## 1. Problem' 'x' '## 5. AC' '- AC-001 GIVEN a WHEN b THEN c' '## 9. Decision' 'A' > "$PD/spec.md"
runp set-spec .claude/claudehut/tasks/0001-demo/spec.md \
  && ok "P0/WS-4: spec ACCEPTS sections + Decision + AC-xxx" || bad "P0/WS-4: spec rejected valid"

# WS-4 plan structural gate (full tier: Implementation Flow + Sketch)
printf '%s\n' '# P' '| T-001 | x | tf | v | - |' > "$PD/plan.md"
runp set-plan .claude/claudehut/tasks/0001-demo/plan.md \
  && bad "P0/WS-4: plan ACCEPTED with no Impl-Flow/Sketch (full)" || ok "P0/WS-4: plan REJECTS missing Impl-Flow/Sketch (full tier)"

# WS-2 plan-reviewer hard gate (smart-gated): sensitive plan REQUIRES a fresh APPROVE
printf '%s\n' '# P' '## Implementation Flow' 'auth' '**T-001 sketch**: SecurityFilterChain' '| T-001 | security/auth | tf | v | - |' > "$PD/plan.md"
runp set-plan .claude/claudehut/tasks/0001-demo/plan.md \
  && bad "P0/WS-2: sensitive plan ACCEPTED without plan-reviewer APPROVE (issue 2 regressed)" || ok "P0/WS-2: sensitive plan REQUIRES plan-reviewer APPROVE (the issue-2 wire)"
printf '%s\n' '| Check | Status | Evidence |' '| AC-001 covered | ✓ | T-001 |' > "$PD/plan-review.md"
runp set-plan-review APPROVE --evidence .claude/claudehut/tasks/0001-demo/plan-review.md \
  && ok "P0/WS-2: set-plan-review APPROVE recorded (coverage table)" || bad "P0/WS-2: set-plan-review rejected a valid verdict"
runp set-plan .claude/claudehut/tasks/0001-demo/plan.md \
  && ok "P0/WS-2: sensitive plan ACCEPTED after fresh plan-review APPROVE" || bad "P0/WS-2: plan rejected despite APPROVE"
# smart-gate: a simple full-tier plan (1 task, non-sensitive) needs NO auditor (no latency tax — issue 5)
mkdir -p "$P0/.claude/claudehut/tasks/0002-simple"
printf '%s\n' '# P' '## Implementation Flow' 'x' '**T-001 sketch**: foo()' '| T-001 | A.java | tf | v | - |' > "$P0/.claude/claudehut/tasks/0002-simple/plan.md"
CLAUDE_PROJECT_DIR="$P0" "$ST" --session q set-plan .claude/claudehut/tasks/0002-simple/plan.md >/dev/null 2>&1 \
  && ok "P0/WS-2: simple full-tier plan ACCEPTED without auditor (smart-gate avoids the latency tax)" || bad "P0/WS-2: smart-gate over-fired on a simple plan"

# WS-8a set-review citation gate — a ✓ row must cite a locus
printf '%s\n' '| item | status | evidence |' '| x | ✓ satisfied | |' './gradlew test — 5 passed' > "$PD/review.md"
runp set-review pass --evidence .claude/claudehut/tasks/0001-demo/review.md \
  && bad "P0/WS-8a: review ACCEPTED an uncited ✓ row" || ok "P0/WS-8a: review REJECTS a ✓ row with no evidence locus"

# Fail-open: content gates degrade on a missing file (never wedge — the gate philosophy)
runp set-brainstorm .claude/claudehut/tasks/0001-demo/nonexistent.md \
  && ok "P0: fail-open — content gate on a missing file passes (never wedge)" || bad "P0: fail-open broken (missing-file rejected)"

# WS-1 off-path detector (inject-phase advisory): valid JSON, warns off-path, excludes research/
mkdir -p "$P0/.claude/prompt/0011-x" "$P0/.claude/prompt/research"
printf 'x\n' > "$P0/.claude/prompt/0011-x/spec.md"; printf 'x\n' > "$P0/.claude/prompt/research/plan.md"
printf '{"phase":"discover"}' > "$P0/.claude/claudehut/state/off.json"
echo '{"session_id":"off","prompt":"hi"}' | CLAUDE_PROJECT_DIR="$P0" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$ROOT/scripts/inject-phase.sh" 2>/dev/null > "$P0/ip.json"
jq -e . < "$P0/ip.json" >/dev/null 2>&1 && ok "P0/WS-1: inject-phase emits VALID JSON with off-path artifacts present" || bad "P0/WS-1: inject-phase invalid JSON (set-e pipefail regression)"
jq -r .hookSpecificOutput.additionalContext < "$P0/ip.json" 2>/dev/null | grep -q "0011-x/spec.md" && ok "P0/WS-1: off-path detector warns on .claude/prompt/0011-x/spec.md" || bad "P0/WS-1: off-path not detected"
jq -r .hookSpecificOutput.additionalContext < "$P0/ip.json" 2>/dev/null | grep -q "research/plan.md" && bad "P0/WS-1: off-path falsely flagged research/" || ok "P0/WS-1: off-path detector excludes research/ (no false positive)"

# --- advisor P0-hardening regressions (B1 dispatch-proof, B2 bypass, M1/M2 freshness, M3 forged citation) ---
PA="$P0/.claude/claudehut/tasks/0003-adv"; mkdir -p "$PA"
# B2: the documented bypass escape hatch must unblock the set-plan smart-gate
printf '%s\n' '# P' '## Implementation Flow' 'auth' '**T-001 sketch**: SecurityFilterChain' '| T-001 | security/auth | tf | v | - |' > "$PA/plan.md"
CLAUDE_PROJECT_DIR="$P0" "$ST" --session adv set-bypass true >/dev/null 2>&1
CLAUDE_PROJECT_DIR="$P0" "$ST" --session adv set-plan .claude/claudehut/tasks/0003-adv/plan.md >/dev/null 2>&1 \
  && ok "P0/B2: set-bypass true unblocks the set-plan smart-gate (escape hatch honored)" || bad "P0/B2: bypass NOT honored in set-plan (broken escape hatch)"
# M1/M2: content-hash freshness — an unchanged reviewed plan passes; any post-review edit is rejected
PB="$P0/.claude/claudehut/tasks/0004-fresh"; mkdir -p "$PB"
printf '%s\n' '# P' '## Implementation Flow' 'auth' '**T-001 sketch**: SecurityFilterChain' '| T-001 | security/auth | tf | v | - |' > "$PB/plan.md"
printf '%s\n' '| Check | Status | Evidence |' '| AC-001 covered | ✓ | T-001 |' > "$PB/plan-review.md"
CLAUDE_PROJECT_DIR="$P0" "$ST" --session fr set-plan-review APPROVE --evidence .claude/claudehut/tasks/0004-fresh/plan-review.md >/dev/null 2>&1
CLAUDE_PROJECT_DIR="$P0" "$ST" --session fr set-plan .claude/claudehut/tasks/0004-fresh/plan.md >/dev/null 2>&1 \
  && ok "P0/WS-2: reviewed plan (byte-identical) ACCEPTED" || bad "P0/WS-2: unchanged reviewed plan rejected"
printf '%s\n' '# P' '## Implementation Flow' 'auth' '**T-001 sketch**: SecurityFilterChain' '| T-001 | security/auth | tf | v | - |' '<!-- backdoor added AFTER review -->' > "$PB/plan.md"
CLAUDE_PROJECT_DIR="$P0" "$ST" --session fr set-plan .claude/claudehut/tasks/0004-fresh/plan.md >/dev/null 2>&1 \
  && bad "P0/M1+M2: post-review plan EDIT accepted (freshness leak)" || ok "P0/M1+M2: post-review plan edit REJECTED (content-hash freshness, mtime-immune)"
# M3: a forged ':N' citation is rejected; a real source filename is accepted
printf '%s\n' '| x | ✓ satisfied | see section 4:9 |' './gradlew test — 1 passed' > "$PA/review.md"
CLAUDE_PROJECT_DIR="$P0" "$ST" --session m3 set-review pass --evidence .claude/claudehut/tasks/0003-adv/review.md >/dev/null 2>&1 \
  && bad "P0/M3: forged ':N' citation (section 4:9) accepted" || ok "P0/M3: forged ':N' locus REJECTED (real filename/Test/#method required)"
printf '%s\n' '| x | ✓ satisfied | AuthService.java:9 |' './gradlew test — 1 passed' > "$PA/review.md"
CLAUDE_PROJECT_DIR="$P0" "$ST" --session m3 set-review pass --evidence .claude/claudehut/tasks/0003-adv/review.md >/dev/null 2>&1 \
  && ok "P0/M3: real filename:line locus ACCEPTED" || bad "P0/M3: real filename locus rejected"
# B1: a dispatched plan-reviewer that returns WITHOUT a verdict is blocked; with a fresh verdict, allowed
PV="$P0/.claude/claudehut/tasks/0005-pr"; mkdir -p "$PV"; printf '{"phase":"plan"}' > "$P0/.claude/claudehut/state/pr.json"; sleep 1
echo '{"session_id":"pr","agent_type":"claudehut-plan-reviewer","stop_hook_active":false}' | CLAUDE_PROJECT_DIR="$P0" bash "$ROOT/scripts/verify-subagent.sh" | jq -e '.decision=="block"' >/dev/null 2>&1 \
  && ok "P0/B1: plan-reviewer SubagentStop BLOCKS when it returns no fresh verdict (dispatch-proof)" || bad "P0/B1: plan-reviewer empty return not blocked"
touch "$PV/plan-review.md"
[ -z "$(echo '{"session_id":"pr","agent_type":"claudehut-plan-reviewer","stop_hook_active":false}' | CLAUDE_PROJECT_DIR="$P0" bash "$ROOT/scripts/verify-subagent.sh")" ] \
  && ok "P0/B1: plan-reviewer SubagentStop ALLOWS with a fresh verdict file" || bad "P0/B1: fresh verdict still blocked"
echo '{"session_id":"pr","agent_type":"claudehut-plan-reviewer","stop_hook_active":true}' | CLAUDE_PROJECT_DIR="$P0" bash "$ROOT/scripts/verify-subagent.sh" | jq -e '.decision=="block"' >/dev/null 2>&1 \
  && bad "P0/B1: plan-reviewer ignores stop_hook_active cap (hang risk)" || ok "P0/B1: plan-reviewer respects stop_hook_active cap (fail-open)"
rm -rf "$P0"

# ============================================================================
# v0.8 P1 — WS-6 fast-Learn + closed reinforcement loop. BEHAVIORAL.
# ============================================================================
echo "== v0.8 P1 WS-6 (fast-Learn + reinforcement) =="
P1="$(mktemp -d)"; CH="$P1/.claude/claudehut"; mkdir -p "$CH/state" "$CH/tasks/0001-x" "$P1/.claude/rules"
# harvest: a signature seen >=2x + a review ✗ row → ≥2 candidates, valid JSONL
printf '%s\n' '{"signature":"could not resolve dependency foo:bar:1.0"}' '{"signature":"could not resolve dependency foo:bar:1.0"}' > "$CH/state/s.failures.jsonl"
printf '%s\n' '| item | status | evidence |' '| N+1 in OrderRepo | ✗ violated | OrderRepo.java:42 |' > "$CH/tasks/0001-x/review.md"
hn="$(CLAUDE_PROJECT_DIR="$P1" bash "$ROOT/scripts/harvest-candidates.sh" --session s --task-dir .claude/claudehut/tasks/0001-x 2>/dev/null)"
{ [ "${hn:-0}" -ge 2 ] && jq -se . < "$CH/tasks/0001-x/learn-candidates.jsonl" >/dev/null 2>&1; } \
  && ok "WS-6: harvest-candidates extracts ≥2 candidates (recurring failure + review ✗) as valid JSONL — no agent" \
  || bad "WS-6: harvest-candidates did not produce valid candidates"
# merge writes the per-session learn-receipt (the Stop-gate proof)
CLAUDE_PROJECT_DIR="$P1" bash "$ROOT/scripts/merge-learnings.sh" --candidates "$CH/tasks/0001-x/learn-candidates.jsonl" --session s >/dev/null 2>&1
[ -f "$CH/state/s.learn-receipt.json" ] && jq -e .ts < "$CH/state/s.learn-receipt.json" >/dev/null 2>&1 \
  && ok "WS-6: merge-learnings writes a per-session learn-receipt" || bad "WS-6: no learn-receipt written by merge"
# .applied reinforcement loop: an injected learning that resurfaces is stamped
printf '%s\n' '{"id":"L-0050","ts":"2026-06-01T00:00:00Z","category":"pitfall","trigger":"jpa|n+1|orderrepo","learning":"OrderRepo N+1","evidence":"OrderRepo.java:42","confidence":0.8,"hits":3}' > "$CH/learnings.jsonl"
printf '%s\n' '["L-0050"]' > "$CH/state/s.injected.json"
printf '%s\n' '{"category":"pitfall","trigger":"OrderRepo, N+1, jpa","learning":"hit again","evidence":"OrderRepo.java:42","confidence":0.6}' > "$P1/c2.jsonl"
CLAUDE_PROJECT_DIR="$P1" bash "$ROOT/scripts/merge-learnings.sh" --candidates "$P1/c2.jsonl" --session s --injected "$CH/state/s.injected.json" >/dev/null 2>&1
[ "$(jq -sr 'map(select(.id=="L-0050"))[0].applied // 0' "$CH/learnings.jsonl" 2>/dev/null)" = "1" ] \
  && ok "WS-6: .applied stamped on an injected learning that resurfaced (inject→use loop CLOSED)" || bad "WS-6: .applied not stamped (loop still open)"
# recurring-promoted re-injection (recurrence>0 keeps being violated → re-surface); clean promoted stays out
printf '%s\n' '{"id":"L-0060","ts":"2026-06-01T00:00:00Z","category":"pitfall","trigger":"redis|cache|ttl","learning":"set TTL on cache","evidence":"C.java:9","confidence":0.9,"hits":6,"promoted":true,"recurrence":2}' '{"id":"L-0061","ts":"2026-06-01T00:00:00Z","category":"pitfall","trigger":"jdbc|pool","learning":"size the pool","evidence":"P.java:1","confidence":0.9,"hits":6,"promoted":true,"recurrence":0}' > "$CH/learnings.jsonl"
inj="$(CLAUDE_PROJECT_DIR="$P1" bash "$ROOT/scripts/inject-learnings.sh" --top 12 2>/dev/null)"
echo "$inj" | grep -q "RECURRING-PROMOTED" && ok "WS-6: a recurring promoted rule (recurrence>0) IS re-injected" || bad "WS-6: recurring promoted rule not re-injected"
echo "$inj" | grep -q "size the pool" && bad "WS-6: clean promoted rule wrongly re-injected (token double-pay)" || ok "WS-6: clean promoted rule (recurrence=0) stays in its rule file (not re-injected)"
rm -rf "$P1"

# ============================================================================
# v0.8 P1 — WS-7 task-profile router. BEHAVIORAL.
# ============================================================================
echo "== v0.8 P1 WS-7 (task-profile router) =="
P7="$(mktemp -d)"; mkdir -p "$P7/.claude/claudehut/state"; ST="$ROOT/bin/claudehut-state"
r7() { CLAUDE_PROJECT_DIR="$P7" "$ST" --session w "$@" >/dev/null 2>&1; }
# set-profile validates the taxonomy
r7 set-profile bogus && bad "WS-7: set-profile accepted an invalid shape" || ok "WS-7: set-profile rejects an invalid shape"
r7 set-profile audit && ok "WS-7: set-profile accepts a valid shape (audit)" || bad "WS-7: set-profile rejected a valid shape"
# set-phase implement is BLOCKED until a profile is set (auto-classify + hard gate, Issue 6)
rm -rf "$P7"; mkdir -p "$P7/.claude/claudehut/state"
r7 set-phase implement && bad "WS-7: set-phase implement allowed with NO profile (classification not forced)" || ok "WS-7: set-phase implement BLOCKED until a profile is set (hard gate)"
r7 set-profile feature; r7 set-phase implement && ok "WS-7: set-phase implement ALLOWED once a profile is set" || bad "WS-7: set-phase implement rejected despite a profile"
# bypass escape hatch honored
rm -rf "$P7"; mkdir -p "$P7/.claude/claudehut/state"
r7 set-bypass true; r7 set-phase implement && ok "WS-7: set-bypass true unblocks the implement classification gate (escape hatch)" || bad "WS-7: bypass not honored on the implement gate"
# gate-done: an AUDIT completes on a findings deliverable, not a code review (genuine adaptivity)
rm -rf "$P7"; CHD="$P7/.claude/claudehut"; mkdir -p "$CHD/state" "$CHD/tasks/0001-a" "$CHD/tasks/0009-old"
gdone() { echo '{"session_id":"w","stop_hook_active":false}' | CLAUDE_PROJECT_DIR="$P7" bash "$ROOT/scripts/gate-done.sh"; }
# M2: a PURE audit (no reuse-scan, never reaches implement) must STILL arm the findings gate — declaring
# the shape IS engagement. (phase=discover, reuse_scan=false → would be "not engaged" without the M2 fix.)
printf '{"session":"w","phase":"discover","profile":"audit","reuse_scan":false,"review":"pending","complexity":"full"}' > "$CHD/state/w.json"
gdone | jq -e '.decision=="block"' >/dev/null 2>&1 \
  && ok "WS-7/M2: profile=audit alone arms the findings gate (pure audit blocks done with no findings)" || bad "WS-7/M2: audit not armed without reuse-scan (rail never fires)"
# M1: a PRIOR task's findings.md must NOT satisfy this audit — the gate checks the RECORDED path, not a glob
printf '# old findings\n- x (A.java:1)\n' > "$CHD/tasks/0009-old/findings.md"
gdone | jq -e '.decision=="block"' >/dev/null 2>&1 \
  && ok "WS-7/M1: a prior task's findings.md does NOT satisfy this audit (recorded path, not a glob)" || bad "WS-7/M1: stale findings.md from another task passed the gate"
# record THIS task's findings via set-findings + a fresh receipt → ALLOW (empty output; block() also exits 0)
printf '# Findings\n- finding 1: X (Foo.java:9)\n' > "$CHD/tasks/0001-a/findings.md"
CLAUDE_PROJECT_DIR="$P7" "$ST" --session w set-findings .claude/claudehut/tasks/0001-a/findings.md >/dev/null 2>&1
printf '{"ts":"2026-06-01T00:00:00Z","added":1}' > "$CHD/state/w.learn-receipt.json"
[ -z "$(gdone)" ] \
  && ok "WS-7: audit ALLOWS done with a RECORDED findings.md (set-findings) + learn-receipt (no code review)" || bad "WS-7: audit blocked despite recorded findings + receipt"
rm -rf "$P7"

# ============================================================================
# v0.8 P1 — WS-8b reasoning loops. STRUCTURAL (prompt-level; convergence is judged by the auditor).
# ============================================================================
echo "== v0.8 P1 WS-8b (reasoning loops) =="
grep -q 'Re-examine loop' "$ROOT/agents/claudehut-brainstormer.md" \
  && grep -qE 'conv -- .*yes.*--> div' "$ROOT/agents/claudehut-brainstormer.md" \
  && ok "WS-8b: brainstormer has a re-examine BACK-EDGE (premortem HIGH-risk → re-diverge, not a linear sweep)" \
  || bad "WS-8b: brainstormer pipeline is still a single linear pass (no re-examine loop)"
grep -q 'loops:' "$ROOT/skills/brainstorm/references/brainstorm-template.md" \
  && ok "WS-8b: brainstorm template records the re-examine loop count (loops:)" || bad "WS-8b: brainstorm template has no loops: field"
grep -q 'plan-review.md' "$ROOT/scripts/verify-subagent.sh" \
  && ok "WS-8b: plan-reviewer (reasoning/conformance auditor) is gated at SubagentStop" || bad "WS-8b: plan-reviewer not gated"

# ============================================================================
# v0.8 P2 — WS-9 concision. The rigor contract is extracted ONCE; the dedup cannot drop enforcement
# (the review re-dispatch loop + set-review citation gate are the runtime backstops).
# ============================================================================
echo "== v0.8 P2 WS-9 (concision) =="
[ -f "$ROOT/skills/review/references/review-rigor.md" ] \
  && ok "WS-9: shared rigor contract extracted to references/review-rigor.md (single source)" || bad "WS-9: review-rigor.md missing"
# every code-review auditor body REFERENCES the contract instead of restating it
ad_ok=true
for a in claudehut-reviewer claudehut-security-auditor claudehut-perf-reviewer claudehut-db-reviewer; do
  grep -qi 'rigor contract' "$ROOT/agents/$a.md" || ad_ok=false
done
$ad_ok && ok "WS-9: all 4 code-review auditors reference the rigor contract (not a 5th inlined copy)" || bad "WS-9: an auditor still inlines / does not reference the rigor contract"
# the reviewer kept its minimalism lens (D2) — a cut must not drop an enforced behavior
grep -qiE 'over-engineering|minimalism' "$ROOT/agents/claudehut-reviewer.md" \
  && ok "WS-9: reviewer retains the minimalism/over-engineering lens after the trim (no behavior dropped)" || bad "WS-9: reviewer lost the minimalism lens in the trim"
# no non-English / stray token left in the always-loaded bodies
grep -rql 'rập-khuôn' "$ROOT/skills" "$ROOT/agents" 2>/dev/null \
  && bad "WS-9: stray 'rập-khuôn' token still in a body" || ok "WS-9: stray non-English token removed"
# the length+provenance lint discriminates (self-test) AND the repo is clean (honest: soft, commit-time)
bash "$ROOT/scripts/lint-prompt-length.sh" --self-test >/dev/null 2>&1 \
  && ok "WS-9: lint-prompt-length self-test passes (flags over-budget + provenance, no false positive)" || bad "WS-9: lint-prompt-length self-test failed"
bash "$ROOT/scripts/lint-prompt-length.sh" >/dev/null 2>&1 \
  && ok "WS-9: repo is within budget + provenance-clean (the WS-9 trim holds)" || bad "WS-9: repo over budget / has provenance noise"

# ============================================================================
# v0.9 Rec 4 — ultra-flow mermaid coverage. The 21 ultra-flow diagrams (one per agent + skill) had no
# deterministic coverage (audit EVAL-1): deleting/corrupting a block shipped with CI green. INVARIANT: every
# agents/*.md and skills/*/SKILL.md carries a NON-EMPTY ```mermaid block. If mmdc (@mermaid-js/mermaid-cli) is
# on PATH each block is also parse-validated; if absent the parse is SKIPPED so the battery stays hermetic.
# ============================================================================
echo "== v0.9 Rec 4 (ultra-flow mermaid coverage) =="
MMDC_OK=false; command -v mmdc >/dev/null 2>&1 && MMDC_OK=true
# print the first fenced mermaid block of a file (between ```mermaid and the next ```)
mermaid_block() { awk '/^```mermaid/{f=1;next} f&&/^```/{exit} f' "$1"; }
# Tracked skills only — same reasoning as C1: an untracked WIP skill is not shipped, so it owes no diagram.
# An ARRAY, because a space anywhere in $ROOT (e.g. "~/Library/Application Support/...") would word-split a
# plain string and silently drop every assertion in this loop with no compensating failure.
MERMAID_FILES=("$ROOT"/agents/*.md)
for s in $(skill_dirs); do MERMAID_FILES+=("$ROOT/skills/$s/SKILL.md"); done
for f in "${MERMAID_FILES[@]}"; do
  [ -f "$f" ] || continue
  n=${f#"$ROOT"/}
  if ! grep -q '^```mermaid' "$f"; then bad "mermaid: $n has no ultra-flow diagram"; continue; fi
  blk="$(mermaid_block "$f")"
  if [ -z "$(printf '%s' "$blk" | tr -d '[:space:]')" ]; then bad "mermaid: $n has an EMPTY mermaid block"; continue; fi
  if $MMDC_OK; then
    tmp="$(mktemp)"; printf '%s\n' "$blk" > "$tmp.mmd"
    if mmdc -i "$tmp.mmd" -o "$tmp.svg" >/dev/null 2>&1; then ok "mermaid valid (mmdc): $n"; else bad "mermaid: $n fails mmdc parse"; fi
    rm -f "$tmp" "$tmp.mmd" "$tmp.svg"
  else
    ok "mermaid present+non-empty: $n (mmdc absent — parse skipped)"
  fi
done

echo
echo "CONFORMANCE: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
