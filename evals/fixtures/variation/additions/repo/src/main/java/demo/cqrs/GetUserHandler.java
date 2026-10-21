package demo.cqrs;

import org.springframework.stereotype.Component;

@Component
public class GetUserHandler extends RequestHandler<String, String> {
  public String handle(String query) {
    return query;
  }
}
