package demo.export;

import org.springframework.stereotype.Component;

@Component
public class TcbExporter implements Exporter {
  public byte[] export(String day) {
    return new byte[0];
  }
}
