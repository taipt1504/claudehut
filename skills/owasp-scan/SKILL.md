---
name: owasp-scan
description: Run OWASP dependency-check + custom Spring Security misconfig regex scans. Used in Phase 5 verify stage. Slash-invoke /claudehut:owasp-scan for on-demand scans. Outputs structured findings list; fails build on High/Critical.
---

# OWASP Scan

Automated dependency CVE check + project regex scan for Spring Security gotchas.

## Quick start

```bash
/claudehut:owasp-scan
```

Runs `scripts/owasp-scan.sh`:

1. **Dependency CVE check** — `./gradlew dependencyCheckAnalyze` (or `mvn dependency-check:check`) if plugin present.
2. **Custom regex sweep** — scan source for known Spring Security misconfig patterns.
3. **Output** — JSON summary at `state/tasks/<id>/owasp-findings.json`.

Reference list: `references/owasp-top10-checklist.md`. CVE mapping: `references/cve-mapping.md`.

## Scripts

- `scripts/owasp-scan.sh` — full scan, exits 1 on any High/Critical.

## Outputs

```json
{
  "ts": "<iso>",
  "totals": {"critical": 0, "high": 1, "medium": 4, "low": 7},
  "findings": [
    {
      "severity": "high",
      "rule": "actuator-exposed",
      "file": "src/main/resources/application.yml",
      "line": 22,
      "detail": "management.endpoints.web.exposure.include=*"
    }
  ]
}
```

## Hard rules

- Block phase advance if any Critical.
- High count > 0 → warn but allow if user confirms.
- Use repository's existing dep-check config; don't override.
- Do not run network scans unless explicitly configured.

## Exit criteria

- [ ] Dependency check completed (or skipped if plugin not configured)
- [ ] Regex sweep done
- [ ] `owasp-findings.json` written
- [ ] Critical count == 0
