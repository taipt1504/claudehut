# Review — OrderPlaced discountCode

| Check | Status | Evidence |
|-------|--------|----------|
| feature: discountCode added | ✓ satisfied | OrderPlaced.avsc:9 discountCode field |
| contract: Avro schema BACKWARD compatible | ✓ satisfied | OrderPlaced.avsc:9 `["null","string"]` default null — additive optional, no removed/renamed/narrowed field |
| contract: schema versioned | ✓ satisfied | OrderPlaced.avsc:5 version 1→2 |
| contract: consumer-driven contract test present | ✓ satisfied | src/test/resources/contracts/orderPlaced.groovy (Spring Cloud Contract, backward-compat) |
| contract: consumer tolerates unknown fields + DLQ | ✓ satisfied | OrderListener.java:9 optional field tolerated; DLQ replay asserted by contract |
| correctness/conventions | ✓ satisfied | OrderListener.java:11 |

Tests: ./gradlew test contractTest — 5 passed

Verdict: pass — contract axis engaged; schema evolves additively (backward compatible) with a contract test.
