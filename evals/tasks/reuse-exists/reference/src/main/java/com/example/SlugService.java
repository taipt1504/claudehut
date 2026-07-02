package com.example;

/**
 * URL-slug generation for article titles.
 * Adopts the existing TextUtils.slugify — thin delegating wrapper, no re-implementation.
 */
public final class SlugService {
  /** Turn an article title into a URL slug by delegating to the shared TextUtils. */
  public String slugify(String title) {
    return TextUtils.slugify(title);
  }
}
