package com.example;
/** Existing shared text utility — reuse this; do not duplicate. */
public final class TextUtils {
  private TextUtils() {}
  /** Convert a title to a URL slug. */
  public static String slugify(String input) {
    return input.toLowerCase().replaceAll("[^a-z0-9]+", "-").replaceAll("(^-|-$)", "");
  }
}
