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
# phase-aware: same file in two DIFFERENT phases is SAFE (never concurrent) — a global check false-positives here
cat > "$R/plan3.md" <<'EOF'
## Phase 1 — domain
| ID | Goal | Files | Test first | Minimal change | Verify | Depends on | Req |
|----|------|-------|------------|----------------|--------|------------|-----|
| T-001 [P] | svc | src/a/Svc.java | t | c | v | — | FR-1 |
| T-002 [P] | repo | src/a/Repo.java | t | c | v | — | FR-2 |
## Phase 3 — cross-cutting
| T-005 [P] | edit svc | src/a/Svc.java | t | c | v | T-001 | FR-5 |
EOF
( cd "$R" && CLAUDE_PROJECT_DIR="$R" "$WT" check-disjoint plan3.md >/dev/null 2>&1 ) && ok "cross-phase file reuse is SAFE (per-phase check, exit 0)" || bad "cross-phase reuse wrongly refused"
# phase-aware: overlap WITHIN a phase is still caught
cat > "$R/plan4.md" <<'EOF'
## Phase 1 — domain
| ID | Goal | Files | Test first | Minimal change | Verify | Depends on | Req |
|----|------|-------|------------|----------------|--------|------------|-----|
| T-001 [P] | svc | src/a/Svc.java | t | c | v | — | FR-1 |
| T-002 [P] | also svc | src/a/Svc.java, src/a/X.java | t | c | v | — | FR-2 |
EOF
( cd "$R" && CLAUDE_PROJECT_DIR="$R" "$WT" check-disjoint plan4.md >/dev/null 2>&1 ); [ $? -eq 2 ] && ok "within-phase overlap still refused (exit 2)" || bad "within-phase overlap not caught"
# schedule output names the parallel batch the implement skill must dispatch
( cd "$R" && CLAUDE_PROJECT_DIR="$R" "$WT" check-disjoint plan3.md 2>&1 | grep -q 'PARALLEL BATCH' ) && ok "check-disjoint prints the per-phase batch schedule" || bad "no schedule emitted"
# EXACT plan-template layout: interleaved ### Phase N headings, one mini-table (with its own header row) per phase.
# Repeated header/separator rows must NOT break phase detection; cross-phase file reuse stays safe.
cat > "$R/plan5.md" <<'EOF'
## 3. Task Breakdown
### Phase 1 — domain / service
| ID | Goal | Files | Test first | Minimal change | Verify | Depends on | Req |
|----|------|-------|------------|----------------|--------|------------|-----|
| T-002 [P] | foo | src/a/FooService.java, src/test/a/FooServiceTest.java | x | c | v | T-001 | FR-2 |
| T-003 [P] | bar | src/a/BarService.java, src/test/a/BarServiceTest.java | y | c | v | T-001 | FR-3 |
### Phase 3 — cross-cutting
| ID | Goal | Files | Test first | Minimal change | Verify | Depends on | Req |
|----|------|-------|------------|----------------|--------|------------|-----|
| T-007 [P] | metrics on foo | src/a/FooService.java | z | c | v | T-002 | FR-7 |
EOF
out5="$( cd "$R" && CLAUDE_PROJECT_DIR="$R" "$WT" check-disjoint plan5.md 2>&1 )"; rc5=$?
[ $rc5 -eq 0 ] && ok "template layout (interleaved ### Phase mini-tables): exit 0" || bad "template layout wrongly refused (rc=$rc5)"
echo "$out5" | grep -q 'PARALLEL BATCH \[T-002, T-003\]' && ok "template layout: phase-1 [P] batch detected (T-002,T-003)" || bad "template layout: phase-1 batch not detected"
# LETTER-labeled phases (Phase A/B, not digits): [P] rows must still be detected (regression — an
# uninitialized `phase` key made these report "no [P] found" -> forced inline; fixed by BEGIN{phase=0} + alnum label).
cat > "$R/plan6.md" <<'EOF'
### Phase A — foundation (done)
| ID | Goal | Files | Test first | Minimal change | Verify | Depends on | Req |
|----|------|-------|------------|----------------|--------|------------|-----|
| T-001 | base | src/a/Base.java | t | c | v | — | F1 |
### Phase B — handlers (parallel)
| ID | Goal | Files | Test first | Minimal change | Verify | Depends on | Req |
|----|------|-------|------------|----------------|--------|------------|-----|
| T-002 [P] | h1 | src/a/H1.java | t | c | v | T-001 | F2 |
| T-003 [P] | h2 | src/a/H2.java | t | c | v | T-001 | F3 |
EOF
( cd "$R" && CLAUDE_PROJECT_DIR="$R" "$WT" check-disjoint plan6.md 2>&1 | grep -q 'PARALLEL BATCH \[T-002, T-003\]' ) && ok "letter-labeled phases: [P] batch still detected (no phantom inline)" || bad "letter-labeled phases: [P] batch MISSED (uninitialized-phase regression)"
# NO phase headings at all: two [P] rows must still form a batch (all in phase 0)
cat > "$R/plan7.md" <<'EOF'
| ID | Goal | Files | Test first | Minimal change | Verify | Depends on | Req |
|----|------|-------|------------|----------------|--------|------------|-----|
| T-001 [P] | a | src/a/A.java | t | c | v | — | F1 |
| T-002 [P] | b | src/b/B.java | t | c | v | — | F2 |
EOF
( cd "$R" && CLAUDE_PROJECT_DIR="$R" "$WT" check-disjoint plan7.md 2>&1 | grep -q 'PARALLEL BATCH \[T-001, T-002\]' ) && ok "no phase headings: [P] batch detected in phase 0" || bad "no-heading [P] batch missed"

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

echo "== W3: sweep must never destroy committed work in a DETACHED worktree =="
# Reproduced before the fix: wt_merged took only the branch NAME and resolved it with `git rev-parse` in
# the MAIN repo. A detached worktree reports its branch as the literal string "HEAD", so that resolved to
# main's HEAD and the check asked "is main's HEAD an ancestor of main's HEAD" — trivially true. Every
# detached worktree looked merged; sweep removed it; the commits had no ref and became unreachable. The
# banner printed alongside said "kept = dirty or unmerged", the opposite of what happened.
WD="$(mktemp -d)"
( cd "$WD" && git init -q . && git config user.email a@b && git config user.name a \
  && echo base > f.txt && git add -A && git commit -qm base ) >/dev/null 2>&1
mkdir -p "$WD/.claude/worktrees"
git -C "$WD" worktree add -q --detach "$WD/.claude/worktrees/agent-x" HEAD >/dev/null 2>&1
( cd "$WD/.claude/worktrees/agent-x" && echo IRREPLACEABLE > result.txt && git add -A \
  && git commit -qm "agent work" ) >/dev/null 2>&1
CLAUDE_PROJECT_DIR="$WD" "$ROOT/bin/claudehut-worktree" sweep >/dev/null 2>&1
[ -d "$WD/.claude/worktrees/agent-x" ] && [ -f "$WD/.claude/worktrees/agent-x/result.txt" ] \
  && ok "W3: a detached worktree with committed work survives sweep" \
  || bad "W3: sweep DESTROYED committed work that no branch pointed at — unrecoverable"
# The control is what makes this a bug fix rather than a blanket refusal to sweep: a genuinely merged
# branch worktree must STILL be removed, or sweep has simply stopped working.
git -C "$WD" worktree add -q -b feat/done "$WD/.claude/worktrees/agent-y" HEAD >/dev/null 2>&1
CLAUDE_PROJECT_DIR="$WD" "$ROOT/bin/claudehut-worktree" sweep >/dev/null 2>&1
[ -d "$WD/.claude/worktrees/agent-y" ] \
  && bad "W3 control: a merged-branch worktree was NOT swept — the guard is now too broad" \
  || ok "W3 control: a merged-branch worktree is still swept"
rm -rf "$WD"

echo "== W4: check-disjoint must see repo-ROOT files, not just nested ones =="
# A path was recognised by "contains a /", which dropped the [P] annotation as intended and ALSO dropped
# every repo-root file. Reproduced: two [P] tasks both listing pom.xml were reported as a safe PARALLEL
# BATCH — and "add dependency X" is precisely the task that edits a build file, so this was the collision
# most likely to happen. orchestration.md calls this command AUTHORITATIVE for the batch schedule.
CD="$(mktemp -d)"
( cd "$CD" && git init -q . && git config user.email a@b && git config user.name a \
  && echo x > f && git add -A && git commit -qm b ) >/dev/null 2>&1
mkp() { printf '## Phase 1\n| ID | Goal | Files | Test first | Verify |\n|---|---|---|---|---|\n%s\n' "$2" > "$CD/$1"; }
mkp root.md '| T-001 [P] | a | `pom.xml`, `src/main/java/A.java` | T1 | v |
| T-002 [P] | b | `pom.xml`, `src/main/java/B.java` | T2 | v |'
mkp ok.md '| T-001 [P] | a | `src/main/java/A.java` | T1 | v |
| T-002 [P] | b | `src/main/java/B.java` | T2 | v |'
mkp prose.md '| T-001 [P] | migration | db/migration/V2__add.sql | — _(migration)_ | v |
| T-002 [P] | other | src/main/java/B.java | T2 | v |'
cdj() { CLAUDE_PROJECT_DIR="$CD" "$ROOT/bin/claudehut-worktree" check-disjoint "$CD/$1" 2>&1 | head -1; }
out_root="$(cdj root.md)"
case "$out_root" in OVERLAP*) ok "W4: two [P] tasks both editing pom.xml are reported as an OVERLAP" ;; *) bad "W4: a root-file collision was reported as a safe parallel batch" ;; esac
# Two controls, because a predicate that flags everything would pass the first assertion on its own.
out_ok="$(cdj ok.md)"
case "$out_ok" in disjoint*) ok "W4 control: genuinely disjoint nested files stay disjoint" ;; *) bad "W4 control: false overlap — the file predicate is too broad" ;; esac
out_prose="$(cdj prose.md)"
case "$out_prose" in disjoint*) ok "W4 control: prose cells (— _(migration)_) create no phantom overlap" ;; *) bad "W4 control: a non-path cell was treated as a file" ;; esac
rm -rf "$CD"

echo "== W9: a repo path containing a space must not hide its managed worktrees =="
# `git worktree list --porcelain` emits `worktree <path>`; the path was read with awk '{print $2}', which
# truncates at the first space. A repo under ~/My Projects/ therefore matched no directory, every managed
# worktree under it silently disappeared from `status` AND from `sweep`, and the tool reported an empty
# repo. Every other fixture here lives under mktemp -d, which never contains a space.
SPD="$(mktemp -d)/My Projects"; mkdir -p "$SPD"
SR="$SPD/repo"; mkdir -p "$SR"
( cd "$SR" && git init -q . && git config user.email a@b && git config user.name a \
  && echo base > f.txt && git add -A && git commit -qm base ) >/dev/null 2>&1
mkdir -p "$SR/.claude/worktrees"
git -C "$SR" worktree add -q -b wt-space "$SR/.claude/worktrees/agent-space" HEAD >/dev/null 2>&1
git -C "$SR" worktree add -q -b wt-space-out "$SPD/outside-wt" HEAD >/dev/null 2>&1   # outside MROOT
st_space="$(CLAUDE_PROJECT_DIR="$SR" "$WT" status 2>&1)"
case "$st_space" in *agent-space*) ok "W9: status sees a managed worktree under a path with a space" ;;
  *) bad "W9: a spaced repo path hid its managed worktrees from status" ;; esac
# Listing it is not enough — the path has to survive all the way into `git worktree remove`, so assert the
# clean+merged worktree is actually gone. A fix that only repaired the echo would pass the status check.
CLAUDE_PROJECT_DIR="$SR" "$WT" sweep >/dev/null 2>&1
[ -d "$SR/.claude/worktrees/agent-space" ] \
  && bad "W9: sweep listed the spaced worktree but could not remove it" \
  || ok "W9: sweep removes a clean+merged worktree under a spaced path"
# Control: widening the parse must not widen the SCOPE GUARD. A worktree outside .claude/worktrees/ is
# still untouchable even though its path now parses correctly.
[ -d "$SPD/outside-wt" ] && ok "W9 control: scope guard still holds for a spaced path outside MROOT" \
  || bad "W9 control: the spaced-path fix broke the managed-root filter"
rm -rf "$(dirname "$SPD")"

echo "== W10: reconcile merges local BRANCHES only, not any committish =="
# The header advertised "every mutating operation validates its target", but the managed() guard had exactly
# one call site, inside sweep. reconcile resolved its argument with `git rev-parse --verify`, which accepts
# any committish — so a tag or a raw SHA naming work that was never an agent branch got --no-ff merged into
# the current branch at exit 0.
NR="$(mktemp -d)/repo"; mkdir -p "$NR"
( cd "$NR" && git init -q . && git config user.email a@b && git config user.name a \
  && echo base > f.txt && git add -A && git commit -qm base \
  && git checkout -q -b not-an-agent-branch && echo t > t.txt && git add -A && git commit -qm tagged \
  && git tag v-random && git checkout -q main ) >/dev/null 2>&1
NSHA="$(git -C "$NR" rev-parse v-random)"
( cd "$NR" && CLAUDE_PROJECT_DIR="$NR" "$WT" reconcile v-random >/dev/null 2>&1 ); rc_tag=$?
[ $rc_tag -ne 0 ] && [ ! -f "$NR/t.txt" ] && ok "W10: reconcile refuses a TAG" \
  || bad "W10: reconcile merged a tag (rc=$rc_tag)"
( cd "$NR" && CLAUDE_PROJECT_DIR="$NR" "$WT" reconcile "$NSHA" >/dev/null 2>&1 ); rc_sha=$?
[ $rc_sha -ne 0 ] && [ ! -f "$NR/t.txt" ] && ok "W10: reconcile refuses a raw SHA" \
  || bad "W10: reconcile merged a raw SHA (rc=$rc_sha)"
# Control: the narrowing is to refs/heads/, NOT to "has a live managed worktree". A branch whose worktree
# was already swept must still reconcile — that is the normal end of an agent's life. A guard that demanded
# a managed worktree would pass both assertions above and break the real workflow.
git -C "$NR" worktree add -q -b wt-swept "$NR/.claude/worktrees/agent-swept" main >/dev/null 2>&1
( cd "$NR/.claude/worktrees/agent-swept" && echo s > s.txt && git add -A && git commit -qm swept ) >/dev/null 2>&1
git -C "$NR" worktree remove --force "$NR/.claude/worktrees/agent-swept" >/dev/null 2>&1
( cd "$NR" && CLAUDE_PROJECT_DIR="$NR" "$WT" reconcile wt-swept >/dev/null 2>&1 ); rc_sw=$?
[ $rc_sw -eq 0 ] && [ -f "$NR/s.txt" ] \
  && ok "W10 control: a local branch whose worktree was already swept still reconciles" \
  || bad "W10 control: the branch guard is too narrow — it now needs a live worktree (rc=$rc_sw)"
rm -rf "$(dirname "$NR")"

echo "== W11: an EMPTY --test-cmd must not merge unverified =="
# `--test-cmd ""` — what a caller gets from interpolating an unset variable — collapsed into the same empty
# $tcmd as "no flag at all". The branch merged, no command ever ran, and the success line was byte-identical
# to an untested merge, so the caller believed the merge was verified. Refused now, and refused BEFORE the
# merge: erroring afterwards would leave behind exactly the merge we are preventing.
TR="$(mktemp -d)/repo"; mkdir -p "$TR"
( cd "$TR" && git init -q . && git config user.email a@b && git config user.name a \
  && echo base > f.txt && git add -A && git commit -qm base ) >/dev/null 2>&1
mkdir -p "$TR/.claude/worktrees"
mkbr() { # $1 branch, $2 file
  git -C "$TR" worktree add -q -b "$1" "$TR/.claude/worktrees/$1" HEAD >/dev/null 2>&1
  ( cd "$TR/.claude/worktrees/$1" && echo x > "$2" && git add -A && git commit -qm "$1" ) >/dev/null 2>&1
}
mkbr wt-empty e.txt; mkbr wt-noflag n.txt; mkbr wt-green g.txt
out_empty="$( cd "$TR" && CLAUDE_PROJECT_DIR="$TR" "$WT" reconcile wt-empty --test-cmd "" 2>&1 )"; rc_e=$?
[ $rc_e -ne 0 ] && [ ! -f "$TR/e.txt" ] \
  && ok "W11: --test-cmd \"\" is refused and the branch is NOT merged" \
  || bad "W11: an empty --test-cmd merged unverified (rc=$rc_e)"
# Control: the refusal must be about the EMPTY value, not about the flag. A fix that rejected --test-cmd
# outright, or one that refused every reconcile, would satisfy the assertion above on its own.
out_noflag="$( cd "$TR" && CLAUDE_PROJECT_DIR="$TR" "$WT" reconcile wt-noflag 2>&1 )"; rc_n=$?
[ $rc_n -eq 0 ] && [ -f "$TR/n.txt" ] && ok "W11 control: omitting --test-cmd still merges" \
  || bad "W11 control: a flagless reconcile was wrongly refused (rc=$rc_n)"
out_green="$( cd "$TR" && CLAUDE_PROJECT_DIR="$TR" "$WT" reconcile wt-green --test-cmd "true" 2>&1 )"; rc_g=$?
[ $rc_g -eq 0 ] && [ -f "$TR/g.txt" ] && ok "W11 control: a non-empty --test-cmd still merges" \
  || bad "W11 control: --test-cmd \"true\" was wrongly refused (rc=$rc_g)"
# The two success lines used to differ by three words, both reading as plain success. Assert they now state
# which one happened — a verified merge and an unverified one must not look alike.
case "$out_green" in *"(tests green)"*) ok "W11: a verified merge says so" ;;
  *) bad "W11: the tested-merge line no longer names its test result" ;; esac
case "$out_noflag" in *"nothing was verified"*) ok "W11: an untested merge names itself as unverified" ;;
  *) bad "W11: an untested merge still reads as a plain success" ;; esac
rm -rf "$(dirname "$TR")"

echo
echo "WORKTREE: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
