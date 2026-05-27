#!/usr/bin/env bash
# tests/static/bash-compat.sh
#
# Scans all .sh files for bash 4+ features that won't work on macOS bash 3.2.

set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PLUGIN_ROOT"

PASS=0; FAIL=0
declare -a FAIL_LIST=()

pass() { printf "  \033[32m✓\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
fail() { printf "  \033[31m✗\033[0m %s :: %s\n" "$1" "$2"; FAIL=$((FAIL+1)); FAIL_LIST+=("$1: $2"); }

# Bash 4+ features to detect:
#   - mapfile / readarray builtin
#   - declare -A (associative arrays)
#   - declare -n (nameref)
#   - ${var,,} ${var^^} case modification
#   - **/* globstar (without shopt enabled)
#   - coproc keyword (uncommon)

scan_feature() {
  local label="$1"
  local pattern="$2"
  local files
  files=$(grep -rnE "$pattern" --include='*.sh' . 2>/dev/null \
    | grep -v '^./tests/static/bash-compat.sh' \
    | grep -v '^./tests/' || true)

  if [[ -z "$files" ]]; then
    pass "$label not used"
  else
    fail "$label" "found uses:"
    echo "$files" | sed 's/^/    /' >&2
  fi
}

echo "===== BASH 3.2 COMPATIBILITY SCAN ====="
echo "(bash 3.2 = macOS default; CI macos-latest verifies cross-platform)"
echo ""

scan_feature "mapfile/readarray (bash 4+)" '\b(mapfile|readarray)\s'
scan_feature "associative arrays (declare -A, bash 4+)" 'declare -[Anlur]'
scan_feature "nameref (declare -n, bash 4.3+)" 'declare -n[a-zA-Z]*\s'
scan_feature "case modification (\${var,,} or \${var^^}, bash 4+)" '\$\{[a-zA-Z_][a-zA-Z0-9_]*[,^]{1,2}'
scan_feature "wait -n (bash 4.3+)" '\bwait\s+-n'

# Check shebang convention
echo ""
echo "=== Shebang check ==="
missing_shebang=0
wrong_shebang=0
for f in $(find scripts bin skills/*/scripts tests -name '*.sh' 2>/dev/null); do
  first=$(head -1 "$f")
  if [[ ! "$first" =~ ^#! ]]; then
    echo "  ✗ $f: missing shebang"
    missing_shebang=$((missing_shebang + 1))
  elif [[ "$first" != "#!/usr/bin/env bash" && "$first" != "#!/bin/bash" ]]; then
    echo "  ⚠ $f: non-standard shebang: $first"
    wrong_shebang=$((wrong_shebang + 1))
  fi
done
[[ $missing_shebang -eq 0 ]] && pass "all scripts have shebang" || fail "shebang" "$missing_shebang scripts missing"
[[ $wrong_shebang -eq 0 ]] && pass "all use #!/usr/bin/env bash" || fail "shebang" "$wrong_shebang non-standard"

echo ""
echo "===== SUMMARY ====="
printf "Total: %d   \033[32mPass: %d\033[0m   \033[31mFail: %d\033[0m\n" $((PASS+FAIL)) "$PASS" "$FAIL"

if [[ "$FAIL" -gt 0 ]]; then
  echo ""
  echo "FAILURES:"
  for f in "${FAIL_LIST[@]}"; do echo "  - $f"; done
  exit 1
fi
exit 0
