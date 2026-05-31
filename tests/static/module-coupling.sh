#!/usr/bin/env bash
# tests/static/module-coupling.sh  (Phase 6.3)
#
# Proves the modularization PARTITION (modularization/modules.json) is real, not
# asserted. The design doc's objection to 6.3 was "the taxonomy doesn't partition —
# jackson/lombok/mapstruct/testcontainers/wiremock are cross-cutting." The seam
# answers it (cross-cutting -> core); this test settles it EMPIRICALLY:
#
#   1. COMPLETE + DISJOINT: every skill (31) and rule (47) is assigned to exactly
#      one module — no skill/rule unowned or double-owned.
#   2. NO pack->pack EDGE: scanning all `claudehut:<x>` references, no file in one
#      domain pack (spring|messaging|quality) references a skill owned by a DIFFERENT
#      pack. Packs are mutually independent; they may depend only on core (and self).
#      That is the property a future split needs — and the proof the partition holds.
#
# A logical partition (CC discovers skills only at flat skills/<name>/, and CC plugins
# are independent units with no cross-plugin refs / dependency resolution — issue
# #9444 — so physical distribution is BLOCKED-ON-PLATFORM). This manifest+proof is
# the substrate a post-#9444 split consumes directly.
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PLUGIN_ROOT"
MANIFEST="modularization/modules.json"
PACKS="spring messaging quality"

PASS=0; FAIL=0
declare -a FAIL_LIST=()
pass() { printf "  \033[32m✓\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
fail() { printf "  \033[31m✗\033[0m %s :: %s\n" "$1" "$2"; FAIL=$((FAIL+1)); FAIL_LIST+=("$1: $2"); }

echo "===== MODULE PARTITION + COUPLING ====="
echo ""

# Flatten the manifest into a lookup table: "<kind>\t<key>\t<module>".
MAP="$(mktemp)"
jq -r '.modules | to_entries[] | .key as $m
       | (.value.skills[]? | "skill\t\(.)\t\($m)"),
         (.value.rules[]?  | "rule\t\(.)\t\($m)")' "$MANIFEST" > "$MAP"

mod_of_skill() { awk -F'\t' -v s="$1" '$1=="skill"&&$2==s{print $3;f=1;exit} END{if(!f)print "core"}' "$MAP"; }   # agents/unknown -> core
mod_of_rule()  { awk -F'\t' -v r="$1" '$1=="rule" &&$2==r{print $3;f=1;exit} END{if(!f)print "UNASSIGNED"}' "$MAP"; }
is_pack() { case " $PACKS " in *" $1 "*) return 0;; *) return 1;; esac; }

# --- 1. COMPLETE + DISJOINT partition --------------------------------------
# skills
miss_sk=0; dup_sk=0
for d in skills/*/; do
  name="$(basename "$d")"
  n="$(awk -F'\t' -v s="$name" '$1=="skill"&&$2==s{c++} END{print c+0}' "$MAP")"
  [[ "$n" -eq 0 ]] && { echo "    skill UNASSIGNED: $name"; miss_sk=$((miss_sk+1)); }
  [[ "$n" -gt 1 ]] && { echo "    skill DOUBLE-assigned: $name"; dup_sk=$((dup_sk+1)); }
done
n_sk_dir="$(ls -d skills/*/ | wc -l | tr -d ' ')"
n_sk_map="$(awk -F'\t' '$1=="skill"{c++} END{print c+0}' "$MAP")"
{ [[ "$miss_sk" -eq 0 && "$dup_sk" -eq 0 && "$n_sk_dir" -eq "$n_sk_map" ]]; } \
  && pass "all $n_sk_dir skills assigned to exactly one module (complete + disjoint)" \
  || fail "skill partition" "miss=$miss_sk dup=$dup_sk dir=$n_sk_dir map=$n_sk_map"

# rules
miss_r=0; dup_r=0
for f in $(find rules -name '*.md'); do
  key="${f#rules/}"; key="${key%.md}"
  n="$(awk -F'\t' -v r="$key" '$1=="rule"&&$2==r{c++} END{print c+0}' "$MAP")"
  [[ "$n" -eq 0 ]] && { echo "    rule UNASSIGNED: $key"; miss_r=$((miss_r+1)); }
  [[ "$n" -gt 1 ]] && { echo "    rule DOUBLE-assigned: $key"; dup_r=$((dup_r+1)); }
done
n_r_dir="$(find rules -name '*.md' | wc -l | tr -d ' ')"
n_r_map="$(awk -F'\t' '$1=="rule"{c++} END{print c+0}' "$MAP")"
{ [[ "$miss_r" -eq 0 && "$dup_r" -eq 0 && "$n_r_dir" -eq "$n_r_map" ]]; } \
  && pass "all $n_r_dir rules assigned to exactly one module (complete + disjoint)" \
  || fail "rule partition" "miss=$miss_r dup=$dup_r dir=$n_r_dir map=$n_r_map"

# --- 2. NO pack->pack reference edge ---------------------------------------
module_of_file() {
  case "$1" in
    agents/*) echo "core" ;;                                  # personas = engine
    rules/*)  k="${1#rules/}"; mod_of_rule "${k%.md}" ;;
    skills/*) echo "$1" | cut -d/ -f2 | while read -r s; do mod_of_skill "$s"; done ;;
    *) echo "core" ;;
  esac
}
declare -a EDGES=()
violations=0
for f in $(find agents rules skills -name '*.md'); do
  src="$(module_of_file "$f")"
  for x in $(grep -ohE 'claudehut:[a-z0-9-]+' "$f" 2>/dev/null | sed 's/^claudehut://' | sort -u); do
    tgt="$(mod_of_skill "$x")"     # agent/engine/unknown refs resolve to core
    [[ "$src" == "$tgt" ]] && continue
    EDGES+=("$src->$tgt")
    if is_pack "$src" && is_pack "$tgt"; then
      echo "    PACK->PACK: $f ($src) -> claudehut:$x ($tgt)"
      violations=$((violations+1))
    fi
  done
done
[[ "$violations" -eq 0 ]] \
  && pass "no pack->pack reference edge — spring/messaging/quality are mutually independent (taxonomy DOES partition)" \
  || fail "coupling" "$violations pack->pack edge(s) — those refs reveal what belongs in core"

# Cross-module edge summary (informational; core<->pack edges are expected + fine)
echo "  --- cross-module edges (unique kinds) ---"
[[ "${#EDGES[@]}" -gt 0 ]] && printf '%s\n' "${EDGES[@]}" | sort | uniq -c | sed 's/^/    /' || echo "    (none)"

echo ""
echo "===== SUMMARY ====="
printf "Total: %d   \033[32mPass: %d\033[0m   \033[31mFail: %d\033[0m\n" $((PASS+FAIL)) "$PASS" "$FAIL"
rm -f "$MAP"
if [[ "$FAIL" -gt 0 ]]; then
  echo ""; echo "FAILURES:"; for f in "${FAIL_LIST[@]}"; do echo "  - $f"; done
  exit 1
fi
exit 0
