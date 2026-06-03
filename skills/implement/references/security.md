# Spring Security + OWASP Playbook

<!-- Researched vs Spring Security 6.5 (context7 ID: /websites/spring_io_spring-security_reference_6_5).
     Source rules folded in: spring-security.md, owasp-top10.md, input-validation.md,
     deserialization.md, secret-mgmt.md, actuator.md, method-security.md. -->

**When:** *SecurityConfig.java, security/ packages, controllers/handlers (authz + validation), deserialization, secrets/actuator config.*

---

## DO

**Filter chain**
- Declare an explicit `SecurityFilterChain` bean — never rely on Boot's auto-config for production.
- Start from `.anyRequest().denyAll()` (or `.authenticated()`); explicitly permit below it.
- Use the lambda DSL — `WebSecurityConfigurerAdapter` is removed in Spring Security 6.

**Authorization**
- `@EnableMethodSecurity` (replaces `@EnableGlobalMethodSecurity`) for `@PreAuthorize` / `@PostAuthorize`.
- Authorize on the **server-derived** principal (`authentication.name`, JWT claim) — never a request param or `@PathVariable` without cross-checking.
- Combine filter-chain rules with method-level guards; neither alone is sufficient.

**JWT / OAuth2**
- Validate signature, expiry (`exp`), issuer (`iss`), audience (`aud`) — use `oauth2ResourceServer` + `NimbusJwtDecoder`; do not roll custom.
- Set session policy `STATELESS` for token-based APIs; disable CSRF accordingly.

**CORS** — explicit allow-list of origins, methods, headers. Never `*` with `allowCredentials(true)`.

**Passwords** — `BCryptPasswordEncoder` (strength ≥ 10) or `Argon2PasswordEncoder.defaultsForSpringSecurity_v5_8()`.

**Actuator** — `include: health,info` only. Gate `/actuator/**` with `ADMIN` role via a dedicated `SecurityFilterChain` ordered before the main chain.

**Input** — `@Valid` on every `@RequestBody`; use `*Request` DTOs, never bind directly to `@Entity` (validation mechanics + `ProblemDetail` error shape are owned by `web.md`; this is the threat-control view).

**Secrets** — read from env/Vault/K8s Secret; never in source or `application.yml` as plain values.

**Deserialization** — never call `activateDefaultTyping`; use `@JsonSubTypes` whitelist for polymorphism.

**Logging** — log auth events (success/fail/role change); mask tokens, passwords, PII in log output.

---

## DON'T

- `.anyRequest().permitAll()` as a default — this is a silent open door.
- `csrf().disable()` on session-based (form-login) APIs.
- `allowedOrigins("*")` combined with `allowCredentials(true)`.
- `management.endpoints.web.exposure.include: '*'` — exposes `/env`, `/heapdump`, etc.
- `endpoint.health.show-details: always` — leaks DB host, queue names to unauthenticated callers.
- `ObjectMapper.activateDefaultTyping(…)` / `enableDefaultTyping(…)` — RCE vector.
- `Class.forName(userInput)` anywhere.
- `new Yaml()` without `SafeConstructor` — arbitrary class instantiation.
- JWT secret as `@Value` from plain `application.properties`.
- `spring.h2.console.enabled=true` in production profiles.
- `@PreAuthorize` with literal IDs like `"#userId == 'admin'"`.
- Binding `@RequestBody User entity` (mass-assignment: client can set `role`, `id`, `createdAt`).
- Logging full request/response bodies (may contain PII or credentials).
- Using the same secret across dev / staging / prod.

---

## Correct example

```java
// SecurityConfig.java — Spring Boot 3.2+ / Spring Security 6.x / Java 17+
@Configuration
@EnableWebSecurity
@EnableMethodSecurity          // replaces @EnableGlobalMethodSecurity
public class SecurityConfig {

    /** Main API chain — stateless JWT resource server */
    @Bean
    @Order(2)
    public SecurityFilterChain apiChain(HttpSecurity http) throws Exception {
        return http
            .securityMatcher("/api/**")
            .csrf(AbstractHttpConfigurer::disable)           // safe: stateless
            .sessionManagement(s -> s.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
            .cors(Customizer.withDefaults())                 // picks up corsConfigurationSource bean
            .authorizeHttpRequests(auth -> auth
                .requestMatchers(HttpMethod.POST, "/api/auth/login").permitAll()
                .requestMatchers("/api/admin/**").hasRole("ADMIN")
                .anyRequest().authenticated())               // deny-by-default via authenticated()
            .oauth2ResourceServer(o -> o.jwt(Customizer.withDefaults()))
            .build();
    }

    /** Actuator chain — ordered first so it matches before apiChain */
    @Bean
    @Order(1)
    public SecurityFilterChain actuatorChain(HttpSecurity http) throws Exception {
        return http
            .securityMatcher(EndpointRequest.toAnyEndpoint())
            .authorizeHttpRequests(auth -> auth
                .requestMatchers(EndpointRequest.to(HealthEndpoint.class, InfoEndpoint.class)).permitAll()
                .anyRequest().hasRole("ADMIN"))
            .httpBasic(Customizer.withDefaults())
            .build();
    }

    @Bean
    public JwtDecoder jwtDecoder(@Value("${spring.security.oauth2.resourceserver.jwt.issuer-uri}") String issuer) {
        return JwtDecoders.fromIssuerLocation(issuer);   // validates sig + exp + iss automatically
    }

    @Bean
    public PasswordEncoder passwordEncoder() {
        return new BCryptPasswordEncoder();              // strength defaults to 10
    }

    @Bean
    public CorsConfigurationSource corsConfigurationSource() {
        var config = new CorsConfiguration();
        config.setAllowedOrigins(List.of("https://app.example.com"));
        config.setAllowedMethods(List.of("GET", "POST", "PUT", "DELETE", "PATCH"));
        config.setAllowedHeaders(List.of("Authorization", "Content-Type"));
        config.setAllowCredentials(true);
        var source = new UrlBasedCorsConfigurationSource();
        source.registerCorsConfiguration("/api/**", config);
        return source;
    }
}

// Method-level authorization
@RestController
@RequestMapping("/api/users")
public class UserController {

    /** Ownership check — server principal, not client param */
    @PreAuthorize("#userId == authentication.name or hasRole('ADMIN')")
    @GetMapping("/{userId}")
    public UserResponse get(@PathVariable String userId) { ... }

    @PreAuthorize("hasRole('ADMIN')")
    @DeleteMapping("/{id}")
    public void delete(@PathVariable String id) { ... }

    /** PostAuthorize — return-object ownership */
    @PostAuthorize("returnObject.ownerId == authentication.name")
    @GetMapping("/{id}/order")
    public Order getOrder(@PathVariable Long id) { ... }
}

// Request DTO — never bind Entity directly
public record CreateUserRequest(
    @NotBlank @Email @Size(max = 254) String email,
    @NotBlank @Size(min = 2, max = 100) String name
) {}

@PostMapping
public UserResponse create(@RequestBody @Valid CreateUserRequest req) { ... }

// Jackson — safe polymorphism, no default typing
@JsonTypeInfo(use = JsonTypeInfo.Id.NAME, property = "type")
@JsonSubTypes({
    @JsonSubTypes.Type(value = OrderCreated.class,  name = "order.created"),
    @JsonSubTypes.Type(value = OrderShipped.class, name = "order.shipped")
})
public abstract class OrderEvent { ... }

@Bean
public Jackson2ObjectMapperBuilderCustomizer jacksonCustomizer() {
    return builder -> builder
        .featuresToEnable(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES);
    // activateDefaultTyping is NEVER called
}
```

```yaml
# application.yml — references only, never plaintext secrets
spring:
  security:
    oauth2:
      resourceserver:
        jwt:
          issuer-uri: ${JWT_ISSUER_URI}
  datasource:
    username: ${DB_USERNAME}
    password: ${DB_PASSWORD}

management:
  endpoints:
    web:
      exposure:
        include: health,info,metrics
  endpoint:
    health:
      show-details: when_authorized   # not "always"
      probes:
        enabled: true                  # K8s liveness/readiness
```

---

## Anti-pattern

```java
// BAD — old adapter (removed in Security 6), blanket permitAll, default typing
@Configuration
public class BadSecurityConfig extends WebSecurityConfigurerAdapter {  // REMOVED in 6.x

    @Override
    protected void configure(HttpSecurity http) throws Exception {
        http
            .csrf().disable()                            // also disables on session-based app
            .authorizeRequests()                         // deprecated — use authorizeHttpRequests
                .anyRequest().permitAll();               // OPEN DOOR
    }
}

// BAD — binding Entity, bypassing mass-assignment protection
@PostMapping("/users")
public User create(@RequestBody User user) { ... }  // client sets role, id, etc.

// BAD — default typing → RCE
ObjectMapper mapper = new ObjectMapper();
mapper.activateDefaultTyping(
    LaissezFaireSubTypeValidator.instance, ObjectMapper.DefaultTyping.NON_FINAL);

// BAD — CORS wildcard with credentials
config.setAllowedOriginPatterns(List.of("*"));
config.setAllowCredentials(true);  // spec violation + security bypass

// BAD — actuator fully exposed
// management.endpoints.web.exposure.include=*
// management.endpoint.health.show-details=always
```

---

## OWASP Top 10 → Spring mapping

| OWASP | Spring control |
|-------|---------------|
| A01 Broken Access Control | `authorizeHttpRequests` deny-by-default + `@PreAuthorize` ownership check; scope DB queries by tenant |
| A02 Cryptographic Failures | `BCryptPasswordEncoder` / Argon2; HTTPS + HSTS; secrets from Vault/env |
| A03 Injection (SQL/JPQL) | JPA/R2DBC parameter binding only — no string concat; never `SpelExpressionParser` on user input |
| A03 Injection (XSS) | JSON output safe by default; Thymeleaf auto-escapes — don't disable |
| A05 Misconfiguration | Actuator `include: health,info`; no `h2-console` in prod; no `*` CORS |
| A07 Auth Failures | JWT: validate sig + `exp` + `iss` + `aud`; account lockout + rate-limit on auth endpoints |
| A08 Deserialization | No `activateDefaultTyping`; `@JsonSubTypes` whitelist; `SafeConstructor` for YAML; `ObjectInputFilter` for Java serialization |
| A10 SSRF | Never pass raw user URL to `WebClient`/`RestTemplate`; allow-list domains; block private IP ranges |

---

## Gotchas / version notes

- **`WebSecurityConfigurerAdapter` removed** in Spring Security 6.0. Use `SecurityFilterChain` beans exclusively.
- **`authorizeRequests()` deprecated** — use `authorizeHttpRequests()` (uses `AuthorizationManager` pipeline).
- **`@EnableMethodSecurity`** replaces `@EnableGlobalMethodSecurity(prePostEnabled=true)` in Security 5.6+. Old annotation still works in 6.x but deprecated; drop it.
- **Multiple `SecurityFilterChain` beans** require `@Order`. Lower number = higher priority. Without `securityMatcher`, the chain matches everything — only one such catch-all is allowed.
- **CSRF for stateless JWT APIs** — safe to disable because there's no browser session cookie. If you mix session + JWT, keep CSRF for session paths.
- **`oauth2ResourceServer` configures `SessionCreationPolicy.STATELESS` implicitly** when used — but set it explicitly for clarity.
- **`Argon2PasswordEncoder.defaultsForSpringSecurity_v5_8()`** is the recommended modern default over v5_2 defaults (higher memory/iteration cost).
- **Spring AOP `@PreAuthorize` skips private methods** — proxy-based; use AspectJ weaving or move logic to a public service method.
- **`spring.h2.console.enabled`** — Spring Boot auto-enables it when H2 is on the classpath in dev. Explicitly `false` in production profile.
- **`EndpointRequest.toAnyEndpoint()`** — use in `securityMatcher` to match Actuator paths regardless of `base-path` config.
- **`show-details: when_authorized`** — unauthenticated callers see only `{"status":"UP"}`; authenticated admins see full details.
- **Secret leaks in git** — rotate immediately, audit access logs, use BFG/`git filter-repo` to scrub history, then force-push. Don't wait.
