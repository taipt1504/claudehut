package demo.export;

import org.springframework.stereotype.Component;

@Component
public class TcbBankExporter extends AbstractBankExporter {
  public String bank() {
    return "TCB";
  }

  public byte[] export(java.util.List<String> rows) {
    return new byte[0];
  }
}
