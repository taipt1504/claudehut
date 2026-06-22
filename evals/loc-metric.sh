#!/usr/bin/env bash
# Minimalism / cost yardstick (audit track D4). Two deterministic measurements over a
# completed work-tree, so the ponytail "lazy senior dev" layer is provable before/after:
#
#   net_loc_added     — net production Java added (added − deleted, src/main only, tests excluded).
#                       Less code = fewer defects AND fewer output tokens (the link to the cost track).
#   reuse_rate        — share of reuse-scan DECISIONS that AVOIDED new code
#                       (drop|framework|adopt|extend) vs total. Higher = lazier = cheaper.
#
# The metric HARNESS is deterministic and needs no Claude (run `--self-test`). Producing live
# numbers needs a completed run; point it at the work-dir.
#
# HONESTY BOUNDARY (ponytail's /ponytail-gain rule): net_loc_added and reuse_rate are MEASURED
# facts about one run. A "% LOC saved" figure is NOT — the un-built version was never written, so
# there is no real baseline to subtract from. Only report a savings % from a real baseline ARM
# (e.g. a no-plugin run on the same task); never fabricate the counterfactual.
#
# Usage:
#   evals/loc-metric.sh <work-dir> [baseline-ref]     # measure (baseline default: HEAD~1 or empty tree)
#   evals/loc-metric.sh --self-test                   # deterministic parser test (no Claude, no git)
set -uo pipefail

# ---- reuse-decision parser (pure text — the deterministically testable core) ----
# Counts DECISION cells in reuse-scan Summary tables. Decisions that avoid new code:
# drop (YAGNI) | framework (stdlib/Spring/dep) | adopt | extend. New code: new.
count_decisions() {
  # stdin = concatenated reuse-scan markdown. Emits: drop framework adopt extend new total
  awk -F'|' '
    /^\|/ {
      # a Summary row has >=4 pipe-fields; Decision is the 3rd content column (col 4 with leading |)
      d=tolower($4); gsub(/[^a-z]/,"",d)
      if (d=="drop")       drop++
      else if (d=="framework") fw++
      else if (d=="adopt")     adopt++
      else if (d=="extend")    ext++
      else if (d=="new")       neu++
    }
    END { printf "%d %d %d %d %d %d\n", drop,fw,adopt,ext,neu, drop+fw+adopt+ext+neu }
  '
}

if [ "${1:-}" = "--self-test" ]; then
  sample='# Reuse Scan: demo
## Summary
| Dimension | Existing asset | Decision | Effort |
|-----------|----------------|----------|--------|
| necessity | speculative cache | drop | - |
| retries | Resilience4j @Retry | framework | S |
| slugify | `TextUtils` | adopt | S |
| filter | `RequestKeyFilter` | extend | S |
| reaper | none | new | M |
'
  read -r drop fw adopt ext neu total < <(printf '%s\n' "$sample" | count_decisions)
  ok=0
  [ "$drop" = 1 ] && [ "$fw" = 1 ] && [ "$adopt" = 1 ] && [ "$ext" = 1 ] && [ "$neu" = 1 ] && [ "$total" = 5 ] || ok=1
  # reuse_rate = (drop+fw+adopt+ext)/total = 4/5 = 0.80
  rate=$(awk -v a="$drop" -v b="$fw" -v c="$adopt" -v d="$ext" -v t="$total" 'BEGIN{printf (t?"%.2f":"0.00"), (a+b+c+d)/t}')
  [ "$rate" = "0.80" ] || ok=1
  if [ "$ok" = 0 ]; then echo "  ok   - self-test: drop=$drop fw=$fw adopt=$adopt ext=$ext new=$neu rate=$rate"; exit 0
  else echo "  FAIL - self-test: drop=$drop fw=$fw adopt=$adopt ext=$ext new=$neu total=$total rate=$rate"; exit 1; fi
fi

work="${1:?usage: loc-metric.sh <work-dir> [baseline-ref]  (or --self-test)}"
base="${2:-}"
chd="$work/.claude/claudehut"

# ---- reuse_rate from the canonical store (tasks/NNNN-*/reuse-scan.md) + legacy flat ----
scans="$( { find "$chd/tasks" -name 'reuse-scan.md' 2>/dev/null; ls "$chd"/reuse-scan-*.md 2>/dev/null; } )"
if [ -n "$scans" ]; then
  read -r drop fw adopt ext neu total < <(cat $scans 2>/dev/null | count_decisions)
else
  drop=0; fw=0; adopt=0; ext=0; neu=0; total=0
fi
reuse_rate=$(awk -v a="$drop" -v b="$fw" -v c="$adopt" -v d="$ext" -v t="$total" 'BEGIN{printf (t?"%.2f":"0.00"), (a+b+c+d)/(t?t:1)}')

# ---- net production LOC added (src/main Java, tests excluded) ----
net_loc=0; prod_files=0
if command -v git >/dev/null 2>&1 && git -C "$work" rev-parse --git-dir >/dev/null 2>&1; then
  if [ -z "$base" ]; then
    base="$(git -C "$work" rev-parse HEAD~1 2>/dev/null || true)"
  fi
  # empty-tree sha as fallback baseline (whole tree counts as added)
  [ -z "$base" ] && base="$(git -C "$work" hash-object -t tree /dev/null 2>/dev/null)"
  numstat="$(git -C "$work" diff --numstat "$base" -- 'src/main/**/*.java' 2>/dev/null || true)"
  if [ -n "$numstat" ]; then
    net_loc="$(printf '%s\n' "$numstat" | awk '{a+=$1; d+=$2} END{print a-d+0}')"
    prod_files="$(printf '%s\n' "$numstat" | grep -cE '.' || echo 0)"
  fi
fi

jq -n \
  --argjson net "$net_loc" --argjson files "$prod_files" \
  --argjson drop "$drop" --argjson fw "$fw" --argjson adopt "$adopt" \
  --argjson ext "$ext" --argjson neu "$neu" --argjson total "$total" \
  --arg rate "$reuse_rate" \
  '{net_loc_added:$net, prod_files_changed:$files,
    reuse_decisions:{drop:$drop,framework:$fw,adopt:$adopt,extend:$ext,new:$neu,total:$total},
    reuse_rate:($rate|tonumber)}' 2>/dev/null \
  || echo "{\"net_loc_added\":$net_loc,\"reuse_rate\":$reuse_rate}"
