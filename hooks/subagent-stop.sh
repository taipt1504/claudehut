#!/usr/bin/env bash
# claudehut SubagentStop hook — write a per-reviewer completion MARKER.
# The SubagentStop event delivers agent_type only (NOT the reviewer's output),
# so this hook cannot persist findings. Each reviewer writes its own findings
# shard (via Bash) to .claudehut/findings/<id>/reviewer-<name>.json before it
# returns; aggregate-findings.sh merges those shards. This marker is an audit
# breadcrumb only — decision/totals come from the shards, never from here.
set -euo pipefail

# shellcheck source=lib/state.sh
source "$(dirname "$0")/lib/state.sh"

input="$(cat)"
PROJECT_ROOT="$(claudehut_project_root)"
[[ -d "$PROJECT_ROOT/.claudehut" ]] || exit 0

agent_type="$(echo "$input" | jq -r '.agent_type // .subagent_type // ""')"
TASK_ID="$(claudehut_task_id)"
[[ "$TASK_ID" == "none" ]] && exit 0

case "$agent_type" in
  claudehut-reviewer-*)
    findings_dir="$PROJECT_ROOT/.claudehut/findings"
    findings_file="$findings_dir/${TASK_ID}-findings.json"
    mkdir -p "$findings_dir"
    [[ -f "$findings_file" ]] || echo '{"reviewers": {}}' > "$findings_file"
    tmp="$(mktemp "${findings_file}.XXXXXX")"
    jq --arg a "$agent_type" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '.reviewers[$a] = ((.reviewers[$a] // {}) + {completed_at: $ts})' "$findings_file" > "$tmp" && mv "$tmp" "$findings_file"
    ;;
esac

exit 0
