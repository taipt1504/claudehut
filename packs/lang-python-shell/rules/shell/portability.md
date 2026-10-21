---
id: rules/shell/portability
paths:
  - "**/*.sh"
  - "bin/*"
severity: medium
tags: [bsd, gnu, macos, linux, portability]
---
<!-- ClaudeHut rule (pack lang-python-shell) — generated into .claude/rules/shell/portability.md by claudehut-init. -->

# Shell portability (macOS BSD userland and Linux GNU)

| Need | Portable form | Not portable |
|---|---|---|
| in-place edit | write a temp file and `mv` | `sed -i` (BSD needs `-i ''`, GNU rejects it) |
| file mtime | `stat -c %Y f 2>/dev/null \|\| stat -f %m f` (GNU first: `stat -f` on Linux is a file-system report) | one of them alone |
| date parsing | do it in `jq` (`strptime`/`mktime`) or Python | `date -d` (GNU) / `date -j -f` (BSD) |
| lock | `flock` when present, else an atomic `mkdir` lock with a stale breaker | `flock` alone (absent on macOS) |
| regex | `grep -E` with POSIX classes (`[[:space:]]`) | `grep -P`, `\s` in `sed` |

- Target bash 3.2 when the script runs on a developer Mac: no associative arrays, no `${var,,}`, no `mapfile`.
- Paths with spaces and non-ASCII names: `git -c core.quotePath=false … -z` and `read -r -d ''`.
