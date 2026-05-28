#!/usr/bin/env bash
# plan-parallel-group-scan.sh <plan-file>
#
# Validates parallel group assignments in a plan doc:
#   1. Every task has "Parallel group: N" (integer ≥ 1).
#   2. No two tasks in the same group share a file (disjoint file sets).
#   3. Group numbers form a contiguous sequence starting at 1.
#   4. If task B depends on task A, group(B) > group(A).
#
# Exits 0 on success; exits 1 and prints violations to stderr.
# POSIX awk only (no gawk extensions).
set -euo pipefail

PLAN="${1:-}"
[[ -f "$PLAN" ]] || { echo "usage: $0 <plan-file>" >&2; exit 1; }

awk '
# ── Parse plan, collect task metadata ─────────────────────────────────

/^## Task [0-9]+:/ {
  # Extract task number: strip "## Task " prefix, grab leading digits
  line = $0
  sub(/^## Task /, "", line)
  cur = line + 0
  tasks[cur] = 1
  in_files = 0
  next
}

cur == 0 { next }

/^\*\*Files:\*\*/ { in_files = 1; next }

in_files && /^[[:space:]]*-[[:space:]]+(create|modify|test):/ {
  line = $0
  sub(/^[[:space:]]*-[[:space:]]+(create|modify|test):[[:space:]]*`*/, "", line)
  sub(/`.*$/, "", line)
  sub(/[[:space:]].*$/, "", line)
  if (line != "") task_files[cur] = task_files[cur] SUBSEP line
  next
}

in_files && !/^[[:space:]]*-[[:space:]]/ { in_files = 0 }

/^\*\*Depends[[:space:]]on:\*\*/ {
  line = $0
  sub(/^\*\*Depends[[:space:]]on:\*\*[[:space:]]*/, "", line)
  if (line ~ /\(none\)/ || line == "") next
  # Iterate over "Task N" occurrences by splitting on "Task "
  n = split(line, parts, /Task[[:space:]]+/)
  for (i = 2; i <= n; i++) {
    dep = parts[i] + 0
    if (dep > 0) task_deps[cur] = task_deps[cur] SUBSEP dep
  }
  next
}

/^\*\*Parallel[[:space:]]group:\*\*/ {
  line = $0
  sub(/^\*\*Parallel[[:space:]]group:\*\*[[:space:]]*/, "", line)
  sub(/[^0-9].*$/, "", line)
  if (line ~ /^[0-9]+$/) task_group[cur] = line + 0
  next
}

# ── Validate at END ────────────────────────────────────────────────────
END {
  errors = 0

  # 1. Every task must have a group
  for (t in tasks) {
    if (!(t in task_group) || task_group[t] == "") {
      print "ERROR: Task " t " missing **Parallel group:** field" > "/dev/stderr"
      errors++
    }
  }
  if (errors > 0) { print errors " parallel-group violation(s) found." > "/dev/stderr"; exit 1 }

  # 2. Groups contiguous from 1
  max_g = 0
  for (t in task_group) { if (task_group[t] > max_g) max_g = task_group[t] }
  for (g = 1; g <= max_g; g++) {
    found = 0
    for (t in task_group) { if (task_group[t] == g) { found = 1; break } }
    if (!found) {
      print "ERROR: No task in group " g " (gap in sequence 1.." max_g ")" > "/dev/stderr"
      errors++
    }
  }

  # 3. Dep ordering: group(dep) < group(task)
  for (t in task_deps) {
    n = split(task_deps[t], deps, SUBSEP)
    for (i = 1; i <= n; i++) {
      dep = deps[i] + 0
      if (dep == 0) continue
      if (!(dep in task_group)) continue
      if (task_group[t] <= task_group[dep]) {
        print "ERROR: Task " t " (group " task_group[t] ") depends on Task " dep \
              " (group " task_group[dep] "): dependent must have higher group" > "/dev/stderr"
        errors++
      }
    }
  }

  # 4. No shared files within same group
  for (t in task_files) {
    g = task_group[t]
    n = split(task_files[t], files, SUBSEP)
    for (i = 1; i <= n; i++) {
      f = files[i]
      if (f == "") continue
      key = g SUBSEP f
      if (key in owner) {
        print "ERROR: File conflict in group " g ": Task " owner[key] " and Task " t \
              " both touch \"" f "\"" > "/dev/stderr"
        errors++
      } else {
        owner[key] = t
      }
    }
  }

  if (errors > 0) {
    print errors " parallel-group violation(s) found." > "/dev/stderr"
    exit 1
  }
  print "parallel-group: OK"
}
' "$PLAN"
