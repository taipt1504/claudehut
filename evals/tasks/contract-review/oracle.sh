#!/usr/bin/env bash
# Oracle for contract-review (v0.9 Rec 2 — message/API contract compatibility as a Review gate).
# The task adds a field to a published Avro event; a rigorous review must ensure it evolves ADDITIVELY
# (optional + default = backward compatible) WITH a contract test, AND its review.md engaged the contract
# axis. End-to-end static checks on the final tree + review artifact — the goal is met whether Implement
# evolved it safely or Review caught a breaking change. Heuristic grep/jq — tune patterns on a false-negative.
set -uo pipefail
work="$1"; chd="$work/.claude/claudehut"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
. "$ROOT/evals/lib/artifact-checks.sh" 2>/dev/null || true
fail=0
chk() { if eval "$2"; then echo "  oracle ✓ $1"; else echo "  oracle ✗ $1"; fail=1; fi; }

# Field added at all.
chk "discountCode field added to the event schema" 'grep -rqi "discountCode" "$work" --include=*.avsc 2>/dev/null'

# OUTCOME 1 — the new field is ADDITIVE (optional, carries a default) → backward compatible, not a bare
# required field. A compatible Avro addition always ships a "default".
chk "schema evolved additively (new field carries a default — backward compatible)" \
  'grep -rqi "\"default\"" "$work" --include=*.avsc 2>/dev/null'

# OUTCOME 2 — a contract test exists for the changed event (Spring Cloud Contract / Pact).
chk "contract test present (Spring Cloud Contract / Pact)" \
  '{ grep -rqiE "spring-cloud-contract|ContractVerifier|StubRunner|au\.com\.dius|[Pp]act" "$work"/src 2>/dev/null; } || { ls "$work"/src/test/resources/contracts/* >/dev/null 2>&1; }'

# ENGAGEMENT — review.md carries a contract-axis row (schema-compat / backward / avro / contract-test).
rv="$(ls "$chd"/tasks/*/review.md 2>/dev/null | head -1)"
chk "review.md engaged the contract axis (schema-compat / backward / avro / contract row)" \
  '[ -n "$rv" ] && grep -qiE "schema|compat|avro|contract|backward|breaking" "$rv" 2>/dev/null'

# Workflow reached an earned pass with recorded evidence.
st=$(ls -t "$chd"/state/*.json 2>/dev/null | head -1)
chk "review reached pass with recorded evidence" \
  '[ -n "$st" ] && jq -e ".review==\"pass\" and (.review_evidence|type==\"string\")" "$st" >/dev/null 2>&1'

[ "$fail" -eq 0 ]
