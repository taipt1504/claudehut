# OWASP Top 10 — Java/Spring Patterns Checklist

## Table of contents

- [A01 — Broken Access Control](#a01--broken-access-control)
- [A02 — Cryptographic Failures](#a02--cryptographic-failures)
- [A03 — Injection](#a03--injection)
- [A04 — Insecure Design](#a04--insecure-design)
- [A05 — Security Misconfiguration](#a05--security-misconfiguration)
- [A06 — Vulnerable Components](#a06--vulnerable-components)
- [A07 — Auth Failures](#a07--auth-failures)
- [A08 — Software/Data Integrity](#a08--softwaredata-integrity)
- [A09 — Logging Failures](#a09--logging-failures)
- [A10 — SSRF](#a10--ssrf)

## A01 — Broken Access Control

Check:
- Every endpoint declares auth (SecurityFilterChain or @PreAuthorize).
- No client-supplied user IDs used as auth identity.
- Multi-tenant queries always scoped by tenant.

Regex patterns to flag:
- `permitAll\(\)` on broad path.
- `@RequestMapping` without surrounding auth declaration.
- Direct `request.getParameter("userId")` for auth.

## A02 — Cryptographic Failures

Check:
- Passwords use BCrypt (Spring Security `PasswordEncoder`).
- No `MessageDigest.getInstance("MD5"|"SHA-1")` for password/token.
- HTTPS enforced.

Regex:
- `MessageDigest\.getInstance\("(MD5|SHA-1)"\)`
- `Cipher\.getInstance\("DES`
- `KeyGenerator\.getInstance\("DES`

## A03 — Injection

Check:
- All SQL is parameterized (`?` or `:param`).
- No string concatenation in queries.
- SpEL never evaluates user input.
- LDAP filters escape user input.

Regex:
- `\.createQuery\([^)]*\+ ` (string concat in JPQL)
- `\.parseExpression\(.*request\.|.*getParameter\(`  (SpEL with user input)
- `\.exec\(.*request\.|.*getParameter\(` (Runtime.exec with user input)
- `new ProcessBuilder\(.*getParameter\(` (ProcessBuilder with user input)

## A04 — Insecure Design

Check:
- Threat model done for new auth/payment/admin features.
- Rate limiting on /login, /password-reset, /otp.

## A05 — Security Misconfiguration

Check:
- `application.yml`: no plaintext credentials.
- Actuator: exposure only health/info publicly.
- CORS: no `*` with `allowCredentials=true`.
- H2 console disabled in prod.
- Error responses: no stack traces leaked.

Regex:
- `management\.endpoints\.web\.exposure\.include[ =:]*\*`
- `allowedOrigins[("]+.*\*` near `allowCredentials.*true`
- `spring\.h2\.console\.enabled[ =:]*true`
- `password[ =:]+[a-zA-Z0-9]{4,}` in YAML/properties
- `secret[ =:]+[a-zA-Z0-9]{8,}`

## A06 — Vulnerable Components

Check:
- `./gradlew dependencyCheckAnalyze` or `mvn dependency-check:check` passes.
- Spring Boot version on supported branch.

## A07 — Auth Failures

Check:
- JWT lib validates signature + expiry + audience.
- Account lockout after N failed logins.
- Session timeout configured.

Regex:
- `\.setSigningKey\(.*\)` with hardcoded secret
- `Jwts\.parser\(\)\.setSigningKey\(\"`
- `\.parseClaimsJwt\(` (unsigned JWT parsing)

## A08 — Software/Data Integrity

Check:
- Jackson `enableDefaultTyping` / `activateDefaultTyping` not used.
- `@JsonTypeInfo` paired with `@JsonSubTypes` whitelist.
- CI uses pinned action SHAs.

Regex:
- `\.enableDefaultTyping\(`
- `\.activateDefaultTyping\(`
- `@JsonTypeInfo` without nearby `@JsonSubTypes`

## A09 — Logging Failures

Check:
- Auth events logged.
- No PII / credentials in logs.

Regex:
- `log\.\w+\(.*password|token|secret|apiKey|api_key)`
- `System\.out\.println`  (use SLF4J)

## A10 — SSRF

Check:
- WebClient/RestTemplate destination URLs not directly from user input.
- Allow-list for outbound calls.
- Timeouts configured.

Regex:
- `WebClient.*\.uri\(.*getParameter\(` 
- `RestTemplate.*\.exchange\(.*getParameter\(`
