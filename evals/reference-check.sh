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

# MCP-PIN: every catalog row must constrain the server it recommends. postgres pins --access-mode, kafka
# pins --allow-tools, and github was the exception — added at the default endpoint, which serves
# create_pull_request / merge_pull_request / push_files / delete_file to a reviewer agent whose stated need
# is "PR/issue context". Read-only endpoint and toolset header verified against github/github-mcp-server.
MCPREC="$ROOT/templates/mcp-recommendations.md"
if grep -q 'api.githubcopilot.com/mcp/ ' "$MCPREC" || grep -qE 'githubcopilot\.com/mcp/"?\s*--header "Auth' "$MCPREC"; then
  echo "  FAIL - MCP-PIN: the github row uses the unpinned default endpoint (full write toolset)"; FAIL=$((FAIL+1))
else
  echo "  ok   - MCP-PIN: the github row is pinned to the read-only endpoint"; PASS=$((PASS+1))
fi
if grep -q 'X-MCP-Toolsets' "$MCPREC"; then
  echo "  ok   - MCP-PIN: the github row narrows its toolsets"; PASS=$((PASS+1))
else
  echo "  FAIL - MCP-PIN: the github row serves every toolset"; FAIL=$((FAIL+1))
fi

# IDEA-F6: anchored slice-reads. A pointer that names an anchor lets the reader open a section instead of a
# whole file — implement/references/testing.md is 12,479 B for what is usually one slice. The mechanism is
# worthless without this check: an anchor that no longer resolves reads exactly like one that does, and the
# repo already carries 26 dead anchors in .claude/docs/design/ as the standing proof of that.
# Every `references/<file>.md#<anchor>` written anywhere in skills/ or agents/ must resolve to a heading.
anch_bad=0; anch_n=0
while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  anch_n=$((anch_n+1))
  tgt="${ref%%#*}"; frag="${ref#*#}"
  # locate the target relative to whichever skill dir referenced it
  hit=""
  for cand in "$ROOT"/skills/*/"$tgt" "$ROOT/$tgt"; do [ -f "$cand" ] && { hit="$cand"; break; }; done
  if [ -z "$hit" ]; then
    echo "  FAIL - anchor target missing: $ref"; anch_bad=$((anch_bad+1)); continue
  fi
  # GitHub-style slug: lowercase, drop punctuation, spaces to hyphens
  if ! grep -E '^#{1,6} ' "$hit" \
       | sed -E 's/^#+ //; s/[^a-zA-Z0-9 -]//g; s/ /-/g' \
       | tr '[:upper:]' '[:lower:]' | grep -qx "$frag"; then
    echo "  FAIL - anchor does not resolve: $ref (no heading slugs to '$frag' in $(basename "$hit"))"
    anch_bad=$((anch_bad+1))
  fi
done < <(grep -rhoE 'references/[a-z0-9-]+\.md#[a-z0-9-]+' "$ROOT/skills" "$ROOT/agents" 2>/dev/null | sort -u)
if [ "$anch_bad" = "0" ]; then
  echo "  ok   - all $anch_n advertised reference anchor(s) resolve"; PASS=$((PASS+1))
else
  echo "  FAIL - $anch_bad advertised anchor(s) do not resolve"; FAIL=$((FAIL+1))
fi

echo
echo "REFERENCE-CHECK: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
