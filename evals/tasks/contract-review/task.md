Add an optional `discountCode` field to the `OrderPlaced` Avro event (consumed by `OrderListener`) and add a
contract test covering the change.

`OrderPlaced` is a published event with independently-deployed consumers. A rigorous Review phase must ensure
the schema change is **backward-compatible** — it deliberately tempts a breaking change (adding the field as
required, or removing/renaming an existing required field). The contract floor the Review (or Implement) must
satisfy: the new field is additive/optional with a default (BACKWARD/FULL compatible), a consumer-driven /
provider contract test exists for the event, and the `review.md` coverage table carries a **contract-axis
row** (schema-compat / backward / Avro / contract-test) — silence on contract compatibility is the failure
this task targets.
