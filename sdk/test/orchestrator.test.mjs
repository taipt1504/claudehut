// sdk/test/orchestrator.test.mjs — end-to-end control-loop smoke for the Phase 7.1
// orchestrator with ALL dependencies stubbed: no SDK, no model, no $, no bash. Proves
// the loop routes phases correctly, runs bash-worker / inline / dispatch branches in
// the right place, accumulates cost, and halts on budget + retry cap. This is the
// "integration verified except the live model call" guarantee — the live call + the
// parity comparison are the only $-gated pieces. Importing orchestrator.mjs here must
// NOT run main() (guarded) and must NOT load the SDK (its import is lazy, inside the
// real dispatchPhase we never call).
import { test } from "node:test";
import assert from "node:assert/strict";
import { runLoop } from "../orchestrator.mjs";

function harness(overrides = {}) {
  const calls = [];
  const deps = {
    loopRetries: () => 0,
    dispatchPrompt: (p) => `prompt:${p}`,
    runInline: (p) => calls.push(`inline:${p}`),
    runBuild: () => calls.push("build"),
    dispatchPhase: async (persona) => { calls.push(`dispatch:${persona}`); return { result: `r:${persona}`, costUsd: 0.5 }; },
    log: () => {},
    retryCap: 3,
    budgetCap: 0,
    ...overrides,
  };
  return { deps, calls };
}

test("runLoop drives a full pipeline route->...->done with correct per-phase routing", async () => {
  const seq = ["route", "brainstorm", "spec", "plan", "build", "loop", "learn", "done"];
  let i = 0;
  const { deps, calls } = harness({ derivePhase: () => seq[Math.min(i, seq.length - 1)] });
  // each consumed phase advances the scripted sequence (simulates artifacts appearing)
  const inl = deps.runInline, bld = deps.runBuild, dsp = deps.dispatchPhase;
  deps.runInline = (p) => { inl(p); i++; };
  deps.runBuild = () => { bld(); i++; };
  deps.dispatchPhase = async (p) => { const r = await dsp(p); i++; return r; };

  const r = await runLoop(deps);
  assert.equal(r.halted, null);
  assert.equal(r.trace[r.trace.length - 1], "done");
  assert.ok(calls.includes("inline:route"), "route runs inline (main-thread classify)");
  assert.ok(calls.includes("dispatch:claudehut-brainstormer"));
  assert.ok(calls.includes("dispatch:claudehut-spec-writer"));
  assert.ok(calls.includes("dispatch:claudehut-planner"));
  assert.ok(calls.includes("build"), "build runs the bash parallel-group worker");
  assert.ok(calls.includes("dispatch:claudehut-verifier"), "loop dispatches the verifier (loop->verify-review)");
  assert.ok(calls.includes("dispatch:claudehut-learner"));
  assert.ok(r.spent > 0, "cost accumulates across dispatched phases");
});

test("runLoop halts (exit-3 path) on budget breach", async () => {
  const { deps } = harness({
    derivePhase: () => "brainstorm",                 // never advances -> would loop forever
    budgetCap: 1,
    dispatchPhase: async () => ({ result: "", costUsd: 5 }), // one dispatch blows the $1 cap
  });
  const r = await runLoop(deps);
  assert.equal(r.halted, "budget");
  assert.ok(r.spent >= 5);
});

test("runLoop halts at the retry cap on the loop phase", async () => {
  const { deps } = harness({ derivePhase: () => "loop", loopRetries: () => 3, retryCap: 3 });
  const r = await runLoop(deps);
  assert.equal(r.halted, "retry-cap");
});

test("runLoop terminates immediately on done / uninitialized (no dispatch)", async () => {
  const a = await runLoop(harness({ derivePhase: () => "done" }).deps);
  assert.equal(a.steps, 0);
  const b = await runLoop(harness({ derivePhase: () => "uninitialized" }).deps);
  assert.equal(b.steps, 0);
});
