#!/usr/bin/env bash
# classify.sh — deterministic intent → route-profile suggestion (Routing pattern,
# Anthropic "Building Effective Agents": "classification can be handled accurately,
# either by an LLM or a more traditional classification model/algorithm").
#
# Reads the task description (args or stdin) and emits a suggestion as JSON:
#   {"profile":"quick|full","db_review":bool,"reason":"...","signal":"..."}
#
# CONSERVATIVE BY CONSTRUCTION: 'quick' requires an explicit trivial signal AND
# the absence of any complexity/migration signal. Everything else → 'full'. A
# misclassification therefore errs toward MORE ceremony, never less — it can
# never silently strip the design gate from a real feature. The orchestrator may
# override this suggestion deliberately, but the default is safe.
set -euo pipefail

text="$*"
[[ -z "$text" ]] && text="$(cat 2>/dev/null || true)"
lc="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"

# Order matters: migration is the most consequential (mandatory DB review), then
# any structural/feature signal, then trivial. First match wins.
MIGRATION='migration|flyway|liquibase|[^a-z]ddl([^a-z]|$)|alter table|create table|drop (table|column)|add column|schema (change|migration)|\.sql([^a-z]|$)'
FULL='new (service|module|endpoint|api|controller|consumer|producer|listener|feature|component|integration)|implement |design |architect|re-?design|refactor|multiple (files|classes|services|modules)|several (files|classes)|event[ -]driven|\bsaga\b|\bkafka\b|rabbitmq|\bnats\b|add (a |an |the )?(feature|endpoint|api|service|controller|consumer|listener|module)'
QUICK='typo|one[ -]line|single[ -]line|\brename\b|off[ -]by[ -]one|null check|fix the (bug|typo)|wrong (operator|sign|value|comparison|method|result)|incorrect (operator|sign|value|result)|change the (sign|operator|value)|minimal (change|fix)|keep (the )?change minimal|update (the )?(comment|javadoc|log|message|constant)'

profile="full"; db="false"; signal="default"
reason="conservative default — no explicit trivial signal, so full pipeline"

if printf '%s' "$lc" | grep -qE "$MIGRATION"; then
  profile="full"; db="true"; signal="migration"
  reason="migration/DDL intent → full pipeline + mandatory DB review"
elif printf '%s' "$lc" | grep -qE "$FULL"; then
  profile="full"; signal="complexity"
  reason="feature/structural intent → full pipeline"
elif printf '%s' "$lc" | grep -qE "$QUICK"; then
  profile="quick"; signal="trivial"
  reason="trivial-fix intent, no complexity/migration signal → build + verify only"
fi

jq -n --arg p "$profile" --argjson db "$db" --arg r "$reason" --arg s "$signal" \
  '{profile:$p, db_review:$db, reason:$r, signal:$s}'
