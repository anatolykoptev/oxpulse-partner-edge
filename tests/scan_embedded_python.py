#!/usr/bin/env python3
"""Every python snippet embedded in a shell script must import what it uses.

#513: channel-render-lib.sh's sni_fallback snippet referenced `os` without
`import os`, raising NameError on any node-config carrying no server_name. It
was unreachable on the live fleet (every node had the field), so it sat latent
until a node-config shape change would arm it fleet-wide — and it detonates in
re_render_xray, which runs AFTER the health gate and outside the rollback
window (#514). Fixed incidentally by f27c29e; nothing guarded it.

The whole point is that these snippets are strings to the shell: no linter,
no import checker, no syntax gate reaches inside them. This does.

Honesty contract, in order of how badly each would mislead:
  - a block whose python cannot be extracted is REPORTED, never skipped
    silently -- a scanner that quietly drops what it cannot read is exactly
    the false green it exists to prevent;
  - a block whose source is a shell variable is counted and named as
    UNANALYSABLE, so the coverage gap is visible rather than implied.
"""
import ast
import pathlib
import re
import sys

# Names that are stdlib modules here. A bare `foo.bar` where foo is in this set
# and foo is neither imported nor assigned in the block is a NameError waiting
# for the right input. Restricted to a known set so a local variable that
# happens to carry attributes is never mistaken for a missing import.
STDLIB = {
    "os", "sys", "json", "re", "hashlib", "hmac", "base64", "pathlib", "yaml",
    "subprocess", "time", "datetime", "socket", "urllib", "shutil", "tempfile",
    "uuid", "secrets", "math", "random", "struct", "binascii", "itertools",
    "collections", "textwrap", "glob", "stat", "errno", "signal", "csv",
}

PY_INVOKE = re.compile(r"python3?\s+(?:-c\s*|-\s*<<|<<)")


def extract_blocks(text):
    """Yield (line_no, source, status). status: ok | unanalysable | unparseable."""
    lines = text.split("\n")
    i = 0
    while i < len(lines):
        line = lines[i]
        m = re.search(r"python3?\s+-\s*<<\s*'?([A-Za-z_][A-Za-z0-9_]*)'?", line)
        if m:  # heredoc form: python3 - <<'PYEOF'
            tag = m.group(1)
            body, j = [], i + 1
            while j < len(lines) and lines[j].strip() != tag:
                body.append(lines[j])
                j += 1
            if j >= len(lines):
                yield (i + 1, "", "unparseable")
            else:
                yield (i + 1, "\n".join(body), "ok")
            i = j + 1
            continue

        m = re.search(r"python3?\s+-c\s*(['\"])", line)
        if m:
            q = m.group(1)
            start = m.end()
            rest = line[start:]
            # Source given by a shell variable -> nothing static to check.
            if rest.lstrip().startswith("$"):
                yield (i + 1, "", "unanalysable")
                i += 1
                continue
            body, j, closed = [], i, False
            seg = rest
            while True:
                # For a double-quoted shell string, \" does not close it.
                k, pos = -1, 0
                while pos < len(seg):
                    c = seg[pos]
                    if c == "\\" and q == '"':
                        pos += 2
                        continue
                    if c == q:
                        k = pos
                        break
                    pos += 1
                if k >= 0:
                    body.append(seg[:k])
                    closed = True
                    break
                body.append(seg)
                j += 1
                if j >= len(lines):
                    break
                seg = lines[j]
            yield (i + 1, "\n".join(body), "ok" if closed else "unparseable")
            i = j + 1
            continue
        i += 1


def missing_imports(src):
    """Return sorted names used as `name.attr` but neither imported nor bound."""
    try:
        tree = ast.parse(src)
    except SyntaxError:
        return None  # signals "could not parse"

    bound = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for a in node.names:
                bound.add((a.asname or a.name).split(".")[0])
        elif isinstance(node, ast.ImportFrom):
            for a in node.names:
                bound.add(a.asname or a.name)
        elif isinstance(node, ast.Name) and isinstance(node.ctx, ast.Store):
            bound.add(node.id)
        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            bound.add(node.name)
        elif isinstance(node, ast.arg):
            bound.add(node.arg)
        elif isinstance(node, ast.alias):
            bound.add((node.asname or node.name).split(".")[0])

    used = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name):
            used.add(node.value.id)
    return sorted(n for n in used if n in STDLIB and n not in bound)


def main():
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    scanned = violations = unanalysable = unparseable = 0
    bad = []

    for path in sorted(root.rglob("*.sh")):
        rel = path.relative_to(root)
        if ".git" in rel.parts:
            continue
        try:
            text = path.read_text()
        except (UnicodeDecodeError, OSError):
            continue
        for lineno, src, status in extract_blocks(text):
            if status == "unanalysable":
                unanalysable += 1
                print(f"  note: {rel}:{lineno} python source is a shell variable — not statically checkable")
                continue
            if status == "unparseable":
                unparseable += 1
                print(f"  UNPARSEABLE: {rel}:{lineno} — extraction failed, NOT skipped silently")
                continue
            scanned += 1
            miss = missing_imports(src)
            if miss is None:
                # Shell interpolation can make a block invalid python on its own.
                # Report it rather than pass it.
                unanalysable += 1
                print(f"  note: {rel}:{lineno} did not parse as standalone python (shell interpolation) — not checked")
                continue
            if miss:
                violations += 1
                bad.append(f"{rel}:{lineno} uses {', '.join(m + '.' for m in miss)} without importing {', '.join(miss)}")

    print()
    print(f"blocks scanned      : {scanned}")
    print(f"unanalysable        : {unanalysable}  (reported above, not hidden)")
    print(f"extraction failures : {unparseable}   (must be 0)")
    print(f"violations          : {violations}")
    for b in bad:
        print(f"  FAIL: {b}")

    return 1 if (violations or unparseable) else 0


if __name__ == "__main__":
    sys.exit(main())
