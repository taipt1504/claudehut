---
id: rules/security/owasp-top10
paths:
  - "**/*Controller.java"
  - "**/*Handler.java"
  - "**/SecurityConfig*.java"
severity: critical
tags: [security, owasp]
---
<!-- ClaudeHut rule template — generated into .claude/rules/security/owasp-top10.md by claudehut-init. Reused & enhanced from committed rules/security/owasp-top10.md. -->


# OWASP Top 10 — Java/Spring Checklist

Apply at every endpoint, every input boundary, every persistence layer.

## A01 — Broken Access Control

- Every endpoint MUST declare auth requirement (`SecurityFilterChain` or method-level `@PreAuthorize`).
- Never trust client-supplied `userId` — use `Principal` / `Authentication` from SecurityContext.
- Multi-tenant: scope every query by `tenant_id` automatically (consider `@TenantId` aspect).
- No "open by default" — start from `deny` and explicitly allow.

## A02 — Cryptographic Failures

- Passwords: BCrypt via `PasswordEncoder` (Spring Security default). Never MD5/SHA1.
- Secrets: Vault / KMS / environment. Never in code, properties files, or git.
- TLS in transit: enforce HTTPS (HSTS header).
- Sensitive fields (PII, payment): consider field-level encryption.

## A03 — Injection

- **SQL**: always parameterized queries. JPA/R2DBC parameter binding. No string concat.
- **JPQL/HQL**: same — use `:param`. No `+` concatenation.
- **OS commands**: avoid `Runtime.exec`; if unavoidable, allow-list args.
- **LDAP**: escape `*()\`.
- **SpEL**: NEVER evaluate user input via `SpelExpressionParser` — known CVE pattern.
- **XSS in REST**: JSON output is safe by default; HTML templating (Thymeleaf) auto-escapes — don't disable.

## A04 — Insecure Design

- Threat model new features (`/threat-model` skill).
- Rate limit auth endpoints (login, password reset, OTP).
- Defense in depth — multiple layers per concern.

## A05 — Security Misconfiguration

- `application.yml`: never commit `password: changeme`.
- Spring Boot Actuator: only expose `/health` and `/info` publicly. `/metrics`, `/env`, `/heapdump` require auth + role.
- Disable `spring.h2.console` in production.
- CORS: never use `*` for `Access-Control-Allow-Origin` with credentials.
- Error responses: don't leak stack traces. Use `ProblemDetail` with sanitized messages.

## A06 — Vulnerable Components

- Run `./gradlew dependencyCheckAnalyze` (OWASP dep-check) in CI.
- Snyk/Dependabot for alerts.
- Pin versions; don't use `latest`.
- Update Spring Boot to current patch within 30 days of release.

## A07 — Identification and Authentication Failures

- JWT: validate signature, expiry, issuer, audience. Use `nimbus-jose-jwt` not custom.
- Session timeout: ≤ 30 min sliding, ≤ 8h absolute.
- MFA for admin accounts.
- Account lockout after N failed attempts (rate-limit per IP + per user).

## A08 — Software and Data Integrity Failures

- Jackson deserialization: disable default typing (`mapper.deactivateDefaultTyping()`).
- Polymorphic types: use `@JsonTypeInfo` with `@JsonSubTypes` whitelist only.
- Signed JARs / supply-chain attestation if shipping artifacts.
- CI: pin action versions by SHA (GitHub Actions).

## A09 — Security Logging and Monitoring

- Log auth events (login success/fail, password change, role change).
- Log access to sensitive resources.
- Don't log PII / credentials / tokens. Mask in logs.
- Alert on anomalies (10× normal error rate, spike in 401s).

## A10 — Server-Side Request Forgery (SSRF)

- Never let user input directly control destination URL.
- If user-supplied URL needed: allow-list domains, disallow private IP ranges (10.*, 192.168.*, 169.254.*, etc.).
- WebClient/RestTemplate: configure default timeouts + size limits.

## Spring-specific gotchas

| Issue | Fix |
|-------|-----|
| `@RequestMapping` without auth | Add `SecurityFilterChain` rule |
| Mass assignment via `@RequestBody Entity` | Use dedicated `*Request` DTO, never bind directly to Entity |
| `@Value` from user input | Compile-time constants only |
| Actuator exposed | `management.endpoints.web.exposure.include=health,info` |
| Spring AOP advice on private methods | Doesn't intercept — use AspectJ if needed |
| `RestTemplate` without timeout | Set `connectTimeout` + `readTimeout` |

## Phase 5 reviewer-security focus

When Phase Loop runs, `claudehut-reviewer-security` checks every category above with reference to changed files in the diff.
