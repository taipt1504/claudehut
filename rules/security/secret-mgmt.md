---
id: rules/security/secret-mgmt
applies-to: "**/*"
severity: critical
tags: [secrets, vault, env-vars]
---

# Secret Management

## Rules

- NEVER commit secrets. Ever.
- Read from environment, secret store (Vault), or cloud KMS — not files.
- Mask secrets in logs.
- Rotate periodically.
- Different secrets per environment (dev / staging / prod).

## Sources by priority (highest first)

1. Cloud secret manager (AWS Secrets Manager, GCP Secret Manager, Vault).
2. K8s Secrets via env var or volume mount.
3. CI/CD secret store (GitHub Actions Secrets, GitLab CI Variables).
4. Local: `.env` file (gitignored) for development only.

## Spring config

```yaml
# application.yml — references, not values
spring:
  datasource:
    username: ${DB_USERNAME}
    password: ${DB_PASSWORD}
  kafka:
    bootstrap-servers: ${KAFKA_BROKERS}
    properties:
      sasl.jaas.config: ${KAFKA_SASL_JAAS_CONFIG}

oauth:
  client-id: ${OAUTH_CLIENT_ID}
  client-secret: ${OAUTH_CLIENT_SECRET}
```

## Vault integration

```yaml
spring:
  cloud:
    vault:
      uri: https://vault.example.com
      authentication: kubernetes
      kv:
        enabled: true
        backend: secret
        default-context: my-app/${spring.profiles.active}
```

Spring fetches secrets at startup; available via `@Value("${db.password}")`.

## Logs — never log secrets

```java
// BAD
log.info("Connecting with token={}", token);
log.info("Request body: {}", body);  // may contain credit card

// GOOD
log.info("Connecting to {} (token masked)", host);
log.info("Request body keys: {}", body.keySet());
```

## Masking utility

```java
public static String maskToken(String token) {
    if (token == null || token.length() < 8) return "****";
    return token.substring(0, 4) + "..." + token.substring(token.length() - 4);
}
```

## Pre-commit detection

Use `gitleaks` or `trufflehog`:

```yaml
# .pre-commit-config.yaml
repos:
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.18.0
    hooks:
      - id: gitleaks
```

Phase 5 reviewer-security regex-scans diff for secret patterns:

```
sk-[a-zA-Z0-9_-]{20,}
AKIA[0-9A-Z]{16}
ghp_[a-zA-Z0-9]{36}
-----BEGIN (RSA |EC |DSA )?PRIVATE KEY-----
postgres(ql)?://[^:]+:[^@]+@
```

## If secret leaks

1. Rotate immediately (don't wait).
2. Audit access logs for unauthorized use.
3. `git filter-branch` or BFG to scrub from history.
4. Force-push to remote (notify team).
5. Document in incident log.

## Anti-patterns

- `application.yml` with plaintext passwords.
- Secrets in git history (even if removed in HEAD — still in git log).
- Secrets in K8s manifests committed to repo (use SealedSecrets or sops).
- Logging full request/response payloads.
- Caching secrets in memory longer than necessary.
- Using same secret across environments.
