#!/usr/bin/env bash
# migrate-tests.sh — bin/claudehut-migrate on a generated v0.11 workspace (10-rollout-eval.md §4, M7). Deterministic,
# no Claude, no network. Workspace: svc-a (plain hooks, extras present), svc-b (husky, no extras), svc-c (.claude/
# ignored), scan-x (git + build.gradle, no plane), docs (no git), a v0.11 root plane; the hub ws-knowledge is absent.
#
#   1. dry-run   prints a per-repo plan with sizes and backups; the workspace tree (incl. .git) keeps its checksum
#   2. apply     hub git-inited (no remote) with hub.json vi; services microservice → hub, inheriting the language;
#                MEMORY.md migrated ≤8192 B; empty learnings repaired; index built; no extras added; hooks only in the
#                safe repo; ignored plane → patch printed, .gitignore untouched; scan-x hub-scanned; root learnings →
#                fleet, .migrated kept; root CLAUDE.md imports PROJECT.md + HUB.md; tasks/, reuse-index.json, the root
#                UA graph and every HEAD unchanged; a decoy CLAUDE_PROJECT_DIR plane is never touched
#   3. re-apply  tree identical except the new backup dir (idempotent)
#   4. restore   tree byte-identical to the pre-apply tree (path + mode + sha), hub moved aside
#   5. refresh   the unattended --refresh-rules (maintain.sh, next version bump) adds no extras to a migrated repo
#                and brings back no rule the user deleted (svc-a dropped vocabulary.md, like va-ms)
#   0. preflight --apply refuses while a claudehut install covering the workspace is another version
#   svc-a also carries what the ewallet rehearsal found: core.hooksPath = its own .git/hooks (absolute), a Vietnamese
#   NFC file name in the plane (restore must give the same bytes back), a linked worktree under .claude/worktrees
#   (the dry-run copy must not point back at it); hooks go through the --plugin-data shim, never $ROOT/bin
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MIG="$ROOT/bin/claudehut-migrate"; INIT="$ROOT/bin/claudehut-init"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok   - $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL - $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 required"; exit 2; }

T="$(mktemp -d)"; T="$(cd "$T" && pwd -P)"; [ -n "${MIGRATE_KEEP:-}" ] && echo "kept: $T" || trap 'rm -rf "$T"' EXIT
WS="$T/ws"; HUB="$WS/ws-knowledge"; mkdir -p "$WS"
export CLAUDE_CONFIG_DIR="$T/cfg"; PD="$T/pdata"   # never the real ~/.claude registry or plugin data dir
PV="$(jq -r .version "$ROOT/.claude-plugin/plugin.json")"
gitq(){ git -C "$1" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "${@:2}"; }
mkrepo() { # $1 name — a small Spring repo with one commit
  local r="$WS/$1"
  mkdir -p "$r/src/main/java/com/ex/$1" "$r/src/main/resources"
  printf "plugins { id 'org.springframework.boot' version '3.3.0' }\ndependencies { implementation 'org.springframework.boot:spring-boot-starter-web' }\n" > "$r/build.gradle"
  printf 'package com.ex;\n@org.springframework.stereotype.Service\npublic class %sService { public void run() {} }\n' "$(printf '%s' "$1" | tr -d '-')" > "$r/src/main/java/com/ex/$1/Svc.java"
  printf 'spring:\n  application:\n    name: %s\n' "$1" > "$r/src/main/resources/application.yml"
  git -C "$r" init -q -b main && gitq "$r" add -A && gitq "$r" commit -qm init
}
v011_plane() { # $1 dir — a v0.11 plane: legacy MEMORY.md over budget, an empty learning, a task dir, reuse-index
  local p="$1/.claude/claudehut"; mkdir -p "$p/tasks/0001-old" "$p/state" "$1/.claude/rules"
  printf '# Project structure\n' > "$1/.claude/rules/project-structure.md"; printf '# Vocabulary\n' > "$1/.claude/rules/vocabulary.md"
  { printf '# ClaudeHut memory index — x\n\n## Always loaded (via @import in CLAUDE.md)\n- PROJECT.md\n\n## Team notes\nKeep this line.\n\n'
    for i in $(seq 1 60); do printf '## Reuse additions (task-%04d)\n- com.ex.Thing%d — reuse it for the %d-th flow, padded text padded text padded text\n\n' "$i" "$i" "$i"; done
  } > "$p/MEMORY.md"
  printf '# Project: x\n' > "$p/PROJECT.md"; printf '# Vocabulary\n' > "$p/LANGUAGE.md"
  printf '{"components":[{"path":"src/main/java/Gone.java"}]}\n' > "$p/reuse-index.json"
  printf 'old plan\n' > "$p/tasks/0001-old/plan.md"
  printf '{"schema":1,"bypass":true}\n' > "$p/state/s1.json"
  { printf '{"id":"L-0001","ts":"2026-06-01T00:00:00Z","category":"pitfall","trigger":"r2dbc tx","learning":"R2DBC transactions need TransactionalOperator in reactive chains","evidence":"A.java:1","confidence":0.8,"hits":2}\n'
    printf '{"id":"L-0002","ts":"2026-06-01T00:00:00Z","category":"pitfall","trigger":"empty","learning":"","evidence":"B.java:1","confidence":0.5,"hits":1}\n'
    printf '{"id":"L-0003","ts":"2026-06-01T00:00:00Z","category":"convention","trigger":"kafka key","learning":"Kafka producers must key messages by aggregate id for ordering","evidence":"C.java:1","confidence":0.7,"hits":1}\n'
  } > "$p/learnings.jsonl"
  printf '\n<!-- ClaudeHut: project-adaptive memory (always-load slice only; see 07 §1.2) -->\n@.claude/claudehut/MEMORY.md\n@.claude/claudehut/PROJECT.md\n@.claude/claudehut/LANGUAGE.md\n' > "$1/CLAUDE.md"
}
for s in svc-a svc-b svc-c scan-x; do mkrepo "$s"; done
for s in svc-a svc-b svc-c; do v011_plane "$WS/$s"; done
printf '.env\n' > "$WS/svc-a/.worktreeinclude"
printf '{"worktree":{"baseRef":"head"},"extraKnownMarketplaces":{"claudehut-marketplace":{"source":{"source":"github","repo":"taipt1504/claudehut"}}}}\n' > "$WS/svc-a/.claude/settings.json"
printf '#!/bin/sh\necho pre\n' > "$WS/svc-a/.git/hooks/pre-commit"; chmod 755 "$WS/svc-a/.git/hooks/pre-commit"
rm "$WS/svc-a/.claude/rules/vocabulary.md"   # deleted by hand (va-ms)
git -C "$WS/svc-a" config core.hooksPath "$WS/svc-a/.git/hooks"   # the default location spelled out (party-ms)
mkdir -p "$WS/svc-a/.claude/claudehut/prompts"
python3 -c 'import sys,unicodedata; open(sys.argv[1] + "/" + unicodedata.normalize("NFC", "3-srs-quản-lý-phân-cấp.md"), "w").write("x\n")' "$WS/svc-a/.claude/claudehut/prompts"
git -C "$WS/svc-a" worktree add -q --detach "$WS/svc-a/.claude/worktrees/wt1" 2>/dev/null
mkdir -p "$WS/svc-b/.husky"; printf '{"worktree":{"baseRef":"head"}}\n' > "$WS/svc-b/.claude/settings.json"
printf '.claude/claudehut/*.md\n!.claude/claudehut/MEMORY.md\n' > "$WS/svc-b/.gitignore"   # last match is a '!': NOT ignored
printf 'build/\n.claude/\n' > "$WS/svc-c/.gitignore"; gitq "$WS/svc-c" add .gitignore; gitq "$WS/svc-c" commit -qm gi
mkdir -p "$WS/docs"; printf 'notes\n' > "$WS/docs/a.md"
# root plane (no git)
v011_plane "$WS"
mkdir -p "$WS/.understand-anything"; printf '{"nodes":[],"edges":[]}\n' > "$WS/.understand-anything/knowledge-graph.json"
# decoy: a session's CLAUDE_PROJECT_DIR leaking into a child call would repair this plane
DECOY="$T/decoy"; v011_plane "$DECOY"

tree_sum() { # $1 dir → one line per file/symlink/dir: path mode sha (backup dirs excluded)
  python3 - "$1" <<'PY'
import hashlib, os, stat, sys
d = sys.argv[1]
for r, dirs, files in os.walk(d):
    dirs[:] = sorted(x for x in dirs if not x.startswith(".claudehut-backup-"))
    for x in sorted(files) + [y for y in dirs if os.path.islink(os.path.join(r, y))]:
        p = os.path.join(r, x); st = os.lstat(p)
        if stat.S_ISLNK(st.st_mode): h = hashlib.sha1(os.readlink(p).encode()).hexdigest()
        else:
            h = hashlib.sha1(open(p, "rb").read()).hexdigest()
        print("%s %o %s" % (os.path.relpath(p, d), st.st_mode & 0o7777, h))
    for x in dirs:
        p = os.path.join(r, x)
        if not os.path.islink(p): print("%s/ %o" % (os.path.relpath(p, d), os.lstat(p).st_mode & 0o7777))
PY
}
heads() { for s in svc-a svc-b svc-c scan-x; do git -C "$WS/$s" rev-parse HEAD; done; }
H0="$(heads)"
sumW0="$(tree_sum "$WS")"; sumD0="$(tree_sum "$DECOY")"

echo "== 1. dry-run writes nothing outside a temp dir"
out="$(CLAUDE_PROJECT_DIR="$DECOY" "$MIG" --workspace "$WS" --hub "$HUB" --language vi --git-hooks safe --plugin-data "$PD" --dry-run --keep-temp 2>&1)"; rc=$?
KT="$(printf '%s' "$out" | sed -n 's/^temp copy kept: \([^ ]*\) .*/\1/p')"
[ "$rc" = 0 ] && ok "dry-run exits 0" || bad "dry-run rc=$rc: $(printf '%s' "$out" | tail -5)"
[ "$sumW0" = "$(tree_sum "$WS")" ] && [ ! -e "$HUB" ] && [ ! -e "$PD" ] && ok "dry-run: workspace tree (incl. .git) unchanged, hub and plugin data dir not created" \
  || bad "dry-run changed the workspace: $(diff <(printf '%s\n' "$sumW0") <(tree_sum "$WS") | head -5)"
printf '%s' "$out" | grep -q -- '-- svc-a' && printf '%s' "$out" | grep -q 'create .claude/claudehut/topology.json ([0-9]* B)' \
  && printf '%s' "$out" | grep -qE 'modify \.claude/claudehut/MEMORY\.md \([0-9]+ → [0-9]+ B\)' \
  && printf '%s' "$out" | grep -qE 'backup → .*/\.claudehut-backup-<ts>/svc-a\.tar\.gz \([0-9]+ B\)' \
  && ok "dry-run plan: per service, files to create/modify with byte sizes and the backup" || bad "dry-run plan incomplete: $(printf '%s' "$out" | head -30)"
printf '%s' "$out" | grep -q 'hub-scan, no plane (1): scan-x' && printf '%s' "$out" | grep -q 'services (3): svc-a svc-b svc-c' \
  && ! printf '%s' "$out" | grep -q 'docs' && ok "dry-run lists 3 services and scan-x for hub-scan; docs (no git) ignored" || bad "discovery wrong: $(printf '%s' "$out" | grep -E 'services|hub-scan')"
printf '%s' "$out" | awk '/^-- svc-b/{on=1;next} /^-- /{on=0} on' | grep -q 'git hooks: skipped — .husky' \
  && ok "dry-run: svc-b hooks skipped (husky)" || bad "dry-run: svc-b hooks not reported as skipped: $(printf '%s' "$out" | awk '/^-- svc-b/{on=1} on' | head -30)"

C="$KT/fs$WS/svc-a"
[ -n "$KT" ] && [ "$(git -C "$C" config core.hooksPath)" = "$C/.git/hooks" ] && [ "$(cat "$C/.claude/worktrees/wt1/.git")" = "gitdir: $C/.git/worktrees/wt1" ] \
  && [ "$(cat "$C/.git/worktrees/wt1/gitdir")" = "$C/.claude/worktrees/wt1/.git" ] \
  && grep -q '>>> claudehut-index >>>' "$C/.git/hooks/post-merge" && [ ! -e "$WS/svc-a/.git/hooks/post-merge" ] \
  && ok "dry-run copy: hooksPath and worktree gitdir pointers rewritten to the copy; its hooks land in the copy, not the source" \
  || bad "dry-run copy points back at the source: hooksPath=$(git -C "$C" config core.hooksPath 2>&1) wt=$(cat "$C/.claude/worktrees/wt1/.git" 2>&1)"
printf '%s' "$out" | awk '/^-- svc-a/{on=1;next} /^-- /{on=0} on' | grep -q 'git hooks: skipped' \
  && bad "dry-run: svc-a (core.hooksPath = own .git/hooks) reported as skipped" || ok "dry-run: core.hooksPath naming the repo's own .git/hooks counts as safe"
printf '%s' "$out" | grep -qF -- "-- plugin data ($PD)" && ok "dry-run plan names the shim it will write in the plugin data dir" || bad "dry-run plan lacks the plugin data line"
rm -rf "$KT"
# Run from an installed layout (<config>/plugins/cache/<mkt>/<plugin>/<ver>), the shim's home is derived.
mkdir -p "$CLAUDE_CONFIG_DIR/plugins/cache/mkt/claudehut"; ln -s "$ROOT" "$CLAUDE_CONFIG_DIR/plugins/cache/mkt/claudehut/$PV"
o="$("$CLAUDE_CONFIG_DIR/plugins/cache/mkt/claudehut/$PV/bin/claudehut-migrate" --workspace "$WS" --hub "$HUB" --language vi --git-hooks safe --dry-run 2>&1)"
printf '%s' "$o" | grep -qF -- "-- plugin data ($CLAUDE_CONFIG_DIR/plugins/data/claudehut-mkt)" && [ ! -e "$CLAUDE_CONFIG_DIR/plugins/data" ] \
  && ok "installed plugin: --plugin-data defaults to <config>/plugins/data/claudehut-mkt (not created by the dry-run)" || bad "default plugin data dir not derived: $(printf '%s' "$o" | grep -E 'plugin data|git hooks call')"

echo "== 0. preflight"
mkdir -p "$CLAUDE_CONFIG_DIR/plugins"
printf '{"version":2,"plugins":{"claudehut@mkt":[{"scope":"project","projectPath":"%s","version":"0.11.0"},{"scope":"project","projectPath":"%s","version":"0.9.1"}]}}\n' "$WS/svc-b" "$T/elsewhere" > "$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"
o="$("$MIG" --workspace "$WS" --hub "$HUB" --language vi --git-hooks safe --plugin-data "$PD" --apply 2>&1)"; rc=$?
[ "$rc" = 2 ] && [ "$sumW0" = "$(tree_sum "$WS")" ] && [ ! -e "$HUB" ] && printf '%s' "$o" | grep -q "stale install: claudehut@mkt 0.11.0 (project scope $WS/svc-b)" \
  && ! printf '%s' "$o" | grep -q elsewhere && ok "preflight: --apply refused (rc 2, nothing written) while svc-b's project install is 0.11.0; an install outside the workspace is ignored" \
  || bad "preflight did not refuse: rc=$rc $(printf '%s' "$o" | tail -4)"
printf '{"version":2,"plugins":{"claudehut@mkt":[{"scope":"project","projectPath":"%s","version":"%s"}]}}\n' "$WS/svc-b" "$PV" > "$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"

echo "== 2. apply"
out="$(CLAUDE_PROJECT_DIR="$DECOY" "$MIG" --workspace "$WS" --hub "$HUB" --language vi --git-hooks safe --plugin-data "$PD" --apply 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "apply exits 0" || bad "apply rc=$rc: $(printf '%s' "$out" | grep -E 'WARN|ABORT' | head -5)"
B1="$(ls -d "$WS"/.claudehut-backup-* 2>/dev/null | head -1)"
[ -n "$B1" ] && for s in svc-a svc-b svc-c _workspace-root; do [ -s "$B1/$s.tar.gz" ] || B1=""; done
[ -n "$B1" ] && tar -tzf "$B1/svc-a.tar.gz" | grep -q '^\.git/hooks/pre-commit$' && tar -tzf "$B1/svc-a.tar.gz" | grep -q '^\.claude/claudehut/MEMORY\.md$' \
  && grep -q "^hub_created" "$B1/manifest.tsv" && ok "backups: one tar.gz per repo + root, holding .claude/ and .git/hooks; manifest records hub_created" \
  || bad "backups missing: $(ls "$WS"/.claudehut-backup-* 2>&1)"
[ -d "$HUB/.git" ] && [ -z "$(git -C "$HUB" remote)" ] && jq -e '.language=="vi" and .schema==1' "$HUB/.claude/claudehut/hub/hub.json" >/dev/null 2>&1 \
  && ok "hub: git init, no remote, hub.json {schema:1, language:vi}" || bad "hub wrong: $(cat "$HUB/.claude/claudehut/hub/hub.json" 2>&1)"
jq -e '(keys|sort)==["scan-x","svc-a","svc-b","svc-c"] and ."scan-x".has_plane==false and ."svc-a".has_plane==true' "$HUB/.claude/claudehut/hub/services.json" >/dev/null 2>&1 \
  && ok "services.json: exactly the 3 services + scan-x (hub-scanned, has_plane false); never the root or the hub" \
  || bad "services.json: $(jq -c 'keys' "$HUB/.claude/claudehut/hub/services.json" 2>&1)"
okt=1; for s in svc-a svc-b svc-c; do
  jq -e '.mode=="microservice" and .hub=="../ws-knowledge" and (has("language")|not)' "$WS/$s/.claude/claudehut/topology.json" >/dev/null 2>&1 || okt=0
  [ -f "$WS/$s/.claude/claudehut/index/meta.json" ] || okt=0
done
[ "$okt" = 1 ] && ok "services: topology microservice → ../ws-knowledge, language inherited (no field), index/meta.json built" || bad "service topology/index wrong: $(cat "$WS/svc-a/.claude/claudehut/topology.json")"
m="$(wc -c < "$WS/svc-a/.claude/claudehut/MEMORY.md" | tr -d ' ')"
[ "$m" -le 8192 ] && grep -q 'Keep this line.' "$WS/svc-a/.claude/claudehut/MEMORY.md" && grep -q 'Reuse additions (task-0060)' "$WS/svc-a/.claude/claudehut/MEMORY-history.md" \
  && ok "MEMORY.md migrated: $m B ≤8192, hand-written section kept, per-task blocks in MEMORY-history.md" || bad "MEMORY.md not migrated ($m B)"
! jq -e 'select(.learning=="")' "$WS/svc-a/.claude/claudehut/learnings.jsonl" >/dev/null 2>&1 && grep -q '"L-0002"' "$WS/svc-a/.claude/claudehut/learnings.rejected.jsonl" 2>/dev/null \
  && ok "learnings --repair: the empty entry moved to learnings.rejected.jsonl" || bad "empty learning still in the store"
[ ! -e "$WS/svc-b/.worktreeinclude" ] && ! jq -e 'has("extraKnownMarketplaces")' "$WS/svc-b/.claude/settings.json" >/dev/null 2>&1 \
  && [ ! -e "$WS/svc-c/.worktreeinclude" ] && [ "$(cat "$WS/svc-a/.worktreeinclude")" = .env ] \
  && ok "no extras added: svc-b/svc-c get no .worktreeinclude, svc-b no marketplace entry; svc-a's own kept" || bad "extras written: $(cat "$WS/svc-b/.claude/settings.json")"
grep -q '# >>> claudehut-index >>>' "$WS/svc-a/.git/hooks/post-merge" 2>/dev/null && grep -q 'echo pre' "$WS/svc-a/.git/hooks/pre-commit" \
  && [ ! -e "$WS/svc-b/.git/hooks/post-merge" ] && jq -e '.git_hooks==true' "$WS/svc-a/.claude/claudehut/topology.json" >/dev/null 2>&1 \
  && ok "git hooks: installed in svc-a (safe), none in svc-b (husky)" || bad "git hooks wrong"
grep -qF "'$PD/bin/claudehut-index'" "$WS/svc-a/.git/hooks/post-merge" && ! grep -qF "$ROOT/bin" "$WS/svc-a/.git/hooks/post-merge" \
  && grep -qF "t='$ROOT/bin/claudehut-index'" "$PD/bin/claudehut-index" && [ -x "$PD/bin/claudehut-index" ] \
  && ok "git hooks call the stable shim in --plugin-data (re-pointed on upgrade), never the versioned plugin path" \
  || bad "hooks pinned to the plugin path: $(grep -F 'update --detach' "$WS/svc-a/.git/hooks/post-merge")"
[ ! -e "$WS/svc-a/.claude/rules/vocabulary.md" ] && [ -f "$WS/svc-b/.claude/rules/vocabulary.md" ] && grep -qx vocabulary.md "$WS/svc-a/.claude/claudehut/rules-emitted.txt" \
  && ok "svc-a's hand-deleted vocabulary.md is not brought back (recorded in rules-emitted.txt)" || bad "apply brought back svc-a's deleted vocabulary.md"
[ "$(git -C "$WS/svc-c" show HEAD:.gitignore)" = "$(cat "$WS/svc-c/.gitignore")" ] && printf '%s' "$out" | awk '/^== service svc-c/{on=1;next} /^== /{on=0} on' | grep -q 'gitignore: plane ignored' \
  && ok "ignored .claude/ (svc-c): patch printed, .gitignore untouched" || bad "svc-c .gitignore handling wrong"
# The printed advice must work when followed: appending the patch alone leaves '.claude/' ignoring the plane (git
# cannot re-include under an ignored dir), so the message names the rule to delete. Follow it on a scratch repo.
gimsg="$(printf '%s' "$out" | awk '/^== service svc-c/{on=1;next} /^== /{on=0} on' | grep 'gitignore: plane ignored')"
gln="$(printf '%s' "$gimsg" | sed -n 's/.*delete line \([0-9]*\) of \([^ ]*\) .*/\1/p')"
G="$T/gi-follow"; mkdir -p "$G/.claude/claudehut/state" "$G/.claude/rules"; git -C "$G" init -q
: > "$G/.claude/claudehut/MEMORY.md"; : > "$G/.claude/claudehut/state/x"; : > "$G/.claude/rules/a.md"
[ -n "$gln" ] && sed "${gln}d" "$WS/svc-c/.gitignore" > "$G/.gitignore" \
  && printf '%s' "$out" | awk '/^== service svc-c/{on=1;next} /^== /{on=0} on' | grep -A1 'gitignore: plane ignored' | tail -1 | tr -s ' ' '\n' | sed '/^$/d' >> "$G/.gitignore"
printf '%s' "$gimsg" | grep -q 'by .gitignore:2 (.claude/)' && [ "$gln" = 2 ] \
  && ! git -C "$G" check-ignore -q .claude/claudehut/MEMORY.md && ! git -C "$G" check-ignore -q .claude/rules/a.md \
  && git -C "$G" check-ignore -q .claude/claudehut/state/x \
  && ok "gitignore advice names the rule to delete (.gitignore:2 .claude/); following it shares the plane, state/ stays ignored" \
  || bad "gitignore advice does not work when followed: $gimsg"
! printf '%s' "$out" | awk '/^== service svc-b/{on=1;next} /^== /{on=0} on' | grep -q 'gitignore: plane ignored' \
  && ok "svc-b: a '!' rule re-including MEMORY.md is not reported as ignored (no advice to delete it)" || bad "svc-b: negation rule reported as ignoring the plane"
[ "$H0" = "$(heads)" ] && [ -z "$(git -C "$WS/svc-a" status --porcelain -- src build.gradle)" ] && ok "no commits: every HEAD unchanged" || bad "a HEAD moved"
F="$HUB/.claude/claudehut/hub/fleet-learnings.jsonl"
[ "$(wc -l < "$F" | tr -d ' ')" = 2 ] && jq -s -e 'all(.[]; .scope=="fleet" and .sources[0].service=="ws") and (map(.id)|sort)==["F-0001","F-0002"]' "$F" >/dev/null 2>&1 \
  && [ -s "$WS/.claude/claudehut/learnings.jsonl.migrated" ] && [ -f "$WS/.claude/claudehut/learnings.jsonl" ] && [ ! -s "$WS/.claude/claudehut/learnings.jsonl" ] \
  && ok "root learnings: 2 valid → fleet-learnings.jsonl (provenance ws), old store .migrated, empty store kept for inject-phase" || bad "root learnings move wrong: $(cat "$F" 2>&1 | head -3)"
c="$(grep -c '^@' "$WS/CLAUDE.md")"
[ "$c" = 2 ] && grep -qx '@.claude/claudehut/PROJECT.md' "$WS/CLAUDE.md" && grep -qx '@ws-knowledge/.claude/claudehut/hub/HUB.md' "$WS/CLAUDE.md" \
  && grep -q 'ClaudeHut: project-adaptive memory' "$WS/CLAUDE.md" && [ -f "$HUB/.claude/claudehut/hub/HUB.md" ] \
  && ok "root CLAUDE.md: @imports only PROJECT.md + hub HUB.md, marker kept" || bad "root CLAUDE.md: $(cat "$WS/CLAUDE.md")"
jq -e '.mode=="microservice" and .hub=="ws-knowledge"' "$WS/.claude/claudehut/topology.json" >/dev/null 2>&1 && ok "root topology.json → hub (fleet learnings reach root sessions)" || bad "root topology wrong"
# The moved rows carry provenance {service: ws}; with the root store now empty they must still be injected at the root
# (the ewallet rehearsal found the self-provenance dedup hiding all 35 of them).
O="$(env -u CLAUDE_PLUGIN_DATA CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$WS" bash "$ROOT/scripts/inject-learnings.sh" --filter "r2dbc transactions reactive" --top 3 --compact 2>/dev/null)"
grep -q '^- \[pitfall\] \[fleet\] R2DBC transactions need TransactionalOperator' <<<"$O" \
  && ok "root session: the moved learnings come back as [fleet] rows (own provenance, empty local store)" || bad "root session sees no moved learnings: $O"
# The emptied root store numbers its next learning L-0001 again; that must not hide the row moved from the old L-0001
# (provenance ids are "migrated:L-####"). On a copy of the root plane, so the idempotency check below is unaffected.
RC="$T/rootcopy"; mkdir -p "$RC/.claude"; cp -Rp "$WS/.claude/claudehut" "$RC/.claude/"
jq --arg h "$HUB" '.hub=$h' "$WS/.claude/claudehut/topology.json" > "$RC/.claude/claudehut/topology.json"
printf '%s\n' '{"category":"pitfall","trigger":"gradle, offline","learning":"Run gradle --offline only once the dependency cache is warm","evidence":"x:1","scope":"service"}' > "$T/rc-cand.jsonl"
(cd "$RC" && env -u CLAUDE_PLUGIN_DATA CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$RC" bash "$ROOT/scripts/merge-learnings.sh" --candidates "$T/rc-cand.jsonl" >/dev/null 2>&1)
O="$(env -u CLAUDE_PLUGIN_DATA CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$RC" bash "$ROOT/scripts/inject-learnings.sh" --top 5 --compact 2>/dev/null)"
nid="$(jq -r '.id' "$RC/.claude/claudehut/learnings.jsonl")"
case "$nid" in L-0001|L-0003) : ;; *) nid="" ;; esac   # the new local id reuses an old one that was moved
[ -n "$nid" ] && grep -q '\[fleet\] R2DBC transactions need TransactionalOperator' <<<"$O" && grep -q '\[fleet\] Kafka producers must key' <<<"$O" \
  && jq -s -e 'map(.sources[0].id) | sort == ["migrated:L-0001","migrated:L-0003"]' "$F" >/dev/null \
  && ok "root: a new local learning reusing a moved id ($nid) hides no moved row (provenance migrated:L-####)" \
  || bad "root: moved row hidden by new local $nid: $(jq -c '.sources' "$F" | tr '\n' ' ') / $O"
keep=1; for f in .claude/claudehut/tasks/0001-old/plan.md .claude/claudehut/reuse-index.json .understand-anything/knowledge-graph.json; do
  [ "$(printf '%s\n' "$sumW0" | grep "^$f ")" = "$(tree_sum "$WS" | grep "^$f ")" ] || keep=0
  [ "$(printf '%s\n' "$sumW0" | grep "^svc-a/$f ")" = "$(tree_sum "$WS" | grep "^svc-a/$f ")" ] || keep=0
done
[ "$keep" = 1 ] && ok "tasks/, reuse-index.json and the root UA graph unchanged" || bad "a kept file changed"
[ "$sumD0" = "$(tree_sum "$DECOY")" ] && ok "decoy CLAUDE_PROJECT_DIR plane untouched (child env pinned)" || bad "decoy plane changed"

echo "== 3. re-apply is idempotent"
sum1="$(tree_sum "$WS")"
out2="$("$MIG" --workspace "$WS" --hub "$HUB" --language vi --git-hooks safe --plugin-data "$PD" --apply 2>&1)"; rc=$?
d="$(diff <(printf '%s\n' "$sum1") <(tree_sum "$WS"))"
[ "$rc" = 0 ] && [ -z "$d" ] && ok "re-apply: tree identical (only a new backup dir)" || bad "re-apply changed: rc=$rc $(printf '%s' "$d" | head -8)"
# A dry-run on the migrated tree must plan nothing: the copy's temp path ends up inside generated files (hook shim
# path, MEMORY.md hub path), so the plan compares content with that prefix stripped (ewallet: ~50 false 'modify').
outd2="$("$MIG" --workspace "$WS" --hub "$HUB" --language vi --git-hooks safe --plugin-data "$PD" --dry-run 2>&1)"; rc=$?
nplan="$(grep -cE '^    (create|modify|delete) ' <<<"$outd2")"
[ "$rc" = 0 ] && [ "$nplan" = 0 ] && ok "dry-run after apply: 0 create/modify/delete lines" \
  || bad "dry-run after apply planned $nplan changes (rc=$rc): $(grep -E '^    (create|modify|delete) ' <<<"$outd2" | head -6)"
[ "$sum1" = "$(tree_sum "$WS")" ] || bad "dry-run after apply wrote into the workspace"

echo "== 4. restore returns the pre-apply tree"
out3="$("$MIG" --restore "$B1" 2>&1)"; rc=$?
d="$(diff <(printf '%s\n' "$sumW0") <(tree_sum "$WS"))"
[ "$rc" = 0 ] && [ -z "$d" ] && [ ! -e "$HUB" ] && ok "restore: byte-identical to the pre-apply tree (path incl. NFC name bytes, mode, sha); hub moved aside" \
  || bad "restore differs: rc=$rc $(printf '%s' "$d" | head -8)"
ls -d "$B1"/.restore-*/aside/_hub_ws-knowledge >/dev/null 2>&1 && ok "restore moved the created hub into the backup dir (never deleted)" || bad "hub not kept aside"

echo "== 5. a later unattended --refresh-rules adds no extras"
"$MIG" --workspace "$WS" --hub "$HUB" --language vi --apply >/dev/null 2>&1
printf '0.0.1' > "$WS/svc-b/.claude/claudehut/.plugin-version"; printf '0.0.1' > "$WS/svc-a/.claude/claudehut/.plugin-version"
CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$WS/svc-a" "$INIT" "$WS/svc-a" --refresh-rules >/dev/null 2>&1
[ ! -e "$WS/svc-a/.claude/rules/vocabulary.md" ] && ok "maintain.sh's --refresh-rules on a version bump keeps svc-a's deleted vocabulary.md deleted" || bad "--refresh-rules brought vocabulary.md back"
s1="$(cksum < "$WS/svc-b/.claude/settings.json")"; c1="$(cksum < "$WS/svc-b/CLAUDE.md")"
CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$WS/svc-b" "$INIT" "$WS/svc-b" --refresh-rules >/dev/null 2>&1
[ ! -e "$WS/svc-b/.worktreeinclude" ] && [ "$s1" = "$(cksum < "$WS/svc-b/.claude/settings.json")" ] && [ "$c1" = "$(cksum < "$WS/svc-b/CLAUDE.md")" ] \
  && ok "maintain.sh's --refresh-rules: settings.json, CLAUDE.md byte-identical; no .worktreeinclude" || bad "--refresh-rules added extras after migration"

echo "== 6. maintain.sh on the Summer KB home (java-common-ms, found by the ewallet rehearsal) logs no hook error"
K="$T/kbws/java-common-ms"; mkdir -p "$K/.claude/claudehut/state" "$K/.claude/summer-kb"
printf '# Project: java-common-ms\n' > "$K/.claude/claudehut/PROJECT.md"
printf "dependencies { implementation 'io.f8a.summer:summer-payment-sdk:1.0' }\n" > "$K/build.gradle"
printf '# canonical index\n' > "$K/.claude/summer-kb/INDEX.md"; printf '# core\n' > "$K/.claude/summer-kb/core.md"
kb0="$(cat "$K/.claude/summer-kb/INDEX.md" "$K/.claude/summer-kb/core.md" | cksum)"
printf '{"session_id":"s-kb","hook_event_name":"SessionStart","source":"startup"}' \
  | env -u CLAUDE_PLUGIN_DATA CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$K" "$ROOT/scripts/maintain.sh" >/dev/null 2>&1
[ ! -s "$K/.claude/claudehut/state/hook-errors.log" ] && [ "$kb0" = "$(cat "$K/.claude/summer-kb/INDEX.md" "$K/.claude/summer-kb/core.md" | cksum)" ] \
  && ok "KB home: no 'summer-kb install failed' in hook-errors.log; canonical INDEX.md/core.md untouched" \
  || bad "KB home: $(cat "$K/.claude/claudehut/state/hook-errors.log" 2>/dev/null)"

echo "== 7. Summer KB: the java-common-ms source stamp follows HEAD; consumers stale → refresh, missing → install, current → kept"
WS="$T/kws"; KH="$WS/kws-knowledge"; mkdir -p "$WS"; KBI="$ROOT/skills/summer-kb-setup/scripts/install_summer_kb.py"
for s in java-common-ms c-stale c-missing c-current; do mkrepo "$s"; v011_plane "$WS/$s"; done
L="$WS/java-common-ms"; mkdir -p "$L/.claude/summer-kb"
printf "dependencies { api platform('io.f8a.summer:summer-platform:1.0') }\n" > "$L/platform.gradle"
printf '# INDEX\n| Doc |\n|---|\n| [core.md](core.md) |\n| [kafka.md](kafka.md) |\n| [payment-sdk.md](payment-sdk.md) |\n| [vietqr.md](vietqr.md) |\n' > "$L/.claude/summer-kb/INDEX.md"
for d in USAGE core kafka payment-sdk vietqr; do printf '# %s\n' "$d" > "$L/.claude/summer-kb/$d.md"; done
gitq "$L" add -A && gitq "$L" commit -qm kb
kbdeps(){ printf "dependencies {\n" > "$WS/$1/build.gradle"; for a in "${@:2}"; do printf "  implementation 'io.f8a.summer:%s'\n" "$a" >> "$WS/$1/build.gradle"; done; printf "}\n" >> "$WS/$1/build.gradle"; gitq "$WS/$1" commit -qam deps; }
kbdeps c-stale summer-core summer-kafka-consumer; kbdeps c-missing summer-payment-sdk; kbdeps c-current summer-core
# c-missing: a commented-out dep (never a module) and one declared only through the version catalog (a module) —
# the KB must read the build like the hub's lib edges do.
mkdir -p "$WS/c-missing/gradle"; printf '[libraries]\nsummer-file = { module = "io.f8a.summer:summer-file" }\nsummer-unused = { module = "io.f8a.summer:summer-rest-common" }\n' > "$WS/c-missing/gradle/libs.versions.toml"
printf "dependencies {\n  // implementation 'io.f8a.summer:summer-kafka-consumer'\n  implementation libs.summer.file\n}\n" >> "$WS/c-missing/build.gradle"; gitq "$WS/c-missing" add -A; gitq "$WS/c-missing" commit -qm catalog
python3 "$KBI" "$WS/c-current" >/dev/null 2>&1; rm -f "$L/.claude/summer-kb/.summer-kb-meta.json"   # current consumer; source unstamped
SK="$WS/c-stale/.claude/summer-kb"; mkdir -p "$SK"
printf '{"source":"sibling","summerCommit":"b6017fb680607a025181445be45b84f6152add32","includedModules":["core","payment-sdk"]}\n' > "$SK/.summer-kb-meta.json"
for d in INDEX USAGE core payment-sdk; do printf 'old %s\n' "$d" > "$SK/$d.md"; done
printf '# team-edited pointer\n' > "$WS/c-stale/.claude/rules/summer-kb.md"; printf 'mine\n' > "$SK/NOTES.txt"
HEADL="$(git -C "$L" rev-parse HEAD)"; cur0="$(tree_sum "$WS/c-current/.claude/summer-kb")"; kw0="$(tree_sum "$WS")"
out="$("$MIG" --workspace "$WS" --hub "$KH" --language vi --dry-run 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -q '^  summer-kb: refresh 1, install 1, up-to-date 1$' <<<"$out" && [ "$kw0" = "$(tree_sum "$WS")" ] \
  && ok "KB dry-run: 'summer-kb: refresh 1, install 1, up-to-date 1' reported; workspace unchanged" \
  || bad "KB dry-run (rc=$rc): $(grep -E 'summer-kb' <<<"$out" | head -6)"
grep -q 'modify .claude/summer-kb/' <<<"$out" && grep -q 'create .claude/summer-kb/' <<<"$out" \
  && ok "KB dry-run plan lists the .claude/summer-kb/ writes per service" || bad "KB dry-run plan: $(grep -E 'summer-kb' <<<"$out" | head -6)"
out="$("$MIG" --workspace "$WS" --hub "$KH" --language vi --apply 2>&1)"; rc=$?
grep -q '^  summer-kb: refresh 1, install 1, up-to-date 1$' <<<"$out" && grep -q '^  summer-kb java-common-ms: source stamped' <<<"$out" \
  && ok "KB apply: java-common-ms stamped first, then refresh 1, install 1, up-to-date 1" || bad "KB apply (rc=$rc): $(grep -E 'summer-kb' <<<"$out" | head -6)"
[ "$(jq -r '.summerCommit + " " + .role' "$L/.claude/summer-kb/.summer-kb-meta.json" 2>/dev/null)" = "$HEADL source" ] \
  && [ "$(jq -c '.modules["payment-sdk"]' "$L/.claude/summer-kb/.summer-kb-meta.json")" = '["payment-sdk","vietqr"]' ] \
  && ok "source .summer-kb-meta.json: summerCommit = java-common-ms HEAD, per-module doc list (vietqr ships in payment-sdk)" \
  || bad "source meta: $(cat "$L/.claude/summer-kb/.summer-kb-meta.json" 2>/dev/null)"
[ "$(jq -r '.summerCommit' "$SK/.summer-kb-meta.json")" = "$HEADL" ] && [ "$(jq -c '.includedModules' "$SK/.summer-kb-meta.json")" = '["core","kafka"]' ] \
  && [ "$(cat "$SK/kafka.md")" = '# kafka' ] && [ ! -e "$SK/payment-sdk.md" ] && ! grep -q 'payment-sdk' "$SK/INDEX.md" \
  && ok "stale consumer refreshed: stamp at HEAD, modules core+kafka, dropped payment-sdk doc removed, INDEX scoped" \
  || bad "stale consumer: $(cat "$SK/.summer-kb-meta.json"; ls "$SK")"
[ "$(cat "$WS/c-stale/.claude/rules/summer-kb.md")" = '# team-edited pointer' ] && [ "$(cat "$SK/NOTES.txt")" = mine ] \
  && ok "hand-edited pointer and a non-KB file in the KB dir are left alone" || bad "a hand-edited file was touched"
MK="$WS/c-missing/.claude/summer-kb"
[ -f "$MK/payment-sdk.md" ] && [ -f "$MK/vietqr.md" ] && [ -f "$MK/core.md" ] && [ ! -e "$MK/kafka.md" ] \
  && [ -f "$WS/c-missing/.claude/rules/summer-kb.md" ] && [ "$(jq -r .summerCommit "$MK/.summer-kb-meta.json")" = "$HEADL" ] \
  && ok "missing consumer installed: payment-sdk + vietqr + core, pointer created, stamp at HEAD" || bad "missing consumer: $(ls -a "$MK" 2>&1)"
KBA="$(jq -c '.detectedArtifacts' "$MK/.summer-kb-meta.json" 2>/dev/null)"
HBA="$(jq -c '[.edges[] | select(.type=="lib" and .from=="c-missing") | .module] | sort' "$KH/.claude/claudehut/hub/service-links.json" 2>/dev/null)"
[ "$KBA" = '["summer-file","summer-payment-sdk"]' ] && [ "$KBA" = "$HBA" ] \
  && ok "KB module set == the hub's lib edges for that service (commented dep ignored, catalog-only dep counted)" \
  || bad "KB artifacts $KBA vs hub lib-edge modules $HBA"
[ -z "$(find "$ROOT/scripts" "$ROOT/skills" -name __pycache__ -print -quit)" ] \
  && ok "the KB installer imports the hub parser without writing __pycache__ into the plugin" || bad "__pycache__ written into the plugin"
[ "$cur0" = "$(tree_sum "$WS/c-current/.claude/summer-kb")" ] && grep -q '^  summer-kb c-current: up-to-date' <<<"$out" \
  && ok "current consumer: reported up-to-date, KB byte-identical" || bad "current consumer KB changed"
KB1="$(ls -d "$WS"/.claudehut-backup-* 2>/dev/null | tail -1)"
tar -tzf "$KB1/c-stale.tar.gz" 2>/dev/null | grep -q 'summer-kb/.summer-kb-meta.json' && ok "the backup taken before the write holds c-stale's old KB" || bad "c-stale KB not in $KB1"
kw1="$(tree_sum "$WS")"
out="$("$MIG" --workspace "$WS" --hub "$KH" --language vi --apply 2>&1)"
grep -q '^  summer-kb: refresh 0, install 0, up-to-date 3$' <<<"$out" && [ "$kw1" = "$(tree_sum "$WS")" ] \
  && ok "KB re-apply: refresh 0, install 0, up-to-date 3; tree identical (idempotent)" \
  || bad "KB re-apply: $(grep -E 'summer-kb' <<<"$out" | head -5) $(diff <(printf '%s\n' "$kw1") <(tree_sum "$WS") | head -5)"
gitq "$L" commit -q --allow-empty -m bump
out="$("$MIG" --workspace "$WS" --hub "$KH" --language vi --dry-run 2>&1)"
grep -q '^  summer-kb: refresh 3, install 0, up-to-date 0$' <<<"$out" && ok "a new java-common-ms commit makes every consumer stale (dry-run: refresh 3)" \
  || bad "after a library commit: $(grep -E 'summer-kb' <<<"$out" | head -5)"

# maintain.sh: a stamp comparison only; a stale KB (here: the library moved one commit) is refreshed detached.
HEADL="$(git -C "$L" rev-parse HEAD)"
kb_wait(){ local i; for i in $(seq 1 50); do [ "$(jq -r .summerCommit "$1" 2>/dev/null)" = "$HEADL" ] && return 0; sleep 0.2; done; return 1; }
# A plugin root with only the KB skill: maintain.sh's rule refresh and detached index update (no bin/) stay out, so no
# background job writes into the hub while the suite cleans up.
KR="$T/kbroot"; mkdir -p "$KR/skills"; ln -s "$ROOT/skills/summer-kb-setup" "$KR/skills/summer-kb-setup"
for s in java-common-ms c-stale; do
  printf '{"session_id":"s-kb2","hook_event_name":"SessionStart","source":"startup"}' \
    | env -u CLAUDE_PLUGIN_DATA CLAUDE_PLUGIN_ROOT="$KR" CLAUDE_PROJECT_DIR="$WS/$s" "$ROOT/scripts/maintain.sh" >/dev/null 2>&1
done
kb_wait "$L/.claude/summer-kb/.summer-kb-meta.json" && kb_wait "$SK/.summer-kb-meta.json" \
  && [ "$(cat "$WS/c-stale/.claude/rules/summer-kb.md")" = '# team-edited pointer' ] \
  && ok "maintain.sh: a library commit → detached refresh of the source stamp and of a consumer's KB (pointer kept)" \
  || bad "maintain.sh refresh: source=$(jq -r .summerCommit "$L/.claude/summer-kb/.summer-kb-meta.json") consumer=$(jq -r .summerCommit "$SK/.summer-kb-meta.json") head=$HEADL"

# maintain.sh first install for a consumer that names Summer only in gradle/libs.versions.toml.
mkrepo c-toml; v011_plane "$WS/c-toml"; mkdir -p "$WS/c-toml/gradle"
printf '[libraries]\nsummer-file = { module = "io.f8a.summer:summer-file" }\n' > "$WS/c-toml/gradle/libs.versions.toml"
printf "dependencies {\n  implementation libs.summer.file\n}\n" > "$WS/c-toml/build.gradle"
printf '{"session_id":"s-kb3","hook_event_name":"SessionStart","source":"startup"}' \
  | env -u CLAUDE_PLUGIN_DATA CLAUDE_PLUGIN_ROOT="$KR" CLAUDE_PROJECT_DIR="$WS/c-toml" "$ROOT/scripts/maintain.sh" >/dev/null 2>&1
[ "$(jq -c .detectedArtifacts "$WS/c-toml/.claude/summer-kb/.summer-kb-meta.json" 2>/dev/null)" = '["summer-file"]' ] \
  && ok "maintain.sh: a catalog-only Summer consumer (libs.versions.toml) gets its first KB install" \
  || bad "catalog-only consumer: $(ls -a "$WS/c-toml/.claude/summer-kb" 2>&1)"

echo "== 8. Summer KB opt-in (--with/--without): docs for modules a service is about to adopt survive --if-stale"
OW="$T/optws"; OL="$OW/java-common-ms/.claude/summer-kb"; mkdir -p "$OL"
printf '# INDEX\n| Module doc |\n|---|\n| [core.md](core.md) |\n| [rest.md](rest.md) |\n| [dr.md](dr.md) | opt-in gate |\n| [featureflag.md](featureflag.md) | opt-in |\n' > "$OL/INDEX.md"
for d in USAGE core rest dr featureflag; do printf '# %s\n' "$d" > "$OL/$d.md"; done
git -C "$OW/java-common-ms" init -q -b main && gitq "$OW/java-common-ms" add -A && gitq "$OW/java-common-ms" commit -qm kb
mkdir -p "$OW/o-svc" "$OW/o-core"; OK8="$OW/o-svc/.claude/summer-kb"
printf "dependencies { implementation 'io.f8a.summer:summer-rest-common' }\n" > "$OW/o-svc/build.gradle"
python3 "$KBI" "$OW/o-svc" --with dr,featureflag >/dev/null 2>&1
[ -f "$OK8/dr.md" ] && [ -f "$OK8/featureflag.md" ] && [ "$(jq -c .optInModules "$OK8/.summer-kb-meta.json")" = '["dr","featureflag"]' ] \
  && ok "--with dr,featureflag installs both docs and stamps optInModules" || bad "--with: $(ls "$OK8" 2>&1) $(jq -c .optInModules "$OK8/.summer-kb-meta.json" 2>&1)"
grep -q '\[dr.md\](dr.md) _(opt-in, not yet a dependency)_' "$OK8/INDEX.md" && grep -q '^> \*\*opt-in (not yet a dependency):\*\* `dr`.*io.f8a.summer:summer-dr-core' "$OK8/INDEX.md" \
  && ! grep '\[rest.md\]' "$OK8/INDEX.md" | grep -q 'not yet a dependency' \
  && ok "INDEX.md marks opt-in docs 'not yet a dependency' (with the artifact to add), a detected module's row unmarked" \
  || bad "INDEX opt-in marker: $(cat "$OK8/INDEX.md")"
printf "dependencies {\n  implementation 'io.f8a.summer:summer-rest-common'\n  implementation 'io.f8a.summer:summer-file'\n}\n" > "$OW/o-svc/build.gradle"
printf '# file\n' > "$OL/file.md"
out="$(python3 "$KBI" "$OW/o-svc" --if-stale 2>&1)"
tail -1 <<<"$out" | grep -q '^summer-kb: refreshed' && [ -f "$OK8/dr.md" ] && [ -f "$OK8/featureflag.md" ] && [ -f "$OK8/file.md" ] \
  && ok "--if-stale after a dependency change refreshes and keeps the opt-in docs" || bad "--if-stale dropped opt-in: $(tail -1 <<<"$out") $(ls "$OK8")"
o0="$(tree_sum "$OK8")"; out="$(python3 "$KBI" "$OW/o-svc" --if-stale 2>&1)"
tail -1 <<<"$out" | grep -q '^summer-kb: up-to-date' && [ "$o0" = "$(tree_sum "$OK8")" ] \
  && ok "a second --if-stale is up-to-date, tree unchanged (no refresh loop)" || bad "opt-in loop: $(tail -1 <<<"$out")"
python3 "$KBI" "$OW/o-svc" --without featureflag >/dev/null 2>&1
[ ! -e "$OK8/featureflag.md" ] && [ -f "$OK8/dr.md" ] && [ "$(jq -c .optInModules "$OK8/.summer-kb-meta.json")" = '["dr"]' ] \
  && ! grep -q 'featureflag' "$OK8/INDEX.md" && ok "--without featureflag removes its doc and INDEX row; dr stays opted in" \
  || bad "--without: $(ls "$OK8") $(jq -c .optInModules "$OK8/.summer-kb-meta.json")"
o0="$(tree_sum "$OK8")"; out="$(python3 "$KBI" "$OW/o-svc" --with nope 2>&1)"; rc=$?
[ "$rc" = 2 ] && [ "$(tail -1 <<<"$out")" = 'summer-kb: skip (error: unknown module nope)' ] && [ "$o0" = "$(tree_sum "$OK8")" ] \
  && ok "--with an unknown module: exit 2, 'summer-kb: skip (error: unknown module nope)', nothing written" || bad "unknown module (rc=$rc): $(tail -2 <<<"$out")"
printf "dependencies { implementation 'io.f8a.summer:summer-dr-core' }\n" > "$OW/o-core/build.gradle"
python3 "$KBI" "$OW/o-core" >/dev/null 2>&1
[ -f "$OW/o-core/.claude/summer-kb/dr.md" ] && [ "$(jq -c .includedModules "$OW/o-core/.claude/summer-kb/.summer-kb-meta.json")" = '["core","dr"]' ] \
  && ! grep -q 'not yet a dependency' "$OW/o-core/.claude/summer-kb/INDEX.md" \
  && ok "a summer-dr-core-only consumer gets dr.md (ARTIFACT_TO_MODULE), unmarked" || bad "-core only: $(ls "$OW/o-core/.claude/summer-kb" 2>&1)"

echo; echo "MIGRATE: $PASS passed, $FAIL failed"
[ -z "${EVAL_COUNT_DIR:-}" ] || printf '%s\n' "$PASS" > "$EVAL_COUNT_DIR/migrate-tests.count"
[ "$FAIL" -eq 0 ]
