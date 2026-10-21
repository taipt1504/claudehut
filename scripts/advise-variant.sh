#!/usr/bin/env bash
# PreToolUse hook (matcher: Write, if Write(*.java)) — ADVISORY, never a gate (ADR-H2). Pack lang-java-spring (M3c).
#
# The write-time sensor of the variation detectors (docs/v0.20 05 §2, 03 guide × sensor): an agent creating a NEW
# production class whose name says "one more variant" (…Provider, …Client, …Sender, …Gateway, …Adapter, …Exporter,
# …Strategy, …Notifier) or whose body calls an external system (HTTP client, URL) in a repo whose index already found port + selector families is told, once per session,
# where those families are and how a variant is added there. It fires at the moment of the decision (the prompt
# hint of inject-phase.sh fires earlier; both were verified delivered in plugin eval, M3c). Speaks only when every
# condition holds; every other path is exit 0 with empty stdout, and the write proceeds in every branch.

case "$0" in */*) _d="${0%/*}" ;; *) _d="." ;; esac
. "$_d/lib/hook-common.sh" 2>/dev/null || exit 0
hc_init
hc_plane_or_exit

fp="$(jq -r '.tool_input.file_path // empty' <<<"$HC_IN")"
case "$fp" in */src/main/java/*.java|src/main/java/*.java) : ;; *) exit 0 ;; esac
[ -e "$fp" ] && exit 0                                    # a new file only: editing an existing class is not a decision
base="${fp##*/}"; cls="${base%.java}"
# One more variant: the class name says so, or the new class itself calls an external system (an HTTP client or a
# URL in its body) — `ZnsService` that POSTs to a vendor is an integration whatever it is called.
case "$cls" in
  *Provider|*Client|*Sender|*Gateway|*Adapter|*Exporter|*Strategy|*Notifier|*Connector|*Integration) : ;;
  *) jq -e '.tool_input.content // "" | test("\\b(WebClient|RestTemplate|RestClient|HttpClient|HttpRequest|OkHttpClient|FeignClient)\\b|https?://")' \
       <<<"$HC_IN" >/dev/null 2>&1 || exit 0 ;;
esac
VJ="$PLANE/index/variation.json"
[ -f "$VJ" ] || hc_index_first_build   # a never-indexed repo: built now when small (the decision is happening now)
[ -f "$VJ" ] || exit 0
line="$(jq -r --arg c "$cls" 'select(.applicable == true)
  | [.patterns[]?.instances[]? | select((.anchor | split(".") | last) != $c)
     | "\(.anchor | split(".") | last) (\(.variants) variants in \(.variant_dir), selector \((.selector.fqn // "a condition") | split(".") | last))"]
  | .[:3] | select(length > 0) | join("; ")' "$VJ" 2>/dev/null | head -c 420)"
[ -n "$line" ] || exit 0
hc_once "advise-variant" || exit 0
hc_ctx PreToolUse "ClaudeHut kb (data from the index): $cls looks like a new variant. This repo adds variants as port + selector — $line. If $cls is a variant of a concern, add it as an implementation behind a port with a selector the same way (kb_patterns has the recipe) instead of calling it directly from domain code. Not blocked; said once per session."
exit 0
