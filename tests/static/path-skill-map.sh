#!/usr/bin/env bash
# tests/static/path-skill-map.sh  (Phase 6.1d)
#
# A path -> rule resolver that PROVES rule globs actually match realistic file
# paths -- the value a presence-grep + count assertion (L1.7 / L4) cannot give:
# a typo'd glob ("**/*NatListener*.java") passes both of those but fails here.
#
# Globs are EXTRACTED FROM FRONTMATTER AT RUNTIME (awk), never hardcoded, so the
# test tracks the rules as they change. Matching uses bash `[[ path == glob ]]`.
# NOTE on semantics: Claude Code's native loader matches `paths:` with minimatch
# (globstar), where `*` does NOT cross `/` and `**/` does. bash `[[ ]]` has no
# globstar -- its `*` spans `/` too -- so it is BROADER than minimatch. That is
# fine for presence/gap assertions (every minimatch hit is also a bash hit; the
# negative Controller case holds because no messaging glob mentions Controller).
# MUST run under real bash (the shebang + run-all.sh's `bash ...` ensure this);
# under zsh, `[[ path == $glob ]]` treats $glob literally and every match fails.
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PLUGIN_ROOT"

PASS=0; FAIL=0
declare -a FAIL_LIST=()
pass() { printf "  \033[32m✓\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
fail() { printf "  \033[31m✗\033[0m %s :: %s\n" "$1" "$2"; FAIL=$((FAIL+1)); FAIL_LIST+=("$1: $2"); }

# Extract the quoted globs from a rule file's `paths:` frontmatter block.
_globs_of() {
  awk '/^---[[:space:]]*$/{n++; if(n==2)exit} n==1' "$1" \
  | awk '/^paths:/{f=1;next} f&&/^[a-z_]+:/{f=0} f&&/^[[:space:]]*-[[:space:]]/{
           s=$0; sub(/^[[:space:]]*-[[:space:]]*"?/,"",s); sub(/"[[:space:]]*$/,"",s); print s }'
}

# resolve <path> -> space-padded list of rule basenames whose globs match <path>.
resolve() {
  local path="$1" rule glob hits=" "
  for rule in $(find rules -name '*.md' | sort); do
    while IFS= read -r glob; do
      [[ -n "$glob" ]] || continue
      # shellcheck disable=SC2053  -- intentional glob (RHS unquoted = pattern)
      if [[ "$path" == $glob ]]; then
        hits="$hits$(basename "$rule" .md) "
        break   # one hit per rule
      fi
    done < <(_globs_of "$rule")
  done
  printf '%s' "$hits"
}
_has() { [[ "$1" == *" $2 "* ]]; }   # _has "<resolved>" <rule-name>

echo "===== PATH -> RULE RESOLVER ====="
echo ""

# Realistic FULL paths (with slashes) -- bare basenames would not exercise `**/`.
p_nats="src/main/java/com/acme/order/OrderNatsListener.java"
p_rabbit="src/main/java/com/acme/order/OrderRabbitListener.java"
p_controller="src/main/java/com/acme/web/PaymentController.java"
p_flyway="src/main/resources/db/migration/V1__init__orders.sql"

r_nats="$(resolve "$p_nats")"
r_rabbit="$(resolve "$p_rabbit")"
r_controller="$(resolve "$p_controller")"
r_flyway="$(resolve "$p_flyway")"

# 1. The gap that 6.1a/b closed: messaging listener paths resolve to their rule.
_has "$r_nats" nats        && pass "OrderNatsListener.java -> nats rule (gap closed; RED before nats.md)" \
                           || fail "nats resolve" "OrderNatsListener.java did not resolve to nats (got:$r_nats)"
_has "$r_rabbit" rabbitmq  && pass "OrderRabbitListener.java -> rabbitmq rule (gap closed; RED before rabbitmq.md)" \
                           || fail "rabbitmq resolve" "OrderRabbitListener.java did not resolve to rabbitmq (got:$r_rabbit)"

# 2. Non-over-trigger: a plain Controller fires NO messaging rule (glob is selective).
overtrig=""
for m in nats rabbitmq kafka-consumer kafka-producer; do _has "$r_controller" "$m" && overtrig="$overtrig $m"; done
[[ -z "$overtrig" ]] && pass "PaymentController.java -> NO messaging rule (selective; got:$r_controller)" \
                     || fail "over-trigger" "Controller wrongly fired:$overtrig"

# 3. Resolver works across rule families (not just messaging) -- sanity on flyway.
_has "$r_flyway" flyway-naming && pass "V*.sql under db/migration -> flyway-naming (resolver family-agnostic)" \
                               || fail "flyway resolve" "migration path did not resolve to flyway-naming (got:$r_flyway)"

echo ""
echo "===== SUMMARY ====="
printf "Total: %d   \033[32mPass: %d\033[0m   \033[31mFail: %d\033[0m\n" $((PASS+FAIL)) "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  echo ""; echo "FAILURES:"; for f in "${FAIL_LIST[@]}"; do echo "  - $f"; done
  exit 1
fi
exit 0
