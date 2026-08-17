#!/usr/bin/env bash
# v0.9 Rec 4 — reference-solution self-check (audit EVAL-2).
# For each evals/tasks/<t>/ that ships a reference/ known-good work tree, assert that task's own oracle.sh
# ACCEPTS it (exit 0). This proves each task is solvable and its oracle is correctly configured / not
# over-strict — a self-check the plugin lacked. Hermetic: runs only the deterministic oracle, never the API.
# Tasks without a reference/ are SKIPPED with a notice (honest partial coverage, not a silent pass).
# Run: evals/reference-check.sh   (exit 0 iff every present reference/ passes its oracle)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASKS="$ROOT/evals/tasks"
PASS=0; FAIL=0; SKIP=0

for d in "$TASKS"/*/; do
  t="$(basename "$d")"; case "$t" in _*) continue ;; esac   # skip _fixtures and dotdirs
  oracle="$d/oracle.sh"; ref="$d/reference"
  [ -f "$oracle" ] || continue
  if [ ! -d "$ref" ]; then
    echo "  skip - $t (no reference/ — oracle not self-checked)"; SKIP=$((SKIP+1)); continue
  fi
  work="$(mktemp -d)/work"; mkdir -p "$work"; cp -R "$ref/." "$work/" 2>/dev/null
  if ( bash "$oracle" "$work" >/dev/null 2>&1 ); then
    echo "  ok   - $t: reference/ passes its own oracle"; PASS=$((PASS+1))
  else
    echo "  FAIL - $t: reference/ REJECTED by its own oracle (oracle mis-configured or reference stale)"; FAIL=$((FAIL+1))
  fi
  rm -rf "$(dirname "$work")"
done

# PLUMB-F-05: an MCP tool name in an agent's `tools:` is a promise the runtime cannot keep if the tool does
# not exist — v0.10 shipped mcp__postgres__query, which the server does not implement, and the call was
# rejected at runtime with nothing in the corpus to catch it. Diff the tree against a checked-in snapshot so
# a NEW name fails here until someone verifies it against the server's own docs and records it.
INV="$ROOT/evals/mcp-inventory.json"
if [ -f "$INV" ]; then
  live="$(grep -ohE 'mcp__[a-z0-9_-]+__[a-zA-Z0-9_-]+' "$ROOT"/agents/*.md | sort -u)"
  known="$(jq -r '.tools[]' "$INV" 2>/dev/null | sort -u)"
  newnames="$(comm -23 <(printf '%s\n' "$live") <(printf '%s\n' "$known"))"
  gone="$(comm -13 <(printf '%s\n' "$live") <(printf '%s\n' "$known"))"
  if [ -z "$newnames" ]; then echo "  ok   - MCP inventory: no unverified tool names in agents/"; PASS=$((PASS+1))
  else echo "  FAIL - MCP inventory: unverified name(s) — verify against the server docs, then record in evals/mcp-inventory.json: $(printf '%s' "$newnames" | tr '\n' ' ')"; FAIL=$((FAIL+1)); fi
  if [ -z "$gone" ]; then echo "  ok   - MCP inventory: snapshot has no stale entries"; PASS=$((PASS+1))
  else echo "  FAIL - MCP inventory: snapshot lists tool(s) no agent declares: $(printf '%s' "$gone" | tr '\n' ' ')"; FAIL=$((FAIL+1)); fi
else
  echo "  FAIL - MCP inventory: evals/mcp-inventory.json missing"; FAIL=$((FAIL+1))
fi

echo
echo "REFERENCE-CHECK: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
