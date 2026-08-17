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

# TOOLS-01 — the inventory check above is structurally blind to the defect it exists to catch. It greps for
# the `mcp__server__tool` shape, so an agent body that tells its reader to "use `describe_topic`" matches
# nothing and ships green — while the runtime has no tool by that bare name and the call is rejected. Two
# bodies shipped exactly that. Scope this to `## MCP` sections: a repo-wide sweep for tool-shaped identifiers
# false-positives on ordinary prose (`KafkaTemplate`, `application.yml`, SQL keywords). Match hyphen AND
# underscore forms — the real Kafka names are hyphenated (`mcp__kafka__list-topics`), so an underscore-only
# pattern would be blind to the likeliest next slip. Tokens naming a real agent or bin/ executable
# (`claudehut-init`) are plugin references, not tool calls.
BARE=""
for f in "$ROOT"/agents/*.md; do
  sec="$(awk '/^## MCP/{p=1;next} /^## /{p=0} p' "$f" 2>/dev/null)"
  [ -n "$sec" ] || continue
  for tok in $(printf '%s\n' "$sec" | grep -ohE '`[a-z0-9]+([_-][a-z0-9]+)+`' | tr -d '`' | sort -u); do
    case "$tok" in mcp__*) continue ;; esac
    { [ -f "$ROOT/agents/$tok.md" ] || [ -e "$ROOT/bin/$tok" ]; } && continue
    BARE="$BARE $(basename "$f" .md):$tok"
  done
done
if [ -z "${BARE// /}" ]; then
  echo "  ok   - MCP prose: every tool named in a '## MCP' section is fully qualified"; PASS=$((PASS+1))
else
  echo "  FAIL - MCP prose: bare tool name(s) with no mcp__server__tool prefix (the runtime has no such tool):$BARE"; FAIL=$((FAIL+1))
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
  # Slug as the RENDERER does: a markdown link contributes its TEXT, not its URL, and a run of spaces
  # (what an em-dash leaves behind) becomes a run of hyphens, because the renderer keeps the empty
  # segment. Getting either wrong reports live anchors as dead — measured: the naive slug called 8 of 9
  # design-doc anchors broken when only 1 was.
  if ! grep -E '^#{1,6} ' "$hit" \
       | sed -E 's/^#+ //; s/\[([^]]*)\]\([^)]*\)/\1/g; s/[^a-zA-Z0-9 -]//g; s/ /-/g' \
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

# D10: the design docs are git-tracked (.gitignore exempts .claude/docs/) and carry 279 anchors. They were
# written off as "26 pre-existing broken"; measured with a correct slug, exactly ONE was. The 26 came from a
# slug that kept URLs and collapsed space runs. Now they are covered, so the count cannot drift back up.
dd_bad=0; dd_n=0
if [ -d "$ROOT/.claude/docs/design" ]; then
  for f in "$ROOT"/.claude/docs/design/*.md; do
    [ -f "$f" ] || continue
    while IFS='|' read -r tgt frag; do
      [ -n "$frag" ] || continue
      dd_n=$((dd_n+1))
      t="$ROOT/.claude/docs/design/${tgt:-$(basename "$f")}"
      if [ ! -f "$t" ]; then
        echo "  FAIL - design anchor target missing: $(basename "$f") -> $tgt"; dd_bad=$((dd_bad+1)); continue
      fi
      if ! sed -nE 's/^#+ //p' "$t" \
           | sed -E 's/\[([^]]*)\]\([^)]*\)/\1/g; s/[^a-zA-Z0-9 -]//g; s/ /-/g' \
           | tr '[:upper:]' '[:lower:]' | grep -qx "$frag"; then
        echo "  FAIL - design anchor dead: $(basename "$f") -> ${tgt:-$(basename "$f")}#$frag"; dd_bad=$((dd_bad+1))
      fi
    done < <(grep -ohE '\]\(\.?/?[0-9A-Za-z._-]*\.md#[a-z0-9-]+\)|\]\(#[a-z0-9-]+\)' "$f" 2>/dev/null \
             | sed -E 's/^\]\(\.?\/?//; s/\)$//; s/#/|/')
  done
fi
if [ "$dd_bad" = "0" ]; then
  echo "  ok   - all $dd_n design-doc anchor(s) resolve"; PASS=$((PASS+1))
else
  echo "  FAIL - $dd_bad of $dd_n design-doc anchor(s) do not resolve"; FAIL=$((FAIL+1))
fi

# A literal NUL makes a file BINARY to git, grep and every review tool — the content is still there and
# every search silently stops finding it. This project shipped that once in v0.10 (merge-learnings.sh and
# record-failure.sh, where a NUL separator was written raw instead of as \u0000), and the v0.11 plan file
# arrived with one for the same reason: prose DESCRIBING the separator. Cheap to check, invisible without it.
nul_bad=0
while IFS= read -r f; do
  case "$f" in *.png|*.jpg|*.gif|*.ico|*.zip) continue ;; esac
  [ -f "$ROOT/$f" ] || continue
  if LC_ALL=C tr -d '\000' < "$ROOT/$f" | cmp -s - "$ROOT/$f"; then : ; else
    echo "  FAIL - NUL byte in tracked text file: $f (git will treat it as binary)"; nul_bad=$((nul_bad+1))
  fi
done < <(cd "$ROOT" && git ls-files 2>/dev/null)
if [ "$nul_bad" = "0" ]; then
  echo "  ok   - no tracked text file contains a NUL byte"; PASS=$((PASS+1))
else
  echo "  FAIL - $nul_bad tracked file(s) contain a NUL byte"; FAIL=$((FAIL+1))
fi

# MF-15 — `claude plugin validate . --strict` is not the manifest gate ci.yml:102 treats it as. Run against
# this repo it prints "Validating marketplace manifest" and then passes: it inspects marketplace.json ONLY,
# so nothing it does covers plugin.json or the relationship between the two files. It also runs "if CLI
# present" (ci.yml:92), so it can skip with no signal at all. The three assertions below are what it does
# not cover, they are deterministic, and they run unconditionally.
MKT="$ROOT/.claude-plugin/marketplace.json"
PLG="$ROOT/.claude-plugin/plugin.json"

# MF-12 — a live landmine, not a gap. marketplace.json's entry is `"source": "./"`, which resolves to the
# marketplace ROOT — and for a marketplace entry whose source resolves to the marketplace root, declaring
# specific subdirectories REPLACES the default `skills/` scan rather than adding to it. Today no `skills`
# key exists, so every skill directory loads. Anyone who later adds one as a "scoping optimization"
# silently drops every skill not listed: no error, no warning, they just stop existing.
# Assert the ABSENCE OF THE KEY, never a skill count — a count goes red the first time someone legitimately
# adds a skill, which teaches the next author to delete the assertion.
mkt_root="$(jq -r '[.plugins[]? | select(.source == "./" or .source == ".")] | length' "$MKT" 2>/dev/null)"
mkt_skills="$(jq -r '[.plugins[]? | select(.source == "./" or .source == ".") | select(has("skills")) | .name] | join(" ")' "$MKT" 2>/dev/null)"
if [ "${mkt_root:-0}" = "0" ]; then
  # Not a pass. The replace-not-merge rule is specific to a root-resolving source; if no entry resolves to
  # the root any more, this assertion has stopped measuring anything and must be re-derived, not skipped.
  echo "  FAIL - MF-12: no marketplace entry sources from the marketplace root — the skills-scan rule this asserts no longer applies; re-derive it"; FAIL=$((FAIL+1))
elif [ -n "$mkt_skills" ]; then
  echo "  FAIL - MF-12: root-sourced marketplace entry declares a 'skills' key ($mkt_skills) — at a root source that REPLACES the default skills/ scan, so every skill not listed there vanishes silently"; FAIL=$((FAIL+1))
else
  echo "  ok   - MF-12: marketplace.json declares no 'skills' key (the default skills/ scan is intact)"; PASS=$((PASS+1))
fi

# MF-15(b) — the marketplace ENTRY name is what `enabledPlugins` keys, not plugin.json's name. They are
# both `claudehut` today and nothing in the toolchain compares them, so a rename on one side strands every
# existing user's enablement entry while both files stay individually valid.
plg_name="$(jq -r '.name // empty' "$PLG" 2>/dev/null)"
ent_n="$(jq -r --arg n "$plg_name" '[.plugins[]? | select(.name == $n)] | length' "$MKT" 2>/dev/null)"
if [ -n "$plg_name" ] && [ "${ent_n:-0}" = "1" ]; then
  echo "  ok   - MF-15: plugin.json name '$plg_name' matches exactly one marketplace entry (the key enabledPlugins uses)"; PASS=$((PASS+1))
else
  echo "  FAIL - MF-15: plugin.json name '$plg_name' matches ${ent_n:-0} marketplace entries — enabledPlugins keys off the ENTRY name, so a mismatch silently disables the plugin for existing users"; FAIL=$((FAIL+1))
fi

# MF-10 mirrors author/homepage/repository/license into the marketplace entry so the listing carries the
# same provenance the manifest does. Mirroring creates a drift surface that did not exist before: two
# copies, no tool comparing them, and a bumped version in one file only is exactly the kind of change a
# release makes. `category` and `keywords` are deliberately NOT compared — category has no plugin.json
# counterpart, and the two keyword lists already differ by design.
mf10_drift=""
for k in version homepage repository license; do
  a="$(jq -r --arg k "$k" '.[$k] // empty' "$PLG" 2>/dev/null)"
  b="$(jq -r --arg k "$k" --arg n "$plg_name" '[.plugins[]? | select(.name == $n)][0] | .[$k] // empty' "$MKT" 2>/dev/null)"
  [ "$a" = "$b" ] || mf10_drift="$mf10_drift $k(plugin.json='$a' marketplace='$b')"
done
a="$(jq -r '.author.name // empty' "$PLG" 2>/dev/null)"
b="$(jq -r --arg n "$plg_name" '[.plugins[]? | select(.name == $n)][0] | .author.name // empty' "$MKT" 2>/dev/null)"
[ "$a" = "$b" ] || mf10_drift="$mf10_drift author.name(plugin.json='$a' marketplace='$b')"
if [ -z "${mf10_drift// /}" ]; then
  echo "  ok   - MF-10: version/homepage/repository/license/author.name agree across plugin.json and the marketplace entry"; PASS=$((PASS+1))
else
  echo "  FAIL - MF-10: mirrored manifest metadata has drifted —$mf10_drift"; FAIL=$((FAIL+1))
fi

# The README's eval counts were stale by an order of magnitude — it advertised "49 structural checks" for a
# suite that had grown to 270. A count in prose rots the moment a test is added, so pin the claim: every
# number the README states for a suite must match what that suite actually reports.
# reference-check.sh is deliberately NOT in this list: a suite that asserts its own advertised count would
# have to run itself. Its README number is maintained by hand and is the one entry this check cannot cover.
rd_bad=0
while IFS='|' read -r script claimed; do
  [ -n "$claimed" ] || continue
  actual="$(bash "$ROOT/evals/$script" 2>/dev/null | grep -oE '[0-9]+ passed' | head -1 | grep -oE '[0-9]+')"
  [ "$actual" = "$claimed" ] \
    || { echo "  FAIL - README claims $claimed assertions for $script, it reports ${actual:-none}"; rd_bad=$((rd_bad+1)); }
done <<'PAIRS'
conformance.sh|270
gate-tests.sh|105
init-tests.sh|115
merge-learnings-tests.sh|51
worktree-tests.sh|53
artifact-oracle-tests.sh|14
ranker-tests.sh|8
PAIRS
if [ "$rd_bad" = "0" ]; then
  echo "  ok   - README eval counts match the suites"; PASS=$((PASS+1))
else
  echo "  FAIL - $rd_bad README eval count(s) are stale"; FAIL=$((FAIL+1))
fi

echo
echo "REFERENCE-CHECK: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
