package com.acme.d;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

/** Reads the compliance URL (no deployed value, no counterpart) and the portal login link it hands to users. */
@Component
public class ComplianceClient {
  @Value("${clients.compliance.url}")
  private String url;

  @Value("${clients.merchant-portal.login-url}")
  private String loginUrl;
}
