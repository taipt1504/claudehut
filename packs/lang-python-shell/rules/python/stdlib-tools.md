---
id: rules/python/stdlib-tools
paths:
  - "**/*.py"
severity: medium
tags: [python, stdlib, cli, subprocess]
---
<!-- ClaudeHut rule (pack lang-python-shell) — generated into .claude/rules/python/stdlib-tools.md by claudehut-init. -->

# Python tooling scripts

- Keep a tool on the standard library unless a dependency is declared and installed by the project; state the
  minimum version and stay within its syntax (e.g. no `match` or `X | Y` types below 3.10).
- A tool shipped inside another tree must not write `__pycache__` there: `sys.dont_write_bytecode = True` before
  local imports, or run it with `python3 -B`.
- `subprocess.run([...])` with an argument list, never `shell=True` on input you did not write; pass `timeout=`
  for anything that can hang.
- Map failures to exit codes on purpose: catch at the entry point and exit with a code the caller documents (a
  crash must not look like a "refused" or "found problems" result).
- Read JSON defensively (`OSError`, `ValueError`) and write it atomically (temp file + `os.replace`).
- Do not use `x or default` for a value where `""`, `0` or `[]` is meaningful: test `is None`.
