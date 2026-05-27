---
name: flyway-migration
description: Flyway migration conventions for PostgreSQL/MySQL — naming, online-safe DDL (CREATE INDEX CONCURRENTLY, expand-contract for renames), idempotency, backfill patterns. Auto-loads when editing `**/db/migration/V*.sql` or `R*.sql`.
---

# Flyway Migrations

## Naming

```
V<version>__<snake_case_description>.sql
```

- `V` (versioned) — runs once, in order.
- `R` (repeatable) — runs whenever checksum changes. Use for views, functions, seed data.
- `<version>` — timestamp (`20250527001`) or semver (`1.2.3`). Strictly monotonic.
- `<snake_case_description>` — short, lowercase, separated by `_`.

Examples:
- `V20250527001__add_users_table.sql`
- `V20250527002__add_user_email_index.sql`
- `R__views_user_summary.sql`

## Quick start

```sql
-- V20250527001__add_tenant_id_to_users.sql
ALTER TABLE users ADD COLUMN tenant_id UUID;
CREATE INDEX CONCURRENTLY idx_users_tenant_id ON users(tenant_id);
```

Detailed: `references/naming-convention.md`, `references/safety-rules.md`, `references/examples.md`.

## Scripts

- `scripts/validate-migration.sh` — runs naming + safety checks (used by claudehut-migration-validator).

## Assets

- `assets/templates/V{semver}__{slug}.sql.tmpl` — migration skeleton.

## Hard rules

- NEVER edit a committed migration. Add a new one to fix.
- ALWAYS `CREATE INDEX CONCURRENTLY` on production-sized tables.
- ALWAYS nullable + backfill + NOT NULL for new non-null columns on large tables.
- USE expand-contract for renames (don't `ALTER COLUMN RENAME` in one go on hot table).
- USE `R__` only for repeatable artifacts (views, functions), NEVER for DDL on tables.

## Exit criteria

- [ ] Filename follows pattern
- [ ] Online safety checked for large tables
- [ ] Backward-compat verified (rolling deploy safe)
- [ ] Rollback plan documented (in commit message or sibling `U__` file)
