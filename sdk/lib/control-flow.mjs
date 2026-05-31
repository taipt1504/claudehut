// sdk/lib/control-flow.mjs — pure, SDK-free orchestration decisions for the
// Phase 7.1 Agent-SDK orchestrator. These are the deterministic parts that must
// be unit-testable WITHOUT a model call or the SDK installed (test:
// sdk/test/control-flow.test.mjs, also wired into run-all.sh L26 when node exists).
//
// Phase DERIVATION is intentionally NOT reimplemented here — orchestrator.mjs shells
// out to the existing artifact-state machine (bin/claudehut-state) so there is one
// source of truth (avoids the writer/reader drift class that bit Phase 4). What lives
// here is only what the SDK layer newly owns: persona->permissions resolution, the
// loop retry cap, the budget gate, and the phase->persona dispatch table.

// Map a derived phase to the subagent persona that executes it. `route` is
// main-thread triage (the orchestrator itself), so it has no dispatch persona.
const PHASE_PERSONA = {
  brainstorm: "claudehut-brainstormer",
  spec: "claudehut-spec-writer",
  plan: "claudehut-planner",
  build: "claudehut-builder",
  loop: "claudehut-verifier",
  learn: "claudehut-learner",
};

export function phasePersona(phase) {
  return PHASE_PERSONA[phase] ?? null; // null => orchestrator handles inline (route) or terminal (done)
}

// Resolve an SDK agent definition from the generated manifest. Throws on an
// unknown persona so a typo fails loud instead of dispatching with no tools.
export function resolveAgent(persona, config) {
  const a = config?.agents?.[persona];
  if (!a) throw new Error(`resolveAgent: unknown persona "${persona}"`);
  return { description: a.description, tools: a.tools, model: a.model, promptSource: a.promptSource, writer: !!a.writer };
}

// Loop retry cap (Phase 5 / loop_max_retries). Retry only while strictly under cap.
export function shouldRetry(retries, cap) {
  return Number(retries) < Number(cap);
}

// Worker-pool budget gate (mirrors skills/build budget-gate semantics): a cap of
// 0/empty/undefined means unlimited; otherwise halt once spend reaches the cap.
export function budgetOk(spentUsd, capUsd) {
  const cap = Number(capUsd);
  if (!cap || cap <= 0) return true; // unlimited
  return Number(spentUsd) < cap;
}

// The canonical full-pipeline phase order (for sequencing + tests). `quick` route
// is a subset (build, loop) derived by the bash state machine, not here.
export const FULL_PHASE_SEQUENCE = ["route", "brainstorm", "spec", "plan", "build", "loop", "learn", "done"];
