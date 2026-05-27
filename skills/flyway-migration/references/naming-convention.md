# Flyway Naming Convention

## Format

```
V<version>__<snake_case_description>.sql      # versioned, runs once
R__<snake_case_description>.sql                # repeatable, runs on checksum change
U<version>__<snake_case_description>.sql       # undo (Flyway Teams only)
```

Note the **two underscores** between version and description.

## Version formats

Pick ONE per project. Don't mix.

### Timestamp (recommended for branches)

```
V20250527001__add_users_table.sql
V20250527002__add_users_email_index.sql
V20250528001__add_tenant_id.sql
```

Format: `YYYYMMDD<seq>` where `<seq>` is 3-digit per-day counter.

Pros: parallel branches don't conflict (different days/sequences).
Cons: long filenames.

### Semver (recommended for releases)

```
V1_0_0__init_schema.sql
V1_1_0__add_users.sql
V1_2_3__hotfix_user_index.sql
```

Format: `<major>_<minor>_<patch>`.

Pros: maps to release versions.
Cons: branches can collide (reserve numbers in shared doc).

## Description rules

- Lowercase only.
- Words separated by single underscore.
- Verb-noun (`add_users_table`) or noun-action (`users_index_add`).
- ≤ 60 chars total filename.

## Bad examples

| File | Why bad |
|------|---------|
| `V1__add users.sql` | spaces |
| `V1_add_users.sql` | single underscore (need two) |
| `V1__AddUsers.sql` | camelCase |
| `v1__add_users.sql` | lowercase V |
| `V01__add_users.sql` then `V001__more.sql` | inconsistent zero-padding |
| `R__users.sql` with `CREATE TABLE` | R for DDL on tables |
| `V1__add_users.SQL` | uppercase extension |

## Strict monotonicity

Flyway by default rejects out-of-order migrations:

```
V1 then V3 then V2  ← rejected (V2 < V3 already applied)
```

If using timestamps + branch merges, enable:

```yaml
spring:
  flyway:
    out-of-order: true
```

Trade-off: may mask actual ordering bugs.

## Branch coordination

When multiple branches add migrations:

- **Timestamps**: rarely conflict (different times)
- **Semver**: reserve numbers in `MIGRATIONS.md`

Validate at PR time:

```bash
ls src/main/resources/db/migration/ | sort | uniq -d  # find duplicates
```
