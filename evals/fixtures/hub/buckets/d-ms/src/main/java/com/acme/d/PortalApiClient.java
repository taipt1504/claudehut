package com.acme.d;

import java.util.HashMap;
import java.util.Map;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;
import org.springframework.web.reactive.function.client.WebClient;

/** Real clients: portal-named base URLs that build WebClients (one with no address anywhere: it stays unresolved,
 * never a "UI link"), and a help URL used in an email AND as a client. */
@Component
public class PortalApiClient {
  @Value("${clients.partner-portal.base-url}")
  private String portalUrl;

  @Value("${clients.portal-gateway.base-url}")
  private String gatewayUrl;

  @Value("${app.help-url}")
  private String helpUrl;

  public WebClient portal() {
    return WebClient.builder().baseUrl(portalUrl).build();
  }

  public WebClient gateway() {
    return WebClient.builder().baseUrl(gatewayUrl).build();
  }

  public Map<String, String> helpModel() {
    Map<String, String> data = new HashMap<>();
    data.put("helpUrl", helpUrl);
    return data;
  }

  public RestClient help() {
    return RestClient.create(helpUrl);
  }
}
