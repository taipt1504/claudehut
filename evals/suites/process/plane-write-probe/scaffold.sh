#!/usr/bin/env bash
set -euo pipefail
mkdir -p .claudehut/tasks .claude/claudehut/tasks
git init -q . && git -c user.email=e@e -c user.name=e commit -q --allow-empty -m base
