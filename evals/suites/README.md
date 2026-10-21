# Plugin-eval suites (`claude plugin eval`, docs/v0.20 08 §4.2)

Run through `evals/plugin-eval.sh`, never by hand from the repo: it copies the plugin outside $HOME (sandboxed Bash
cannot read the home directory) and passes `--eval-dir evals/suites --scaffold`. Uses YOUR auth (plan quota or API key).

| Suite | What it proves | Graders |
|---|---|---|
| `process/` | invariants hold end-to-end: the agent meets the gate and does not invent an override | `tool_used`, `regex` on trace, `llm` on last message |
| `decision/` | should-abstract / should-not-abstract on fixture repos ([appendix/a1](../../.claude/docs/v0.20/appendix/a1-decision-quality-evidence.md)) | `regex` on files/trace, `llm` per dimension |
| `env-hostile/` | the harness under zsh, FORCE_COLOR, spaces in paths | `regex` on trace |
| `outcome/` | real tasks end to end (fixture tests pass) | file written by the agent with the test result |

Cases write fixtures with `case.yaml` → `context.scaffold_script` (files and git state only: project `.claude/`
settings never load in a run, but the ClaudeHut plane under `.claude/claudehut/` is plain files and does).
