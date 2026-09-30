#!/usr/bin/env bash
# doclint.sh — structural lint + length budgets for ClaudeHut task artifacts (v0.12 M3, 06-artifact-standards.md).
#
# The schema is NOT hard-coded here: each kind's rules come from the `<!-- ch:schema … -->` block at the top of
# skills/*/references/<kind>-template.md (06 §5). Two rule kinds (ADR-D1): STRUCTURAL rules are "blocking"
# (claudehut-state set-* refuses on them — inside an opted-in task only); BUDGET rules are "advisory" (measured,
# printed, never fail).
#
# Usage:
#   doclint.sh [--json] [--advise] [--report] [--kind spec|plan|brainstorm|plan-review|task|context]
#              [--route light|full] [--profile P] [--language en|vi] [--state task.json] [--spec spec.md]
#              [--verdict APPROVE|REVISE] [--mode gate|advise|report] FILE [FILE...]
#   doclint.sh --self-test
#
#   default   one violation per line: `L<n> <blocking|advisory> <section>: <message>` then one `budget:` line.
#             exit 0 = no blocking violation, 1 = >=1 blocking violation, 2 = usage/template error.
#   --json    one JSON object per FILE (JSONL): {file,kind,profile,route,language,blocking:[..],advisory:[..],
#             budget:{..},words,verdict}. Same exit codes.
#   --advise  never fails (exit 0); prints at most ONE short line (for a hook's additionalContext); silent when
#             clean, when the kind is unknown or when the template is missing.
#   --report  prints the section | words | budget table (and over-cap cells); exit 0.
#   --mode    06 §6 spelling: gate = default, advise = --advise, report = --report.
#
# Kind is inferred from the file name (spec.md, plan.md, brainstorm.md, plan-review.md, task.md, context.md).
# profile/route: --profile/--route → --state task.json → artifact header (`profile:`/`route:`, legacy `type:`)
# → default (feature; route light for task.md, full otherwise). L1 compares the header with --state/--profile/
# --route and is skipped when none is given; given one, a profile:/route: key the template example declares but the
# header lacks is blocking too. L10 reads --spec or the sibling spec.md; no spec is blocking when --route/--state
# says full (the set-plan gate), advisory otherwise.
# language: --language → the plane's topology.json.language → its hub's hub.json.language → en (07 §4.1).
# language=vi multiplies every word budget (budget=W, total*, Col:Nw) by 1.4; Col:Nc byte caps stay as is (06 §10).
#
# Template lookup: $DOCLINT_TEMPLATES (colon-separated dirs; when set, ONLY these) else $ROOT/skills/*/references.
# The first <kind>-template.md that carries a ch:schema block wins.
#
# ch:schema grammar — the templates' own `<!-- ch:grammar … -->` comment is the reference; in short:
#   <!-- ch:schema kind=<kind> [total=N] [total.<profile|route>=N ...] [allow="H,H"]
#   [N. ]Heading | req=<p,p,..>|- | budget=W | diagram=required | cells=Col:Nw,Col:Nc | cols=C,C,..
#   ...
#   -->
#   - header: total.<profile> then total.<route> win over total. allow= (extension) = extra allowed H2 names.
#   - one row per H2 section, in document order; the artifact heading is "## " + "[N. ]Heading", compared
#     exactly after trimming spaces (a trailing <!-- comment --> is ignored). A "## " heading with no row is
#     rejected (L2); "### " subheadings are free. `req=` lists the profiles/routes that require the heading;
#     `req=-` = optional; no req = always required. budget = words of the section body (advisory, L3).
#     diagram=required → a mermaid block or a line "n/a — <reason, >=3 words>" in the section (blocking, L7).
#     cells = caps for every table column whose header is exactly Col, anywhere in the file (w = words,
#     c = UTF-8 bytes; advisory, L6). Lines starting with '#' inside the block are comments.
#   - table shape (extension): cols= when given, else the header of the template's first table under that
#     heading. Blocking for Tasks (Files stays the 3rd column for check-disjoint) and plan-review Findings (L11);
#     advisory L2 for every other section.
#   - legacy 06 §5 skeletons wrapped in ```markdown fences also contribute their "## " headings to the allowlist.
#
# "word" = whitespace token with >=1 letter or digit; `|`, `|---|` rows, mermaid bodies and <!-- --> are skipped.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "doclint: python3 missing" >&2; exit 2; }

PY=""
IFS= read -r -d '' PY <<'PYEOF' || true
import sys, os, re, json, glob, tempfile, shutil

ROOT = sys.argv[1]
ARGV = sys.argv[2:]
KINDS = ('spec', 'plan', 'brainstorm', 'plan-review', 'task', 'context')
VI_FACTOR = 1.4
AMEND_RE = re.compile(r'amend|round [0-9]|revision [0-9]', re.I)
FENCE_RE = re.compile(r'^\s*(```+|~~~+)\s*([A-Za-z0-9_+.-]*)')
HEAD_RE = re.compile(r'^(#{1,6})\s+(.*?)\s*#*\s*$')
SEP_RE = re.compile(r'^\s*\|?[\s:|-]+\|?\s*$')
MERMAID_OK = re.compile(r'^(flowchart|graph|sequenceDiagram|stateDiagram(-v2)?)\b')
NA_RE = re.compile(r'^\s*[>*_-]*\s*`?n/?a`?\s*(?:—|–|--|-|:)\s*(.+)$', re.I)
SEC_KEYS = {'req', 'budget', 'diagram', 'cells', 'cols'}

class Err(Exception):
    pass

# ---------------------------------------------------------------- text helpers
def words(s):
    s = re.sub(r'(?<!\\)\|', ' ', s)
    return sum(1 for t in s.split() if re.search(r'[^\W_]', t))

def norm_head(h):
    h = re.sub(r'<!--.*?-->', '', h)
    h = re.sub(r'^\s*(§\s*)?\d+(\.\d+)*[.)]?\s+', '', h)
    return re.sub(r'\s+', ' ', h).strip().strip('*').strip().lower()

def head_key(h):
    """schema/allowlist identity: the heading text, trailing <!-- comment --> dropped, spaces trimmed."""
    return re.sub(r'\s+', ' ', re.sub(r'<!--.*?-->', '', h)).strip()

def col_key(c):
    return re.sub(r'\s+', ' ', c).strip()

def col_base(c):
    c = c.replace('`', '')
    c = re.sub(r'\(.*$', '', c)
    return re.sub(r'\s+', ' ', c).strip().strip('*').strip().lower()

def split_row(line):
    s = line.strip()
    if s.startswith('|'):
        s = s[1:]
    if s.endswith('|') and not s.endswith('\\|'):
        s = s[:-1]
    cells, cur, tick, i = [], [], False, 0
    while i < len(s):
        ch = s[i]
        if ch == '\\' and i + 1 < len(s) and s[i + 1] == '|':
            cur.append('|'); i += 2; continue
        if ch == '`':
            tick = not tick
        if ch == '|' and not tick:
            cells.append(''.join(cur).strip()); cur = []
        else:
            cur.append(ch)
        i += 1
    cells.append(''.join(cur).strip())
    return cells

def sec_label(name):
    if name is None:
        return 'header'
    n = re.sub(r'<!--.*?-->', '', name).strip()
    m = re.match(r'^(\d+)[.)]\s+(.*)$', n)
    return ('§%s %s' % (m.group(1), m.group(2).strip())) if m else n

def fmt_budget(n, base, factor, unit=''):
    if factor != 1.0:
        return '%d%s/%d%s (%d×%s)' % (n, unit, round(base * factor), unit, base, ('%g' % factor).replace('.', ','))
    return '%d%s/%d%s' % (n, unit, base, unit)

# ---------------------------------------------------------------- document model
class Doc:
    def __init__(self, text):
        self.lines = text.split('\n')
        self.fences = []          # dicts: lang, start, end (1-based line nos), body lines
        self.heads = []           # (lineno, level, text)
        self.tables = []          # dicts: start, header, rows [(lineno, cells)], sec
        self.masked = []          # per line: text used for word counts ('' for skipped)
        self.in_fence = []
        self.unclosed = None
        self._parse()

    def _parse(self):
        L = self.lines
        fence = None
        in_comment = False
        tbl = None
        for i, raw in enumerate(L, 1):
            if fence is not None:
                m = FENCE_RE.match(raw)
                if m and m.group(1)[0] == fence['mark'][0] and len(m.group(1)) >= len(fence['mark']) and not m.group(2):
                    fence['end'] = i
                    self.fences.append(fence); fence = None
                    self.masked.append(''); self.in_fence.append(True)
                    continue
                fence['body'].append(raw)
                self.masked.append('' if fence['lang'] == 'mermaid' else raw)
                self.in_fence.append(True)
                continue
            m = FENCE_RE.match(raw)
            if m and not in_comment:
                if tbl: self.tables.append(tbl); tbl = None
                fence = {'mark': m.group(1), 'lang': m.group(2).lower(), 'start': i, 'end': None, 'body': []}
                self.masked.append(''); self.in_fence.append(True)
                continue
            self.in_fence.append(False)
            # strip html comments (possibly multi-line)
            out, s = [], raw
            while s:
                if in_comment:
                    j = s.find('-->')
                    if j < 0: s = ''; break
                    s = s[j + 3:]; in_comment = False
                else:
                    j = s.find('<!--')
                    if j < 0: out.append(s); break
                    out.append(s[:j]); s = s[j + 4:]; in_comment = True
            vis = ''.join(out)
            self.masked.append(vis)
            hm = HEAD_RE.match(vis) if vis.strip() else None
            if hm:
                if tbl: self.tables.append(tbl); tbl = None
                self.heads.append((i, len(hm.group(1)), hm.group(2).strip()))
                continue
            if vis.strip().startswith('|'):
                if tbl is None:
                    tbl = {'start': i, 'header': split_row(vis), 'rows': []}
                elif SEP_RE.match(vis) and '-' in vis:
                    pass
                else:
                    tbl['rows'].append((i, split_row(vis)))
            else:
                if tbl and vis.strip() == '' and not raw.strip().startswith('|'):
                    self.tables.append(tbl); tbl = None
                elif tbl and vis.strip():
                    self.tables.append(tbl); tbl = None
        if tbl: self.tables.append(tbl)
        if fence is not None:
            self.unclosed = fence
            self.fences.append(fence)
        # sections: H2 boundaries
        h2 = [(ln, t) for (ln, lv, t) in self.heads if lv == 2]
        self.sections = []   # (name|None, start, end) inclusive ranges, heading line excluded
        prev_ln, prev_name = 0, None
        for ln, t in h2:
            self.sections.append((prev_name, prev_ln + 1, ln - 1))
            prev_ln, prev_name = ln, t
        self.sections.append((prev_name, prev_ln + 1, len(L)))
        for t in self.tables:
            t['sec'] = self.section_of(t['start'])
        for f in self.fences:
            f['sec'] = self.section_of(f['start'])

    def section_of(self, ln):
        for name, s, e in self.sections:
            if s - 1 <= ln <= e:
                return name
        return None

    def sec_words(self, name_start, name_end):
        return sum(words(self.masked[i - 1]) for i in range(name_start, name_end + 1))

    def meta(self):
        """header metadata from `>` lines before the first H2 (and `key: value` lines)."""
        first_h2 = next((ln for (ln, lv, t) in self.heads if lv == 2), len(self.lines) + 1)
        md = {}
        for i in range(1, first_h2):
            if self.in_fence[i - 1]:
                continue
            s = self.masked[i - 1].strip()
            if not s.startswith('>'):
                continue
            for seg in re.split(r'\s[·|]\s|\s·|·\s', s.lstrip('> ').strip()):
                m = re.match(r'^\**\s*([A-Za-z][\w-]*)\s*\**\s*:\s*\**\s*(.+?)\s*\**\s*$', seg.strip())
                if m and m.group(1).lower() not in md:
                    md[m.group(1).lower()] = m.group(2).strip().strip('`')
        return md

# ---------------------------------------------------------------- template / schema
_TPL_CACHE = {}

def template_dirs():
    env = os.environ.get('DOCLINT_TEMPLATES')
    if env:
        return [d for d in env.split(':') if d]
    return sorted(glob.glob(os.path.join(ROOT, 'skills', '*', 'references')))

def find_template(kind):
    for d in template_dirs():
        p = os.path.join(d, kind + '-template.md')
        if os.path.isfile(p):
            try:
                txt = open(p, encoding='utf-8').read()
            except OSError:
                continue
            if re.search(r'<!--\s*ch:schema\b', txt):
                return p
    return None

def parse_kv(s):
    out = {}
    for m in re.finditer(r'([\w.-]+)=("([^"]*)"|\S+)', s):
        out[m.group(1)] = m.group(3) if m.group(3) is not None else m.group(2)
    return out

def parse_caps(v, where):
    caps = {}
    for part in v.split(','):
        part = part.strip()
        if not part:
            continue
        m = re.match(r'^(.+):(\d+)\s*(w|c)$', part)
        if not m:
            raise Err('%s: bad cap %r (want Col:Nw or Col:Nc)' % (where, part))
        caps[col_key(m.group(1))] = (m.group(1).strip(), int(m.group(2)), m.group(3))
    return caps

def load_schema(kind):
    if kind in _TPL_CACHE:
        return _TPL_CACHE[kind]
    p = find_template(kind)
    if not p:
        _TPL_CACHE[kind] = None
        return None
    txt = open(p, encoding='utf-8').read()
    m = re.search(r'<!--\s*ch:schema\b(.*?)-->', txt, re.S)
    body = m.group(1)
    lines = body.split('\n')
    head = parse_kv(lines[0])
    sch = {'path': p, 'kind': head.get('kind', kind), 'totals': {}, 'sections': [], 'allow': set(),
           'skeleton_cols': {}, 'warnings': []}
    for k, v in head.items():
        if k == 'total' or k.startswith('total.'):
            if not v.isdigit():
                raise Err('%s: %s=%r is not an integer' % (p, k, v))
            sch['totals'][k] = int(v)
        elif k == 'allow':
            sch['allow'] |= {head_key(x) for x in v.split(',') if x.strip()}
        elif k != 'kind':
            sch['warnings'].append('unknown header key %r' % k)
    for ln in lines[1:]:
        s = ln.strip()
        if not s or s.startswith('#'):
            continue
        parts = [x.strip() for x in s.split('|')]
        sec = {'name': parts[0], 'key': head_key(parts[0]), 'req': None, 'budget': None,
               'diagram': False, 'cells': {}, 'cols': None}
        for part in parts[1:]:
            if '=' not in part:
                sch['warnings'].append('%s: property %r has no "="' % (parts[0], part)); continue
            k, v = part.split('=', 1); k = k.strip(); v = v.strip()
            if k not in SEC_KEYS:
                sch['warnings'].append('%s: unknown key %r' % (parts[0], k)); continue
            if k == 'req':
                sec['req'] = [] if v.startswith('-') else [x.strip().lower() for x in v.split(',') if x.strip()]
            elif k == 'budget':
                mm = re.match(r'^(\d+)', v)
                if not mm: raise Err('%s: %s budget=%r' % (p, parts[0], v))
                sec['budget'] = int(mm.group(1))
            elif k == 'diagram':
                sec['diagram'] = v.lower().startswith('required')
            elif k == 'cells':
                sec['cells'] = parse_caps(v, '%s: %s' % (p, parts[0]))
            elif k == 'cols':
                sec['cols'] = [x.strip() for x in v.split(',') if x.strip()]
        sch['sections'].append(sec)
    # skeleton: ```markdown fences of the template, else the body after the schema block
    rest = txt[:m.start()] + txt[m.end():]
    fenced = re.findall(r'^```+\s*markdown\s*\n(.*?)^```+\s*$', rest, re.S | re.M)
    skel = '\n'.join(fenced) if fenced else txt[m.end():]
    cur = None
    for sl in skel.split('\n'):
        vis = re.sub(r'<!--.*?-->', '', sl)
        hm = HEAD_RE.match(vis) if vis.strip() else None
        if hm and len(hm.group(1)) == 2:
            cur = head_key(hm.group(2))
            if fenced:
                sch['allow'].add(cur)
            continue
        if hm:
            continue
        if cur and vis.strip().startswith('|') and cur not in sch['skeleton_cols'] and not SEP_RE.match(vis):
            sch['skeleton_cols'][cur] = [c for c in split_row(vis)]
    sch['allow'] |= {s['key'] for s in sch['sections']}
    # header keys the example declares (L1: an artifact of this kind must declare them too) — the first `>` line
    # after a "# " title and before any "## ", fenced skeleton or not
    sch['hdr_keys'] = set()
    h1 = False
    for x in txt[m.end():].split('\n'):
        if x.startswith('# '):
            h1 = True
        elif h1 and x.startswith('## '):
            break
        elif h1 and x.startswith('>'):
            sch['hdr_keys'] = set(Doc(x).meta()) & {'profile', 'route'}
            break
    _TPL_CACHE[kind] = sch
    return sch

# ---------------------------------------------------------------- context resolution
def infer_kind(path):
    b = os.path.basename(path).lower()
    b = re.sub(r'\.md$', '', b)
    return b if b in KINDS else None

def read_json(p):
    try:
        with open(p, encoding='utf-8') as f:
            return json.load(f)
    except (OSError, ValueError):
        return None

def resolve_language(path):
    d = os.path.dirname(os.path.abspath(path))
    for _ in range(8):
        tp = os.path.join(d, 'topology.json')
        if os.path.isfile(tp):
            t = read_json(tp) or {}
            if t.get('language') in ('en', 'vi'):
                return t['language']
            hub = t.get('hub') or os.environ.get('CLAUDEHUT_HUB')
            if hub:
                hp = hub if os.path.isabs(hub) else os.path.join(d, hub)
                cand = hp if hp.endswith('.json') else os.path.join(hp, 'hub.json')
                h = read_json(cand) or {}
                if h.get('language') in ('en', 'vi'):
                    return h['language']
            return 'en'
        if os.path.basename(d) == 'claudehut' and os.path.basename(os.path.dirname(d)) == '.claude':
            break
        nd = os.path.dirname(d)
        if nd == d:
            break
        d = nd
    return 'en'

LEGACY_TYPE = {'feature': 'feature', 'refactor': 'feature', 'bugfix': 'bugfix', 'bug': 'bugfix',
               'migration': 'migration'}

def first_word(v):
    m = re.match(r'^\s*([A-Za-z-]+)', v or '')
    return m.group(1).lower() if m else None

# ---------------------------------------------------------------- the linter
def lint(path, opts):
    kind = opts.get('kind') or infer_kind(path)
    res = {'file': path, 'kind': kind, 'blocking': [], 'advisory': [], 'budget': {}, 'words': 0,
           'profile': None, 'route': None, 'language': None, 'verdict': None, 'template': None}
    if kind not in KINDS:
        raise Err('%s: cannot infer kind (use --kind)' % path)
    try:
        text = open(path, encoding='utf-8', errors='replace').read()
    except OSError as e:
        raise Err('%s: %s' % (path, e.strerror))
    doc = Doc(text)
    md = doc.meta()
    sch = load_schema(kind)
    if sch is None and kind != 'context':
        raise Err('no %s-template.md with a ch:schema block in %s' % (kind, ':'.join(template_dirs()) or '(none)'))
    res['template'] = sch['path'] if sch else None

    def B(rule, ln, sec, msg):
        res['blocking'].append({'rule': rule, 'line': ln, 'section': sec, 'msg': msg})

    def A(rule, ln, sec, msg):
        res['advisory'].append({'rule': rule, 'line': ln, 'section': sec, 'msg': msg})

    # profile / route / language
    state = read_json(opts['state']) if opts.get('state') else None
    auth_p = opts.get('profile') or (state or {}).get('profile')
    auth_r = opts.get('route') or (state or {}).get('route')
    hdr_p = first_word(md.get('profile'))
    hdr_r = first_word(md.get('route'))
    legacy = LEGACY_TYPE.get(first_word(md.get('type')) or '')
    profile = auth_p or hdr_p or legacy or 'feature'
    route = auth_r or hdr_r or ('light' if kind == 'task' else 'full')
    lang = opts.get('language') or resolve_language(path)
    factor = VI_FACTOR if lang == 'vi' else 1.0
    res.update(profile=profile, route=route, language=lang)

    # L1 — header vs task.json (only when an authoritative value is given). A key the kind's template example
    # declares but this header lacks does not match either (the set-* gate always passes --route/--profile).
    hkeys = (sch or {}).get('hdr_keys', set())
    for key, auth, hdr in (('profile', auth_p, hdr_p), ('route', auth_r, hdr_r)):
        if not auth:
            continue
        src = '--' + key if opts.get(key) else 'task.json'
        if hdr is None and key in hkeys and not (key == 'profile' and legacy):
            B('L1', None, 'header', 'no %s: — add "%s: %s" to the header line' % (key, key, auth.lower()))
        elif hdr and hdr != auth.lower():
            B('L1', None, 'header', '%s: %s but expected %s (from %s)' % (key, hdr, auth, src))

    # L2 — forbidden amendment headings (any level)
    for ln, lv, t in doc.heads:
        if AMEND_RE.search(t):
            B('L2', ln, sec_label(t) if lv == 2 else 'heading',
              'forbidden heading "%s" — revise in place: bump rev, add a Changelog line' % t.strip())

    words_total = sum(words(x) for x in doc.masked)
    res['words'] = words_total
    bsec = {}
    if sch:
        by_key = {s['key']: (i, s) for i, s in enumerate(sch['sections'])}
        present = {}
        order = []
        for ln, lv, t in doc.heads:
            if lv != 2:
                continue
            k = head_key(t)
            if k in present:
                B('L2', ln, sec_label(t), 'duplicate heading "## %s"' % t)
                continue
            present[k] = ln
            if k in by_key:
                order.append((by_key[k][0], ln, t))
            elif sch['allow'] and k not in sch['allow'] and not AMEND_RE.search(t):
                allow = [s['name'] for s in sch['sections']] + sorted(
                    a for a in sch['allow'] if a not in by_key)
                B('L2', ln, sec_label(t), 'heading "## %s" not in allowlist: %s' % (t, ', '.join(allow)))
        for a, b in zip(order, order[1:]):
            if b[0] < a[0]:
                B('L2', b[1], sec_label(b[2]), 'heading "## %s" out of order (template order: %s)'
                  % (b[2], ' → '.join(s['name'] for s in sch['sections'])))
        for s in sch['sections']:
            req = s['req']
            need = (req is None) or (profile in req) or (route in req)
            if need and s['key'] not in present:
                B('L2', None, sec_label(s['name']), 'missing required heading "## %s" (profile=%s, route=%s)'
                  % (s['name'], profile, route))
        try:
            rev = int(re.match(r'\d+', md.get('rev', '1')).group(0))
        except (AttributeError, ValueError):
            rev = 1
        if rev > 1 and not any(norm_head(k) == 'changelog' for k in present):
            B('L2', None, 'Changelog', 'rev: %d needs a "## Changelog" line per revision' % rev)

        # section words / budgets (L3)
        for name, s_, e_ in doc.sections:
            if name is None:
                continue
            k = head_key(name)
            w = doc.sec_words(s_, e_)
            ent = {'words': w, 'factor': factor}
            if k in by_key and by_key[k][1]['budget']:
                base = by_key[k][1]['budget']
                ent.update(budget=round(base * factor), base=base)
                if w > round(base * factor):
                    A('L3', s_ - 1, sec_label(name), 'section %s (budget)' % fmt_budget(w, base, factor))
            bsec[sec_label(name)] = ent
        # total (L4)
        tk = None
        for key in ('total.' + profile, 'total.' + route, 'total'):
            if key in sch['totals']:
                tk = key; break
        if tk:
            base = sch['totals'][tk]
            res['budget']['total'] = {'words': words_total, 'budget': round(base * factor), 'base': base,
                                      'factor': factor, 'key': tk}
            if words_total > round(base * factor):
                A('L4', None, 'total', 'total %s (budget %s)' % (fmt_budget(words_total, base, factor), tk))
        else:
            res['budget']['total'] = {'words': words_total}
        res['budget']['sections'] = bsec

        # table shape (L2 / L11) from cols= or skeleton header
        for s in sch['sections']:
            want = s['cols'] or sch['skeleton_cols'].get(s['key'])
            if not want and kind == 'plan-review' and s['key'] == 'findings':
                want = ['ID', 'Sev', 'Locus', 'Gap', 'Fix']
            if not want:
                continue
            rule = 'L11' if kind == 'plan-review' else 'L2'
            for t in doc.tables:
                if t['sec'] is None or head_key(t['sec']) != s['key']:
                    continue
                got = [col_key(c) for c in t['header']]
                exp = [col_key(c) for c in want]
                if got != exp:
                    # blocking only where a consumer parses the columns: Tasks (check-disjoint reads Files as
                    # field $4) and plan-review Findings (L11); elsewhere the template shape is advisory.
                    hard = rule == 'L11' or norm_head(s['key']) == 'tasks'
                    (B if hard else A)(rule, t['start'], sec_label(t['sec']), 'table columns | %s | — expected | %s |'
                      % (' | '.join(t['header']), ' | '.join(want)))

        # cell caps (L6): section-scoped caps first, else by column name anywhere in the file
        glob_caps = {}
        for s in sch['sections']:
            for ck, cv in s['cells'].items():
                glob_caps.setdefault(ck, cv)
        for t in doc.tables:
            skey = head_key(t['sec']) if t['sec'] else None
            scaps = by_key[skey][1]['cells'] if skey in by_key else {}
            cols = [col_key(c) for c in t['header']]
            for ln, cells in t['rows']:
                for ci, cell in enumerate(cells):
                    if ci >= len(cols):
                        break
                    cap = scaps.get(cols[ci]) or glob_caps.get(cols[ci])
                    if not cap:
                        continue
                    cname, n, unit = cap
                    cname = re.sub(r'\s*\(.*$', '', cname)
                    if unit == 'w':
                        got, lim = words(cell), round(n * factor)
                        if got > lim:
                            A('L6', ln, sec_label(t['sec']), 'cell %s — %s (budget)'
                              % (cname, fmt_budget(got, n, factor, 'w')))
                    else:
                        got = len(cell.encode('utf-8'))
                        if got > n:
                            A('L6', ln, sec_label(t['sec']), 'cell %s — %dc/%dc (budget)%s' % (
                                cname, got, n, '' if got == len(cell) else ' · %d chars' % len(cell)))

        # L7 — diagram=required
        for s in sch['sections']:
            if not s['diagram'] or s['key'] not in present:
                continue
            rng = next(((a, b) for (nm, a, b) in doc.sections if nm and head_key(nm) == s['key']), None)
            has_m = any(f['lang'] == 'mermaid' and f['sec'] and head_key(f['sec']) == s['key']
                        for f in doc.fences)
            has_na = False
            if rng:
                for i in range(rng[0], rng[1] + 1):
                    if doc.in_fence[i - 1]:
                        continue
                    mm = NA_RE.match(doc.masked[i - 1])
                    if mm and words(mm.group(1)) >= 3:
                        has_na = True; break
            if not (has_m or has_na):
                B('L7', present[s['key']], sec_label(s['name']),
                  'needs a ```mermaid diagram or a line "n/a — <reason, >=3 words>"')

    # L5 — fences (all kinds)
    for f in doc.fences:
        sec = sec_label(f['sec'])
        if f is doc.unclosed:
            B('L5', f['start'], sec, 'unclosed ``` fence')
            continue
        if f['lang'] in ('java', 'kotlin', 'kt'):
            B('L5', f['start'], sec, '```%s fence — code belongs in the implementation, not the %s' % (f['lang'], kind))
        elif f['lang'] == 'mermaid':
            first = next((x.strip() for x in f['body'] if x.strip() and not x.strip().startswith('%%')), '')
            if not MERMAID_OK.match(first):
                B('L5', f['start'], sec, 'mermaid must start with flowchart|graph|sequenceDiagram|stateDiagram(-v2), got "%s"' % first[:40])
        elif len(f['body']) > 12:
            B('L5', f['start'], sec, '```%s fence has %d lines (max 12)' % (f['lang'] or '', len(f['body'])))

    # L8 — [NEEDS CLARIFICATION]
    marks = []
    for i, x in enumerate(doc.masked, 1):
        for _ in re.finditer(r'\[NEEDS CLARIFICATION', x):
            marks.append(i)
    if len(marks) > 3:
        B('L8', marks[0], 'header', '%d [NEEDS CLARIFICATION] markers (max 3)' % len(marks))
    for ln in marks:
        sec = doc.section_of(ln)
        if sec and norm_head(sec) == 'open questions' and 'non-blocking' in doc.lines[ln - 1].lower():
            continue
        B('L8', ln, sec_label(sec), 'open [NEEDS CLARIFICATION] — resolve it or tag it non-blocking in Open Questions')

    # L9 — Decisions table
    for t in doc.tables:
        if not t['sec'] or norm_head(t['sec']) != 'decisions' or not t['rows']:
            continue
        cols = [col_base(c) for c in t['header']]
        if 'id' not in cols:
            continue
        ic = cols.index('id')
        if 'status' not in cols:
            B('L9', t['start'], sec_label(t['sec']), 'Decisions table has no Status column')
            continue
        sc = cols.index('status')
        ids = [(ln, c[ic].strip('*` ')) for ln, c in t['rows'] if len(c) > ic]
        seen = set()
        for ln, i_ in ids:
            if i_ in seen:
                B('L9', ln, sec_label(t['sec']), 'duplicate decision ID %s' % i_)
            seen.add(i_)
        for ln, c in t['rows']:
            st = (c[sc] if len(c) > sc else '').strip('*` ').strip()
            m = re.match(r'^superseded-by\s+(D-\d+)$', st, re.I)
            if st.lower() == 'accepted':
                continue
            if m:
                if m.group(1) not in seen:
                    B('L9', ln, sec_label(t['sec']), 'superseded-by %s — no such decision' % m.group(1))
                continue
            B('L9', ln, sec_label(t['sec']), 'Status "%s" — want accepted | superseded-by D-k' % st)

    # L10 — plan ↔ spec
    if kind == 'plan':
        sp = opts.get('spec') or os.path.join(os.path.dirname(path), 'spec.md')
        if not os.path.isfile(sp):
            # gate mode (a route from --route/--state, i.e. claudehut-state set-plan): the full route's plan must
            # be checked against its spec; standalone runs only note it.
            if auth_r and auth_r.lower() == 'full':
                B('L10', None, 'header', 'no spec to check coverage against at %s — record the spec first (set-spec)' % rel_art(sp))
            else:
                A('L10', None, 'header', 'coverage not checked — no spec at %s (pass --spec)' % rel_art(sp))
        else:
            stext = open(sp, encoding='utf-8', errors='replace').read()
            sdoc = Doc(stext)
            smd = sdoc.meta()
            mrev = re.match(r'\d+', smd.get('rev', '1'))
            srev = int(mrev.group(0)) if mrev else 1
            prev = md.get('spec-rev')
            if prev is None:
                B('L10', None, 'header', 'plan header has no spec-rev (spec is rev %d)' % srev)
            else:
                mm = re.match(r'\d+', prev)
                if not mm or int(mm.group(0)) != srev:
                    B('L10', None, 'header', 'spec-rev: %s but spec is rev %d — re-plan against the current spec' % (prev, srev))
            sids = set(re.findall(r'\bAC-\d+\b', '\n'.join(sdoc.masked)))
            dids = set(re.findall(r'\bD-\d+\b', '\n'.join(sdoc.masked)))
            reqs = set()
            has_req = False
            for t in doc.tables:
                cols = [col_base(c) for c in t['header']]
                if 'req' not in cols:
                    continue
                has_req = True
                rc = cols.index('req')
                for ln, c in t['rows']:
                    if len(c) > rc:
                        for rid in re.findall(r'\b(?:AC|D)-\d+\b', c[rc]):
                            reqs.add(rid)
                            if rid not in sids and rid not in dids:
                                B('L10', ln, sec_label(t['sec']), 'Req %s does not exist in the spec' % rid)
            missing = sorted(sids - reqs)
            if missing:
                B('L10', None, 'Req', '%s not covered by any Req cell%s' % (
                    ', '.join(missing[:10]) + (' …' if len(missing) > 10 else ''),
                    '' if has_req else ' (plan has no Req column)'))

    # L11 — plan-review verdict
    if kind == 'plan-review':
        vl = [(i, x) for i, x in enumerate(doc.masked, 1)
              if not doc.in_fence[i - 1] and re.match(r'^\s*\**\s*Verdict\s*\**\s*:', x)]
        if len(vl) != 1:
            B('L11', vl[1][0] if len(vl) > 1 else None, 'header', 'want exactly one "Verdict:" line, found %d' % len(vl))
        if vl:
            v = re.sub(r'^\s*\**\s*Verdict\s*\**\s*:\s*', '', vl[0][1]).strip().strip('*` ').strip()
            if v in ('APPROVE', 'REVISE'):
                res['verdict'] = v
            else:
                B('L11', vl[0][0], 'header', 'Verdict "%s" — want APPROVE or REVISE' % v)
        if opts.get('verdict') and res['verdict'] and opts['verdict'].upper() != res['verdict']:
            B('L11', vl[0][0], 'header', 'file says Verdict: %s but the command says %s' % (res['verdict'], opts['verdict']))
        for t in doc.tables:
            if not t['sec'] or norm_head(t['sec']) != 'findings':
                continue
            cols = [col_base(c) for c in t['header']]
            if 'sev' in cols:
                sc = cols.index('sev')
                for ln, c in t['rows']:
                    sv = (c[sc] if len(c) > sc else '').strip('*` ')
                    if sv not in ('CRIT', 'HIGH', 'MED'):
                        B('L11', ln, 'Findings', 'Sev "%s" — want CRIT | HIGH | MED' % sv)
            if len(t['rows']) > 10:
                A('L11', t['start'], 'Findings', '%d findings rows (budget 10)' % len(t['rows']))
    res['blocking'].sort(key=lambda v: (v['line'] or 0))
    res['advisory'].sort(key=lambda v: (v['line'] or 0))
    return res

# ---------------------------------------------------------------- output
def vline(v, sev):
    tail = (' [line %d]' % v['line']) if v['line'] else ''
    return '%s %s %s: %s%s' % (v['rule'], sev, v['section'], v['msg'], tail)

def budget_line(r):
    t = r['budget'].get('total', {})
    parts = []
    if 'base' in t:
        parts.append('total ' + fmt_budget(t['words'], t['base'], t['factor']))
    else:
        parts.append('total %dw' % r['words'])
    for k, e in r['budget'].get('sections', {}).items():
        if 'base' in e:
            parts.append('%s %s' % (k, fmt_budget(e['words'], e['base'], e['factor'])))
    return 'budget: ' + ' · '.join(parts)

def report(r):
    out = ['%s (%s, profile=%s, route=%s, language=%s)' % (r['file'], r['kind'], r['profile'], r['route'], r['language']),
           '| Section | Words | Budget |', '|---|---|---|']
    for k, e in r['budget'].get('sections', {}).items():
        out.append('| %s | %d | %s |' % (k, e['words'], e.get('budget', '—')))
    t = r['budget'].get('total', {})
    if 'base' in t:
        out.append('| total | %s | %s |' % (fmt_budget(t['words'], t['base'], t['factor']), t['key']))
    else:
        out.append('| total | %d | — |' % r['words'])
    for v in r['advisory']:
        if v['rule'] in ('L6', 'L11'):
            out.append(vline(v, 'advisory'))
    return '\n'.join(out)

def rel_art(p):
    """a path from its .claude/claudehut/ segment on (project-relative); else p"""
    i = p.find('.claude/claudehut/')
    return p[i:] if i >= 0 else p

def shorten(s, n):
    """cut at a word boundary with an ellipsis"""
    if len(s) <= n:
        return s
    cut = s[:n].rsplit(' ', 1)[0].rstrip(' ,;:—-')
    return (cut or s[:n]) + '…'

def advise(r):
    nb, na = len(r['blocking']), len(r['advisory'])
    if not nb and not na:
        return None
    lst = r['blocking'] if nb else r['advisory']
    det = '; '.join('%s %s: %s' % (v['rule'], v['section'], shorten(v['msg'], 90)) for v in lst[:2])
    return '%s%s — %d blocking, %d advisory in %s' % (
        det, '; …' if len(lst) > 2 else '', nb, na, os.path.basename(r['file']))

# ---------------------------------------------------------------- self-test
ST_SPEC_TPL = '''<!-- ch:schema kind=spec total.feature=120 total.bugfix=60
1. Context           | req=feature,bugfix | budget=20
2. Requirements      | req=feature,bugfix | cells=Requirement (EARS):8w,Acceptance (GWT):10w
3. Flow              | req=feature        | budget=30 | diagram=required
4. Decisions         | req=feature,bugfix | cells=Decision (Y-statement):6w
5. Open Questions    | req=-
-->
```markdown
# Spec: <title>
> id: <id> · profile: feature · route: full · rev: 1
## 1. Context
## 2. Requirements
| ID | Requirement (EARS) | Acceptance (GWT) |
## 3. Flow
## 4. Decisions
| ID | Decision (Y-statement) | Rejected options | Confirmation | Status |
## 5. Open Questions
## Changelog
```
'''
ST_PLAN_TPL = '''<!-- ch:schema kind=plan total.full=200
1. Approach | req=full | budget=30
2. Tasks    | req=full | cells=Goal:5w,Test first:20c
-->
```markdown
## 1. Approach
## 2. Tasks
| ID | Goal | Files | Test first | Verify | Depends | Req |
## Changelog
```
'''
ST_PR_TPL = '''<!-- ch:schema kind=plan-review total=100
Findings | cells=Gap:5w,Fix:5w
-->
```markdown
Verdict: APPROVE|REVISE
## Findings
| ID | Sev | Locus | Gap | Fix |
## Notes
```
'''
ST_GOOD_SPEC = '''# Spec: t
> id: 0001-t · profile: feature · route: full · rev: 1 · status: draft

## 1. Context
Small context line.

## 2. Requirements
| ID | Requirement (EARS) | Acceptance (GWT) |
|---|---|---|
| AC-001 | WHEN x THE SYSTEM SHALL y | GIVEN a WHEN b THEN c |

## 3. Flow
```mermaid
sequenceDiagram
  A->>B: go
```

## 4. Decisions
| ID | Decision (Y-statement) | Rejected options | Confirmation | Status |
|---|---|---|---|---|
| D-1 | use x | y | test | accepted |

## 5. Open Questions
- [NEEDS CLARIFICATION: later] non-blocking, owner: po
'''

def self_test():
    tmp = tempfile.mkdtemp(prefix='doclint-st.')
    fails = []
    try:
        td = os.path.join(tmp, 'tpl'); os.makedirs(td)
        for k, v in (('spec', ST_SPEC_TPL), ('plan', ST_PLAN_TPL), ('plan-review', ST_PR_TPL)):
            open(os.path.join(td, k + '-template.md'), 'w').write(v)
        os.environ['DOCLINT_TEMPLATES'] = td
        _TPL_CACHE.clear()
        tdir = os.path.join(tmp, 'tasks', '0001-t'); os.makedirs(tdir)

        def run(name, text, opts=None, kind=None):
            p = os.path.join(tdir, name)
            open(p, 'w').write(text)
            o = dict(opts or {}); o.setdefault('language', 'en')
            if kind: o['kind'] = kind
            return lint(p, o)

        def rules(r, sev):
            return {v['rule'] for v in r[sev]}

        def expect(label, r, sev, rule, present=True):
            if (rule in rules(r, sev)) != present:
                fails.append('%s: expected %s %s %s; got blocking=%s advisory=%s' % (
                    label, rule, sev, 'present' if present else 'absent',
                    [vline(v, 'b') for v in r['blocking']], [vline(v, 'a') for v in r['advisory']]))

        g = run('spec.md', ST_GOOD_SPEC)
        if g['blocking'] or g['advisory']:
            fails.append('good spec not clean: %s %s' % (g['blocking'], g['advisory']))
        expect('L1', run('spec.md', ST_GOOD_SPEC, {'profile': 'bugfix'}), 'blocking', 'L1')
        nop = ST_GOOD_SPEC.replace(' · profile: feature', '')
        expect('L1 missing key (gate)', run('spec.md', nop, {'profile': 'bugfix'}), 'blocking', 'L1')
        expect('L1 missing key (standalone)', run('spec.md', nop), 'blocking', 'L1', False)
        expect('L2 amend', run('spec.md', ST_GOOD_SPEC + '\n## Amendment 2\nx\n'), 'blocking', 'L2')
        expect('L2 missing', run('spec.md', ST_GOOD_SPEC.replace('## 1. Context', '## Background')), 'blocking', 'L2')
        expect('L3', run('spec.md', ST_GOOD_SPEC.replace('Small context line.', 'word ' * 25)), 'advisory', 'L3')
        expect('L4', run('spec.md', ST_GOOD_SPEC + '\n' + 'filler ' * 150), 'advisory', 'L4')
        expect('L5 java', run('spec.md', ST_GOOD_SPEC + '\n```java\nclass A {}\n```\n'), 'blocking', 'L5')
        expect('L6', run('spec.md', ST_GOOD_SPEC.replace('| use x |', '| ' + 'w ' * 9 + '|')), 'advisory', 'L6')
        expect('L7', run('spec.md', re.sub(r'```mermaid.*?```\n', 'prose only\n', ST_GOOD_SPEC, flags=re.S)), 'blocking', 'L7')
        expect('L7 n/a', run('spec.md', re.sub(r'```mermaid.*?```\n', 'n/a — single service no flow\n', ST_GOOD_SPEC, flags=re.S)), 'blocking', 'L7', False)
        expect('L8', run('spec.md', ST_GOOD_SPEC.replace('Small context line.', '[NEEDS CLARIFICATION: who]')), 'blocking', 'L8')
        expect('L9', run('spec.md', ST_GOOD_SPEC.replace('| accepted |', '| superseded-by D-9 |')), 'blocking', 'L9')
        plan = ('# Plan: t\n> id: 0001-t · spec-rev: 1 · route: full · rev: 1 · status: draft\n\n## 1. Approach\nreuse D-1.\n\n'
                '## 2. Tasks\n| ID | Goal | Files | Test first | Verify | Depends | Req |\n|---|---|---|---|---|---|---|\n'
                '| T1 | do it | a.java | FooTest#bar | gradle | - | AC-001 |\n')
        expect('plan good', run('plan.md', plan), 'blocking', 'L10', False)
        expect('L10 rev', run('plan.md', plan.replace('spec-rev: 1', 'spec-rev: 2')), 'blocking', 'L10')
        expect('L10 cov', run('plan.md', plan.replace('| AC-001 |', '| D-1 |')), 'blocking', 'L10')
        nosp = {'spec': os.path.join(tmp, 'none', 'spec.md')}
        expect('L10 no spec (standalone)', run('plan.md', plan, nosp), 'blocking', 'L10', False)
        expect('L10 no spec (gate, full)', run('plan.md', plan, dict(nosp, route='full')), 'blocking', 'L10')
        adv = advise(run('plan.md', plan + '\n```java\nclass A {}\n```\n', dict(nosp, route='full')))
        # rule id first, no absolute path, no command hint (the planner has no Bash), ends with the file's base name
        if (not adv or not adv.startswith('L') or tmp in adv or '\n' in adv or 'doclint.sh' in adv
                or not adv.endswith(' in plan.md')):
            fails.append('advise line: %r' % adv)
        if shorten('alpha beta gamma', 12) != 'alpha beta…':
            fails.append('shorten: %r' % shorten('alpha beta gamma', 12))
        pr = '# Plan review\n> id: 0001-t · plan-rev: 1 · round: 1\nVerdict: APPROVE\n\n## Findings\n| ID | Sev | Locus | Gap | Fix |\n|---|---|---|---|---|\n\n## Notes\nnone\n'
        r = run('plan-review.md', pr)
        if r['blocking'] or r['verdict'] != 'APPROVE':
            fails.append('good plan-review not clean: %s' % r['blocking'])
        expect('L11', run('plan-review.md', pr + '\nVerdict: REVISE\n'), 'blocking', 'L11')
        expect('L11 param', run('plan-review.md', pr, {'verdict': 'REVISE'}), 'blocking', 'L11')
        expect('L4 en', run('spec.md', ST_GOOD_SPEC + '\n' + 'filler ' * 90), 'advisory', 'L4')
        vi = run('spec.md', ST_GOOD_SPEC + '\n' + 'filler ' * 90, {'language': 'vi'})
        t = vi['budget']['total']
        if not (t['budget'] == 168 and not any(v['rule'] == 'L4' for v in vi['advisory'])):
            fails.append('vi factor: %s' % t)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
        os.environ.pop('DOCLINT_TEMPLATES', None)
        _TPL_CACHE.clear()
    # the real templates: every ch:schema block must parse cleanly
    for k in KINDS:
        try:
            s = load_schema(k)
        except Err as e:
            fails.append('template %s: %s' % (k, e)); continue
        if s is None:
            print('note - %s: no %s-template.md with a ch:schema block' % (k, k))
        elif s['warnings']:
            fails.append('template %s: %s' % (s['path'], '; '.join(s['warnings'])))
        else:
            print('ok - template %s: %d sections (%s)' % (k, len(s['sections']), os.path.relpath(s['path'], ROOT)))
    # the real templates' filled examples (from the first "# " line after the schema block) must pass (06 AC-14)
    ex = tempfile.mkdtemp(prefix='doclint-ex.')
    try:
        ed = os.path.join(ex, 'tasks', '0001-example'); os.makedirs(ed)
        found = []
        for k in KINDS:
            s = _TPL_CACHE.get(k)
            if not s:
                continue
            txt = open(s['path'], encoding='utf-8').read()
            m = re.search(r'<!--\s*ch:schema\b.*?-->', txt, re.S)
            mm = re.search(r'^# ', txt[m.end():], re.M)
            if not mm:
                print('note - template %s: no filled example' % k); continue
            open(os.path.join(ed, k + '.md'), 'w', encoding='utf-8').write(txt[m.end() + mm.start():])
            found.append(k)
        for k in found:
            try:
                r = lint(os.path.join(ed, k + '.md'), {'language': 'en'})
            except Err as e:
                fails.append('example %s: %s' % (k, e)); continue
            if r['blocking']:
                fails.append('example in %s-template.md: %s' % (k, '; '.join(vline(v, 'blocking') for v in r['blocking'])))
            else:
                print('ok - example in %s-template.md passes (%s)' % (k, budget_line(r)))
            for v in r['advisory']:
                print('note - example %s: %s' % (k, vline(v, 'advisory')))
    finally:
        shutil.rmtree(ex, ignore_errors=True)
    for f in fails:
        print('FAIL - ' + f)
    print('DOCLINT SELF-TEST: %s' % ('FAIL (%d)' % len(fails) if fails else 'PASS'))
    return 1 if fails else 0

# ---------------------------------------------------------------- main
def main():
    opts = {}
    files = []
    mode = 'gate'
    js = False
    a = list(ARGV)
    VAL = {'--kind': 'kind', '--route': 'route', '--profile': 'profile', '--language': 'language',
           '--state': 'state', '--spec': 'spec', '--verdict': 'verdict'}
    while a:
        x = a.pop(0)
        if x == '--self-test':
            return self_test()
        if x == '--json':
            js = True
        elif x == '--advise':
            mode = 'advise'
        elif x == '--report':
            mode = 'report'
        elif x == '--mode':
            if not a: raise Err('--mode needs a value')
            mode = a.pop(0)
            if mode not in ('gate', 'advise', 'report'): raise Err('--mode gate|advise|report')
        elif x in VAL:
            if not a: raise Err('%s needs a value' % x)
            opts[VAL[x]] = a.pop(0)
        elif x in ('-h', '--help'):
            print(open(os.path.join(ROOT, 'scripts', 'doclint.sh')).read().split('set -uo')[0]); return 0
        elif x.startswith('--'):
            raise Err('unknown option %s' % x)
        else:
            files.append(x)
    if opts.get('kind') and opts['kind'] not in KINDS:
        raise Err('--kind must be one of %s' % '|'.join(KINDS))
    if opts.get('language') and opts['language'] not in ('en', 'vi'):
        raise Err('--language en|vi')
    if not files:
        raise Err('no FILE given')
    rc = 0
    for f in files:
        try:
            r = lint(f, opts)
        except Err as e:
            if mode == 'advise':
                continue
            if js:
                print(json.dumps({'file': f, 'error': str(e)}, ensure_ascii=False))
            else:
                print('doclint: error: %s' % e, file=sys.stderr)
            rc = max(rc, 2)
            continue
        if mode == 'advise':
            line = advise(r)
            if line:
                print(line)
                break  # at most one line
            continue
        if js:
            print(json.dumps(r, ensure_ascii=False))
        elif mode == 'report':
            print(report(r))
        else:
            for v in r['blocking']:
                print(vline(v, 'blocking'))
            for v in r['advisory']:
                print(vline(v, 'advisory'))
            print(budget_line(r))
        if r['blocking'] and mode == 'gate':
            rc = max(rc, 1)
    return 0 if mode in ('advise', 'report') and rc < 2 else (0 if mode == 'advise' else rc)

try:
    sys.exit(main())
except Err as e:
    if '--advise' in ARGV or 'advise' in ARGV:
        sys.exit(0)
    print('doclint: error: %s' % e, file=sys.stderr)
    sys.exit(2)
PYEOF
exec python3 -c "$PY" "$ROOT" "$@"
