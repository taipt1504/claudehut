# Spring MVC Controller Patterns

## Resource controller

```java
@RestController
@RequestMapping(value = "/api/v1/users", produces = MediaType.APPLICATION_JSON_VALUE)
@RequiredArgsConstructor
public class UserController {

    private final UserService userService;

    @PostMapping(consumes = MediaType.APPLICATION_JSON_VALUE)
    @ResponseStatus(HttpStatus.CREATED)
    public UserResponse create(@RequestBody @Valid CreateUserRequest req) {
        return userService.create(req);
    }

    @GetMapping("/{id}")
    public UserResponse get(@PathVariable String id) {
        return userService.get(id);
    }

    @GetMapping
    public PageResponse<UserResponse> list(@RequestParam(defaultValue = "0") int page,
                                            @RequestParam(defaultValue = "20") int size) {
        return userService.list(PageRequest.of(page, size));
    }

    @PutMapping("/{id}")
    public UserResponse update(@PathVariable String id, @RequestBody @Valid UpdateUserRequest req) {
        return userService.update(id, req);
    }

    @DeleteMapping("/{id}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void delete(@PathVariable String id) {
        userService.delete(id);
    }
}
```

## Pagination response

```java
public record PageResponse<T>(
    List<T> items,
    int page,
    int size,
    long totalElements,
    int totalPages,
    boolean hasNext
) {
    public static <T> PageResponse<T> of(Page<T> p) {
        return new PageResponse<>(p.getContent(), p.getNumber(), p.getSize(),
            p.getTotalElements(), p.getTotalPages(), p.hasNext());
    }
}
```

## Async controller

```java
@GetMapping("/{id}/report")
public CompletableFuture<ReportResponse> generateReport(@PathVariable String id) {
    return reportService.generateAsync(id);
}
```

## Streaming response

```java
@GetMapping(value = "/{id}/export", produces = MediaType.TEXT_CSV_VALUE)
public ResponseEntity<StreamingResponseBody> export(@PathVariable String id) {
    StreamingResponseBody body = out -> exportService.streamCsv(id, out);
    return ResponseEntity.ok()
        .header(HttpHeaders.CONTENT_DISPOSITION, "attachment; filename=export.csv")
        .body(body);
}
```

## File upload

```java
@PostMapping(value = "/upload", consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
public UploadResponse upload(@RequestParam MultipartFile file) {
    if (file.isEmpty()) {
        throw new IllegalArgumentException("file required");
    }
    return uploadService.process(file);
}
```

## Cross-origin

Don't use `@CrossOrigin` per-controller. Configure globally:

```java
@Bean
public WebMvcConfigurer corsConfigurer() {
    return new WebMvcConfigurer() {
        @Override
        public void addCorsMappings(CorsRegistry registry) {
            registry.addMapping("/api/**")
                .allowedOrigins("https://app.example.com")
                .allowedMethods("GET","POST","PUT","DELETE")
                .allowCredentials(true);
        }
    };
}
```

## ResponseEntity vs return-type

- Return DTO directly when always 200 (or annotate `@ResponseStatus`).
- Use `ResponseEntity<T>` when status varies (201 vs 200, conditional 304).
- Use `ResponseEntity<Void>` for endpoints that return only status.
