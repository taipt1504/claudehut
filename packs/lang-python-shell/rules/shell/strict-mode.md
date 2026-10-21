---
id: rules/shell/strict-mode
paths:
  - "**/*.sh"
  - "bin/*"
severity: high
tags: [bash, set-u, quoting, exit-codes]
---
<!-- ClaudeHut rule (pack lang-python-shell) — generated into .claude/rules/shell/strict-mode.md by claudehut-init. -->

# Shell scripts: strict mode, quoting, exit codes

- Start with `set -euo pipefail` (or `set -uo pipefail` when the script must survive a failing step and checks `$?`
  itself). Say which in a comment when it is the second.
- Quote every expansion: `"$var"`, `"$@"`, `"${arr[@]}"`. An unquoted path breaks on the first space.
- An array that may be empty under `set -u`: `${arr[@]+"${arr[@]}"}`. bash 3.2 (macOS `/bin/bash`) aborts on a bare
  `"${arr[@]}"` when the array is empty.
- `$(…)` strips trailing newlines and runs in a subshell: a variable set or an `exit` inside it does not reach the
  caller. `cmd | while read` runs the loop in a subshell too; use `while …; done < <(cmd)` when the loop sets state.
- Decide what each exit code means and keep it stable (0 ok, 1 refused/failed check, 2 usage). A caller that
  reads "1" as "refused" must never get 1 from a crash.
- `jq`'s `//` replaces `false` as well as `null`: `.flag // true` is always true. Test with `if .flag == null`.
- Write files atomically: temp file in the same directory, then `mv -f`. Never `>` straight onto a file another
  process reads.
