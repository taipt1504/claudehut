#!/usr/bin/env bash
# doclint-replay.sh — READ-ONLY replay of scripts/doclint.sh over a corpus of legacy (v0.11) task artifacts
# (v0.12 M3, 06 §12 AC-1, 10-rollout-eval row M3). Nothing in the corpus is written: files are only read by
# doclint (one python process, JSONL out); all output goes to stdout (and --out FILE if given).
#
# Usage: evals/doclint-replay.sh [--corpus GLOB_ROOT] [--out FILE] [--json]
#   --corpus  workspace root; artifacts = <root>/*/.claude/claudehut/tasks/*/{spec,plan,brainstorm,plan-review,task}.md
#             (default: $DOCLINT_CORPUS or /Users/taiphan/Documents/Projects/ewallet-workspace)
#   --json    print the aggregate as one JSON object instead of the tables
#
# Report: per kind — files, p50/p90 words, budget; rule × kind hit counts (files with >=1 hit, split by
# blocking/advisory; L2 split into amend/missing/allowlist/order/table); then the three acceptance targets:
#   va-ms 0008 plan → L4 (total over budget) · va-ms 0024 brainstorm → L2 AMENDMENT heading ·
#   party-ms 0002 plan → L6 Test first cell of 2,685 characters (2,709 UTF-8 bytes; `c` caps count bytes).
# Exit 1 when a target is not caught (or the corpus is missing); legacy violations themselves never fail it.
#
# Templates: a kind whose skills/*/references/<kind>-template.md carries a ch:schema block uses it; the rest
# fall back to evals/fixtures/doclint/templates (06 §5 shapes). The source used per kind is printed.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORPUS="${DOCLINT_CORPUS:-/Users/taiphan/Documents/Projects/ewallet-workspace}"
OUT=""; JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --corpus) CORPUS="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --json) JSON=1; shift ;;
    *) echo "doclint-replay: unknown arg $1" >&2; exit 2 ;;
  esac
done
[ -d "$CORPUS" ] || { echo "doclint-replay: corpus $CORPUS not found" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/doclint-replay.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/tpl"
SRC=""
for k in spec plan brainstorm plan-review task context; do
  real=""
  for f in "$ROOT"/skills/*/references/"$k"-template.md; do
    [ -f "$f" ] && grep -q 'ch:schema' "$f" && { real="$f"; break; }
  done
  if [ -n "$real" ]; then cp "$real" "$TMP/tpl/"; SRC="$SRC $k=skills"
  else cp "$ROOT/evals/fixtures/doclint/templates/$k-template.md" "$TMP/tpl/"; SRC="$SRC $k=fixture"; fi
done

find "$CORPUS" -path '*/.claude/claudehut/tasks/*' -maxdepth 6 -type f \
  \( -name spec.md -o -name plan.md -o -name brainstorm.md -o -name plan-review.md -o -name task.md \) \
  2>/dev/null | sort >"$TMP/files"
N="$(wc -l <"$TMP/files" | tr -d ' ')"
[ "$N" -gt 0 ] || { echo "doclint-replay: no artifacts under $CORPUS" >&2; exit 1; }
DIRS="$(sed 's#/[^/]*$##' "$TMP/files" | sort -u | wc -l | tr -d ' ')"
ALLDIRS="$(find "$CORPUS" -path '*/.claude/claudehut/tasks/*' -mindepth 5 -maxdepth 5 -type d 2>/dev/null | grep -c '/tasks/[^/]*$' || true)"

# one doclint process for the whole corpus (JSONL); exit code is irrelevant here (legacy files violate)
tr '\n' '\0' <"$TMP/files" | DOCLINT_TEMPLATES="$TMP/tpl" xargs -0 bash "$ROOT/scripts/doclint.sh" --json --language en \
  >"$TMP/out.jsonl" 2>"$TMP/err" || true

python3 - "$TMP/out.jsonl" "$CORPUS" "$N" "$DIRS" "$SRC" "$JSON" "$ALLDIRS" >"$TMP/report" <<'PY'
import sys, json, re, collections
path, corpus, n, dirs, src, js, alldirs = sys.argv[1:8]
rows = [json.loads(l) for l in open(path, encoding='utf-8') if l.strip()]
KINDS = ['spec', 'plan', 'brainstorm', 'plan-review', 'task']
def sub(v):
    if v['rule'] != 'L2': return v['rule']
    m = v['msg']
    if m.startswith('forbidden heading'): return 'L2 amend'
    if m.startswith('missing required'): return 'L2 missing'
    if 'not in allowlist' in m: return 'L2 allowlist'
    if 'out of order' in m: return 'L2 order'
    if m.startswith('table columns'): return 'L2 table'
    if m.startswith('duplicate heading'): return 'L2 duplicate'
    if m.startswith('rev:'): return 'L2 changelog'
    return 'L2 other'
def pct(xs, p):
    if not xs: return 0
    xs = sorted(xs); k = (len(xs) - 1) * p / 100.0; f = int(k); c = min(f + 1, len(xs) - 1)
    return round(xs[f] + (xs[c] - xs[f]) * (k - f))
per = {k: {'files': 0, 'words': [], 'budget': None, 'hits': collections.Counter(), 'errors': 0} for k in KINDS}
rulekeys = set()
for r in rows:
    k = r.get('kind') or 'plan'
    if 'error' in r:
        kk = re.sub(r'\.md$', '', r['file'].rsplit('/', 1)[-1]); per.setdefault(kk, per['plan'])['errors'] += 1; continue
    d = per[k]; d['files'] += 1; d['words'].append(r['words'])
    t = r['budget'].get('total', {})
    if 'base' in t: d['budget'] = t['budget']
    seen = set()
    for sev in ('blocking', 'advisory'):
        for v in r[sev]:
            key = (sub(v), sev[0]); seen.add(key)
    for key in seen:
        d['hits'][key] += 1; rulekeys.add(key)
def find(svc, task, kind):
    for r in rows:
        f = r['file']
        if ('/%s/' % svc) in f and re.search(r'/tasks/%s[^/]*/%s\.md$' % (task, re.escape(kind)), f):
            return r
    return None
targets = []
r = find('va-ms', '0008', 'plan')
hit = r and [v for v in r['advisory'] if v['rule'] == 'L4']
targets.append(('va-ms 0008 plan → L4 total over budget', bool(hit), hit[0]['msg'] if hit else (r and 'no L4') or 'file not found'))
r = find('va-ms', '0024', 'brainstorm')
hit = r and [v for v in r['blocking'] if v['rule'] == 'L2' and v['msg'].startswith('forbidden heading') and 'AMENDMENT' in v['msg'].upper()]
targets.append(('va-ms 0024 brainstorm → L2 AMENDMENT heading', bool(hit), ('%d hit(s), first: %s' % (len(hit), hit[0]['msg'][:90])) if hit else (r and 'no L2 amend') or 'file not found'))
r = find('party-ms', '0002', 'plan')
hit = r and [v for v in r['advisory'] if v['rule'] == 'L6' and 'Test first' in v['msg'] and ('2685 chars' in v['msg'] or '2685c/' in v['msg'])]
targets.append(('party-ms 0002 plan → L6 Test first cell 2,685 chars', bool(hit), ('%s [line %s]' % (hit[0]['msg'], hit[0]['line'])) if hit else (r and 'no 2,685-char L6') or 'file not found'))
ok = all(t[1] for t in targets)
if js == '1':
    print(json.dumps({'corpus': corpus, 'files': int(n), 'task_dirs': int(dirs), 'all_task_dirs': int(alldirs or 0), 'templates': src.split(),
        'kinds': {k: {'files': d['files'], 'p50': pct(d['words'], 50), 'p90': pct(d['words'], 90),
                      'budget': d['budget'], 'errors': d['errors'],
                      'hits': {'%s/%s' % kk: c for kk, c in sorted(d['hits'].items())}} for k, d in per.items()},
        'targets': [{'target': t[0], 'caught': t[1], 'evidence': t[2]} for t in targets], 'ok': ok}, ensure_ascii=False))
else:
    print('# doclint replay (read-only) — %s' % corpus)
    print('%s artifacts in %s task dirs (of %s task dirs) · templates:%s' % (n, dirs, alldirs, src))
    print()
    print('| Kind | Files | p50 words | p90 words | Budget | Over budget (L4) | Errors |')
    print('|---|---|---|---|---|---|---|')
    for k, d in per.items():
        if not d['files'] and not d['errors']: continue
        print('| %s | %d | %d | %d | %s | %d | %d |' % (k, d['files'], pct(d['words'], 50), pct(d['words'], 90),
              d['budget'] or '—', d['hits'].get(('L4', 'a'), 0), d['errors']))
    print()
    ks = [k for k in KINDS if per[k]['files']]
    print('Files with >=1 hit, rule × kind (b = blocking, a = advisory):')
    print()
    print('| Rule | ' + ' | '.join(ks) + ' |')
    print('|---|' + '---|' * len(ks))
    def order(x):
        m = re.match(r'L(\d+)', x[0]); return (int(m.group(1)), x[0], x[1])
    for key in sorted(rulekeys, key=order):
        print('| %s (%s) | ' % key + ' | '.join(str(per[k]['hits'].get(key, 0)) for k in ks) + ' |')
    print()
    print('Acceptance targets (06 §12 AC-1):')
    for t in targets:
        print('- [%s] %s — %s' % ('x' if t[1] else ' ', t[0], t[2]))
    print()
    print('REPLAY: %s' % ('PASS — all three targets caught' if ok else 'FAIL — a target was not caught'))
sys.exit(0 if ok else 1)
PY
rc=$?
cat "$TMP/report"
[ -s "$TMP/err" ] && { echo; echo "doclint stderr:"; head -5 "$TMP/err"; }
[ -n "$OUT" ] && cp "$TMP/report" "$OUT"
exit "$rc"
