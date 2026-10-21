# env-hostile

Covered by deterministic suites, not by `claude plugin eval`: an eval run withholds most of the shell env
(FORCE_COLOR, zsh, user hooks) by design. See `evals/regress/verify-tests.sh` (path with a space, rtk-style
rewriting hook H1–H7, python3 missing G18) and `claudehut-kernel selftest` (real runtime canaries).
