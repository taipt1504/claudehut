---
id: rules/framework/flyway-naming
paths:
  - "**/db/migration/R*.sql"
  - "**/db/migration/V*.sql"
severity: high
tags: [flyway, migration, naming]
---


# Flyway Migration Naming

## Pattern

```
V<version>__<snake_case_description>.sql      # versioned, runs once in order
R__<snake_case_description>.sql                # repeatable, runs when checksum changes
```

## Versioned migrations (V)

- `V20250527001__add_users_table.sql`
- `V20250527002__add_user_email_index.sql`
- `V1_2_3__add_orders_table.sql`

Version formats accepted by Flyway:
- Timestamp: `20250527001` (YYYY-MM-DD + sequence)
- Semver: `1_2_3`

Choose ONE format per project. Timestamps prevent merge conflicts between branches.

## Repeatable migrations (R)

- `R__views_user_summary.sql` — view definition
- `R__functions_audit_trigger.sql` — function

Re-run when content checksum changes. Use for:
- Views, materialized views.
- Functions, stored procedures.
- Seed data (idempotent).

**NEVER** for DDL on tables — that's `V`.

## Rules

| Rule | Example |
|------|---------|
| Two underscores between version and description | `V20250527001__add_users_table.sql` |
| Description: lowercase, snake_case | `add_users_table`, not `addUsersTable` |
| Description: verb-noun or noun-action | `add_X_index`, `rename_X_column`, `backfill_X_data` |
| Strictly monotonic version | No `V001` then `V0005` then `V003` |
| No duplicates | `V20250527001` must be unique |
| `.sql` extension | not `.SQL`, not `.psql` |

## Out-of-order migrations

Default Flyway rejects out-of-order. Enable explicitly if cherry-picking:

```yaml
spring:
  flyway:
    out-of-order: true
```

Use with caution — can mask conflicts.

## Branch coordination

When multiple branches add migrations:
- Use timestamp version format → no conflicts.
- Reserve version numbers in shared doc if using sequence format.

## Examples

```
src/main/resources/db/migration/
├── V20250527001__add_users_table.sql
├── V20250527002__add_users_email_index.sql
├── V20250527003__add_orders_table.sql
├── V20250528001__add_tenant_id_to_users.sql
└── R__views_user_summary.sql
```

## Detection

Phase 5 + PreToolUse hook run `scripts/validate-migration.sh`:

- Naming pattern.
- Online safety.
- `R__` not containing table DDL.

## References

- See `claudehut:flyway-migration` skill.
- `rules/framework/migration-safety.md` for content rules.
