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

# ---------------------------------------------------------------------------------------------------
# check-disjoint, second wave: W14 (phase labels), W12 (intra-task duplicates), W6 (the dependency half
# of [P]), W5 (exit-2 output), W13 (concurrency chunking). One fixture repo, one helper.
AW="$(mktemp -d)/repo"; mkdir -p "$AW"
( cd "$AW" && git init -q . && git config user.email a@b && git config user.name a \
  && echo x > f && git add -A && git commit -qm b ) >/dev/null 2>&1
AHDR='| ID | Goal | Files | Test first | Minimal change | Verify | Depends on | Req |
|----|------|-------|------------|----------------|--------|------------|-----|'
# check-disjoint exits NON-ZERO by contract when it finds a problem, so a `cdj ... | grep -q` pipeline
# fails under `set -o pipefail` on exactly the case being tested. Capture, then match. Never pipe.
adj() { CLAUDE_PROJECT_DIR="$AW" "$WT" check-disjoint "$AW/$1" 2>&1; }

echo "== W14: phase labels are the plan's own, not a sequence counter =="
# `phase++` numbered headings in order of appearance, so a plan whose phases are 1 and 3 printed "phase 1"
# and "phase 2" — the tool named a phase the plan does not contain, in the output orchestration.md:32 calls
# the authoritative dispatch plan.
printf '### Phase 1 — a\n%s\n| T-001 [P] | a | src/a/A.java | t | c | v | — | F1 |\n| T-002 [P] | b | src/b/B.java | t | c | v | — | F2 |\n### Phase 3 — c\n%s\n| T-005 [P] | e | src/e/E.java | t | c | v | — | F5 |\n' "$AHDR" "$AHDR" > "$AW/lab.md"
out_lab="$(adj lab.md)"
case "$out_lab" in *"phase 3: [T-005]"*) ok "W14: a plan with Phase 1 and Phase 3 reports phase 3" ;;
  *) bad "W14: phase 3 was renumbered (sequence counter, not the plan's label)" ;; esac
case "$out_lab" in *"phase 2"*) bad "W14: emitted a phase 2 the plan does not contain" ;;
  *) ok "W14 control: no phantom phase 2 in a 1-and-3 plan" ;; esac
# Control: labels must stay labels for non-numeric phases too, and the implicit pre-heading phase stays 0.
printf '### Phase B — b\n%s\n| T-002 [P] | h1 | src/a/H1.java | t | c | v | — | F2 |\n| T-003 [P] | h2 | src/a/H2.java | t | c | v | — | F3 |\n' "$AHDR" > "$AW/labB.md"
case "$(adj labB.md)" in *"phase B: PARALLEL BATCH [T-002, T-003]"*) ok "W14 control: a letter-labeled phase reports its letter" ;;
  *) bad "W14 control: letter-labeled phase lost its label" ;; esac

echo "== W12: a path listed twice in ONE task is not a cross-task overlap =="
# `sort | uniq -d` over (phase, path) pairs cannot tell same-task from cross-task, so a task that listed
# the same file twice in its own Files cell was reported as an OVERLAP against itself — a false positive
# that serialized a phase which was in fact parallel-safe.
printf '### Phase 1 — a\n%s\n| T-001 [P] | a | src/a/A.java, src/a/A.java | t | c | v | — | F1 |\n| T-002 [P] | b | src/b/B.java | t | c | v | — | F2 |\n' "$AHDR" > "$AW/dup.md"
out_dup="$(adj dup.md)"; rc_dup=$?
[ $rc_dup -eq 0 ] && ok "W12: an intra-task duplicate path is not an overlap (exit 0)" \
  || bad "W12: a task colliding with itself was reported as an OVERLAP (rc=$rc_dup)"
# Control: the dedupe keys on (phase, TASK, path), not on path. A dedupe keyed on path alone would satisfy
# the assertion above and then silently swallow a REAL collision whenever one side also duplicated it.
printf '### Phase 1 — a\n%s\n| T-001 [P] | a | src/a/A.java, src/a/A.java | t | c | v | — | F1 |\n| T-002 [P] | b | src/a/A.java | t | c | v | — | F2 |\n' "$AHDR" > "$AW/dup2.md"
out_dup2="$(adj dup2.md)"; rc_dup2=$?
[ $rc_dup2 -eq 2 ] && case "$out_dup2" in *"src/a/A.java"*) ok "W12 control: a duplicated path that ANOTHER task also owns is still an OVERLAP" ;;
  *) bad "W12 control: the real collision lost its path" ;; esac \
  || bad "W12 control: deduping swallowed a genuine cross-task collision (rc=$rc_dup2)"

echo "== W6: [P] means disjoint Files AND no same-phase dependency — the second half was unchecked =="
# plan-template.md: "[P] = no dependency on another task in the SAME phase and disjoint Files". The awk
# read the ID cell and the Files cell and never the Depends-on cell, so a planner that marked a task [P]
# while declaring a dependency on a sibling [P] task got both dispatched concurrently — a task running
# alongside its own stated prerequisite. Reproduced at exit 0 before the fix.
printf '### Phase 1 — a\n%s\n| T-001 [P] | a | src/a/A.java | t | c | v | — | F1 |\n| T-002 [P] | b | src/b/B.java | t | c | v | T-001 | F2 |\n' "$AHDR" > "$AW/dep.md"
out_dep="$(adj dep.md)"; rc_dep=$?
[ $rc_dep -eq 2 ] && ok "W6: a [P] task depending on a same-phase [P] task is refused (exit 2)" \
  || bad "W6: a [P] task ran alongside its own declared dependency (rc=$rc_dep)"
case "$out_dep" in *"T-002 depends on T-001"*) ok "W6: the offending pair is named" ;;
  *) bad "W6: exit 2 without naming which tasks collide" ;; esac
# Control 1 — the narrowing that matters most. A dependency on a same-phase NON-[P] task is untouched: the
# predicate must read "[P] sibling", not "any same-phase dependency". Nothing else catches an over-fire here.
printf '### Phase 1 — a\n%s\n| T-001 | seq | src/a/A.java | t | c | v | — | F1 |\n| T-002 [P] | b | src/b/B.java | t | c | v | T-001 | F2 |\n| T-003 [P] | c | src/c/C.java | t | c | v | T-001 | F3 |\n' "$AHDR" > "$AW/depnp.md"
out_depnp="$(adj depnp.md)"; rc_depnp=$?
[ $rc_depnp -eq 0 ] && ok "W6 control: depending on a same-phase NON-[P] task stays legal (exit 0)" \
  || bad "W6 control: over-fired on a same-phase non-[P] dependency (rc=$rc_depnp)"
# Control 2 — cross-phase dependencies are the NORMAL case; the template's own Phase 1 depends on Phase 0.
printf '### Phase 0 — setup\n%s\n| T-001 [P] | m | db/migration/V2__x.sql | t | c | v | — | F1 |\n### Phase 1 — a\n%s\n| T-002 [P] | b | src/b/B.java | t | c | v | T-001 | F2 |\n| T-003 [P] | c | src/c/C.java | t | c | v | T-001 | F3 |\n' "$AHDR" "$AHDR" > "$AW/depx.md"
out_depx="$(adj depx.md)"; rc_depx=$?
[ $rc_depx -eq 0 ] && ok "W6 control: a CROSS-phase dependency stays legal (exit 0)" \
  || bad "W6 control: over-fired on a cross-phase dependency (rc=$rc_depx)"
case "$out_depx" in *"phase 1: PARALLEL BATCH [T-002, T-003]"*) ok "W6 control: the cross-phase plan still batches phase 1" ;;
  *) bad "W6 control: cross-phase plan lost its batch" ;; esac

echo "== W5: an UNSAFE phase must never be printed as a PARALLEL BATCH =="
# The schedule was built with no knowledge of the overlaps, so on the exit-2 path the offending phase was
# printed as a normal "PARALLEL BATCH [...]" line — byte-identical to a safe one — under a caption asking
# the reader to cross-reference and subtract. orchestration.md:32 says to follow this schedule and NOT
# re-derive batches by eye, so the two together told the model to dispatch the unsafe phase in parallel.
printf '### Phase 1 — a\n%s\n| T-001 [P] | a | src/a/A.java | t | c | v | — | F1 |\n| T-002 [P] | b | src/a/A.java | t | c | v | — | F2 |\n### Phase 2 — b\n%s\n| T-003 [P] | c | src/c/C.java | t | c | v | — | F3 |\n| T-004 [P] | d | src/d/D.java | t | c | v | — | F4 |\n' "$AHDR" "$AHDR" > "$AW/uns.md"
out_uns="$(adj uns.md)"; rc_uns=$?
[ $rc_uns -eq 2 ] && ok "W5: the overlapping plan still exits 2" || bad "W5: expected exit 2 (rc=$rc_uns)"
case "$out_uns" in *"phase 1: PARALLEL BATCH"*) bad "W5: the UNSAFE phase is still printed as a PARALLEL BATCH" ;;
  *) ok "W5: the unsafe phase carries no PARALLEL BATCH line" ;; esac
case "$out_uns" in *"phase 1: SEQUENTIAL (overlap)"*) ok "W5: the unsafe phase is labelled SEQUENTIAL (overlap)" ;;
  *) bad "W5: the unsafe phase is not labelled" ;; esac
# Control: "no PARALLEL BATCH anywhere on exit 2" would also be satisfied by deleting the schedule. The
# SAFE phase of the same plan must still be dispatched in parallel — that is the whole point of per-phase.
case "$out_uns" in *"phase 2: PARALLEL BATCH [T-003, T-004]"*) ok "W5 control: the safe phase of the same plan is still a PARALLEL BATCH" ;;
  *) bad "W5 control: the schedule stopped naming safe batches on the exit-2 path" ;; esac
# Control: a dependency-unsafe phase must be labelled too, or W6 reintroduces exactly the defect W5 fixes.
case "$(adj dep.md)" in *"phase 1: SEQUENTIAL (dependency)"*) ok "W5 control: a dependency-unsafe phase is also labelled SEQUENTIAL" ;;
  *) bad "W5 control: a dependency-unsafe phase is still printed as a parallel batch" ;; esac

echo "== W13: the batch schedule respects orchestration.md's max-3 concurrency cap =="
# The schedule emitted one unbounded PARALLEL BATCH line however many [P] tasks a phase had, while
# orchestration.md:37 caps live dispatch at "max 3 concurrent". A 6-task phase therefore handed the model a
# batch it had to re-chunk by eye — the exact thing orchestration.md:32 forbids.
mkw() { { printf '### Phase 1 — a\n%s\n' "$AHDR"
          i=1; while [ "$i" -le "$2" ]; do printf '| T-00%s [P] | t%s | src/x/F%s.java | t | c | v | — | F%s |\n' "$i" "$i" "$i" "$i"; i=$((i+1)); done
        } > "$AW/$1"; }
mkw six.md 6; mkw four.md 4; mkw three.md 3
out_six="$(adj six.md)"
case "$out_six" in *"PARALLEL BATCH 1/2 [T-001, T-002, T-003]"*) ok "W13: a 6-task phase is chunked into waves of 3" ;;
  *) bad "W13: a 6-task phase is still dispatched as one unbounded batch" ;; esac
case "$out_six" in *"PARALLEL BATCH 2/2 [T-004, T-005, T-006]"*) ok "W13: the tail wave carries the remaining tasks" ;;
  *) bad "W13: the tail wave is missing or mis-split" ;; esac
case "$(adj four.md)" in *"PARALLEL BATCH 2/2 [T-004]"*) ok "W13: 4 tasks split 3 + 1" ;;
  *) bad "W13: 4 tasks did not split at the cap" ;; esac
# Control, and the one existing assertions cannot provide: a phase that FITS in one wave must keep the
# original unsuffixed line. An off-by-one chunker suffixes a 3-task phase and every 2-task assertion above
# still passes, so only a boundary-sized phase catches it.
case "$(adj three.md)" in *"phase 1: PARALLEL BATCH [T-001, T-002, T-003]"*) ok "W13 control: a 3-task phase stays a single unsuffixed batch" ;;
  *) bad "W13 control: a single-wave phase gained a wave suffix (off-by-one at the cap)" ;; esac
rm -rf "$(dirname "$AW")"

echo
echo "WORKTREE: $PASS passed, $FAIL failed"
# W19: publish the count so reference-check.sh can pin the README number without re-running this suite.
[ -z "${EVAL_COUNT_DIR:-}" ] || printf '%s\n' "$PASS" > "$EVAL_COUNT_DIR/worktree-tests.count"
[ "$FAIL" -eq 0 ]
