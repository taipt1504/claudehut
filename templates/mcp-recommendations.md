<!-- ClaudeHut MCP recommendation catalog. Read by claudehut-init to SUGGEST (never auto-install) MCP servers per detected stack. ClaudeHut ships NO active .mcp.json — MCP is opt-in per project. See docs/design/08-mcp-integration.md. -->

# MCP recommendation catalog

ClaudeHut does **not** bundle or auto-connect any MCP server. Instead, `claudehut-init` detects the project's
stack and **suggests** the servers below — the developer runs the `claude mcp add` commands they want.
Project-scoped servers land in the project's own `.mcp.json` (created by `claude mcp add --scope project`, not
shipped by the plugin) and require per-server approval before use. The Review auditors **degrade gracefully**
when a server is absent (they review statically) — nothing here is required for the workflow to run.

How init uses this file: for each **tech-stack** row whose `detect-when` matches a detected dependency, emit
its command; always offer the **research** row. Present them as a copy-pasteable block under
"Recommended MCP servers for this project (optional)". Replace `<…>` placeholders and never print real
secrets — tell the user to substitute their own connection string / token at run time.

## Bucket 1 — tech-stack (emit per detected dependency)

| Server | detect-when | Phase value | `claude mcp add` command (project scope) |
|--------|-------------|-------------|------------------------------------------|
| postgres | `org.postgresql` / `r2dbc-postgresql` / Postgres in compose | Brainstorm, Review — live schema + `EXPLAIN` for db/perf reviewers | `claude mcp add --scope project -e DATABASE_URI="<POSTGRES_URL>" postgres -- uvx postgres-mcp --access-mode=restricted` |
| mysql | `mysql-connector` / `r2dbc-mysql` / MySQL in compose | Brainstorm, Review — schema + `EXPLAIN` | `claude mcp add --scope project mysql -- npx -y mcp-server-mysql --url "<MYSQL_URL>"` |
| kafka | `spring-kafka` / `kafka-clients` | Implement, Review — topics, consumer groups, lag | two steps, see note below |
| github | git remote on github.com | Plan, Review, Learn — PR/issue context | `claude mcp add --scope project --transport http github https://api.githubcopilot.com/mcp/readonly --header "Authorization: Bearer <GITHUB_TOKEN>" --header "X-MCP-Toolsets: issues,pull_requests"` |

> **MCP-PIN — every row above is toolset-pinned, and the github row was the exception.** postgres pins
> `--access-mode=restricted` and kafka pins `--allow-tools`; github was added unpinned at the default
> endpoint, which serves the full toolset including `create_pull_request`, `merge_pull_request`,
> `push_files`, `create_or_update_file` and `delete_file`. The row's own stated value is "PR/issue
> context" — reading. It now uses the documented read-only endpoint
> (`https://api.githubcopilot.com/mcp/readonly`) and narrows the surface with
> `X-MCP-Toolsets: issues,pull_requests`, both verified against
> github/github-mcp-server `docs/remote-server.md`. An unpinned server is not a smaller version of a
> pinned one: it hands a reviewer agent the ability to merge.

> RabbitMQ / NATS: no mature public MCP at time of writing — add by the same pattern when one ships.

## Bucket 2 — research (offer to any project)

| Server | Purpose | `claude mcp add` command (user scope) |
|--------|---------|---------------------------------------|
| context7 | Up-to-date library/framework docs (Spring, Hibernate, Reactor, …) for the brainstormer's best-practice axis. | `claude mcp add --scope user --transport http context7 https://mcp.context7.com/mcp` |

> Manage/inspect installed servers with `/mcp`; remove with `claude mcp remove <name>`.

### Notes on two of the rows

**postgres — `--access-mode=restricted` is not optional.** The flag's default is `unrestricted`, so omitting it
gives a "read-only" reviewer full write access to the database it was pointed at. `restricted` keeps every
tool but runs `execute_sql` in a read-only transaction with an execution-time bound.
(`@modelcontextprotocol/server-postgres`, recommended here previously, is deprecated on npm.)

**kafka — needs a config file, so it is two steps.** There is no environment-variable path for the bootstrap
servers:

```sh
npx @confluentinc/mcp-confluent --init-config          # writes ./config.yaml, then edit it
claude mcp add --scope project kafka -- npx -y @confluentinc/mcp-confluent --config ./config.yaml \
  --allow-tools list-topics,list-consumer-groups,describe-consumer-group,get-consumer-group-lag,consume-messages
```

Keep the server named `kafka`; renaming it changes every `mcp__kafka__*` name the reviewers declare.
`--allow-tools` is a flag of the **server**, not of `claude mcp add` (which has no tool filter), so it goes
after the `--`. The pin matters: unfiltered, this server also exposes `create-topics`, `delete-topics` and
`produce-message`, which a read-only reviewer has no business holding. `consume-messages` is safe to allow —
it generates a random consumer group per call and never commits, so it cannot move an application's offsets.
