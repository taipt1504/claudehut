#!/usr/bin/env bash
# Discriminator: WHY did path-scoped rules score 0/6? Test which paths: glob FORMS actually fire in
# `claude -p` by editing one matching file with 4 competing marker rules present:
#   always (no paths:)        -> ALWAYS_MARK   (control; expect fire)
#   paths: ["**/*.java"]      -> GSTAR_MARK
#   paths: ["*Entity.java"]   -> BARE_MARK
#   paths: ["**/*Entity.java"]-> DSTAR_MARK    (the form the plugin's rules use; scored 0/6)
# Edit an existing UserEntity.java (guarantees a READ of a matching file). Marker present == that rule loaded.
# H2 (glob bug): some path form fires, **/*Entity.java doesn't.  H1 (mechanism): no path form fires. COSTS TOKENS.
set -uo pipefail
N="${1:-3}"
command -v claude >/dev/null || { echo "claude not on PATH" >&2; exit 2; }
mk() { mkdir -p "$1"; printf '%s\n' "$2" > "$1/$3"; }

a=0;g=0;b=0;d=0
for ((i=1;i<=N;i++)); do
  w="$(mktemp -d)/p"; mkdir -p "$w/.claude/rules" "$w/src/main/java/com/x"
  printf '# control\nMANDATORY: every Java class MUST have `// ALWAYS_MARK` directly above its class declaration.\n' > "$w/.claude/rules/always.md"
  printf -- '---\npaths:\n  - "**/*.java"\n---\nMANDATORY: every Java class MUST have `// GSTAR_MARK` directly above its class declaration.\n' > "$w/.claude/rules/gstar.md"
  printf -- '---\npaths:\n  - "*Entity.java"\n---\nMANDATORY: every entity class MUST have `// BARE_MARK` directly above its class declaration.\n' > "$w/.claude/rules/bare.md"
  printf -- '---\npaths:\n  - "**/*Entity.java"\n---\nMANDATORY: every entity class MUST have `// DSTAR_MARK` directly above its class declaration.\n' > "$w/.claude/rules/dstar.md"
  printf 'package com.x;\n\npublic class UserEntity {\n  private Long id;\n}\n' > "$w/src/main/java/com/x/UserEntity.java"
  ( cd "$w" && git init -q && git add -A && git commit -qm base >/dev/null 2>&1 )
  ( cd "$w" && claude --print --permission-mode acceptEdits "Add a String email field to the UserEntity class in src/main/java/com/x/UserEntity.java. Edit that file." < /dev/null >/dev/null 2>&1 ) || true
  f="$w/src/main/java/com/x/UserEntity.java"
  A=0;G=0;B=0;D=0
  grep -q 'ALWAYS_MARK' "$f" 2>/dev/null && { A=1; a=$((a+1)); }
  grep -q 'GSTAR_MARK' "$f" 2>/dev/null && { G=1; g=$((g+1)); }
  grep -q 'BARE_MARK' "$f" 2>/dev/null && { B=1; b=$((b+1)); }
  grep -q 'DSTAR_MARK' "$f" 2>/dev/null && { D=1; d=$((d+1)); }
  echo "  [#$i] always=$A  **/*.java=$G  *Entity.java=$B  **/*Entity.java=$D"
  rm -rf "$w"
done
echo
echo "GLOB DISCRIMINATOR (N=$N, edit of UserEntity.java):"
echo "  always (no paths:)        $a/$N"
echo "  paths **/*.java           $g/$N"
echo "  paths *Entity.java        $b/$N"
echo "  paths **/*Entity.java     $d/$N   <- the plugin's rule glob form"
