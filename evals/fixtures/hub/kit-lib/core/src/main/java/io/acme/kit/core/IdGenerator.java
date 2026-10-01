package io.acme.kit.core;

/** SPI: a service may supply its own id scheme. */
public interface IdGenerator {
  String next();
}
