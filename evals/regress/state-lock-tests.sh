#!/usr/bin/env bash
# state-lock-tests.sh — the Python state writer's plane lock (claudehut_kernel/state.py), pinned in-process: the
# interleavings hook-tests builds for the bash writer with a PATH stub of mkdir (R3-C1, 0128b37), which cannot
# reach an os.mkdir syscall. Prints "STATE-LOCK: N passed, M failed"; exit 1 on failure.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "STATE-LOCK: 0 passed, 0 failed (no python3)"; exit 0; }
python3 -B - "$ROOT/scripts/kernel" <<'PY'
import os, sys, tempfile, time
sys.path.insert(0, sys.argv[1])
from claudehut_kernel import state as st

passed = failed = 0
def check(name, cond):
    global passed, failed
    if cond: passed += 1; print("ok - " + name)
    else: failed += 1; print("FAIL - " + name)

def mk():
    s = st.State(["status"], legacy=None)
    s.state_dir = tempfile.mkdtemp()
    return s, os.path.join(s.state_dir, ".state.lock")

real_mkdir = os.mkdir

# 1. A holder releases INSIDE the failed-mkdir window: the first mkdir fails (the dir exists), the holder is gone
#    before the writer looks. That is the benign race, not an unwritable filesystem: the retry must TAKE the lock.
s, lock = mk(); real_mkdir(lock); calls = []
def racing(p, *a):
    if p == lock and not calls:
        calls.append(1); os.rmdir(lock); raise FileExistsError(p)
    return real_mkdir(p, *a)
os.mkdir = racing
try:
    t0 = time.time(); s.acquire_lock()
finally:
    os.mkdir = real_mkdir
check("R3-C1: a holder released inside the failed-mkdir window → the writer takes the lock", s._lock_mkdir == lock and os.path.isdir(lock))
check("R3-C1: … at once (no wait toward the 10 s cap)", time.time() - t0 < 1)
s.release_lock()
check("release removes the mkdir lock and keeps the flock file", not os.path.exists(lock) and os.path.exists(lock + ".flock"))

# 2. A plain FILE at the lock path is never a lock: cleared once, then the lock is taken.
s, lock = mk(); open(lock, "w").close()
s.acquire_lock()
check("a plain file at the lock path is cleared and the lock taken", s._lock_mkdir == lock and os.path.isdir(lock))
s.release_lock()

# 3. A mkdir that can never succeed (read-only fs) fails OPEN promptly, never stalls.
s, lock = mk()
def hard(p, *a):
    if p == lock: raise PermissionError(p)
    return real_mkdir(p, *a)
os.mkdir = hard
try:
    t0 = time.time(); s.acquire_lock()
finally:
    os.mkdir = real_mkdir
check("an unwritable lock path fails open within a second (no lock held)", s._lock_mkdir is None and time.time() - t0 < 1)
s.release_lock()

# 4. A stale lock (mtime ≥30 s, a crashed writer) is stolen; a fresh one is not (waited for instead).
s, lock = mk(); real_mkdir(lock); os.utime(lock, (time.time() - 100, time.time() - 100))
s.acquire_lock()
check("a stale lock dir (100 s old) is stolen at once", s._lock_mkdir == lock)
s.release_lock()

print("STATE-LOCK: %d passed, %d failed" % (passed, failed))
sys.exit(1 if failed else 0)
PY
