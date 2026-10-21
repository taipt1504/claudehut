# plane-path.sh — the ONE place bash code resolves where a ClaudeHut plane lives (ADR K-18, docs/v0.20 09).
# Sourced by hooks (via hook-common.sh) and by bin/ scripts. Python has the same rule in
# scripts/kernel/claudehut_kernel/plane.py; scripts/index/*.py import it from there.
#
# Layout 0.12.8+: <repo>/.claudehut/        — writable plane data (tasks, learnings, index, state, ledger, events).
#                                             Outside `.claude/`, which Claude Code treats as a protected path
#                                             (file-tool writes prompt, go to the classifier, or are DENIED in dontAsk).
# Legacy:         <repo>/.claude/claudehut/ — still read and written when it is the only plane; migrate moves it.
# Both present:   the new one wins; the legacy one is reported once (claudehut-state status / init), never merged.
#
# A hub keeps the same rule one level down: <hub>/.claudehut/hub, legacy <hub>/.claude/claudehut/hub.

CH_PLANE_NEW=".claudehut"
CH_PLANE_LEGACY=".claude/claudehut"

# ch_plane_dir <project-dir> → absolute plane dir: the existing new plane, else the existing legacy plane, else the
# new location (callers that only READ check `[ -d ]`; creators such as claudehut-init create it).
ch_plane_dir() {
  local p="${1%/}"
  if [ -d "$p/$CH_PLANE_NEW" ]; then printf '%s' "$p/$CH_PLANE_NEW"
  elif [ -d "$p/$CH_PLANE_LEGACY" ]; then printf '%s' "$p/$CH_PLANE_LEGACY"
  else printf '%s' "$p/$CH_PLANE_NEW"; fi
}

# ch_plane_rel <project-dir> → the plane dir relative to the project (".claudehut" or ".claude/claudehut").
ch_plane_rel() {
  local p="${1%/}"
  if [ -d "$p/$CH_PLANE_NEW" ]; then printf '%s' "$CH_PLANE_NEW"
  elif [ -d "$p/$CH_PLANE_LEGACY" ]; then printf '%s' "$CH_PLANE_LEGACY"
  else printf '%s' "$CH_PLANE_NEW"; fi
}

# ch_hub_dir <hub-root-or-hub-dir> → the hub's data dir (…/hub), or empty when there is none.
ch_hub_dir() {
  local h="${1%/}"
  if [ -d "$h/$CH_PLANE_NEW/hub" ]; then printf '%s' "$h/$CH_PLANE_NEW/hub"
  elif [ -d "$h/$CH_PLANE_LEGACY/hub" ]; then printf '%s' "$h/$CH_PLANE_LEGACY/hub"
  elif [ -f "$h/hub.json" ]; then printf '%s' "$h"; fi
}

# ch_hub_root <path> → strip a trailing /.claudehut/hub or /.claude/claudehut/hub (either spelling names the hub).
ch_hub_root() {
  local h="${1%/}"
  h="${h%/$CH_PLANE_NEW/hub}"; h="${h%/$CH_PLANE_LEGACY/hub}"
  printf '%s' "$h"
}

# ch_is_plane_path <project-relative path> → 0 when the path is inside either plane layout.
ch_is_plane_path() {
  case "$1" in "$CH_PLANE_NEW"/*|"$CH_PLANE_LEGACY"/*|*/"$CH_PLANE_NEW"/*|*/"$CH_PLANE_LEGACY"/*) return 0 ;; esac
  return 1
}
