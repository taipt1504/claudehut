#!/usr/bin/env bash
# scripts/regen-using-claudehut.sh — regenerate skills/using-claudehut/SKILL.md
# from the live skills/*/SKILL.md inventory. Idempotent — run after any skill
# add/remove/description-edit.
#
# Output is written between two HTML comment markers in the SKILL.md body so
# the human-written discipline narrative is preserved across regenerations.
set -euo pipefail

_find_plugin_root() {
  if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]]; then echo "$CLAUDE_PLUGIN_ROOT"; return; fi
  local d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
  while [[ "$d" != "/" && -n "$d" ]]; do
    [[ -f "$d/.claude-plugin/plugin.json" ]] && { echo "$d"; return; }
    d="$(dirname "$d")"
  done
  echo "error: cannot locate ClaudeHut plugin root" >&2; exit 1
}
PLUGIN_ROOT="$(_find_plugin_root)"
TARGET="$PLUGIN_ROOT/skills/using-claudehut/SKILL.md"
MARK_BEGIN="<!-- catalog:begin -->"
MARK_END="<!-- catalog:end -->"

# 1) Build catalog table from skills/*/SKILL.md frontmatter.
#
# Determinism notes (CI runs on Linux, dev usually on macOS):
#   - Skill files are enumerated via `find … | LC_ALL=C sort` so glob order is
#     locale-independent. Plain bash globs ordered differently on macOS vs Linux
#     when filenames mix hyphens/underscores under non-C locales.
#   - Description truncation uses awk `substr` on byte semantics with an
#     explicit `LC_ALL=C`; macOS BSD `cut -c` and GNU `cut -c` differ on
#     multibyte chars (em-dash, Vietnamese accents) which appear in some
#     skill descriptions.
CATALOG_TMP="$(mktemp)"
{
  echo "$MARK_BEGIN"
  echo ""
  echo "| Skill | When to invoke (description excerpt) |"
  echo "|-------|--------------------------------------|"
  while IFS= read -r f; do
    dir="$(dirname "$f")"
    stem="$(basename "$dir")"
    [[ "$stem" == "using-claudehut" ]] && continue
    name="$(awk '/^---/{c++; next} c==1 && /^name:/{sub(/^name:[[:space:]]*/,""); print; exit}' "$f")"
    desc="$(awk '/^---/{c++; next} c==1 && /^description:/{sub(/^description:[[:space:]]*/,""); print; exit}' "$f")"
    # Escape pipes, then byte-truncate to 180 via awk (consistent across platforms).
    excerpt="$(printf '%s' "$desc" | sed 's/|/\\|/g' | LC_ALL=C awk '{print substr($0, 1, 180)}')"
    [[ -z "$name" ]] && name="$stem"
    echo "| \`claudehut:$name\` | $excerpt |"
  done < <(find "$PLUGIN_ROOT/skills" -mindepth 2 -maxdepth 2 -name 'SKILL.md' -type f | LC_ALL=C sort)
  echo ""
  echo "_Auto-generated from \`skills/*/SKILL.md\` by \`scripts/regen-using-claudehut.sh\`. Do not hand-edit this block._"
  echo ""
  echo "$MARK_END"
} > "$CATALOG_TMP"

# 2) Compose the final SKILL.md (frontmatter + narrative + catalog block).
NEW_FILE="$(mktemp)"
cat > "$NEW_FILE" <<'HEAD_EOF'
---
name: using-claudehut
description: ClaudeHut workflow + plugin-skill discovery contract for subagents. Preloaded into every dispatch-eligible agent via `skills:` frontmatter so the subagent receives, at startup, (a) the non-negotiable skill-invocation discipline and (b) the catalog of all plugin skills with trigger excerpts. Lets the subagent decide — natively, no hook injection — which skill(s) to invoke when its task touches a domain its preloaded skills do not cover (e.g. builder hitting Kafka, mapping, JPA, WebFlux, ...).
---

# Using ClaudeHut — subagent skill discipline

You are running as a ClaudeHut subagent. Your context window is fresh
and isolated from the main thread. The plugin skills are reachable
through the `Skill` tool; the catalog at the bottom of this file is the
authoritative list of what is available.

## Non-negotiable invocation rule

> **Even a 1% chance a skill matches the work in front of you means
> you MUST invoke that skill to check.**

Before you write code, edit a config, draft an artifact, or answer a
domain question, scan the catalog. If any row plausibly matches the
work — invoke that skill via the `Skill` tool **first**, then continue.

This is not optional. It is not "use judgment". It is not "if you
think it helps". Match in catalog → invoke. Read the skill body. Apply
the conventions. Then act.

## Red flags (rationalizations that mean "invoke the skill")

| Rationalization                                  | Reality |
|--------------------------------------------------|---------|
| "I already know this pattern."                   | Your training data is generic; the skill is project-tuned. |
| "Task is small."                                 | Small tasks are how silent drift accumulates. |
| "Skill invocation is overkill."                  | Invocation is near-zero cost; skipping risks rule violation. |
| "My preloaded skills already cover it."          | Preload is a starter kit, not exhaustive coverage. |
| "I'll guess and verify later."                   | Guessing first burns turns and produces non-conforming code. |
| "It's just a one-line change."                   | Conventions decide what that one line should look like. |

## How dispatch maps to skill invocation

You arrived here because the main thread dispatched a phase via `Task`
with a `subagent_type` (e.g. `claudehut-builder`). The phase skill the
main thread invoked (e.g. `claudehut:build`) is also preloaded into
your `skills:` frontmatter. You do **not** need to re-invoke your phase
skill. You **do** need to invoke any domain skill your work touches.

Examples:

| Your phase agent          | Work in front of you           | Skill to invoke |
|---------------------------|--------------------------------|------------------|
| `claudehut-builder`       | Touching `*Controller.java`    | `claudehut:spring-mvc` (or `spring-webflux` per stack) |
| `claudehut-builder`       | Touching `*KafkaListener.java` | `claudehut:kafka-consumer` |
| `claudehut-builder`       | Touching `*Producer.java`      | `claudehut:kafka-producer` |
| `claudehut-builder`       | Touching `*Mapper.java`        | `claudehut:mapstruct` |
| `claudehut-builder`       | Touching `*Dto/*Request/*Response.java` | `claudehut:jackson` |
| `claudehut-builder`       | Touching `*Repository.java`    | `claudehut:jpa-hibernate` (or `r2dbc` per stack) |
| `claudehut-builder`       | Touching `db/migration/V*.sql` | `claudehut:flyway-migration` |
| `claudehut-builder`       | New Java file                  | `claudehut:reuse-scan` |
| `claudehut-builder`       | Adding `*Test.java`            | `claudehut:tdd-cycle` (preloaded — already in context) |
| `claudehut-builder`       | Adding `*IT.java`              | `claudehut:testcontainers` |
| `claudehut-verifier`      | Pre-dispatching reviewers      | `claudehut:verify-review` (preloaded) |
| Any agent                 | Bug investigation              | `claudehut:systematic-debug` |
| Any agent                 | Stuck/no convergence           | `claudehut:systematic-debug` |

If the work touches multiple domains, invoke each matching skill in
order. The Skill tool is idempotent — calling the same skill twice in
one task is harmless.

## When you are unsure

Default to **invoke**. The bar to skip a catalog match is "I can
articulate why the skill is irrelevant to this exact line of work and
write it in a comment for the reviewer." If you cannot, invoke.

## Catalog

HEAD_EOF

cat "$CATALOG_TMP" >> "$NEW_FILE"
rm -f "$CATALOG_TMP"

# 3) Compare with existing and only rewrite if different (idempotent).
mkdir -p "$(dirname "$TARGET")"
if [[ -f "$TARGET" ]] && diff -q "$NEW_FILE" "$TARGET" >/dev/null 2>&1; then
  echo "using-claudehut: no change"
  rm -f "$NEW_FILE"
else
  mv "$NEW_FILE" "$TARGET"
  echo "using-claudehut: regenerated $TARGET"
fi
