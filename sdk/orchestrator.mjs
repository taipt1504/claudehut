#!/usr/bin/env node
// sdk/orchestrator.mjs — Phase 7.1: a programmatic ClaudeHut orchestrator on the
// Claude Agent SDK. The control loop (phase sequencing, retry cap, budget gate)
// is deterministic JS instead of model-interpreted prose — that is the robustness
// win (control flow no longer depends on the model cooperating with SKILL.md).
//
// WRAP model (not replace): this reuses the existing plugin runtime behind the SDK —
//   - phase DERIVATION: bin/claudehut-state phase (the one artifact-state machine)
//   - phase PROMPT: skills/<phase>/scripts/dispatch-prompt.sh (keeps Phase-4 JIT
//     retrieval + artifact injection — the dynamic enrichment context:fork couldn't
//     carry, see 6.4)
//   - build workers: skills/build/scripts/run-parallel-group.sh (bash workers behind
//     the SDK, per the 7.1 spec) + Phase-5 telemetry/budget
//   - subagent tools/permissions: sdk/agent-config.json (the SDK ignores filesystem
//     allowed-tools, so they are declared programmatically here)
//
// VERIFIED deterministically (no $): the mapping (run-all.sh L26) + the pure control
// helpers (sdk/test/control-flow.test.mjs). The ONE thing this cannot self-verify is
// the live "parity at lower variance" gate — that needs k>=3 paid model runs (see
// sdk/README.md "$ boundary"). Run live with: node sdk/orchestrator.mjs "<task>".
import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { phasePersona, phaseSkillDir, resolveAgent, shouldRetry, budgetOk } from "./lib/control-flow.mjs";

const PLUGIN_ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const CONFIG = JSON.parse(readFileSync(join(PLUGIN_ROOT, "sdk/agent-config.json"), "utf8"));

const sh = (cmd, args, opts = {}) =>
  execFileSync(cmd, args, { cwd: PLUGIN_ROOT, encoding: "utf8", ...opts }).trim();

const derivePhase = () => sh("bin/claudehut-state", ["phase"]);
const loopRetries = () => Number(sh("bin/claudehut-state", ["retries"]) || 0);
const dispatchPrompt = (phase, userPrompt) =>
  sh(join(PLUGIN_ROOT, `skills/${phaseSkillDir(phase)}/scripts/dispatch-prompt.sh`), [userPrompt], { maxBuffer: 1 << 24 });

// Build the SDK agent definition for one persona from the generated manifest.
function sdkAgent(persona) {
  const a = resolveAgent(persona, CONFIG);
  return {
    [persona]: {
      description: a.description,
      prompt: readFileSync(join(PLUGIN_ROOT, a.promptSource), "utf8"),
      tools: a.tools,
      model: a.model,
    },
  };
}

// Dispatch one phase to its subagent via the SDK. The SDK import is lazy so the
// pure helpers (and the mapping tests) load without the package installed.
async function dispatchPhase(persona, prompt) {
  const { query } = await import("@anthropic-ai/claude-agent-sdk");
  let result = "";
  for await (const msg of query({
    prompt,
    options: {
      agents: sdkAgent(persona),
      allowedTools: CONFIG.orchestratorAllowedTools,
      permissionMode: CONFIG.sessionPermissionMode,
      settingSources: ["project"], // load .claude/ (rules, hooks) — the WRAP
    },
  })) {
    if (msg.type === "result" && typeof msg.result === "string") result = msg.result;
  }
  return result;
}

async function main() {
  const userPrompt = process.argv.slice(2).join(" ").trim();
  if (!userPrompt) {
    console.error('usage: node sdk/orchestrator.mjs "<task description>"');
    process.exit(2);
  }
  const retryCap = Number(process.env.CLAUDEHUT_LOOP_MAX_RETRIES || 3);
  const budgetCap = Number(process.env.CLAUDEHUT_MAX_POOL_USD || 0); // 0 => unlimited
  let spent = 0;

  for (let step = 0; step < 32; step++) {
    const phase = derivePhase();
    console.error(`[orchestrator] phase=${phase} retries=${loopRetries()} spent=$${spent.toFixed(2)}`);
    if (phase === "done" || phase === "uninitialized") break;
    if (!budgetOk(spent, budgetCap)) { console.error("[orchestrator] BUDGET HALT"); process.exit(3); }
    if (phase === "loop" && !shouldRetry(loopRetries(), retryCap)) {
      console.error(`[orchestrator] retry cap ${retryCap} reached — escalating to user`);
      break;
    }

    const persona = phasePersona(phase);
    if (!persona) { // route / inline-orchestrator phase: run the phase skill's script directly
      sh(join(PLUGIN_ROOT, `skills/${phaseSkillDir(phase)}/scripts/classify.sh`), [userPrompt], { stdio: "inherit" });
      continue;
    }
    if (phase === "build") {
      // bash workers behind the SDK (worktrees + Phase-5 telemetry/budget)
      sh(join(PLUGIN_ROOT, "skills/build/scripts/run-parallel-group.sh"), [], { stdio: "inherit" });
      continue;
    }
    const out = await dispatchPhase(persona, dispatchPrompt(phase, userPrompt));
    process.stdout.write(out + "\n");
  }
}

main().catch((e) => { console.error("[orchestrator] error:", e.message); process.exit(1); });
