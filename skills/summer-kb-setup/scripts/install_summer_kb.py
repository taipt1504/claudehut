#!/usr/bin/env python3
"""
install_summer_kb.py — install a service-scoped Summer Framework KB into a consumer service.

Detects io.f8a.summer:summer-* deps in the target service, resolves the KB source
(sibling java-common-ms/.claude/summer-kb if present, else the skill's bundled snapshot),
copies only the module docs that service uses, generates a scoped INDEX.md + local USAGE.md,
writes a local always-on pointer (.claude/rules/summer-kb.md), and stamps .summer-kb-meta.json.

Usage:  python3 install_summer_kb.py [SERVICE_DIR]   (default: current working directory)
        --dry-run   print the plan, write nothing
Does NOT git add/commit (committing .claude/summer-kb/ is the team's call).
"""
import sys, os, re, json, shutil, glob, argparse, datetime

ARTIFACT_TO_MODULE = {
    'summer-core': 'core',
    'summer-rest-common': 'rest', 'summer-rest-autoconfigure': 'rest',
    'summer-data-r2dbc': 'data', 'summer-data-autoconfigure': 'data',
    'summer-data-outbox': 'data', 'summer-data-outbox-autoconfigure': 'data',
    'summer-data-audit': 'data', 'summer-data-audit-autoconfigure': 'data',
    'summer-security-autoconfigure': 'security', 'summer-apisix-resource-server': 'security',
    'summer-jwt-resource-server': 'security', 'summer-apikey-resource-server': 'security',
    'summer-keycloak': 'security',
    'summer-kafka-consumer': 'kafka', 'summer-kafka-consumer-autoconfigure': 'kafka',
    'summer-ratelimit-core': 'ratelimit', 'summer-ratelimit-autoconfigure': 'ratelimit',
    'summer-payment-sdk': 'payment-sdk',
    'summer-platform': 'platform',
    'summer-test': 'test',
    'summer-file': 'file',
}
ALL_MODULES = ['core', 'rest', 'data', 'security', 'kafka', 'ratelimit', 'payment-sdk', 'platform', 'test', 'file']
COORD = re.compile(r'io\.f8a\.summer:(summer-[a-z0-9-]+)')


def detect_artifacts(service):
    arts = set()
    for ext in ('*.gradle', '*.gradle.kts', '*.toml'):
        for f in glob.glob(os.path.join(service, '**', ext), recursive=True):
            if os.sep + 'build' + os.sep in f:
                continue
            try:
                txt = open(f, encoding='utf-8', errors='ignore').read()
            except OSError:
                continue
            arts.update(COORD.findall(txt))
    return arts


def resolve_source(service, skill_dir):
    """Return (source_dir, kind, summer_commit). Prefer sibling java-common-ms, else bundled."""
    d = os.path.abspath(service)
    for _ in range(8):  # walk up to workspace root
        cand = os.path.join(d, 'java-common-ms', '.claude', 'summer-kb')
        if os.path.isfile(os.path.join(cand, 'INDEX.md')):
            commit = None
            meta = os.path.join(d, 'java-common-ms', '.understand-anything', 'meta.json')
            if os.path.isfile(meta):
                try:
                    commit = json.load(open(meta)).get('gitCommitHash')
                except Exception:
                    pass
            return cand, 'sibling', commit
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    bundle = os.path.join(skill_dir, 'references', 'summer-kb')
    commit = None
    bm = os.path.join(bundle, '.bundle-meta.json')
    if os.path.isfile(bm):
        try:
            commit = json.load(open(bm)).get('summerCommit')
        except Exception:
            pass
    return bundle, 'bundled', commit


def referenced_modules(line):
    """Modules a line 'belongs to'. A row with a (mod.md) doc-link belongs to the linked module(s)
    ONLY (ignore incidental cells like 'Depends on: core'). Otherwise use pure module-name cells
    (the Doc column of the cheat-sheet / topic-map rows)."""
    links = {m for m in ALL_MODULES if f'({m}.md)' in line}
    if links:
        return links
    mods = set()
    if line.lstrip().startswith('|'):
        for cell in line.split('|'):
            toks = [t for t in re.split(r'[\s/]+', cell.strip()) if t]
            if toks and all(t in ALL_MODULES for t in toks):
                mods.update(toks)
    return mods


def scope_index(src_index_text, included, detected_arts):
    """Filter the canonical INDEX to included modules; rebuild §4 coordinates from detected artifacts."""
    lines = src_index_text.splitlines()
    out, in_coords = [], False
    for ln in lines:
        if ln.startswith('## 4.'):
            in_coords = True
            out.append(ln)
            arts = sorted(a for a in detected_arts) or ['(none detected)']
            out.append('')
            out.append('Detected in this service (group `io.f8a.summer`):')
            out.append('')
            out.append(' · '.join(f'`{a}`' for a in arts))
            out.append('')
            out.append('> Version via the `summer-platform` BOM. Repo: GitLab Maven (`git.newera.inc`, needs `GITLAB_TOKEN`).')
            continue
        if in_coords:
            continue  # drop original coordinate body
        ref = referenced_modules(ln)
        if ref and ref.isdisjoint(included):
            continue  # row about a module not installed here
        out.append(ln)
    # drop '### ' groups left with no table rows
    pruned, i = [], 0
    while i < len(out):
        ln = out[i]
        if ln.startswith('### '):
            j = i + 1
            has_row = False
            while j < len(out) and not out[j].startswith(('### ', '## ')):
                if out[j].lstrip().startswith('|') and '---' not in out[j] and not re.match(r'\|\s*(Need|Contract|Topic|Prefix|Module doc)\b', out[j]):
                    has_row = True
                j += 1
            if not has_row:
                i = j
                continue
        pruned.append(ln)
        i += 1
    return '\n'.join(pruned).rstrip() + '\n'


def localize_usage(src_usage_text):
    """Point USAGE at the local docs path instead of the library sibling."""
    t = src_usage_text.replace('java-common-ms/.claude/summer-kb/', '.claude/summer-kb/')
    t = t.replace('`.claude/summer-kb/` (sibling repo under this workspace)',
                  '`.claude/summer-kb/` (local to this service)')
    return t


LOCAL_POINTER = """# Summer Framework KB (always-on)

This service consumes Summer (`io.f8a.summer`). A **service-scoped** KB documenting the Summer modules this
service uses lives locally at **`.claude/summer-kb/`**.

## Rule
When a task touches Summer — a `io.f8a.summer:summer-*` dependency, a `f8a.*` / `summer.*` property, an
auto-config gate, a `Ufid`/`Txid` annotation (`@JE`/`@SE`/`@TX`/`@Compact`/`@UInt128`/`@UfidPrefix`), a Summer
Kafka contract, or any Summer type (`ApiResponse`, `ViewableException`, outbox/audit, resource-server, rate
limiter) — you **MUST** ground the decision in this KB, not memory or guesswork.

## How
1. Start at `.claude/summer-kb/USAGE.md` (when/how/grounding), then `INDEX.md` (topic → module → source).
2. Each module doc: banner + `TL;DR · Activate · Config keys · Public API · Usage · Gotchas · Graph refs`.
3. Cite the graph node id / source path the KB gives. Never invent property names, gate defaults, or coordinates.
4. If the KB lacks a fact, read the source it points to; if unverifiable, mark `[unverified]` — never guess.

KB lives under `.claude/` (committable — share with the team; never commit `.claude/claudehut/state/`). Refresh with `/summer-kb-setup` after Summer upgrades.
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('service', nargs='?', default=os.getcwd())
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--skill-dir', default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    args = ap.parse_args()

    service = os.path.abspath(args.service)
    if not os.path.isdir(service):
        print(f"ERROR: service dir not found: {service}", file=sys.stderr)
        return 2

    arts = detect_artifacts(service)
    if not arts:
        print(f"No io.f8a.summer:summer-* dependencies found under {service}.")
        print("This does not look like a Summer consumer service. Nothing installed.")
        print("(Checked *.gradle, *.gradle.kts, *.toml, excluding build/.)")
        return 1

    modules = {ARTIFACT_TO_MODULE[a] for a in arts if a in ARTIFACT_TO_MODULE}
    modules.add('core')  # base value types are always in play
    unknown = sorted(a for a in arts if a not in ARTIFACT_TO_MODULE)

    src, kind, commit = resolve_source(service, args.skill_dir)
    included = sorted(modules, key=ALL_MODULES.index)

    print(f"Service:   {service}")
    print(f"Detected:  {', '.join(sorted(arts))}")
    if unknown:
        print(f"Unknown artifacts (no module doc): {', '.join(unknown)}")
    print(f"Modules:   {', '.join(included)}")
    print(f"Source:    {kind}  ({src})  summerCommit={commit}")
    dest = os.path.join(service, '.claude', 'summer-kb')
    print(f"Dest:      {dest}")

    if args.dry_run:
        print("\n[dry-run] would write: " + ", ".join(included) + ".md + INDEX.md + USAGE.md + .claude/rules/summer-kb.md")
        return 0

    os.makedirs(dest, exist_ok=True)
    written = []
    for m in included:
        s = os.path.join(src, f'{m}.md')
        if os.path.isfile(s):
            shutil.copyfile(s, os.path.join(dest, f'{m}.md'))
            written.append(f'{m}.md')

    # scoped INDEX
    idx_src = os.path.join(src, 'INDEX.md')
    if os.path.isfile(idx_src):
        scoped = scope_index(open(idx_src, encoding='utf-8').read(), set(included), arts)
        banner = (f"<!-- service-scoped install: {', '.join(included)} · source={kind} "
                  f"· summerCommit={commit} -->\n")
        open(os.path.join(dest, 'INDEX.md'), 'w', encoding='utf-8').write(banner + scoped)
        written.append('INDEX.md')

    # localized USAGE
    usage_src = os.path.join(src, 'USAGE.md')
    if os.path.isfile(usage_src):
        open(os.path.join(dest, 'USAGE.md'), 'w', encoding='utf-8').write(
            localize_usage(open(usage_src, encoding='utf-8').read()))
        written.append('USAGE.md')

    # local always-on pointer
    rules_dir = os.path.join(service, '.claude', 'rules')
    os.makedirs(rules_dir, exist_ok=True)
    open(os.path.join(rules_dir, 'summer-kb.md'), 'w', encoding='utf-8').write(LOCAL_POINTER)
    written.append('.claude/rules/summer-kb.md')

    # stamp
    stamp = {
        'source': kind, 'summerCommit': commit,
        'installedAt': datetime.datetime.now().isoformat(timespec='seconds'),
        'includedModules': included, 'detectedArtifacts': sorted(arts),
        'unknownArtifacts': unknown,
    }
    json.dump(stamp, open(os.path.join(dest, '.summer-kb-meta.json'), 'w'), indent=2)
    written.append('.summer-kb-meta.json')

    print("\nInstalled (local, untracked — not committed):")
    for w in written:
        print(f"  .claude/summer-kb/{w}" if not w.startswith('.claude') else f"  {w}")
    print(f"\nDone. {len(included)} module docs scoped to this service. "
          f"Agents auto-load via .claude/rules/summer-kb.md.")
    return 0


if __name__ == '__main__':
    sys.exit(main())
