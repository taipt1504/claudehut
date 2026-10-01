plugins {
  java
  id("org.springframework.boot") version "3.3.0"
}

val kitKafkaVersion: String by project

dependencies {
  implementation(platform(libs.kit.platform))
  implementation(libs.kit.rest.autoconfigure)
  implementation("io.acme.kit:kit-kafka:${kitKafkaVersion}")
  implementation(group = "io.acme.kit", name = "kit-core", version = "1.4.0")
}
