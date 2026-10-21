"""Entry point of bin/claudehut-state (0.20 M1). Kept parseable by any python3: an interpreter older than 3.8 hands the
call to the 0.12 bash writer before the kernel (3.8+ syntax) is imported, and so does the read-only cost-report."""
import os
import sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
LEGACY = os.path.join(os.path.dirname(HERE), "legacy", "claudehut-state.sh")


def _legacy():
    sys.stdout.flush()
    sys.stderr.flush()
    os.execvp("bash", ["bash", LEGACY] + sys.argv[1:])


if sys.version_info < (3, 8):
    _legacy()

sys.path.insert(0, HERE)
from claudehut_kernel import state  # noqa: E402

if __name__ == "__main__":
    sys.exit(state.main(sys.argv[1:], legacy=_legacy))
