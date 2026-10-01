<!-- ch:schema kind=spec total.feature=1200 total.bugfix=500 total.migration=700
1. Context             | req=feature,bugfix,migration | budget=120
2. Goals & Non-Goals   | req=- (optional)             | budget=100
3. Requirements        | req=feature,bugfix,migration | cells=Requirement (EARS):40w,Acceptance (GWT):60w
4. Flow                | req=feature                  | budget=80 | diagram=required
5. Contracts           | req=feature                  | budget=150
6. Decisions           | req=feature,bugfix,migration | cells=Decision (Y-statement):80w,Rejected options:40w
7. Open Questions      | req=- (optional)             | budget=60
Rollback               | req=migration
-->
# Spec template (doclint fixture — mirrors 06 §5.4)

```markdown
# Spec: <title>
> id: NNNN-slug · profile: feature|bugfix|migration · route: full · rev: 1 · status: draft|approved · date: YYYY-MM-DD
## 1. Context
## 2. Goals & Non-Goals
## 3. Requirements
| ID | Requirement (EARS) | Acceptance (GWT) |
| AC-001 | WHEN … THE SYSTEM SHALL … | GIVEN … WHEN … THEN … |
## 4. Flow
## 5. Contracts
## 6. Decisions
| ID | Decision (Y-statement) | Rejected options | Confirmation | Status |
## 7. Open Questions
## Rollback
## Changelog
```
