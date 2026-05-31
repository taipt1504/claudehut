#!/usr/bin/env node
// sdk/orchestrator.mjs — Phase 7.1: a programmatic ClaudeHut orchestrator on the
// Claude Agent SDK. Deterministic control flow instead of model-interpreted prose.
//
// It WALKS THE ROUTE'S DECLARED PHASE SEQUENCE (route artifact `.phases`, e.g.
// quick=[build,loop] or full=[brainstorm,spec,plan,build,loop,learn]) rather than
// re-deriving the phase each tick: in quick mode the artifact state machine returns
// "build" both before AND after the builder runs (the build->done transition needs a
// findings.json that only the loop/verify phase writes), so a re-derive loop would
// re-dispatch build forever. Walking the sequence + using findings (pass|fail) to
// decide done-vs-retry is the correct deterministic model. (This is why the live
// smoke matters — the unit test's scripted-advancing derivePhase masked it.)
//
// WRAP model (not replace): reuses the existing runtime behind the SDK —
//   - route: skills/route/scripts/{classify,write-route}.sh (classify + persist)
//   - phase PROMPT: skills/<dir>/scripts/dispatch-prompt.sh (Phase-4 enrichment)
//   - full-mode parallel build: skills/build/scripts/run-parallel-group.sh (bash
//     workers behind the SDK) when a plan exists; quick build = a single SDK builder
//   - subagent tools/perms: sdk/agent-config.json
//
// runLoop(deps) is unit-tested with NO SDK/model/$ (sdk/test/orchestrator.test.mjs).
// Live run: node sdk/orchestrator.mjs "<task>"  (cd sdk && npm install).
import { readFileSync, writeFileSync, readdirSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { phasePersona, phaseSkillDir, resolveAgent, budgetOk } from "./lib/control-flow.mjs";

const PLUGIN_ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const CONFIG = JSON.parse(readFileSync(join(PLUGIN_ROOT, "sdk/agent-config.json"), "utf8"));

// ---- the control loop — deps injected so it is unit-testable sans SDK/$/bash ----
export async function runLoop(deps) {
  const { derivePhase, runRoute, routePhases, hasPlan, runBuild, dispatchPhase, dispatchPrompt,
          findingsDecision, log, retryCap, budgetCap, maxSteps = 40 } = deps;
  let spent = 0, lastOutput = "", steps = 0, retries = 0;
  const trace = [];
  const account = (r) => { spent += Number(r?.costUsd || 0); if (r?.result) lastOutput = r.result; };

  if (derivePhase() === "route") runRoute();           // triage first if not yet routed
  const phases = routePhases();                         // the ordered required phases
  if (!phases.length) return { trace, halted: "no-route", spent, steps, lastOutput };
  const buildIdx = phases.indexOf("build");

  for (let pi = 0; pi < phases.length && steps < maxSteps; pi++) {
    const phase = phases[pi];
    trace.push(phase);
    log(`phase=${phase} (${pi + 1}/${phases.length}) retries=${retries} spent=$${spent.toFixed(2)}`);
    if (!budgetOk(spent, budgetCap)) return { trace, halted: "budget", spent, steps, lastOutput };
    steps++;

    if (phase === "build") {
      if (hasPlan()) runBuild();                        // full-mode: bash parallel workers
      else account(await dispatchPhase("claudehut-builder", dispatchPrompt("build")));
    } else if (phase === "loop") {
      account(await dispatchPhase("claudehut-verifier", dispatchPrompt("loop"))); // writes findings.json
      const decision = findingsDecision();              // pass | fail | ""
      if (decision === "fail") {
        if (retries >= retryCap) return { trace, halted: "retry-cap", spent, steps, lastOutput };
        retries++; pi = (buildIdx >= 0 ? buildIdx : pi) - 1; continue; // retry from build
      }
      // pass / no-decision → advance
    } else {
      const persona = phasePersona(phase);              // brainstorm/spec/plan/learn
      if (persona) account(await dispatchPhase(persona, dispatchPrompt(phase)));
    }
  }
  return { trace, halted: null, spent, steps, lastOutput };
}

// ---- real dependency wiring (used by main; NOT exercised by the unit tests) ----
const sh = (cmd, args, opts = {}) => {
  const r = execFileSync(cmd, args, { cwd: PLUGIN_ROOT, encoding: "utf8", ...opts });
  return r == null ? "" : r.trim(); // stdio:"inherit" makes execFileSync return null
};
const projectRoot = () => process.env.CLAUDE_PROJECT_DIR || ".";
const _readJsonIn = (subdir, suffix) => {
  try {
    const dir = join(projectRoot(), subdir);
    const f = readdirSync(dir).find((x) => x.endsWith(suffix));
    return f ? JSON.parse(readFileSync(join(dir, f), "utf8")) : null;
  } catch { return null; }
};

function realDeps(userPrompt) {
  const stateBin = join(PLUGIN_ROOT, "bin/claudehut-state");
  return {
    derivePhase: () => sh(stateBin, ["phase"]),
    routePhases: () => _readJsonIn(".claudehut/state", "route-")?.phases
                       ?? (() => { const j = _readJsonIn(".claudehut/state", ".json"); return j?.phases || []; })(),
    findingsDecision: () => _readJsonIn(".claudehut/findings", "-findings.json")?.decision || "",
    hasPlan: () => { try { return readdirSync(join(projectRoot(), ".claudehut/plans")).some((f) => f.endsWith("-plan.md")); } catch { return false; } },
    dispatchPrompt: (phase) =>
      sh(join(PLUGIN_ROOT, `skills/${phaseSkillDir(phase)}/scripts/dispatch-prompt.sh`),
         [userPrompt], { maxBuffer: 1 << 24 }),
    runRoute: () => {
      const out = sh(join(PLUGIN_ROOT, "skills/route/scripts/classify.sh"), [userPrompt]);
      let profile = "full", db = false;
      try { const j = JSON.parse(out); profile = j.profile || "full"; db = !!j.db_review; } catch { /* default full */ }
      const args = [profile]; if (db) args.push("--db-review");
      sh(join(PLUGIN_ROOT, "skills/route/scripts/write-route.sh"), args);
    },
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
  // `claude --print --output-format json`-shaped envelope so evals/score.sh grades
  // the SDK arm identically to the bash arms (run.sh sdk mode + --variance parity).
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
