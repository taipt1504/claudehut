#!/usr/bin/env bash
# PostToolUse hook (matcher: Write|Edit, async). Cosmetic only: formats the written Java file
# so reviewer agents never waste signal on style nits. Non-blocking; probes for a formatter and
# exits 0 if none is installed. Self-guards on *.java below (no hooks.json `if` — async + this
# guard make one redundant, and an `if` glob mismatch could silently skip nested paths). See 06 §3.
# Plane first (K7, AC1): a user-scope install must not rewrite Java in repos that never opted into ClaudeHut.
# 05 §4 row 6 names only "a formatter"; the plane test is the precondition of every hook (§2), not an extra one.
case "$0" in */*) _d="${0%/*}" ;; *) _d="." ;; esac
. "$_d/lib/hook-common.sh" 2>/dev/null || exit 0
hc_init
hc_plane_or_exit          # no plane → exit 0, the formatter never runs
trap - ERR                # a failed formatter is a normal negative here; the EXIT trap still exits 0, silently

fp="$(jq -r '.tool_input.file_path // empty' <<<"$HC_IN" 2>/dev/null || true)"
# The hook now carries if:"Write(*.java)" / if:"Edit(*.java)", so this is belt-and-braces rather than the
# only guard — kept because the script is also runnable by hand, where no hook filter applies.
case "$fp" in *.java) ;; *) exit 0 ;; esac
hc_rel "$fp" || exit 0    # only files inside the project: never rewrite scratchpad, /tmp or a sibling repo
[ -f "$fp" ] || exit 0

if command -v google-java-format >/dev/null 2>&1; then
  google-java-format --replace "$fp" >/dev/null 2>&1 || true
elif command -v palantir-java-format >/dev/null 2>&1; then
  palantir-java-format --replace "$fp" >/dev/null 2>&1 || true
fi
exit 0
