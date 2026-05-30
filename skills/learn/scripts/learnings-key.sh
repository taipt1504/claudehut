#!/usr/bin/env bash
# learnings-key.sh — SINGLE SOURCE OF TRUTH for the learning sidecar/retrieval key.
#
# retrieve-relevant.sh WRITES this key (as a retrieval-log sig + reads S_prior back)
# and update-usefulness.sh INDEXES usefulness.json by it. If the two ever derive the
# key differently — a trailing space, field order, downcase method — the usefulness
# prior (4.3) silently dies: every lookup misses, S_prior stays 0.5 forever, and the
# whole thing ships green (the Phase-0 no-op-gate / Phase-2 never-run failure class).
# So the key is defined EXACTLY ONCE here, as a jq def both scripts prepend to their
# jq program. Do not inline a second copy.
#
# Key = lower(title):category. Pure jq (jq 1.6 has NO sha256 builtin — a derived sig
# would fork shasum per entry in the dispatch hot path). Stable + collision-free at
# corpus scale N~20-200. It deliberately does NOT match the stored .signature field
# (sha256, written by the learner agent); these scripts own their own key space.
LEARNINGS_KEY_JQ_DEF='def learning_key: ((.title // "") | ascii_downcase) + ":" + (.category // "");'
