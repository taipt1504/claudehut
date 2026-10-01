#!/usr/bin/env python3
"""
install_summer_kb.py — install a service-scoped Summer Framework KB into a consumer service.

Detects io.f8a.summer:summer-* deps in the target service, resolves the KB source
(sibling java-common-ms/.claude/summer-kb if present, else the skill's bundled snapshot),
copies only the module docs that service uses, generates a scoped INDEX.md + local USAGE.md,
writes the local always-on pointer (.claude/rules/summer-kb.md) when it is missing, and stamps
.summer-kb-meta.json with the source's summerCommit.

The source of truth is java-common-ms/.claude/summer-kb/, stamped with the library repo's HEAD in its own
.summer-kb-meta.json (role "source": summerCommit + the doc list of every module). Run in java-common-ms itself,
this script only (re)writes that stamp; run in a consumer, it refreshes a stale source stamp first.

Usage:  python3 install_summer_kb.py [SERVICE_DIR] [--if-stale] [--dry-run]   (SERVICE_DIR default: cwd)
        --if-stale  install when the KB is missing, refresh when the consumer's summerCommit differs from the
                    source's or its Summer module set changed; otherwise write nothing
        --dry-run   print the plan, write nothing
The last line is always "summer-kb: <installed|refreshed|up-to-date|source ...|skip ...>" (claudehut-migrate parses
it). Exit 0 = done, 1 = not a Summer consumer, 2 = error. Never touches a file outside .claude/summer-kb/ except
creating a missing .claude/rules/summer-kb.md. Does NOT git add/commit.
"""
import sys, os, re, json, shutil, argparse, datetime, subprocess

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
    'summer-kafka-dlt-handling': 'kafka-dlt-handling', 'summer-kafka-dlt-handling-autoconfigure': 'kafka-dlt-handling',
    'summer-ratelimit-core': 'ratelimit', 'summer-ratelimit-autoconfigure': 'ratelimit',
    'summer-payment-sdk': 'payment-sdk',
    'summer-platform': 'platform',
    'summer-test': 'test',
    'summer-file': 'file',
}
MODULE_ORDER = ['core', 'rest', 'data', 'security', 'kafka', 'kafka-dlt-handling', 'ratelimit', 'payment-sdk',
                'platform', 'test', 'file']
# Docs that ship inside another module (INDEX: "vietqr.md — ships in payment-sdk").
EXTRA_DOCS = {'payment-sdk': ['vietqr']}
# Every doc stem INDEX scoping knows; extended at runtime with the source's own *.md (a new doc is never dangling).
ALL_MODULES = list(MODULE_ORDER) + ['vietqr']
COORD = re.compile(r'io\.f8a\.summer:(summer-[a-z0-9-]+)')
SKIP_DIRS = {'build', '.claude', '.gradle', '.git', '.idea', 'node_modules', 'out'}
META = '.summer-kb-meta.json'


def _extract():
    """The hub's dependency parser (scripts/index/extract.py of this plugin), so the KB's module set is exactly the
    set of lib edges the hub draws for this service. None when the skill runs outside the plugin tree."""
    d = os.path.join(os.path.dirname(os.path.realpath(__file__)), '..', '..', '..', 'scripts', 'index')
    if not os.path.isfile(os.path.join(d, 'extract.py')):
        return None
    sys.path.insert(0, os.path.abspath(d))
    sys.dont_write_bytecode = True  # never a __pycache__ inside the plugin
    try:
        import extract
        return extract
    except Exception:
        return None
    finally:
        sys.path.pop(0)


def build_texts(service):
    """{repo-relative path: text} of the dependency inputs: *.gradle(.kts), gradle.properties, gradle/*.versions.toml.
    .claude/ is skipped: agent worktrees under it are full repo copies (java-common-ms's settings.gradle excludes it
    for the same reason)."""
    texts = {}
    for root, dirs, files in os.walk(service):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for f in files:
            if not (f.endswith(('.gradle', '.gradle.kts', '.toml')) or f == 'gradle.properties'):
                continue
            try:
                txt = open(os.path.join(root, f), encoding='utf-8', errors='ignore').read()
            except OSError:
                continue
            texts[os.path.relpath(os.path.join(root, f), service).replace(os.sep, '/')] = txt
    return texts


def detect_artifacts(service):
    """summer-* artifacts the service declares, parsed like the hub's lib edges (extract.extract_deps: comments
    ignored, a version-catalog entry counts only where a build file references it, map-style group:/name: too).
    Without the plugin's parser: a plain coordinate grep."""
    texts = build_texts(service)
    ex = _extract()
    if ex is not None:
        return {d['artifact'] for d in ex.extract_deps(texts) if d.get('group') == 'io.f8a.summer'
                and d.get('artifact', '').startswith('summer-')}
    return {a for t in texts.values() for a in COORD.findall(t)}


def module_for(art, mod_docs):
    """artifact → KB module: the table, else the artifact minus summer- / -autoconfigure when the source has that doc."""
    if art in ARTIFACT_TO_MODULE:
        return ARTIFACT_TO_MODULE[art]
    m = re.sub(r'-autoconfigure$', '', art[len('summer-'):])
    return m if m in mod_docs else None


def load_json(path):
    try:
        with open(path, encoding='utf-8') as f:
            v = json.load(f)
        return v if isinstance(v, dict) else None
    except (OSError, ValueError):
        return None


def git_head(repo):
    if not os.path.exists(os.path.join(repo, '.git')):
        return None
    try:
        r = subprocess.run(['git', '-C', repo, 'rev-parse', '-q', '--verify', 'HEAD'], capture_output=True, text=True,
                           timeout=10, env=dict(os.environ, GIT_OPTIONAL_LOCKS='0'))
    except (OSError, subprocess.SubprocessError):
        return None
    h = r.stdout.strip()
    return h if r.returncode == 0 and re.fullmatch(r'[0-9a-f]{40,64}', h) else None


def resolve_source(service, skill_dir):
    """Return (source_dir, kind, library_dir). Prefer sibling java-common-ms, else the bundled snapshot."""
    d = os.path.abspath(service)
    for _ in range(8):  # walk up to workspace root
        lib = os.path.join(d, 'java-common-ms')
        cand = os.path.join(lib, '.claude', 'summer-kb')
        if os.path.isfile(os.path.join(cand, 'INDEX.md')):
            return cand, 'sibling', lib
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    return os.path.join(skill_dir, 'references', 'summer-kb'), 'bundled', None


def source_commit(src, kind, lib):
    """The source's summerCommit: the library repo's HEAD; without git, its stamp, then the UA graph's commit."""
    if kind == 'bundled':
        return (load_json(os.path.join(src, '.bundle-meta.json')) or {}).get('summerCommit')
    return git_head(lib) or (load_json(os.path.join(src, META)) or {}).get('summerCommit') \
        or (load_json(os.path.join(lib, '.understand-anything', 'meta.json')) or {}).get('gitCommitHash')


def module_docs(src):
    """module → its doc stems present in the source (a doc no module claims is a module of its own)."""
    stems = sorted(f[:-3] for f in os.listdir(src) if f.endswith('.md') and f not in ('INDEX.md', 'USAGE.md'))
    for st in stems:
        if st not in ALL_MODULES:
            ALL_MODULES.append(st)
    out, claimed = {}, set()
    for m in MODULE_ORDER:
        docs = [x for x in [m] + EXTRA_DOCS.get(m, []) if x in stems]
        claimed.update(docs)
        if docs:
            out[m] = docs
    for st in stems:
        if st not in claimed:
            out[st] = [st]
    return out


def write_if_changed(path, text):
    try:
        if open(path, encoding='utf-8').read() == text:
            return False
    except OSError:
        pass
    tmp = path + '.tmp.%d' % os.getpid()
    with open(tmp, 'w', encoding='utf-8') as f:
        f.write(text)
    os.replace(tmp, path)
    return True


def stamp_source(src, commit, docs, dry):
    """Write the source's own .summer-kb-meta.json (no timestamp: unchanged content is never rewritten)."""
    if not commit:
        return None
    doc = {'schema': 1, 'role': 'source', 'summerCommit': commit, 'includedModules': list(docs), 'modules': docs}
    text = json.dumps(doc, indent=2) + '\n'
    path = os.path.join(src, META)
    try:
        same = open(path, encoding='utf-8').read() == text
    except OSError:
        same = False
    if same:
        return 'current'
    if not dry:
        write_if_changed(path, text)
    return 'stamped'


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



def consumer_state(dest, commit, included, docs, if_stale):
    """→ (state, old meta). install: no KB yet · refresh: stale stamp, module set changed or a doc missing."""
    old = load_json(os.path.join(dest, META))
    if old is None:
        return 'install', None
    if not if_stale:
        return 'refresh', old
    if old.get('summerCommit') != commit or old.get('includedModules') != included:
        return 'refresh', old
    want = docs + ['INDEX', 'USAGE']
    if any(not os.path.isfile(os.path.join(dest, d + '.md')) for d in want):
        return 'refresh', old
    return 'up-to-date', old


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('service', nargs='?', default=os.getcwd())
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--if-stale', action='store_true')
    ap.add_argument('--skill-dir', default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    args = ap.parse_args()

    service = os.path.abspath(args.service)
    if not os.path.isdir(service):
        print(f"ERROR: service dir not found: {service}", file=sys.stderr)
        print("summer-kb: skip (error: no such directory)")
        return 2

    src, kind, lib = resolve_source(service, args.skill_dir)
    dest = os.path.join(service, '.claude', 'summer-kb')
    commit = source_commit(src, kind, lib)
    mod_docs = module_docs(src) if os.path.isdir(src) else {}

    # java-common-ms itself: the sibling source IS the destination. It installs nothing (the scoped INDEX would
    # overwrite the canonical one); it only keeps its own stamp in line with the library HEAD.
    if os.path.realpath(src) == os.path.realpath(dest):
        st = stamp_source(src, commit, mod_docs, args.dry_run)
        print(f"This service holds the canonical KB ({src}). Nothing installed.")
        if st is None:
            print("summer-kb: source (no commit to stamp)")
        else:
            print(f"summer-kb: source {'would be stamped' if args.dry_run and st == 'stamped' else st} "
                  f"summerCommit={commit[:7]}")
        return 0

    arts = detect_artifacts(service)
    if not arts:
        print(f"No io.f8a.summer:summer-* dependencies found under {service}.")
        print("This does not look like a Summer consumer service. Nothing installed.")
        print("(Checked *.gradle, *.gradle.kts, gradle.properties, *.toml, excluding build/ and .claude/; comments ignored.)")
        print("summer-kb: skip (not a Summer consumer)")
        return 1

    modules = {module_for(a, mod_docs) for a in arts} - {None}
    modules.add('core')  # base value types are always in play
    unknown = sorted(a for a in arts if module_for(a, mod_docs) is None)
    included = sorted(modules, key=lambda m: (MODULE_ORDER.index(m) if m in MODULE_ORDER else len(MODULE_ORDER), m))
    docs = [d for m in included for d in mod_docs.get(m, [])]

    # A sibling source stamp that lags the library HEAD is refreshed first (the only file outside this service
    # the script writes, and only the generated stamp).
    src_stamp = stamp_source(src, commit, mod_docs, args.dry_run) if kind == 'sibling' else None
    state, old = consumer_state(dest, commit, included, docs, args.if_stale)

    print(f"Service:   {service}")
    print(f"Detected:  {', '.join(sorted(arts))}")
    if unknown:
        print(f"Unknown artifacts (no module doc): {', '.join(unknown)}")
    print(f"Modules:   {', '.join(included)}  (docs: {', '.join(docs) or 'none'})")
    print(f"Source:    {kind}  ({src})  summerCommit={commit}" + (f"  [source stamp {src_stamp}]" if src_stamp else ''))
    print(f"Dest:      {dest}")
    word = {'install': 'installed', 'refresh': 'refreshed', 'up-to-date': 'up-to-date'}[state]
    if state == 'up-to-date':
        if not args.dry_run:  # mtime only: maintain.sh's "build file newer than the stamp" check stops firing
            try:
                os.utime(os.path.join(dest, META))
            except OSError:
                pass
        print(f"summer-kb: up-to-date summerCommit={(commit or 'unknown')[:7]}")
        return 0
    if args.dry_run:
        print("\n[dry-run] would write: " + ", ".join(d + '.md' for d in docs) + " + INDEX.md + USAGE.md"
              + ("" if os.path.exists(os.path.join(service, '.claude', 'rules', 'summer-kb.md'))
                 else " + .claude/rules/summer-kb.md"))
        print(f"summer-kb: would be {word} summerCommit={(commit or 'unknown')[:7]}")
        return 0

    os.makedirs(dest, exist_ok=True)
    written = []
    for d in docs:
        shutil.copyfile(os.path.join(src, d + '.md'), os.path.join(dest, d + '.md'))
        written.append(d + '.md')
    # Docs of modules this service no longer uses: only the ones the previous stamp says it installed.
    if old:
        prev = old.get('docs') if isinstance(old.get('docs'), list) else \
            [m for m in (old.get('includedModules') or []) if isinstance(m, str)]
        for d in prev:
            if isinstance(d, str) and re.fullmatch(r'[a-z0-9-]+', d) and d not in docs:
                f = os.path.join(dest, d + '.md')
                if os.path.isfile(f):
                    os.remove(f)
                    written.append(f'{d}.md (removed)')

    idx_src = os.path.join(src, 'INDEX.md')
    if os.path.isfile(idx_src):
        scoped = scope_index(open(idx_src, encoding='utf-8').read(), set(docs), arts)
        banner = (f"<!-- service-scoped install: {', '.join(included)} · source={kind} "
                  f"· summerCommit={commit} -->\n")
        write_if_changed(os.path.join(dest, 'INDEX.md'), banner + scoped)
        written.append('INDEX.md')
    usage_src = os.path.join(src, 'USAGE.md')
    if os.path.isfile(usage_src):
        write_if_changed(os.path.join(dest, 'USAGE.md'), localize_usage(open(usage_src, encoding='utf-8').read()))
        written.append('USAGE.md')

    # The always-on pointer: created when missing, never rewritten (it may carry the team's own edits).
    rules_dir = os.path.join(service, '.claude', 'rules')
    pointer = os.path.join(rules_dir, 'summer-kb.md')
    if not os.path.exists(pointer):
        os.makedirs(rules_dir, exist_ok=True)
        write_if_changed(pointer, LOCAL_POINTER)
        written.append('.claude/rules/summer-kb.md')

    stamp = {
        'source': kind, 'summerCommit': commit,
        'installedAt': datetime.datetime.now().isoformat(timespec='seconds'),
        'includedModules': included, 'docs': docs, 'detectedArtifacts': sorted(arts),
        'unknownArtifacts': unknown,
    }
    write_if_changed(os.path.join(dest, META), json.dumps(stamp, indent=2) + '\n')
    written.append(META)

    print("\nWritten (local, untracked — not committed):")
    for w in written:
        print(f"  .claude/summer-kb/{w}" if not w.startswith('.claude') else f"  {w}")
    print(f"\nDone. {len(docs)} module docs scoped to this service. Agents auto-load via .claude/rules/summer-kb.md.")
    print(f"summer-kb: {word} summerCommit={(commit or 'unknown')[:7]}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
