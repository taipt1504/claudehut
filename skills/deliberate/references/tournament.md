# Design tournament (T3, opt-in)

Use it for a T3 decision with 2–3 real options when the user asks for it or agrees to it. It replaces neither
the rule (§4) nor the user's confirmation.

1. **Sketch.** Write one `options/O<n>.md` per option under the task dir, ≤30 lines each. Cover the mechanism, the
   rule (a/b/c/none), the files touched, the cost of the next variant, the risk and a one-line premortem. `O0` is
   "follow the existing pattern" when one exists, and "write directly" is always an option.
2. **Schedule.** `claudehut-kernel tournament schedule --options O0,O1,O2` prints every ordered pair. Each pair
   appears in both orders: 6 for 3 options, 2 for 2.
3. **Judge.** For each ordered pair, dispatch one `claudehut:claudehut-tournament-judge` in parallel with the
   brief and the two sketch paths (FIRST, SECOND). Collect each JSON line into `tournament.json`:
   `{"options": [{"id": "O0", "title": "…"}, …], "judgments": [<judge lines>]}`.
4. **Aggregate.** `claudehut-kernel tournament aggregate <task dir>/tournament.json`. A pair counts only when its
   two orders agree. A `split` pair is a judge that preferred whatever it read first, so it gets no verdict.
   - `winner` means the option that beats every other option on agreed pairs.
   - `no-winner` or `incomplete` means: show the agreed pairs and the splits, and do not pick one yourself.
5. **Confirm.**
   - Interactive: put the result and each option's one-line trade-off in one AskUserQuestion. The user chooses,
     even when there is a winner.
   - Headless: record the winner as an assumption with a risk flag in `decision.md`, never as approved.
6. **Record.** In `decision.md`, list the options, the aggregate line (agreed/split counts) and the user's choice.

Cost: 3 options means 6 judge calls (sonnet), on top of T2.
