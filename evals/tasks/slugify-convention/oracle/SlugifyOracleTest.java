package com.example;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.assertEquals;

// HELD-OUT oracle. Pins the project's ARBITRARY slug convention: spaces become a
// DOUBLE underscore "__" (not the standard "-", not a single "_"), lowercased.
// A base model that hasn't retrieved the convention defaults to "-" and fails
// every case; only the seeded learning reveals "__".
class SlugifyOracleTest {
    @Test void spacesBecomeDoubleUnderscore() { assertEquals("hello__world",   TextUtils.slugify("Hello World")); }
    @Test void multipleWords()                { assertEquals("foo__bar__baz",  TextUtils.slugify("Foo Bar Baz")); }
    @Test void lowercasesAndKeepsAlnum()      { assertEquals("api__v2",        TextUtils.slugify("API v2")); }
}
