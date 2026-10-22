#!/usr/bin/env bash
# EVL-4 (M6): task 0001-holder-name in phase review, lanes clean, test output saved. The plane is at .claudehut/
# (ADR K-18), which a run may write, so the agent writes review.md itself. Gate mode block.
set -euo pipefail
T=.claudehut/tasks/0001-holder-name
mkdir -p src/main/java/demo src/test/java/demo build "$T" .claudehut/state
cat > src/main/java/demo/Account.java <<'J'
package demo;

public class Account {
  private final String holderName;

  public Account(String holderName) {
    if (holderName == null || holderName.isBlank()) {
      throw new IllegalArgumentException("holderName");
    }
    this.holderName = holderName;
  }

  public String holderName() {
    return holderName;
  }
}
J
cat > src/test/java/demo/AccountTest.java <<'J'
package demo;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import org.junit.jupiter.api.Test;

class AccountTest {
  @Test
  void holderNameIsKept() {
    assertEquals("An", new Account("An").holderName());
  }

  @Test
  void blankHolderNameIsRejected() {
    assertThrows(IllegalArgumentException.class, () -> new Account(" "));
  }
}
J
cat > build.gradle <<'G'
plugins { id 'java' }
repositories { mavenCentral() }
dependencies {
  testImplementation 'org.junit.jupiter:junit-jupiter:5.10.2'
  testRuntimeOnly 'org.junit.platform:junit-platform-launcher'
}
test { useJUnitPlatform() }
G
printf '$ gradle test\n> Task :compileJava\n> Task :compileTestJava\n> Task :test\nAccountTest > holderNameIsKept() PASSED\nAccountTest > blankHolderNameIsRejected() PASSED\nBUILD SUCCESSFUL in 4s — 2 tests passed\n' > build/test-output.txt
printf '{"schema":1,"mode":"mono","language":"en","gates":{"mode":"block"}}\n' > .claudehut/topology.json
git init -q . && git -c user.email=e@e -c user.name=e add -A && git -c user.email=e@e -c user.name=e commit -qm base
base="$(git rev-parse --short HEAD)"
cat > "$T/task.json" <<J
{"schema":2,"id":"0001-holder-name","route":"light","profile":"feature","phase":"review","plan_approved":true,
 "review":"pending","plan_review_round":0,"doc_schema":2,"base":{".":"$base"},"pre_dirty":{".":[]},
 "scope":["src/main/*"],"enforcement_set":[],"status":"active","session":"earlier-session","created":"2026-10-20T00:00:00Z"}
J
cat > "$T/task.md" <<'M'
# Task 0001 — holder name
## Acceptance criteria
- AC-001 the holder name given to the constructor is kept and returned by `holderName()`
- AC-002 a blank holder name is rejected with `IllegalArgumentException`
## Tasks
| T | Goal |
|---|---|
| T1 | validate and keep the holder name |
M
