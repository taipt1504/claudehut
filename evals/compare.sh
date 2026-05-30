#!/usr/bin/env bash
# compare.sh <results-A.jsonl> <results-B.jsonl>   # A/B table (default)
# compare.sh --variance <results.jsonl>            # per-(task,mode) mean + variance
#
# Default: per-task A/B table (latest row per task in each file). Falsifies "the
# apparatus helps": compare claudehut vs baseline on pass@1, retries, cost, wall.
#
# --variance: pass@k stability. Given k repeated runs of each task in ONE file,
# print per-(task,mode) mean + population variance of pass@1 / cost / wall. Makes
# the "parity at LOWER variance" gate (a Phase 7.1 SDK-replatform precondition)
# executable: a re-platform must hold pass@1 while not raising variance. A null
# pass_at_1 (ungradeable run) counts as 0.
set -euo pipefail

if [[ "${1:-}" == "--variance" ]]; then
  F="${2:?usage: compare.sh --variance <results.jsonl>}"
  [[ -f "$F" ]] || { echo "results file not found: $F" >&2; exit 2; }
  printf '%-22s %-10s | %3s | %-9s %-9s | %-10s %-10s | %-12s %-12s\n' \
    "task" "mode" "n" "mean_pass" "var_pass" "mean_cost" "var_cost" "mean_wall" "var_wall"
  jq -r '[.task, (.mode // "-"), (.pass_at_1 // 0), (.cost_usd // 0), (.wall_ms // 0)] | @tsv' "$F" \
  | awk -F'\t' '
      { k=$1 SUBSEP $2; tk[k]=$1; md[k]=$2; n[k]++;
        sp[k]+=$3; sp2[k]+=$3*$3; sc[k]+=$4; sc2[k]+=$4*$4; sw[k]+=$5; sw2[k]+=$5*$5 }
      END {
        for (k in n) {
          c=n[k];
          mp=sp[k]/c; vp=sp2[k]/c-mp*mp; if(vp<0)vp=0;   # E[x^2]-E[x]^2, clamp FP noise
          mc=sc[k]/c; vc=sc2[k]/c-mc*mc; if(vc<0)vc=0;
          mw=sw[k]/c; vw=sw2[k]/c-mw*mw; if(vw<0)vw=0;
          printf "%-22s %-10s | %3d | %-9.4f %-9.4f | %-10.6f %-10.6f | %-12.1f %-12.1f\n",
                 tk[k], md[k], c, mp, vp, mc, vc, mw, vw;
        }
      }' | sort
  exit 0
fi

A="${1:?usage: compare.sh <A.jsonl> <B.jsonl>}"; B="${2:?usage: compare.sh <A.jsonl> <B.jsonl>}"
[[ -f "$A" && -f "$B" ]] || { echo "both result files must exist" >&2; exit 2; }
_latest() { jq -s --arg t "$1" 'map(select(.task==$t)) | last // {}' "$2"; }
printf '%-22s | %-26s | %-26s\n' "task / metric" "$(basename "$A" .jsonl)" "$(basename "$B" .jsonl)"
printf -- '-%.0s' {1..80}; echo
tasks="$(cat "$A" "$B" | jq -r '.task' | sort -u)"
for t in $tasks; do
  ra="$(_latest "$t" "$A")"; rb="$(_latest "$t" "$B")"
  for m in terminal_status pass_at_1 retries cost_usd wall_ms; do
    va="$(printf '%s' "$ra" | jq -r ".$m // \"-\"")"
    vb="$(printf '%s' "$rb" | jq -r ".$m // \"-\"")"
    printf '%-22s | %-26s | %-26s\n' "$t.$m" "$va" "$vb"
  done
  printf -- '-%.0s' {1..80}; echo
done
