package demo.export;

public abstract class AbstractBankExporter {
  public abstract String bank();

  public abstract byte[] export(java.util.List<String> rows);
}
