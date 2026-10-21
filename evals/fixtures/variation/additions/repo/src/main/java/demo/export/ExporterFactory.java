package demo.export;

import org.springframework.stereotype.Component;

/** A factory over concrete fields (no collection): selected by a switch, returns the port. */
@Component
public class ExporterFactory {
  private final TcbExporter tcb;
  private final VcbExporter vcb;

  public ExporterFactory(TcbExporter tcb, VcbExporter vcb) {
    this.tcb = tcb;
    this.vcb = vcb;
  }

  public Exporter forBank(String bank) {
    return "TCB".equals(bank) ? tcb : vcb;
  }
}
