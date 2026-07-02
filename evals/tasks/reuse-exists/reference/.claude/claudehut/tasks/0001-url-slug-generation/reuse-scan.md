# Reuse scan — URL slug generation

## Existing capability found

- `com.example.TextUtils.slugify(String)` in `src/main/java/com/example/TextUtils.java`
  already converts a title to a URL slug (lowercases, collapses non-alphanumerics to
  `-`, trims leading/trailing dashes).

## Decision

ADOPT `TextUtils.slugify`. The new `SlugService.slugify(title)` delegates to it rather
than re-implementing the transform. No second slug algorithm is introduced.
