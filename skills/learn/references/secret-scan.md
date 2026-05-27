# Secret-Scan Regex Set

MUST run on every candidate entry before append.

## Hard reject patterns

```regex
sk-[a-zA-Z0-9_-]{20,}                        # OpenAI, Anthropic API keys
AKIA[0-9A-Z]{16}                              # AWS access key
-----BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----
ghp_[a-zA-Z0-9]{36}                           # GitHub PAT classic
github_pat_[a-zA-Z0-9_]{82}                   # GitHub fine-grained
gho_[a-zA-Z0-9]{36}                           # GitHub OAuth token
xox[baprs]-[0-9a-zA-Z-]{10,}                  # Slack tokens
glpat-[0-9a-zA-Z_-]{20}                       # GitLab PAT
eyJ[a-zA-Z0-9_-]{20,}\.eyJ[a-zA-Z0-9_-]{20,}\.[a-zA-Z0-9_-]{20,}  # JWT
postgres(ql)?://[^:]+:[^@]+@                  # DB URL with creds
mongodb(\+srv)?://[^:]+:[^@]+@
redis://[^:]+:[^@]+@
```

## Heuristic patterns (flag, request manual confirm)

```regex
(password|passwd|pwd|secret|token|api[_-]?key)\s*[:=]\s*['"]?[A-Za-z0-9+/=_-]{8,}
['"][A-Za-z0-9+/]{40,}={0,2}['"]              # likely base64 secret
```

## Length-based heuristic

- Any literal string > 32 chars in diff context: warn, request confirmation.
- Hex strings > 32 chars: warn (might be hash, key, or signature).

## Recovery on detection

1. Reject the entry. Log to `state/tasks/<id>/learn-rejected.log`.
2. Do NOT log the matched secret text. Only log the pattern type matched.
3. Notify user: "Entry skipped due to potential secret pattern. Review manually if false positive."

## False positive handling

Allow override via `claudehut-config.json#learn.secret_scan_allowlist`: a list of regex patterns that the user has confirmed are safe (e.g., a hash of a public commit).

## Why this matters

Memory is committed to git. A leaked secret in memory persists in history even after deletion. Defense in depth: secret-scan at extraction + pre-commit hook + reviewer-security in Phase 5.
