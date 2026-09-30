Replay fixtures for evals/hook-tests.sh (AC15, 10-rollout-eval.md M1). Built from two real ewallet-workspace
transcripts; only the hook-input fields a hook reads are kept (session_id, cwd, hook_event_name, tool_name,
tool_input.file_path). No old_string/new_string, no transcript text. __PROJECT__ is replaced by the fixture
project dir at test time; the report-service scratchpad path is kept verbatim because it is outside the repo.

core-ledger-2e70d1d8.edit.json      PreToolUse Edit that v0.11 gate-write.sh denied:
                                    "complexity=small fast lane denied — touches 343 files (fast-lane cap 2)"
                                    (transcript line 3428 and again at 4402).
core-ledger-2e70d1d8.state.json     the v0.11 state shape of that session at the deny (no schema:2).
report-service-652fab55.scratchpad.json / .ua.json
                                    PreToolUse Write calls v0.11 denied with "run claudehut:discover first"
                                    in a session that was not doing workflow work (transcript lines 207, 1630).
report-service-652fab55.state.json  the armed-at-discover v0.11 state bootstrap.sh created for that session.
v011-gate-write.sh.txt              scripts/gate-write.sh verbatim from 2c0b93b (the last v0.11 commit), kept
                                    NON-executable as the replay oracle: hook-tests.sh runs it once per replay to
                                    prove each fixture still reproduces the v0.11 deny.
