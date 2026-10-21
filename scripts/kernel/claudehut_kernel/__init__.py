"""ClaudeHut kernel (0.20 design, docs/v0.20/04-kernel-control.md).

Python 3 stdlib only. Strangler migration (ADR K-11): modules here replace bash logic one verb at a time,
behind the same CLI contract. The first modules are the gate engine (K2), the event log (K1) and
claudehut-verify (K7).
"""
__version__ = "0.12.7"
