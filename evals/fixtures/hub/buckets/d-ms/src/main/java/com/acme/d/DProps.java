package com.acme.d;

import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "app")
public class DProps {
  private MerchantPortal merchantPortal;

  public MerchantPortal getMerchantPortal() {
    return merchantPortal;
  }

  public static class MerchantPortal {
    private String url;

    public String getUrl() {
      return url;
    }
  }
}
