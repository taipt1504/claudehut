#!/usr/bin/env bash
# owasp-scan.sh — dep-check + custom regex sweep for Spring Security misconfigs
set -uo pipefail

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cd "$PROJECT_ROOT"

TASK_ID="${1:-$(cat .claudehut/state/active-task.json 2>/dev/null | jq -r '.task_id // "adhoc"')}"
OUT_DIR=".claudehut/state/tasks/$TASK_ID"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/owasp-findings.json"

declare -a findings=()

# 1. Dependency CVE check
DEPCHECK_REPORT="build/reports/dependency-check-report.json"
if [[ -f "gradlew" ]]; then
  if ./gradlew tasks --all 2>/dev/null | grep -q dependencyCheckAnalyze; then
    echo "Running dep-check (may take 60-120s)..." >&2
    ./gradlew dependencyCheckAnalyze --quiet 2>/dev/null || true
  fi
elif [[ -f "pom.xml" ]]; then
  if mvn -version >/dev/null 2>&1; then
    mvn dependency-check:check -q 2>/dev/null || true
    DEPCHECK_REPORT="target/dependency-check-report.json"
  fi
fi

if [[ -f "$DEPCHECK_REPORT" ]]; then
  while IFS= read -r vuln; do
    sev="$(echo "$vuln" | jq -r '.severity // "medium" | ascii_downcase')"
    findings+=("$(jq -nc --arg s "$sev" --arg r "cve" \
      --arg t "$(echo "$vuln" | jq -r '.name // ""')" \
      --arg d "$(echo "$vuln" | jq -r '.description // ""' | head -c 200)" \
      '{severity: $s, rule: $r, title: $t, detail: $d}')")
  done < <(jq -c '.dependencies[]?.vulnerabilities[]?' "$DEPCHECK_REPORT" 2>/dev/null)
fi

# 2. Regex sweep for known misconfigs
sweep() {
  local rule="$1" sev="$2" pattern="$3" glob="$4"
  while IFS= read -r match; do
    file="${match%%:*}"
    line="$(echo "$match" | cut -d: -f2)"
    detail="$(echo "$match" | cut -d: -f3- | head -c 200)"
    findings+=("$(jq -nc --arg s "$sev" --arg r "$rule" \
      --arg f "$file" --argjson ln "$line" --arg d "$detail" \
      '{severity: $s, rule: $r, file: $f, line: $ln, detail: $d}')")
  done < <(grep -rnE --include="$glob" "$pattern" src/ 2>/dev/null || true)
}

sweep "actuator-exposed" "high" 'management\.endpoints\.web\.exposure\.include[ =:]*\*' "*.yml"
sweep "actuator-exposed" "high" 'management\.endpoints\.web\.exposure\.include[ =:]*\*' "*.yaml"
sweep "actuator-exposed" "high" 'management\.endpoints\.web\.exposure\.include[ =:]*\*' "*.properties"
sweep "h2-console-enabled" "high" 'spring\.h2\.console\.enabled[ =:]*true' "*.yml"
sweep "h2-console-enabled" "high" 'spring\.h2\.console\.enabled[ =:]*true' "*.properties"
sweep "jackson-default-typing" "critical" '\.(enable|activate)DefaultTyping\(' "*.java"
sweep "spel-user-input" "critical" '\.parseExpression\(.*getParameter|.*request\.' "*.java"
sweep "runtime-exec-user-input" "critical" '\.exec\(.*getParameter|.*request\.' "*.java"
sweep "weak-hash" "medium" 'MessageDigest\.getInstance\("(MD5|SHA-1)"\)' "*.java"
sweep "perm-it-all" "high" 'permitAll\(\)' "*SecurityConfig*.java"

# 3. Compose result
totals=$(printf '%s\n' "${findings[@]}" | jq -s '
  group_by(.severity)
  | map({key: .[0].severity, value: length})
  | from_entries
  | { critical: (.critical // 0), high: (.high // 0), medium: (.medium // 0), low: (.low // 0) }
')

jq -nc --argjson totals "$totals" --argjson findings "$(printf '%s\n' "${findings[@]}" | jq -s '.')" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{ts: $ts, totals: $totals, findings: $findings}' > "$OUT"

cat "$OUT" | jq '{ts, totals}'

critical=$(jq -r '.totals.critical' "$OUT")
if [[ "$critical" -gt 0 ]]; then
  echo "BLOCK: $critical critical findings" >&2
  exit 1
fi
exit 0
