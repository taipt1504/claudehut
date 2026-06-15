#!/usr/bin/env bash
# Oracle for review-catches-defects (v0.5 review-rigor verification).
# The task tempts 4 classic Java/Spring defects (N+1 / EAGER collection / missing @Valid /
# entity-as-request-body). A rigorous Review phase must ensure the SHIPPED code has none of them.
# These are HEURISTIC static checks on the final working tree + the review artifact — not a compiler.
# Each check prints its verdict so a live run is debuggable. (Tune patterns if a false-negative shows up.)
set -uo pipefail
work="$1"; src="$work/src/main"; chd="$work/.claude/claudehut"
fail=0
chk() { if eval "$2"; then echo "  oracle ✓ $1"; else echo "  oracle ✗ $1"; fail=1; fi; }

# The feature was implemented at all (a summary endpoint exists).
chk "summary endpoint implemented" \
  'grep -rqiE "summary" "$src" 2>/dev/null'

# CLEAN-INPUT: the POST body is validated — @Valid or @Validated guards a @RequestBody somewhere.
chk "POST body validated (@Valid/@Validated on a @RequestBody)" \
  'grep -rqE "@Valid|@Validated" "$src" 2>/dev/null && grep -rqE "@RequestBody" "$src" 2>/dev/null'

# NO ENTITY-AS-BODY: a request DTO type exists (record/class named *Request/*Dto/*Command) — the
# controller should bind a DTO, not the Order @Entity. (Heuristic: such a type is present in src.)
chk "request DTO present (not entity bound as @RequestBody)" \
  'grep -rqiE "class +[A-Za-z]*(Request|Dto|Command)|record +[A-Za-z]*(Request|Dto|Command)" "$src" 2>/dev/null'

# CLEAN-FETCH: the @OneToMany collection was NOT switched to EAGER (LAZY default kept).
chk "no FetchType.EAGER introduced on collections" \
  '! grep -rqE "FetchType\.EAGER|fetch *= *EAGER" "$src" 2>/dev/null'

# RIGOR ARTIFACT: review.md exists with a coverage-table row (the v0.5 contract output).
chk "review.md has a coverage table" \
  'grep -rqiE "^[[:space:]]*\|.*(✓|✗|satisfied|violated|n-?/?a)" "$chd"/tasks/*/review.md 2>/dev/null'

# PERF DIMENSION EXERCISED: review.md shows the perf reviewer actually engaged the data-access surface
# (mentions N+1 / fetch join / @EntityGraph / lazy) — evidence depth, not a skim.
chk "review engaged the perf/data-access dimension" \
  'grep -rqiE "N\+1|EntityGraph|join fetch|fetch join|lazy|fetch strateg" "$chd"/tasks/*/review.md 2>/dev/null'

# Workflow actually reached an earned pass (state).
st=$(ls -t "$chd"/state/*.json 2>/dev/null | head -1)
chk "review reached pass with recorded evidence" \
  '[ -n "$st" ] && jq -e ".review==\"pass\" and (.review_evidence|type==\"string\")" "$st" >/dev/null 2>&1'

[ "$fail" -eq 0 ]
