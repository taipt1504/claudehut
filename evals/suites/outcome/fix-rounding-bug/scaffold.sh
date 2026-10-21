#!/usr/bin/env bash
# A plain-JDK project (no Gradle: the sandbox has no network) with a failing self-check.
set -euo pipefail
mkdir -p src/demo .claude/claudehut
cat > src/demo/Fee.java <<'J'
package demo;

import java.math.BigDecimal;
import java.math.RoundingMode;

public final class Fee {
  private Fee() {}

  /** Fee in VND for an amount: 1.1% rounded HALF_UP to whole dong, at least 1,000 and at most 50,000. */
  public static long of(long amount) {
    BigDecimal fee = BigDecimal.valueOf(amount).multiply(new BigDecimal("0.011")).setScale(0, RoundingMode.DOWN);
    long f = fee.longValue();
    if (f < 1000) {
      return 1000;
    }
    return f;
  }
}
J
cat > src/demo/FeeCheck.java <<'J'
package demo;

public final class FeeCheck {
  public static void main(String[] a) {
    check(Fee.of(50_000), 1_000);
    check(Fee.of(1_000_045), 11_000);
    check(Fee.of(1_000_046), 11_001);
    check(Fee.of(10_000_000), 50_000);
    System.out.println("ALL CHECKS PASSED");
  }

  private static void check(long got, long want) {
    if (got != want) {
      throw new AssertionError("got " + got + " want " + want);
    }
  }
}
J
printf '{"schema":1,"mode":"mono","language":"en"}\n' > .claude/claudehut/topology.json
git init -q . && git -c user.email=e@e -c user.name=e add -A && git -c user.email=e@e -c user.name=e commit -qm base
