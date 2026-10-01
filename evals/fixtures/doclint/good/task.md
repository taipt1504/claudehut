# Task: Trim log noise
> id: 0002-log-noise · route: light · profile: bugfix · rev: 1 · status: draft

## 1. Approach
Lower the WebClient log level; reuse the existing logback profile.

## 2. Tasks
| ID | Goal | Files | Test first | Verify | Depends |
|---|---|---|---|---|---|
| T1 | quiet webclient logs | src/main/resources/logback.xml | LogLevelTest#quiet | gradle test | - |
