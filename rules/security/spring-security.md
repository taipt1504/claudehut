---
id: rules/security/spring-security
applies-to: "**/SecurityConfig*.java, **/WebSecurityConfig*.java"
severity: critical
tags: [spring-security, auth, authorization]
---

# Spring Security Configuration

## DO

- Explicit SecurityFilterChain / SecurityWebFilterChain — no defaults.
- Start from `denyAll()`, explicitly permit.
- Use `@PreAuthorize` for method-level checks.
- BCrypt for passwords via `PasswordEncoder`.
- Configure CORS explicitly.
- Disable CSRF only for stateless APIs.
- HSTS header on HTTPS.

## DON'T

- `permitAll()` blanket.
- `csrf().disable()` for session-based APIs.
- Allow `*` in CORS with credentials.
- Hardcoded credentials in `SecurityConfig`.
- Skip auth on Actuator endpoints other than `health`/`info`.

## SecurityFilterChain — MVC

```java
@Configuration
@EnableWebSecurity
@EnableMethodSecurity
public class SecurityConfig {

    @Bean
    public SecurityFilterChain api(HttpSecurity http) throws Exception {
        return http
            .csrf(AbstractHttpConfigurer::disable)  // stateless API
            .sessionManagement(s -> s.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
            .authorizeHttpRequests(auth -> auth
                .requestMatchers("/actuator/health", "/actuator/info").permitAll()
                .requestMatchers(HttpMethod.POST, "/auth/login").permitAll()
                .requestMatchers("/api/admin/**").hasRole("ADMIN")
                .anyRequest().authenticated())
            .oauth2ResourceServer(o -> o.jwt(Customizer.withDefaults()))
            .build();
    }

    @Bean
    public PasswordEncoder passwordEncoder() {
        return new BCryptPasswordEncoder();
    }
}
```

## SecurityWebFilterChain — WebFlux

```java
@Configuration
@EnableWebFluxSecurity
@EnableReactiveMethodSecurity
public class SecurityConfig {

    @Bean
    public SecurityWebFilterChain api(ServerHttpSecurity http) {
        return http
            .csrf(ServerHttpSecurity.CsrfSpec::disable)
            .authorizeExchange(ex -> ex
                .pathMatchers("/actuator/health", "/actuator/info").permitAll()
                .pathMatchers("/api/admin/**").hasRole("ADMIN")
                .anyExchange().authenticated())
            .oauth2ResourceServer(o -> o.jwt(Customizer.withDefaults()))
            .build();
    }
}
```

## Method-level auth

```java
@RestController
public class UserController {

    @PreAuthorize("hasRole('ADMIN')")
    @DeleteMapping("/users/{id}")
    public void delete(@PathVariable String id) { ... }

    @PreAuthorize("#userId == authentication.name or hasRole('ADMIN')")
    @GetMapping("/users/{userId}")
    public UserResponse get(@PathVariable String userId) { ... }
}
```

## JWT validation

```java
@Bean
public JwtDecoder jwtDecoder(@Value("${jwt.issuer-uri}") String issuer) {
    return JwtDecoders.fromIssuerLocation(issuer);
}

// Or with explicit keys:
@Bean
public JwtDecoder jwtDecoder(@Value("${jwt.jwks-uri}") String jwksUri) {
    return NimbusJwtDecoder.withJwkSetUri(jwksUri).build();
}
```

## CORS

```java
@Bean
public CorsConfigurationSource corsConfigurationSource() {
    var config = new CorsConfiguration();
    config.setAllowedOrigins(List.of("https://app.example.com"));
    config.setAllowedMethods(List.of("GET","POST","PUT","DELETE"));
    config.setAllowedHeaders(List.of("Authorization","Content-Type"));
    config.setAllowCredentials(true);
    var source = new UrlBasedCorsConfigurationSource();
    source.registerCorsConfiguration("/api/**", config);
    return source;
}

// Wire into SecurityFilterChain:
http.cors(Customizer.withDefaults())  // uses the bean above
```

## Anti-patterns

- `.anyRequest().permitAll()` followed by manual checks in controllers — leaks easily.
- JWT secret as `@Value` from plain `application.properties`.
- Forgotten CSRF on session-based form submission.
- Actuator endpoints exposed (see `actuator.md`).
- `@PreAuthorize` with literal user IDs (`"#userId == 'admin'"`).

## Logging auth events

Log login success/fail, password change, role change, MFA enable/disable:

```java
@EventListener
public void onAuthenticationSuccess(AuthenticationSuccessEvent ev) {
    log.info("auth-success user={}", ev.getAuthentication().getName());
}
```
