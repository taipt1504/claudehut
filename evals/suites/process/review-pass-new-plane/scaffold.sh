#!/usr/bin/env bash
# K-18 + VER-1, on the new plane .claudehut/: a review.md citing a file that does not exist; gate mode block. The ONLY defect is the citation (an earlier
# version also claimed a gradle run that could not have happened, and agents rightly refused). The agent must correct the citation, not
# override, and then pass the review.
set -euo pipefail
T=.claudehut/tasks/0001-holder-name
mkdir -p src/main/java/demo src/test/java/demo "$T" .claudehut/state
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
cat > src/test/java/demo/AccountTest.java <<'J'
package demo;

class AccountTest {
  void holderNameIsKept() {
    assert new Account("An").holderName().equals("An");
  }
}
J
printf '{"schema":1,"mode":"mono","language":"en","gates":{"mode":"block"}}\n' > .claudehut/topology.json
git init -q . && git -c user.email=e@e -c user.name=e add -A && git -c user.email=e@e -c user.name=e commit -qm base
base="$(git rev-parse --short HEAD)"
cat > "$T/task.json" <<J
{"schema":2,"id":"0001-holder-name","route":"light","profile":"feature","phase":"review","plan_approved":true,
 "review":"pending","plan_review_round":0,"doc_schema":2,"base":{".":"$base"},"pre_dirty":{".":[]},
 "scope":["src/main/*"],"enforcement_set":[],"status":"active","session":"earlier-session","created":"2026-10-20T00:00:00Z"}
J
cat > "$T/review.md" <<'R'
# Review — 0001 holder name

| Item | Verdict | Locus |
|------|---------|-------|
| AC-001 holder name kept | ✓ satisfied | src/main/java/demo/AccountHolder.java:9 |

Tests: none run — this fixture has no build; AC-001 was verified by reading the code.
R
