// sdk/test/control-flow.test.mjs — deterministic unit tests for the Phase 7.1
// orchestrator control flow. No SDK, no model, no network. Run: node --test sdk/test
// (run-all.sh L26 runs this when node is present, else SKIPs — keeps the bash suite
// portable while still exercising the JS control flow where node exists).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { phasePersona, phaseSkillDir, resolveAgent, shouldRetry, budgetOk, FULL_PHASE_SEQUENCE } from "../lib/control-flow.mjs";

const ROOT = dirname(dirname(dirname(fileURLToPath(import.meta.url))));
const CONFIG = JSON.parse(readFileSync(join(ROOT, "sdk/agent-config.json"), "utf8"));

test("phasePersona maps each executing phase to its subagent; route/done have none", () => {
  assert.equal(phasePersona("build"), "claudehut-builder");
  assert.equal(phasePersona("loop"), "claudehut-verifier");
  assert.equal(phasePersona("brainstorm"), "claudehut-brainstormer");
  assert.equal(phasePersona("learn"), "claudehut-learner");
  assert.equal(phasePersona("route"), null);   // main-thread triage
  assert.equal(phasePersona("done"), null);     // terminal
});

test("phaseSkillDir maps loop->verify-review; every dispatched phase resolves to a REAL script (producer, catches ENOENT)", () => {
  assert.equal(phaseSkillDir("loop"), "verify-review"); // the one phase name != skill dir
  assert.equal(phaseSkillDir("build"), "build");
  // phases dispatched via dispatch-prompt.sh (build uses run-parallel-group, route uses classify)
  for (const ph of ["brainstorm", "spec", "plan", "loop", "learn"]) {
    const p = join(ROOT, `skills/${phaseSkillDir(ph)}/scripts/dispatch-prompt.sh`);
    assert.ok(existsSync(p), `phase ${ph} -> ${p} must exist on disk (else execFileSync ENOENT at runtime)`);
  }
  assert.ok(existsSync(join(ROOT, `skills/${phaseSkillDir("route")}/scripts/classify.sh`)), "route -> classify.sh exists");
  assert.ok(existsSync(join(ROOT, "skills/build/scripts/run-parallel-group.sh")), "build -> run-parallel-group.sh exists");
});

test("every phase persona resolves to a real subagent in the manifest", () => {
  for (const ph of FULL_PHASE_SEQUENCE) {
    const p = phasePersona(ph);
    if (!p) continue;
    const a = resolveAgent(p, CONFIG);
    assert.ok(Array.isArray(a.tools) && a.tools.length > 0, `${p} has tools`);
    assert.ok(a.promptSource.startsWith("agents/"), `${p} promptSource points at the persona`);
  }
});

test("resolveAgent throws loud on an unknown persona (no silent no-tool dispatch)", () => {
  assert.throws(() => resolveAgent("claudehut-nope", CONFIG), /unknown persona/);
});

test("only writer personas (builder, learner) carry Edit/Write — least privilege", () => {
  for (const [name, a] of Object.entries(CONFIG.agents)) {
    const writes = a.tools.includes("Edit") || a.tools.includes("Write");
    assert.equal(writes, a.writer, `${name}: writer flag matches its tools`);
    if (!a.writer) assert.ok(!writes, `${name} read-only carries no Edit/Write`);
  }
  assert.ok(CONFIG.agents["claudehut-builder"].writer);
  assert.ok(CONFIG.agents["claudehut-learner"].writer);
});

test("orchestrator (the SDK driver) is NOT a dispatchable subagent + holds the Agent tool", () => {
  assert.equal(CONFIG.agents["claudehut-orchestrator"], undefined);
  assert.ok(CONFIG.orchestratorAllowedTools.includes("Agent"));
});

test("shouldRetry respects a strict cap", () => {
  assert.equal(shouldRetry(0, 3), true);
  assert.equal(shouldRetry(2, 3), true);
  assert.equal(shouldRetry(3, 3), false);
  assert.equal(shouldRetry(4, 3), false);
});

test("budgetOk: cap 0/empty = unlimited; otherwise halt at the cap", () => {
  assert.equal(budgetOk(99, 0), true);     // unlimited
  assert.equal(budgetOk(99, ""), true);    // unlimited
  assert.equal(budgetOk(1.0, 8.0), true);
  assert.equal(budgetOk(8.0, 8.0), false); // reached
  assert.equal(budgetOk(8.5, 8.0), false);
});
