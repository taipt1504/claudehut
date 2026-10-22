#!/usr/bin/env bash
# SessionStart hook (startup|resume) — K10 pack registry (docs/v0.20 07 §1.1, M5a).
#
# A hook does not get other plugins' bin/ on PATH and a plugin cannot reach into another plugin's root (verified,
# 07 §1.1), so a split install cannot discover its packs by calling the kernel. Instead every plugin that ships
# packs runs THIS script from its own root: it writes one entry per packs/*/claudehut-pack.json it carries to
# <plane>/state/packs/<pack>.json — {pack, version, root, manifest_hash} — and the kernel reads the registry from
# the project's plane. Self-contained on purpose (no hook-common, no kernel call): the same file is vendored into
# the split plugins. Never creates a plane; writes only when an entry changed; prints nothing; always exits 0.

root="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$root" ]; then
  case "$0" in */*) root="$(cd "${0%/*}/.." 2>/dev/null && pwd)" ;; *) root="$(cd .. && pwd)" ;; esac
fi
proj="${CLAUDE_PROJECT_DIR:-$PWD}"
# The plane rule of scripts/lib/plane-path.sh (ADR K-18), inlined: .claudehut wins, then the legacy location.
if [ -d "$proj/.claudehut" ]; then plane="$proj/.claudehut"
elif [ -d "$proj/.claude/claudehut" ]; then plane="$proj/.claude/claudehut"
else exit 0
fi
command -v jq >/dev/null 2>&1 || exit 0
dir="$plane/state/packs"
mkdir -p "$dir" 2>/dev/null || exit 0

sha() { # empty when no hasher: the kernel then skips the hash check
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  fi
}
for m in "$root"/packs/*/claudehut-pack.json; do
  [ -f "$m" ] || continue
  ent="$(jq -c --arg root "$root" --arg h "$(sha "$m")" '{pack, version, root: $root, manifest_hash: $h}' "$m" 2>/dev/null)" || continue
  pack="$(jq -r '.pack // empty' <<<"$ent")"
  case "$pack" in ''|*/*|.*) continue ;; esac
  f="$dir/$pack.json"
  [ "$(cat "$f" 2>/dev/null)" = "$ent" ] && continue
  printf '%s\n' "$ent" >"$f.tmp.$$" 2>/dev/null && mv -f "$f.tmp.$$" "$f" 2>/dev/null
  rm -f "$f.tmp.$$" 2>/dev/null
done
exit 0
