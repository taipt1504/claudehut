package demo.cqrs;

import org.springframework.stereotype.Component;

@Component
public class ListOrdersHandler extends RequestHandler<String, String> {
  public String handle(String query) {
    return query;
  }
}
