#!/usr/bin/env python3
"""Spell out the plot style structs' MacSurf-added fields at positional initializers.

MacSurf extends both plot style structs considerably -- plot_font_style_t goes
from 7 members to 16, plot_style_t from 5 to 19 -- and leaves older positional
initializers short, because their CodeWarrior build does not use
-Wmissing-field-initializers.

C zero-fills the remaining fields when an initializer is present, so the code
was never wrong, only implicit. Spelling the fields out keeps the warning
active for the cases where it would catch something real, rather than demoting
it tree-wide.

The member lists are READ FROM THE HEADER rather than hard-coded: enumerating
them by hand got it wrong twice (first missing the shadow_* set, then
transform/hyphens and the whole plot_style_t side).

Base is MacSurf's tree, not pristine upstream. Upstream uses designated
initializers for several of these and MacSurf rewrites them positionally, so
only MacSurf's content matches the hunk context after the generated stack
applies.

Designated initializers are left alone -- they name their fields.

Usage: WORK=<WORK>/vitabrowser-work tools/gen-fontstyle-init-patch.py
"""
import os
import re
import subprocess
import sys

W = os.path.expanduser(os.environ.get('WORK', '<WORK>/vitabrowser-work'))
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MS = os.path.join(W, 'browser', 'netsurf')
HDR = os.path.join(MS, 'include', 'netsurf', 'plot_style.h')
OUT = os.path.join(ROOT, 'patches', 'vitabrowser',
                   '05-netsurf-plot-style-init.patch')

# Files carrying positional initializers. form.c and the other hand-ported
# files are excluded: their copies in $WORK/handport are edited directly.
FILES = [
    'desktop/plot_style.c',
    'desktop/page-info.c',
    'desktop/local_history.c',
    'content/handlers/html/box_textarea.c',
    'content/handlers/html/redraw_border.c',
]

TYPES = {'plot_font_style_t': 'plot_font_style',
         'plot_style_t': 'plot_style_s'}


def struct_fields(src, tag):
    m = re.search(r'struct\s+' + tag + r'\s*\{(.*?)\n\}', src, re.S)
    if not m:
        return []
    body = re.sub(r'/\*.*?\*/', '', m.group(1), flags=re.S)
    return re.findall(
        r'^\s*[A-Za-z_][\w \*]*?([A-Za-z_]\w*)\s*(?:\[[^\]]*\])?\s*;', body, re.M)


def count_elements(body):
    """Top-level comma-separated element count of an initializer body."""
    depth = n = 0
    seen = False
    for ch in re.sub(r'/\*.*?\*/', '', body, flags=re.S):
        if ch in '([{':
            depth += 1
        elif ch in ')]}':
            depth -= 1
        elif ch == ',' and depth == 0:
            n += 1
            seen = False
            continue
        if not ch.isspace():
            seen = True
    return n + (1 if seen else 0)


def pad(text, fields_by_type):
    lines = text.splitlines(keepends=True)
    decl = re.compile(r'\b(' + '|'.join(TYPES) + r')\b[^=;]*=\s*\{')
    out, i, n = [], 0, 0
    while i < len(lines):
        m = decl.search(lines[i])
        out.append(lines[i])
        if not m:
            i += 1
            continue
        fields = fields_by_type[m.group(1)]
        body, j, depth = [], i + 1, 1
        while j < len(lines):
            depth += lines[j].count('{') - lines[j].count('}')
            if depth == 0:
                break
            body.append(lines[j])
            j += 1
        joined = ''.join(body)
        have = count_elements(joined)
        if re.search(r'^\s*\.\w+\s*=', joined, re.M) or have >= len(fields):
            out.extend(body)
            out.append(lines[j])
            i = j + 1
            continue
        k = len(body) - 1
        while k >= 0 and not body[k].strip():
            k -= 1
        indent = re.match(r'\s*', body[k]).group(0) or '\t'
        body[k] = body[k].rstrip('\n').rstrip() + ',\n'
        missing = fields[have:]
        for idx, f in enumerate(missing):
            sep = ',' if idx < len(missing) - 1 else ''
            body.append(f'{indent}0{sep}   /* {f} */\n')
        out.extend(body)
        out.append(lines[j])
        n += 1
        i = j + 1
    return ''.join(out), n


def main():
    hdr = open(HDR, errors='replace').read()
    fields_by_type = {t: struct_fields(hdr, tag) for t, tag in TYPES.items()}
    for t, f in fields_by_type.items():
        if not f:
            print(f'could not read members of {t}', file=sys.stderr)
            return 2
        print(f'{t}: {len(f)} members')

    chunks, total = [], 0
    for rel in FILES:
        src = os.path.join(MS, rel)
        if not os.path.exists(src):
            continue
        new, n = pad(open(src, errors='replace').read(), fields_by_type)
        if n == 0:
            print(f'  {rel}: nothing to pad')
            continue
        tmp = f'/tmp/psinit-{os.path.basename(rel)}'
        open(tmp, 'w').write(new)
        d = subprocess.run(['diff', '-u', src, tmp],
                           capture_output=True, text=True).stdout.splitlines(keepends=True)
        os.unlink(tmp)
        if not d:
            continue
        d[0] = f'--- a/{rel}\n'
        d[1] = f'+++ b/{rel}\n'
        chunks.extend(d)
        total += n
        print(f'  {rel}: padded {n}')

    with open(OUT, 'w') as fh:
        fh.write("# vitabrowser: spell out the plot style structs' MacSurf-added fields\n#\n")
        fh.write('# Generated by tools/gen-fontstyle-init-patch.py -- regenerate, do not\n')
        fh.write('# hand-edit. Member lists are read from plot_style.h, not hard-coded:\n')
        fh.write('# enumerating them by hand got it wrong twice.\n#\n')
        fh.write('# C zero-fills the rest, so this keeps -Wmissing-field-initializers\n')
        fh.write('# useful rather than fixing a defect. Designated initializers untouched.\n#\n')
        fh.write('# Applies to: netsurf (after the generated stack)\n')
        fh.writelines(chunks)
    print(f'{OUT}: {total} initializers padded')
    return 0


if __name__ == '__main__':
    sys.exit(main())
