#!/usr/bin/env bash
# Live A/B: are native .claude/rules/ LOADED + FOLLOWED by the agent? (answers "is rules-only reliable?")
# Two arbitrary markers the model never emits unprompted → marker in output == rule loaded AND obeyed.
#   CONTROL  : always.md (no paths:) → mandates `// ALWAYS-7341` on every Java class (loads at session start).
#   TREATMENT: entity.md (paths: **/*Entity.java) → mandates `// ENTITY-7341` on entity classes (path-load).
# Conditions: EDIT (agent reads+edits an existing entity) vs CREATE (agent writes a fresh entity — the
#   load-on-Write gap). Bare project, no plugin (isolates the native rule mechanism the plugin generates into).
# COSTS TOKENS. Run: evals/rule-load-probe.sh [N]   (default N=3 per condition)
set -uo pipefail
N="${1:-3}"
command -v claude >/dev/null || { echo "claude not on PATH" >&2; exit 2; }

setup() { # $1 workdir
  local w="$1"; mkdir -p "$w/.claude/rules" "$w/src/main/java/com/x"
  cat > "$w/.claude/rules/always.md" <<'EOF'
# Project convention (control)
MANDATORY: every Java class MUST have the exact comment `// ALWAYS-7341` on the line directly above its `class` declaration. Non-negotiable house style.
EOF
  cat > "$w/.claude/rules/entity.md" <<'EOF'
---
paths:
  - "**/*Entity.java"
---
# Entity convention (treatment)
MANDATORY: every JPA entity class MUST have the exact comment `// ENTITY-7341` on the line directly above its `class` declaration. Non-negotiable house style.
EOF
  ( cd "$w" && git init -q && git add -A && git commit -qm base >/dev/null 2>&1 )
}

ae=0; ac=0; pe=0; pc=0   # always/path × edit/create marker counts
for cond in edit create; do
  for ((i=1;i<=N;i++)); do
    w="$(mktemp -d)/p"; setup "$w"
    if [ "$cond" = edit ]; then
      printf 'package com.x;\n\npublic class UserEntity {\n  private Long id;\n}\n' > "$w/src/main/java/com/x/UserEntity.java"
      ( cd "$w" && git add -A && git commit -qm stub >/dev/null 2>&1 )
      prompt="Add a String email field to the UserEntity class in src/main/java/com/x/UserEntity.java. Edit that file."
    else
      prompt="Create a JPA entity class named OrderEntity with a Long id and a BigDecimal amount field at src/main/java/com/x/OrderEntity.java."
    fi
    ( cd "$w" && claude --print --permission-mode acceptEdits "$prompt" < /dev/null >/dev/null 2>&1 ) || true
    a=0; e=0
    grep -rq 'ALWAYS-7341' "$w/src" 2>/dev/null && a=1
    grep -rq 'ENTITY-7341' "$w/src" 2>/dev/null && e=1
    made=$(find "$w/src" -name '*Entity.java' 2>/dev/null | wc -l | tr -d ' ')
    echo "  [$cond #$i] entity-file=$made  control(always)=$a  treatment(path)=$e"
    if [ "$cond" = edit ]; then ae=$((ae+a)); pe=$((pe+e)); else ac=$((ac+a)); pc=$((pc+e)); fi
    rm -rf "$w"
  done
done
echo
echo "RULE LOAD+USE RESULT (N=$N per condition):"
echo "  CONTROL  always-on rule followed:   edit $ae/$N   create $ac/$N   <- are rules obeyed at all?"
echo "  TREATMENT path-scoped rule followed: edit $pe/$N   create $pc/$N   <- do paths: rules load+get used? (edit vs fresh-create)"
echo
echo "Read: control LOW => agent ignores rules (USE problem, skills won't fix via load alone)."
echo "      control high, treatment low-on-create => path-trigger gap on fresh Write (the flagged risk)."
echo "      both high => rules-only loads+used reliably."
