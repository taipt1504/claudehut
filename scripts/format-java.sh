#!/usr/bin/env bash
# PostToolUse hook (matcher: Write|Edit, if: Edit(*.java)|Write(*.java), async).
# Cosmetic only: formats the written Java file so reviewer agents never waste signal on
# style nits. Non-blocking; probes for a formatter and exits 0 if none is installed. See 06 §3.
set -euo pipefail

in="$(cat || true)"
command -v jq >/dev/null 2>&1 || exit 0

fp="$(jq -r '.tool_input.file_path // empty' <<<"$in" 2>/dev/null || true)"
case "$fp" in *.java) ;; *) exit 0 ;; esac
[ -f "$fp" ] || exit 0

if command -v google-java-format >/dev/null 2>&1; then
  google-java-format --replace "$fp" >/dev/null 2>&1 || true
elif command -v palantir-java-format >/dev/null 2>&1; then
  palantir-java-format --replace "$fp" >/dev/null 2>&1 || true
fi
exit 0
