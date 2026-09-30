# ClaudeHut — session digest

ClaudeHut plans and reviews Java/Spring changes. Route every new request yourself; no hook blocks you.

## Routes
| Route | When | What runs |
|---|---|---|
| `direct` | No file change (question, explanation, RCA, audit), or a one-sentence diff in one module with no risk signal | Answer, or edit and run the related tests. No task |
| `light` | Clear intent, one obvious approach, needs new tests or several files in one service | `start --route light`; `task.md` (Approach, Tasks), test-first, one reviewer |
| `full` | Unclear intent, 2+ materially different approaches, or an API/Kafka contract, schema/migration, authn/authz or cross-service change | `start --route full`; skills `claudehut:discover`, brainstorm, write-spec, write-plan, implement, review, capture-learnings |

Judge by intent and semantic risk, not file count.

## Ask, escalate, override
- Two adjacent routes both fit and differ a lot in effort: one AskUserQuestion, 2-3 options, your pick first with a one-line reason.
- Hidden complexity: escalate yourself (`start` or `set-route`) and tell the user in one line. Lowering a route: ask first.
- "skip workflow" or "làm nhanh": `direct` for this request, no `start`, no bypass or confirmation; an open task gets `end --status abandoned`. "làm đủ quy trình": `full`. An override covers the current request only.

## Tools
Use any plugin's skills, agents and MCP tools whose description fits. Look up code in this order: project index or hub, then `.understand-anything/knowledge-graph.json` (Read or jq), then targeted Grep/Glob.
If a skill call returns no body, Read `skills/<name>/SKILL.md` under the plugin root.
Dispatch ClaudeHut agents by `subagent_type` `claudehut:claudehut-<name>` without `name`, unless the user wants a teammate. Independent dispatches go in one message. Subagents cannot ask the user or write state; the main thread does both.

## State CLI
`--session` defaults to `$CLAUDEHUT_SESSION_ID`; if empty, pass the Session id below.
- `start --route light|full --slug <s> [--profile feature|bugfix|audit|investigation|migration]` prints the task dir; every artifact of the task goes there.
- Task already open for this request: continue it. Another session's task: `resume <id>`.
- `set-phase <p>`, `set-route light|full`, `status`, `end --status done|abandoned`.
- A new request, or a profile change after it finished: `start --profile <new>`.
