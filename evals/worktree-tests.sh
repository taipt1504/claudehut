#!/usr/bin/env bash
# Deterministic tests for bin/claudehut-worktree (no Claude needed).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
WT="$ROOT/bin/claudehut-worktree"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }

mkrepo() { # fresh repo with one commit; echoes path
  local r; r="$(mktemp -d)/repo"; mkdir -p "$r"
  ( cd "$r" && git init -q && git config user.email t@t && git config user.name t \
    && echo base > f.txt && mkdir -p src && echo a > src/a.java && git add -A && git commit -qm base ) >/dev/null
  echo "$r"
}

echo "== check-disjoint =="
R="$(mkrepo)"
cat > "$R/plan.md" <<'EOF'
| ID | Goal | Files | Test first | Minimal change | Verify | Depends on | Req |
|----|------|-------|------------|----------------|--------|------------|-----|
| T-001 [P] | a | src/a/Svc.java, src/a/SvcTest.java | t | c | v | — | FR-1 |
| T-002 [P] | b | src/b/Other.java | t | c | v | — | FR-2 |
| T-003 | seq | src/a/Svc.java | t | c | v | T-001 | FR-3 |
EOF
( cd "$R" && CLAUDE_PROJECT_DIR="$R" "$WT" check-disjoint plan.md >/dev/null 2>&1 ) && ok "disjoint [P] files pass" || bad "disjoint pass"
cat > "$R/plan2.md" <<'EOF'
| T-001 [P] | a | src/a/Svc.java | t | c | v | — | FR-1 |
| T-002 [P] | b | src/a/Svc.java, src/b/X.java | t | c | v | — | FR-2 |
EOF
( cd "$R" && CLAUDE_PROJECT_DIR="$R" "$WT" check-disjoint plan2.md >/dev/null 2>&1 ); [ $? -eq 2 ] && ok "overlapping [P] files refused (exit 2)" || bad "overlap refused"

echo "== sweep: scope guard + merged/unchanged only =="
R="$(mkrepo)"
( cd "$R"
  mkdir -p .claude/worktrees
  git worktree add .claude/worktrees/agent-clean -b wt-clean -q 2>/dev/null            # unchanged -> removable
  git worktree add .claude/worktrees/agent-dirty -b wt-dirty -q 2>/dev/null
  echo dirty > .claude/worktrees/agent-dirty/f.txt                                      # dirty -> keep
  git worktree add .claude/worktrees/agent-unmerged -b wt-unmerged -q 2>/dev/null
  ( cd .claude/worktrees/agent-unmerged && echo new > n.txt && git add -A && git commit -qm work )  # committed, unmerged -> keep
  git worktree add "$(dirname "$R")/outside-wt" -b wt-outside -q 2>/dev/null            # OUTSIDE managed root -> untouchable
) >/dev/null 2>&1
out="$(cd "$R" && CLAUDE_PROJECT_DIR="$R" "$WT" sweep 2>&1)"
[ ! -d "$R/.claude/worktrees/agent-clean" ]    && ok "sweep removes clean+merged"        || bad "clean removed"
[ -d "$R/.claude/worktrees/agent-dirty" ]      && ok "sweep keeps DIRTY (agent work)"    || bad "dirty kept"
[ -d "$R/.claude/worktrees/agent-unmerged" ]   && ok "sweep keeps unmerged branch"       || bad "unmerged kept"
[ -d "$(dirname "$R")/outside-wt" ]            && ok "scope guard: outside worktree untouched" || bad "outside untouched"

echo "== reconcile: merge, conflict-abort, red-test rollback =="
R="$(mkrepo)"
( cd "$R"
  mkdir -p .claude/worktrees
  git worktree add .claude/worktrees/agent-x -b wt-x -q 2>/dev/null
  ( cd .claude/worktrees/agent-x && echo feature > feat.txt && git add -A && git commit -qm feat )
) >/dev/null 2>&1
( cd "$R" && CLAUDE_PROJECT_DIR="$R" "$WT" reconcile wt-x >/dev/null 2>&1 ) && [ -f "$R/feat.txt" ] \
  && ok "reconcile merges agent branch" || bad "reconcile merge"
( cd "$R"
  git worktree add .claude/worktrees/agent-c -b wt-c -q 2>/dev/null
  ( cd .claude/worktrees/agent-c && echo theirs > f.txt && git add -A && git commit -qm theirs )
  echo ours > f.txt && git add -A && git commit -qm ours
) >/dev/null 2>&1
( cd "$R" && CLAUDE_PROJECT_DIR="$R" "$WT" reconcile wt-c >/dev/null 2>&1 ); rc=$?
[ $rc -eq 2 ] && [ -z "$(cd "$R" && git status --porcelain)" ] && ok "conflict: aborted cleanly (exit 2, tree restored)" || bad "conflict abort (rc=$rc)"
( cd "$R"
  git worktree add .claude/worktrees/agent-r -b wt-r -q 2>/dev/null
  ( cd .claude/worktrees/agent-r && echo red > red.txt && git add -A && git commit -qm red )
) >/dev/null 2>&1
before="$(cd "$R" && git rev-parse HEAD)"
( cd "$R" && CLAUDE_PROJECT_DIR="$R" "$WT" reconcile wt-r --test-cmd "false" >/dev/null 2>&1 ); rc=$?
[ $rc -eq 3 ] && [ "$(cd "$R" && git rev-parse HEAD)" = "$before" ] && ok "red tests: merge rolled back (exit 3)" || bad "red rollback (rc=$rc)"
( cd "$R" && CLAUDE_PROJECT_DIR="$R" "$WT" reconcile wt-r --test-cmd "true" >/dev/null 2>&1 ) && ok "green tests: merge kept" || bad "green kept"

echo "== dirty main tree refused =="
( cd "$R" && echo x >> f.txt )
( cd "$R" && CLAUDE_PROJECT_DIR="$R" "$WT" reconcile wt-x >/dev/null 2>&1 ) && bad "dirty tree accepted" || ok "reconcile refuses dirty main tree"

echo
echo "WORKTREE: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
