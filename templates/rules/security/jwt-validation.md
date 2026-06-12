---
id: rules/security/jwt-validation
paths:
  - "**/*Jwt*.java"
  - "**/*TokenProvider*.java"
  - "**/SecurityConfig.java"
  - "**/*OAuth*.java"
severity: critical
tags: [jwt, oauth2, security]
---
<!-- ClaudeHut rule template — generated into .claude/rules/security/jwt-validation.md by claudehut-init. Reused & enhanced from committed rules/security/jwt-validation.md. -->


# JWT Validation — Spring Security 6 OAuth2 Resource Server

Default stack: `spring-boot-starter-oauth2-resource-server` (Nimbus).
Custom JJWT / jose4j implementations: prefer the starter — it handles JWKS rotation, algorithm pinning, and clock skew out of the box.

## Decoder — use issuer discovery, never hand-roll

```java
// CORRECT — fetches JWKS from /.well-known/openid-configuration at startup
@Bean
JwtDecoder jwtDecoder() {
    NimbusJwtDecoder decoder = (NimbusJwtDecoder)
            JwtDecoders.fromIssuerLocation(issuerUri);        // pins RS256 from discovery

    OAuth2TokenValidator<Jwt> validators = new DelegatingOAuth2TokenValidator<>(
            new JwtTimestampValidator(Duration.ofSeconds(60)), // exp + nbf, 60s skew
            new JwtIssuerValidator(issuerUri),                 // iss exact match
            audienceValidator());                              // aud must contain this service

    decoder.setJwtValidator(validators);
    return decoder;
}

private OAuth2TokenValidator<Jwt> audienceValidator() {
    return new JwtClaimValidator<List<String>>(
            JwtClaimNames.AUD,
            aud -> aud != null && aud.contains("my-service-id"));
}
```

```yaml
# Minimal application.yml — issuer-uri triggers auto-configuration
spring:
  security:
    oauth2:
      resourceserver:
        jwt:
          issuer-uri: https://idp.example.com
          audiences: https://my-service-id.example.com   # built-in aud validation (Spring Security 6.1+)
```

## Algorithm confusion — the forging attack

| Mistake | Attack | Outcome |
|---|---|---|
| Accept `alg` from token header | Attacker sets `alg=HS256`, signs with server's **public key** | Token accepted as valid |
| Trust multiple algs without pinning | Downgrade to weak alg | Signature bypass |
| Static secret key, no rotation | Key exfiltration | Permanent forgery until manual rotation |

**Fix:** pin via `jwsAlgorithm` — never rely on the header:

```java
NimbusJwtDecoder decoder = NimbusJwtDecoder
        .withIssuerLocation(issuerUri)
        .jwsAlgorithm(SignatureAlgorithm.RS256)   // pin; reject everything else
        .build();
```

If you genuinely need two algorithms (e.g. RS256 + ES256): call `.jwsAlgorithm()` twice. Never add HS256 alongside an asymmetric alg.

## Required claims decision table

| Claim | Validator | Failure mode if missing |
|---|---|---|
| `exp` | `JwtTimestampValidator` (default) | Replay of expired tokens forever |
| `nbf` | `JwtTimestampValidator` (default) | Token accepted before activation window |
| `iss` | `JwtIssuerValidator` | Cross-tenant token acceptance |
| `aud` | `JwtClaimValidator` (custom, see above) | Token for service A accepted by service B |

Clock skew default: **60 seconds** (verified in Spring Security 6.5 docs). Override only for high-clock-drift environments; do not exceed 300s.

## Authority mapping — avoid SCOPE_ surprise

Default `JwtGrantedAuthoritiesConverter` maps `scope` claim → `SCOPE_read`, `SCOPE_write`.
If your IdP uses `roles` or a custom claim, configure explicitly:

```java
@Bean
JwtAuthenticationConverter jwtAuthConverter() {
    JwtGrantedAuthoritiesConverter gac = new JwtGrantedAuthoritiesConverter();
    gac.setAuthoritiesClaimName("roles");     // claim name in your token
    gac.setAuthorityPrefix("ROLE_");          // prefix for hasRole() checks
    JwtAuthenticationConverter conv = new JwtAuthenticationConverter();
    conv.setJwtGrantedAuthoritiesConverter(gac);
    return conv;
}
```

Mismatch symptom: `hasRole("ADMIN")` always returns 403 even with correct token — check authority string with a debug log of `Authentication.getAuthorities()`.

## What NOT to put in claims

JWT payload is **base64-encoded, not encrypted**. Anyone with the token can read every claim.

- No passwords, secrets, or API keys.
- No PII (SSN, full DOB, card numbers) — GDPR/CCPA liability.
- No sensitive internal IDs that aid enumeration.
- Keep payload small: large tokens hurt every HTTP request.

If confidentiality is needed: use JWE (JSON Web Encryption) or pass sensitive data server-side via opaque reference tokens.

## Revocation reality

Access tokens are **bearer credentials** — valid until `exp`. There is no standard online revocation for stateless JWT.

| Strategy | Trade-off |
|---|---|
| Short `exp` (≤ 15 min) + refresh rotation | Best default; limits blast radius of leaked token |
| Blocklist in Redis keyed on `jti` | Works but adds per-request latency + distributed state |
| Reference (opaque) tokens + introspection | Revocable instantly; adds IDP round-trip |

Design rule: **do not issue access tokens > 1 hour TTL** unless you have a blocklist. Refresh tokens must be rotated on use (detect reuse = revoke entire family).

## Key rotation via JWKS

- JWKS endpoint (`jwk-set-uri`) returns multiple keys; each key has a `kid` header.
- `NimbusJwtDecoder` re-fetches JWKS automatically on unknown `kid` — rotation is zero-downtime.
- Static symmetric secret (`secret-value`) has no rotation path — avoid for production.

## When NOT to use this pattern

- **Internal service-to-service (mTLS network)** — mTLS + service mesh provides stronger guarantees without token overhead.
- **Very short-lived batch jobs** — workload identity (IRSA, Workload Identity Federation) is simpler than token issuance.
- **Single-server session apps** — stateful sessions with CSRF protection are simpler and immediately revocable.

## Anti-patterns

- Parsing JWT with `split("\\.")` + manual Base64 decode — skips signature verification entirely.
- Storing the signing secret in `application.properties` committed to git.
- Trusting claims without calling `decoder.decode()` first (e.g., reading `Authorization` header as plain JSON).
- Ignoring `JwtException` in a catch block → silently treating unauthenticated requests as anonymous.
- Using the same `kid`/secret across dev/staging/prod environments.
