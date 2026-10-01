# Review: round2 fixture

## Lanes

| Lane | Result | Reason |
|---|---|---|
| reviewer | ✓ | always |
| test | ✓ 12/0 | route full |
| security | ✗ 1 HIGH | path:SecurityConfig |
| contract | ✓ | hunk:@*Mapping OrderController.java |

## Findings

| Severity | file:line | Quote | Lane | Reporters |
|---|---|---|---|---|
| ✗ HIGH | SecurityConfig.java:5 | `return null` | security | 1 |
| ✗ LOW | OrderController.java:5 | missing @Timed | contract | 1 |

## Verdict

FAIL — security outstanding.
