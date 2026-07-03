# file — summer-file
> Consumer-facing: yes · Auto-config: manual dep · Depends on: none (leaf)

## TL;DR
- Streaming zip exporter: groups rows into entries, caps rows-per-entry + total zip bytes, never buffers the whole file in memory or on disk.
- Plain utility library — no `@AutoConfiguration`, no beans, no gate; all entry points are `static` on `ZipExporter`.
- Consumer owns the workbook format via `ChunkWriter` (e.g. Apache POI, not pulled in) and the row shape via `ExportRow`/`DatedExportRow`.

## Activate
| Aspect | Value |
|---|---|
| Gradle | `implementation 'io.f8a.summer:summer-file'` (add manually) |
| Auto-config | none — no `*AutoConfiguration`, no beans registered |
| Gate | none — static utility; call `ZipExporter` directly |
| Reactor | `Flux` is `compileOnly` in `file/build.gradle`; the `Flux` overloads resolve only if the consumer already has reactor on its classpath (WebFlux services do) |

Note: the `ChunkWriter` you implement typically needs a workbook library (e.g. Apache POI `SXSSFWorkbook`) — this module does NOT provide one.

## Config keys
None — types/utilities only.

## Public API
| Type | Path · node | When to use |
|---|---|---|
| `ZipExporter` (static) | `file/src/main/java/io/f8a/summer/file/export/ZipExporter.java` · `class:file/src/main/java/io/f8a/summer/file/export/ZipExporter.java:ZipExporter` | Call to produce the zip. `writeZip(rows,out,spec)` blocks into any `OutputStream`; `pipeZip(rows,spec,executor)` returns a `PipedInputStream` immediately for stream→upload |
| `ExportSpec<R>` (`@Value @Builder`) | `.../ExportSpec.java` · `class:.../ExportSpec.java:ExportSpec` | Per-export config: `baseName`, `fileExtension` (default `.xlsx`), `maxRowsPerFile` (default 100_000), `maxZipSizeBytes` (default 0 = no cap), `chunkWriter` |
| `ChunkWriter<R>` (`@FunctionalInterface`) | `.../ChunkWriter.java` · `class:.../ChunkWriter.java:ChunkWriter` | Implement to write one chunk as a complete workbook: `void writeChunk(List<R> rows, OutputStream out)`. Called once per emitted zip entry |
| `ExportRow` | `.../ExportRow.java` · `class:.../ExportRow.java:ExportRow` | Marker every row type implements; exporter streams these flat |
| `DatedExportRow extends ExportRow` | `.../DatedExportRow.java` · `class:.../DatedExportRow.java:DatedExportRow` | Implement (`LocalDate date()`) when rows should be grouped into one entry-group per date |
| `SizeLimitedOutputStream` | `.../SizeLimitedOutputStream.java` · `class:.../SizeLimitedOutputStream.java:SizeLimitedOutputStream` | Internal; `ZipExporter` wraps output in it when `maxZipSizeBytes > 0`. Usable standalone but you rarely call it directly |

### ZipExporter methods (real signatures)
```java
static <R extends ExportRow> void writeZip(Iterable<R> rows, OutputStream out, ExportSpec<R> spec) throws IOException
static <R extends ExportRow> void writeZip(Flux<R> rows, OutputStream out, ExportSpec<R> spec) throws IOException
static <R extends ExportRow> PipedInputStream pipeZip(Iterable<R> rows, ExportSpec<R> spec, Executor executor) throws IOException
static <R extends ExportRow> PipedInputStream pipeZip(Flux<R> rows, ExportSpec<R> spec, Executor executor) throws IOException
```

## Usage
```java
// 1. row type — DatedExportRow groups by date()
record TransactionRow(LocalDate date, String id, BigDecimal amount) implements DatedExportRow {}

// 2. chunk writer — MUST NOT close `out` (ZipExporter owns the zip-entry lifecycle)
ChunkWriter<TransactionRow> writer = (rows, out) -> {
  try (var wb = new SXSSFWorkbook()) {   // Apache POI, consumer-provided
    wb.createSheet();                      // header row + one sheet row per element
    wb.write(out);                         // no out.close()
  }
};

// 3. spec (baseName used only for non-dated rows; maxZipSizeBytes 0 = no cap)
ExportSpec<TransactionRow> spec = ExportSpec.<TransactionRow>builder()
    .baseName("transactions").fileExtension(".xlsx")   // extension: include leading dot
    .maxRowsPerFile(100_000).maxZipSizeBytes(50L * 1024 * 1024)
    .chunkWriter(writer).build();

// 4. reactive stream -> upload, no temp file (executor MUST tolerate blocking):
PipedInputStream in = ZipExporter.pipeZip(txFlux, spec, r -> Schedulers.boundedElastic().schedule(r));
objectStorage.put(key, in);
```

## Gotchas
- `DatedExportRow` rows MUST arrive contiguous/sorted by `date()`; grouping flushes on date change, so unsorted input splits one date into multiple non-adjacent groups. Sort before exporting.
- Entry names: dated → `<yyyy-MM-dd>_<seq><ext>`; flat → `<baseName>_<seq><ext>`. `baseName` is ignored for dated rows.
- `writeChunk` must NOT close `out` — `ZipExporter` opens/closes each zip entry.
- Empty input still emits exactly one entry (calls `writeChunk` with an empty list) so the zip always has ≥1 workbook — your writer must handle an empty row list (typically header-only).
- `writeZip` throws `IllegalArgumentException` if `maxRowsPerFile <= 0`, `chunkWriter == null`, or `fileExtension` null/empty.
- `maxZipSizeBytes > 0` wraps output in `SizeLimitedOutputStream`; overflow aborts mid-stream with `IOException` — a partial zip is already written to the sink, the consumer must discard it. `new SizeLimitedOutputStream(out, maxBytes<=0)` itself throws `IllegalArgumentException`.
- Blocking: `writeZip`/`pipeZip` iterate rows on the running thread and POI serialization is synchronous. The `Flux` overloads call `Flux#toIterable()` (256 prefetch) — never run on the Netty event loop; use `Schedulers.boundedElastic()`.
- `pipeZip` on writer failure closes the `PipedInputStream`, so a blocked reader unblocks with `"Pipe closed"` `IOException` and the upload sees the failure.

## Graph refs
- `file:file/src/main/java/io/f8a/summer/file/export/ZipExporter.java`
- `file:file/src/main/java/io/f8a/summer/file/export/ExportSpec.java`
- `file:file/src/main/java/io/f8a/summer/file/export/ChunkWriter.java`
- `file:file/src/main/java/io/f8a/summer/file/export/ExportRow.java`
- `file:file/src/main/java/io/f8a/summer/file/export/DatedExportRow.java`
- `file:file/src/main/java/io/f8a/summer/file/export/SizeLimitedOutputStream.java`
- `file:file/build.gradle`
