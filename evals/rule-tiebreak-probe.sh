#!/usr/bin/env bash
# Tie-breaker: probe1 (**/*Entity.java) scored 0/6, probe2 (same glob) 3/3. Replicate probe1's narrow-glob-ALONE
# setup but with a grep-ROBUST single-token marker (ZZ9MARK) to rule out a marker-paraphrase grep artifact.
# Splits EDIT (reads matching file → should load) vs CREATE (fresh write → suspected load gap). COSTS TOKENS.
set -uo pipefail
N="${1:-3}"
command -v claude >/dev/null || { echo "claude not on PATH" >&2; exit 2; }
pe=0; pc=0
for cond in edit create; do
  for ((i=1;i<=N;i++)); do
    w="$(mktemp -d)/p"; mkdir -p "$w/.claude/rules" "$w/src/main/java/com/x"
    printf '# control (no paths)\nMANDATORY: every Java class MUST contain the token ZZALWAYS in a comment above its class declaration.\n' > "$w/.claude/rules/always.md"
    printf -- '---\npaths:\n  - "**/*Entity.java"\n---\nMANDATORY: every entity class MUST contain the token ZZ9MARK in a comment above its class declaration.\n' > "$w/.claude/rules/entity.md"
    if [ "$cond" = edit ]; then
      printf 'package com.x;\n\npublic class UserEntity {\n  private Long id;\n}\n' > "$w/src/main/java/com/x/UserEntity.java"
      P="Add a String email field to the UserEntity class in src/main/java/com/x/UserEntity.java. Edit that file."
    else
      P="Create a JPA entity class named OrderEntity with a Long id field at src/main/java/com/x/OrderEntity.java."
    fi
    ( cd "$w" && git init -q && git add -A && git commit -qm base >/dev/null 2>&1 )
    ( cd "$w" && claude --print --permission-mode acceptEdits "$P" < /dev/null >/dev/null 2>&1 ) || true
    e=0; grep -rq 'ZZ9MARK' "$w/src" 2>/dev/null && e=1
    al=0; grep -rq 'ZZALWAYS' "$w/src" 2>/dev/null && al=1
    echo "  [$cond #$i] always(ZZALWAYS)=$al  path **/*Entity.java(ZZ9MARK)=$e"
    [ "$cond" = edit ] && pe=$((pe+e)) || pc=$((pc+e))
    rm -rf "$w"
  done
done
echo
echo "TIE-BREAK (narrow **/*Entity.java ALONE, robust marker, N=$N):"
echo "  path rule on EDIT (reads matching file): $pe/$N"
echo "  path rule on CREATE (fresh write):       $pc/$N"
echo "  edit high => probe1's 0 was a grep artifact; path rules DO load on edit. create low => load-on-write gap."
