#!/usr/bin/env bash
# Oracle for clean-first-run: a test was written (test-first), and the SumService exists.
set -uo pipefail
work="$1"
fail=0
find "$work/src/test" -name '*Test.java' 2>/dev/null | grep -q . || { echo "  oracle: no test file (test-first not honored)"; fail=1; }
find "$work/src/main" -name 'SumService.java' 2>/dev/null | grep -q . || { echo "  oracle: SumService not created"; fail=1; }
[ "$fail" -eq 0 ]
