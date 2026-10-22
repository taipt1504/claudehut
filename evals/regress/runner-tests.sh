#!/usr/bin/env bash
# runner-tests.sh — `claudehut-run` (M5d; docs/v0.20 09 §5 option B, §7 auth, ADR K-17). No model is called: a stub
# `claude` on PATH records its argv and whether a credential reached it.
#   RN1-RN4  auth: auto → plan without a credential (no --bare, keys stripped), → api with one (--bare, --plugin-dir,
#            scratch CLAUDE_CONFIG_DIR); --auth api without a credential is refused; a secret value is never printed
#   RN5-RN7  mining on synthetic transcripts: exact counts by class, harness rate (bash-exit/user-rejected excluded),
#            by tool and by command through allowlists, no excerpt or name in the report, unparsable lines skipped
#   RN8-RN9  --summarize sends counts only, through the chosen auth; the report records auth_mode + claude_version
#   RN10     eval builds evals/plugin-eval.sh --auth <mode> + pass-through args (dry run)
#   RN11     drift: index state + vendor-leak per project, read-only (the project tree is unchanged)
#   RN12-RN13 model calls from an empty dir; apiKeyHelper counts as api
#   RN14-RN15 propose: mining → one proposal (class, pack, file, eval case) in the report dir, no pack edit
# Prints "RUNNER: N passed, M failed"; exit 1 on failure.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
command -v python3 >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || { echo "RUNNER: 0 passed, 0 failed (no python3/jq)"; exit 0; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/runner tests.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "ok - $1"; else FAIL=$((FAIL+1)); echo "FAIL - $1"; fi; }
export CLAUDEHUT_HOST_PROBE=0
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY
RUN="$ROOT/bin/claudehut-run"
SECRET="sk-test-DO-NOT-PRINT-4242"

mkdir -p "$TMP/bin"
cat >"$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then echo "9.9.9 (stub)"; exit 0; fi
{ printf 'argv:'; printf ' [%s]' "$@"; echo; echo "key:${ANTHROPIC_API_KEY:+set}"; echo "config:${CLAUDE_CONFIG_DIR:-}"; echo "pwd:$PWD"; } >>"$STUB_LOG"
echo '{"result":"stub summary","total_cost_usd":0.01}'
EOF
chmod +x "$TMP/bin/claude"
export PATH="$TMP/bin:$PATH" STUB_LOG="$TMP/stub.log"
mkdir -p "$TMP/cfg"; export CLAUDE_CONFIG_DIR="$TMP/cfg"   # isolate from the user's settings (an apiKeyHelper there)
cd "$TMP" || exit 1
TX="$ROOT/evals/fixtures/transcripts"

out="$("$RUN" mining --projects-dir "$TX" --summarize --dry-run --json)"
check "RN1: auto without a credential → plan, no --bare" 'jq -e ".auth_mode==\"plan\" and (.argv|index(\"--bare\"))==null" <<<"$out" >/dev/null'
out="$(ANTHROPIC_API_KEY="$SECRET" "$RUN" mining --projects-dir "$TX" --summarize --dry-run --json --out "$TMP/o-api")"
check "RN2: auto with ANTHROPIC_API_KEY → api: --bare, --plugin-dir, scratch CLAUDE_CONFIG_DIR" 'jq -e ".auth_mode==\"api\" and (.argv|index(\"--bare\"))!=null and (.argv|index(\"--plugin-dir\"))!=null and .env.CLAUDE_CONFIG_DIR==\"<set>\"" <<<"$out" >/dev/null'
check "RN3: the secret value is never printed (shown as <set>)" '[[ "$out" != *"$SECRET"* ]] && jq -e ".env.ANTHROPIC_API_KEY==\"<set>\"" <<<"$out" >/dev/null'
"$RUN" mining --auth api --projects-dir "$TX" --dry-run >/dev/null 2>"$TMP/err"; rc=$?
check "RN4: --auth api without a credential is refused with the reason (rc=$rc)" '[ "$rc" = 2 ] && grep -q "needs ANTHROPIC_API_KEY" "$TMP/err"'

"$RUN" mining --projects-dir "$TX" --out "$TMP/o1" --json >"$TMP/m.json"; rc=$?
check "RN5: mining counts by class (zsh-glob 2, bash-exit 2, other 2, permission/edit/not-read/state-cli/modified/rejected 1; 13 calls, 12 errors)" \
  '[ "$rc" = 0 ] && jq -e ".mining.tool_calls==13 and .mining.tool_errors==12 and .mining.by_class[\"zsh-glob\"]==2 and .mining.by_class[\"bash-exit\"]==2 and .mining.by_class[\"permission-denied\"]==1 and .mining.by_class[\"edit-mismatch\"]==1 and .mining.by_class[\"file-not-read\"]==1 and .mining.by_class[\"state-cli\"]==1 and .mining.by_class[\"file-modified\"]==1 and .mining.by_class[\"user-rejected\"]==1 and .mining.by_class.other==2" "$TMP/m.json" >/dev/null'
check "RN5b: harness errors exclude bash-exit and user-rejected (9 of 13 calls)" \
  'jq -e ".mining.harness_errors==9 and .mining.harness_error_rate==0.6923" "$TMP/m.json" >/dev/null'
check "RN5c: by tool (mcp__* bucketed as mcp) and bash-exit by command (allowlist, else other-cmd)" \
  'jq -e ".mining.by_tool==({\"Bash\":10,\"mcp\":1,\"Edit\":1}) and .mining.bash_exit_by_command==({\"git\":1,\"other-cmd\":1})" "$TMP/m.json" >/dev/null'
check "RN6: the report holds counts only — no excerpt, no project dir, tool-server or command-path name" '! grep -q "SECRET-MARKER-7f3a" "$TMP/o1/report.json" && ! grep -q "proj-a" "$TMP/o1/report.json" && ! grep -q "acme-internal" "$TMP/o1/report.json" && [ -f "$TMP/o1/report.json" ]'
check "RN7: a dry run writes nothing" '[ ! -e "$TMP/o-api" ]'

: >"$STUB_LOG"
ANTHROPIC_API_KEY="$SECRET" "$RUN" mining --auth plan --projects-dir "$TX" --summarize --out "$TMP/o2" >/dev/null 2>&1
check "RN8a: plan strips the key before calling claude (no --bare, no key, no config override)" 'grep -q "^key:$" "$STUB_LOG" && ! grep -q "\[--bare\]" "$STUB_LOG" && grep -q "^config:$TMP/cfg$" "$STUB_LOG"'
check "RN8b: the prompt carries counts, never an excerpt" '! grep -q "SECRET-MARKER-7f3a" "$STUB_LOG" && grep -q "zsh-glob" "$STUB_LOG"'
: >"$STUB_LOG"
ANTHROPIC_API_KEY="$SECRET" "$RUN" mining --auth api --projects-dir "$TX" --summarize --out "$TMP/o3" >/dev/null 2>&1
check "RN8c: api calls claude --bare with the key and a scratch config dir under the report dir" 'grep -q "^key:set$" "$STUB_LOG" && grep -q "\[--bare\]" "$STUB_LOG" && grep -q "^config:$TMP/o3/claude-config$" "$STUB_LOG"'
check "RN9: the report records auth_mode, claude_version and the summary" 'jq -e ".auth_mode==\"api\" and .claude_version==\"9.9.9 (stub)\" and .summary==\"stub summary\"" "$TMP/o3/report.json" >/dev/null && ! grep -q "$SECRET" "$TMP/o3/report.json"'

out="$("$RUN" eval --dry-run --json -- --case end-refused-without-review --runs 1 --ablation none)"
check "RN10: eval → evals/plugin-eval.sh --auth plan + the pass-through args" 'jq -e "(.argv[1]|endswith(\"evals/plugin-eval.sh\")) and .argv[2:5]==[\"--auth\",\"plan\",\"--case\"] and (.argv|index(\"--ablation\"))!=null" <<<"$out" >/dev/null'

P="$TMP/proj"; mkdir -p "$P/.claudehut" "$P/src/main/java/demo/domain"; printf 'Acme\n' >"$P/.claudehut/vendors.txt"
printf 'package demo.domain;\n\npublic enum Route {\n  ACME\n}\n' >"$P/src/main/java/demo/domain/Route.java"
git -C "$P" init -q && git -C "$P" add -A && git -C "$P" -c user.email=t@t -c user.name=t commit -qm i
h0="$(cd "$P" && find . -path ./.git -prune -o -type f -print | sort | xargs shasum | shasum)"
"$RUN" drift --project "$P" --out "$TMP/o4" --json >"$TMP/d.json"
h1="$(cd "$P" && find . -path ./.git -prune -o -type f -print | sort | xargs shasum | shasum)"
check "RN11: drift reports index state and vendor findings per project, read-only" 'jq -e ".drift.projects[0].vendor_findings==1 and .drift.projects[0].index==\"none\" and .drift.projects[0].project==\"project-1\"" "$TMP/d.json" >/dev/null && [ "$h0" = "$h1" ]'

# RN12: a model call never runs in the caller's repo (its hooks would write the plane, its transcript would be mined)
PP="$TMP/plane-repo"; mkdir -p "$PP/.claudehut/state"; printf '{}' >"$PP/.claudehut/topology.json"
git -C "$PP" init -q
hp0="$(cd "$PP" && find . -path ./.git -prune -o -type f -print | sort | xargs shasum | shasum)"
: >"$STUB_LOG"
( cd "$PP" && "$RUN" mining --auth plan --projects-dir "$TX" --summarize --out "$TMP/o5" >/dev/null 2>&1 )
hp1="$(cd "$PP" && find . -path ./.git -prune -o -type f -print | sort | xargs shasum | shasum)"
check "RN12: the model call runs from an empty dir under the report, the caller's repo is byte-identical" 'grep -q "^pwd:.*/o5/cwd$" "$STUB_LOG" && ! grep -q "plane-repo" "$STUB_LOG" && [ "$hp0" = "$hp1" ]'
# RN13: an apiKeyHelper is an api credential (09 §7): auto → api with the helper passed along; plan is refused
printf '{"apiKeyHelper":"/usr/bin/true"}\n' >"$TMP/cfg/settings.json"
out="$("$RUN" mining --projects-dir "$TX" --summarize --dry-run --json)"
"$RUN" mining --auth plan --projects-dir "$TX" --dry-run >/dev/null 2>"$TMP/err"; rc=$?
check "RN13: apiKeyHelper in settings → auto picks api and passes the helper via --settings; --auth plan is refused (rc=$rc)" \
  'jq -e ".auth_mode==\"api\" and (.argv|index(\"--settings\"))!=null" <<<"$out" >/dev/null && [ "$rc" = 2 ] && grep -q "apiKeyHelper is configured" "$TMP/err"'
rm -f "$TMP/cfg/settings.json"

# RN14-RN15 (M6b): propose ranks the mined classes and writes a proposal to the report dir only — never a pack edit
out="$("$RUN" propose --projects-dir "$TX" --out "$TMP/o6" --json)"
check "RN14: no class with a known change + eval case → no proposal, a question instead" \
  'jq -e ".proposal==null and (.questions|length)==1 and .mining.state_cli_by_check.plan==1" <<<"$out" >/dev/null && [ ! -e "$TMP/o6/proposal.md" ]'
g0="$(git -C "$ROOT" status --porcelain -- packs skills agents | shasum)"
out="$("$RUN" propose --projects-dir "$ROOT/evals/fixtures/transcripts-loop" --out "$TMP/o7" --json)"
g1="$(git -C "$ROOT" status --porcelain -- packs skills agents | shasum)"
check "RN15: two locus refusals → proposal review-no-locus (pack, file, eval case) in proposal.md; no pack file touched" \
  'jq -e ".proposal.class==\"review-no-locus\" and .proposal.count==2 and .proposal.pack==\"workflow-standard\" and .proposal.eval==\"process/review-locus-first-try\"" <<<"$out" >/dev/null && grep -q "Nothing in a pack was changed" "$TMP/o7/proposal.md" && ! grep -q "SECRET-MARKER-7f3a" "$TMP/o7/proposal.md" "$TMP/o7/report.json" && [ "$g0" = "$g1" ] && [ -d "$ROOT/evals/suites/process/review-locus-first-try" ]'

echo "RUNNER: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
