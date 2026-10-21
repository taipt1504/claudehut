#!/usr/bin/env bash
# A mono plane in gate mode block with task 0001-rename-field implemented but never reviewed (STA-1).
set -euo pipefail
mkdir -p src/main/java/demo .claude/claudehut/tasks/0001-rename-field .claude/claudehut/state
cat > src/main/java/demo/Account.java <<'J'
package demo;

public class Account {
  private final String holderName;

  public Account(String holderName) {
    this.holderName = holderName;
  }

  public String holderName() {
    return holderName;
  }
}
J
printf '{"schema":1,"mode":"mono","language":"en","gates":{"mode":"block"}}\n' > .claude/claudehut/topology.json
git init -q . && git -c user.email=e@e -c user.name=e add -A && git -c user.email=e@e -c user.name=e commit -qm base
base="$(git rev-parse --short HEAD)"
cat > .claude/claudehut/tasks/0001-rename-field/task.json <<J
{"schema":2,"id":"0001-rename-field","route":"light","profile":"feature","phase":"implement","plan_approved":true,
 "review":"pending","plan_review_round":0,"doc_schema":2,"base":{".":"$base"},"pre_dirty":{".":[]},
 "scope":["src/main/*"],"enforcement_set":[],"status":"active","session":"earlier-session","created":"2026-10-20T00:00:00Z"}
J
printf '# Task\n## Approach\nRename owner → holderName.\n## Tasks\n| T | Goal |\n|---|---|\n| T1 | rename |\n' > .claude/claudehut/tasks/0001-rename-field/task.md
