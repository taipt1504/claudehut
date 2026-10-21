package demo.export;

import org.springframework.stereotype.Component;

@Component
public class VcbBankExporter extends AbstractBankExporter {
  public String bank() {
    return "VCB";
  }

  public byte[] export(java.util.List<String> rows) {
    return new byte[0];
  }
}
