# ClaudeHut — session digest

ClaudeHut plans and reviews Java/Spring changes. Route every new request yourself by intent and semantic risk, not file count; no hook blocks you.

## Routes
| Route | When | What runs |
|---|---|---|
| `direct` | No file change (question, explaining, RCA, audit), or a one-sentence diff in one module with no risk signal | Answer, or edit + related tests. No task |
| `light` | Clear intent, one obvious approach, new tests or several files in one service | `start --route light`; `task.md` (Approach, Tasks), test-first, one reviewer |
| `full` | Unclear intent, 2+ materially different approaches, or an API/Kafka contract, schema/migration, authn/authz or cross-service change | `start --route full`; `claudehut:discover`, brainstorm (optional), write-spec, write-plan, implement, review, capture-learnings |

## Ask, escalate, override
- Two adjacent routes fit with very different effort: one AskUserQuestion, 2-3 options, your pick first with a reason.
- Hidden complexity: escalate yourself (`start`/`set-route`), tell the user in one line. Lowering: ask first.
- "skip workflow"/"làm nhanh": `direct`, no `start` or confirmation; an open task gets `end --status abandoned`. "làm đủ quy trình": `full`. Overrides cover the current request only.

## Tools
Any plugin's skills, agents, MCP tools may fit. Look up code: `claudehut-index brief`/`find` (CLI path: Index line), then `.understand-anything/knowledge-graph.json` (jq), then targeted Grep/Glob.
Another service: `svc <name>`/`links --service <name>` before reading its repo. A task spanning services: `start --repo <a> --repo <b>`.
Skill call with no body: Read `skills/<name>/SKILL.md` under the plugin root.
Dispatch agents as `claudehut:claudehut-<name>` without `name` (a teammate only if asked); independent ones in one message, copy the language line verbatim into each prompt. Subagents never ask the user or write state.

## State CLI
`--session` defaults to `$CLAUDEHUT_SESSION_ID`, else the Session id below.
- `start --route light|full --slug <s> [--profile feature|bugfix|audit|investigation|migration]` prints the task dir for every task artifact.
- Task open for this request: continue it; another session's task: `resume <id>`.
- `set-phase <p>`, `set-route light|full`, `status`, `end --status done|abandoned`.
- A new request, or a profile change after it finished: `start --profile <new>`.
