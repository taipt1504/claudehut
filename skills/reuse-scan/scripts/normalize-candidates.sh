#!/usr/bin/env bash
# normalize-candidates.sh — merge candidate JSON arrays + dedupe + rank
# Usage: cat array1.json array2.json | normalize-candidates.sh
set -euo pipefail

jq -s '
  add
  | group_by(.path)
  | map(
      # Pick highest-score per path, preserve source list
      sort_by(-.score) | .[0] as $top
      | $top + {sources: ([.[].source] | unique)}
    )
  | sort_by(-.score)
  | .[0:5]
'
