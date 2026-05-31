// sdk/test/orchestrator.test.mjs — end-to-end control-loop smoke for the Phase 7.1
// orchestrator with ALL dependencies stubbed: no SDK, no model, no $, no bash. The
// loop is SEQUENCE-driven (walks the route's `.phases`) with a findings-based
// loop/retry, so these stubs model exactly what the live run does — unlike a scripted
// derivePhase, which would mask the "build re-dispatches forever" bug the live smoke
// caught. Importing orchestrator.mjs must NOT run main() (guarded) or load the SDK
// (its import is lazy, inside the real dispatchPhase we never call).
import { test } from "node:test";
import assert from "node:assert/strict";
import { runLoop } from "../orchestrator.mjs";

function harness(overrides = {}) {
  const calls = [];
  const deps = {
    derivePhase: () => "build",            // already routed (not "route") => skip runRoute
    runRoute: () => calls.push("route"),
    routePhases: () => ["build", "loop"],  // quick profile by default
    hasPlan: () => false,                  // quick: dispatch a single builder
    runBuild: () => calls.push("build"),   // full: bash parallel workers
    findingsDecision: () => "pass",        // verify passes by default
    dispatchPrompt: (p) => `prompt:${p}`,
    dispatchPhase: async (persona) => { calls.push(`dispatch:${persona}`); return { result: `r:${persona}`, costUsd: 0.5 }; },
    log: () => {},
    retryCap: 3,
    budgetCap: 0,
    ...overrides,
  };
  return { deps, calls, n: (s) => calls.filter((c) => c === s).length };
}

test("quick route [build,loop] + findings pass: builder then verifier, ends clean", async () => {
  const { deps, calls } = harness();
  const r = await runLoop(deps);
  assert.equal(r.halted, null);
  assert.deepEqual(r.trace, ["build", "loop"]);
  assert.ok(calls.includes("dispatch:claudehut-builder"), "quick build dispatches a single builder");
  assert.ok(calls.includes("dispatch:claudehut-verifier"), "loop dispatches the verifier (loop->verify-review)");
  assert.ok(!calls.includes("build"), "no parallel-group worker in quick mode (no plan)");
});

test("route phase triggers classify+persist (runRoute) when not yet routed", async () => {
  const { deps, calls } = harness({ derivePhase: () => "route" });
  await runLoop(deps);
  assert.ok(calls.includes("route"), "runRoute persists the route artifact before walking phases");
});

test("full route walks brainstorm->spec->plan->build(plan)->loop->learn", async () => {
  const { deps, calls } = harness({
    routePhases: () => ["brainstorm", "spec", "plan", "build", "loop", "learn"],
    hasPlan: () => true,   // full has a plan -> build uses bash parallel workers
  });
  const r = await runLoop(deps);
  assert.equal(r.halted, null);
  for (const p of ["claudehut-brainstormer", "claudehut-spec-writer", "claudehut-planner", "claudehut-verifier", "claudehut-learner"])
    assert.ok(calls.includes(`dispatch:${p}`), `dispatched ${p}`);
  assert.ok(calls.includes("build"), "full build runs the bash parallel-group worker (plan present)");
});

test("loop findings=fail retries from build up to the cap, then halts retry-cap", async () => {
  const { deps, n } = harness({ findingsDecision: () => "fail", retryCap: 3 });
  const r = await runLoop(deps);
  assert.equal(r.halted, "retry-cap");
  assert.equal(n("dispatch:claudehut-builder"), 4, "build runs cap+1 times (initial + 3 retries)");
});

test("budget breach halts (exit-3 path)", async () => {
  const { deps } = harness({ budgetCap: 1, dispatchPhase: async () => ({ result: "", costUsd: 5 }) });
  const r = await runLoop(deps);
  assert.equal(r.halted, "budget");
  assert.ok(r.spent >= 5);
});

test("no route artifact -> halted no-route (never dispatches blind)", async () => {
  const { deps, calls } = harness({ derivePhase: () => "build", routePhases: () => [] });
  const r = await runLoop(deps);
  assert.equal(r.halted, "no-route");
  assert.equal(calls.length, 0);
});
