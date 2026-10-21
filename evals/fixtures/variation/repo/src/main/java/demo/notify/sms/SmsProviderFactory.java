package demo.notify.sms;

import java.util.List;
import java.util.Map;
import java.util.function.Function;
import java.util.stream.Collectors;
import org.springframework.stereotype.Component;

@Component
public class SmsProviderFactory {
  private final Map<String, SmsProvider> byCode;

  public SmsProviderFactory(List<SmsProvider> providers) {
    this.byCode = providers.stream().collect(Collectors.toMap(SmsProvider::code, Function.identity()));
  }

  public SmsProvider get(String code) {
    return byCode.get(code);
  }
}
