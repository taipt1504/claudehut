"""T3 design tournament, deterministic part (docs/v0.20 appendix a2 §4.4; M6c). Pack `deliberation` owns the workflow.

Each option is sketched; a judge (a different model from the one that sketched) compares every pair TWICE, once in
each order (A-vs-B, then B-vs-A). A pair's verdict counts only when both orders name the same option (or both say
tie): a judge that prefers whatever it reads first disagrees with itself and the pair gets no verdict.

Input (tournament.json):
  {"options": [{"id": "O0", "title": "..."}, ...],
   "judgments": [{"first": "O0", "second": "O1", "winner": "first|second|tie", "reason": "..."}, ...]}
Output: per pair `agreed` / `split` / `missing`, the Condorcet winner over agreed pairs (beats every other option),
or none. A T3 choice is never final here: `needs_user_confirmation` is always true (the user confirms the option).
"""
import itertools
import json

WINNERS = ("first", "second", "tie")


def schedule(option_ids):
    """Every ordered pair: each unordered pair is judged in both orders."""
    ids = list(dict.fromkeys(option_ids))
    if len(ids) < 2:
        raise ValueError("a tournament needs at least 2 options")
    return [{"first": a, "second": b} for a, b in itertools.permutations(ids, 2)]


def validate(doc):
    """→ list of problems (empty when the document is usable)."""
    probs = []
    opts = doc.get("options") if isinstance(doc, dict) else None
    if not isinstance(opts, list) or len(opts) < 2:
        return ["options: need a list of at least 2 options"]
    ids = [o.get("id") if isinstance(o, dict) else None for o in opts]
    if any(not isinstance(i, str) or not i for i in ids) or len(set(ids)) != len(ids):
        probs.append("options: every option needs a unique string id")
    for n, j in enumerate(doc.get("judgments") or []):
        if not isinstance(j, dict):
            probs.append(f"judgments[{n}]: not an object")
            continue
        if j.get("first") not in ids or j.get("second") not in ids or j.get("first") == j.get("second"):
            probs.append(f"judgments[{n}]: first/second must be two different option ids")
        if j.get("winner") not in WINNERS:
            probs.append(f"judgments[{n}]: winner must be first|second|tie")
    return probs


def _picked(j):
    w = j.get("winner")
    return "tie" if w == "tie" else j.get("first") if w == "first" else j.get("second")


def aggregate(doc):
    probs = validate(doc)
    if probs:
        raise ValueError("; ".join(probs))
    ids = [o["id"] for o in doc["options"]]
    seen = {}
    for j in doc.get("judgments") or []:
        seen[(j["first"], j["second"])] = _picked(j)   # a later judgment of the same order replaces an earlier one
    pairs, beats = [], {i: set() for i in ids}
    for a, b in itertools.combinations(ids, 2):
        ab, ba = seen.get((a, b)), seen.get((b, a))
        if ab is None or ba is None:
            state, verdict = "missing", None
        elif ab == ba:
            state, verdict = "agreed", ab
            if ab != "tie":
                beats[ab].add(b if ab == a else a)
        else:
            state, verdict = "split", None
        pairs.append({"pair": [a, b], "state": state, "verdict": verdict, "a_first": ab, "b_first": ba})
    n = len(ids) - 1
    winner = next((i for i in ids if len(beats[i]) == n), None)
    counts = {s: sum(p["state"] == s for p in pairs) for s in ("agreed", "split", "missing")}
    status = "winner" if winner else "incomplete" if counts["missing"] else "no-winner"
    return {"status": status, "winner": winner, "wins": {i: sorted(beats[i]) for i in ids}, "pairs": pairs,
            "counts": counts, "consistency": round(counts["agreed"] / len(pairs), 4) if pairs else 0.0,
            "needs_user_confirmation": True}


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)
