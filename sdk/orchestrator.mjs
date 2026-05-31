#!/usr/bin/env node
// sdk/orchestrator.mjs — Phase 7.1: a programmatic ClaudeHut orchestrator on the
// Claude Agent SDK. The control loop (phase sequencing, retry cap, budget gate) is
// deterministic JS instead of model-interpreted prose — control flow no longer
// depends on the model cooperating with SKILL.md.
//
// WRAP model (not replace): reuses the existing runtime behind the SDK —
//   - phase DERIVATION: bin/claudehut-state phase (the one artifact-state machine)
//   - phase PROMPT: skills/<dir>/scripts/dispatch-prompt.sh (keeps Phase-4 JIT
//     retrieval + artifact injection — what context:fork couldn't carry, see 6.4)
//   - build workers: skills/build/scripts/run-parallel-group.sh (bash behind SDK)
//   - subagent tools/perms: sdk/agent-config.json (the SDK ignores filesystem
//     allowed-tools, so they are declared programmatically)
//
// runLoop() takes its dependencies as parameters, so the full control flow (routing,
// build, loop, retry cap, budget halt, termination) is unit-tested with NO SDK, NO
// model, NO $ (sdk/test/orchestrator.test.mjs). main() injects the real deps. The
// ONLY part that needs spend is the live model call inside the real dispatchPhase —
// and the live "parity at lower variance" comparison (sdk/README.md "$ boundary").
// Run live: node sdk/orchestrator.mjs "<task>"  (after `cd sdk && npm install`).
import { readFileSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { phasePersona, phaseSkillDir, resolveAgent, shouldRetry, budgetOk } from "./lib/control-flow.mjs";

const PLUGIN_ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const CONFIG = JSON.parse(readFileSync(join(PLUGIN_ROOT, "sdk/agent-config.json"), "utf8"));

// ---- the control loop — dependencies injected so it is unit-testable sans SDK/$/bash ----
export async function runLoop(deps) {
  const { derivePhase, loopRetries, runInline, runBuild, dispatchPhase, dispatchPrompt,
          log, retryCap, budgetCap, maxSteps = 32 } = deps;
  let spent = 0, lastOutput = "", steps = 0;
  const trace = [];
  for (let step = 0; step < maxSteps; step++) {
    const phase = derivePhase();
    trace.push(phase);
    log(`phase=${phase} retries=${loopRetries()} spent=$${spent.toFixed(2)}`);
    if (phase === "done" || phase === "uninitialized") break;
    if (!budgetOk(spent, budgetCap)) return { trace, halted: "budget", spent, steps, lastOutput };
    if (phase === "loop" && !shouldRetry(loopRetries(), retryCap))
      return { trace, halted: "retry-cap", spent, steps, lastOutput };
    const persona = phasePersona(phase);
    steps++;
    if (!persona) { runInline(phase); continue; }       // route: main-thread classify
    if (phase === "build") { runBuild(); continue; }     // bash workers behind the SDK
    const r = await dispatchPhase(persona, dispatchPrompt(phase));
    spent += Number(r?.costUsd || 0);
    if (r?.result) lastOutput = r.result;
  }
  return { trace, halted: null, spent, steps, lastOutput };
}

// ---- real dependency wiring (used by main; NOT exercised by the unit tests) ----
const sh = (cmd, args, opts = {}) =>
  execFileSync(cmd, args, { cwd: PLUGIN_ROOT, encoding: "utf8", ...opts }).trim();

function realDeps(userPrompt) {
  return {
    derivePhase: () => sh("bin/claudehut-state", ["phase"]),
    loopRetries: () => Number(sh("bin/claudehut-state", ["retries"]) || 0),
    dispatchPrompt: (phase) =>
      sh(join(PLUGIN_ROOT, `skills/${phaseSkillDir(phase)}/scripts/dispatch-prompt.sh`),
         [userPrompt], { maxBuffer: 1 << 24 }),
    runInline: (phase) =>
      sh(join(PLUGIN_ROOT, `skills/${phaseSkillDir(phase)}/scripts/classify.sh`),
         [userPrompt], { stdio: "inherit" }),
    runBuild: () =>
      sh(join(PLUGIN_ROOT, "skills/build/scripts/run-parallel-group.sh"), [], { stdio: "inherit" }),
    dispatchPhase: async (persona, prompt) => {
      const { query } = await import("@anthropic-ai/claude-agent-sdk"); // lazy: tests never load it
      const a = resolveAgent(persona, CONFIG);
      const agents = { [persona]: {
        description: a.description,
        prompt: readFileSync(join(PLUGIN_ROOT, a.promptSource), "utf8"),
        tools: a.tools, model: a.model,
      } };
      let result = "", costUsd = 0;
      for await (const msg of query({ prompt, options: {
        agents,
        allowedTools: CONFIG.orchestratorAllowedTools,
        permissionMode: CONFIG.sessionPermissionMode,
        settingSources: ["project"],
      } })) {
        if (msg.type === "result") {
          if (typeof msg.result === "string") result = msg.result;
          if (typeof msg.total_cost_usd === "number") costUsd = msg.total_cost_usd;
        }
      }
      return { result, costUsd };
    },
    log: (m) => console.error(`[orchestrator] ${m}`),
    retryCap: Number(process.env.CLAUDEHUT_LOOP_MAX_RETRIES || 3),
    budgetCap: Number(process.env.CLAUDEHUT_MAX_POOL_USD || 0), // 0 => unlimited
  };
}

async function main() {
  const userPrompt = process.argv.slice(2).join(" ").trim();
  if (!userPrompt) { console.error('usage: node sdk/orchestrator.mjs "<task description>"'); process.exit(2); }
  const r = await runLoop(realDeps(userPrompt));
  // Emit a `claude --print --output-format json`-shaped envelope so evals/score.sh
  // grades the SDK arm identically to the bash arms (run.sh sdk mode + --variance parity).
  const envelope = {
    total_cost_usd: r.spent,
    num_turns: r.steps,
    subtype: r.halted ? `halted_${r.halted}` : "success",
    is_error: r.halted === "budget",
    result: r.lastOutput,
    _phase_trace: r.trace,
  };
  const out = process.env.CLAUDEHUT_ORCH_JSON_OUT;
  if (out) writeFileSync(out, JSON.stringify(envelope));
  else process.stdout.write(JSON.stringify(envelope) + "\n");
  if (r.halted === "budget") process.exit(3);
}

// Guard: importing this module (for tests) must NOT run main().
if (import.meta.url === pathToFileURL(process.argv[1] || "x").href) {
  main().catch((e) => { console.error("[orchestrator] error:", e.message); process.exit(1); });
}
