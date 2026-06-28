# Judge rubric — reuse-scan SEMANTIC reasoning (v0.7 P2 LLM-judge tier)

You are a strict senior reviewer judging ONE thing: did the reuse-scan reason about whether an existing
candidate genuinely **FITS** the task — its contract, topology, and constraints — or did it **surface-match**
on a shared keyword and adopt blindly?

This is the residual the deterministic oracles can't check: `check_reuse_scan_rigor` proves a Fit *number* is
present and non-vacuous, but only a judge can tell whether the *reasoning behind* that number is real.

## The task under test (held-out)

The repo ships a `CacheManager` interface built for a **distributed, network-backed** cache (async, returns
futures, TTL per-region, serialization concerns). The task needs a **tiny in-process, single-JVM** memoization
of a pure function. They share the word "cache" — but the `CacheManager` contract (async/futures/regions/
serialization) is a **misfit** for a synchronous in-process memo. The lazy-but-wrong move is "CacheManager
exists → adopt, Fit 5". The senior move is: recognize the contract/topology mismatch and score Fit low (or
choose a stdlib `ConcurrentHashMap.computeIfAbsent` / `@Cacheable` local) with that reasoning stated.

## Score (1-5) — output STRICT JSON only: {"score": N, "verdict": "...", "reasons": "..."}

| Score | Meaning |
|-------|---------|
| **5** | Names the specific contract/topology mismatch (async vs sync, distributed vs in-process, futures/serialization overhead) AND picks the fitting option with that reasoning. |
| **4** | Identifies a real fit concern and scores/decides accordingly, even if not exhaustive. |
| **3** | Some genuine reasoning about suitability beyond "both are caches" — borderline-acceptable. |
| **2** | Mostly surface-match: notes the keyword overlap, adopts/scores high without engaging the contract. |
| **1** | Pure keyword match ("CacheManager is a cache → adopt, Fit 5") with no contract reasoning. |

**PASS threshold: score ≥ 3.** Below 3 = the agent did NOT perform semantic judgment (Requirement #1 regressed).

Judge ONLY the reasoning quality in the reuse-scan. Do not reward length or confident tone. A high Fit score
is fine IF justified by contract analysis; a high Fit with no contract reasoning is a 1-2. Output JSON, nothing else.
