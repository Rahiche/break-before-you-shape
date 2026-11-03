"""Build an English prose corpus from the Python standard library's docstrings.

One paragraph per line, whitespace collapsed. Paragraphs that look like code
(doctest prompts, tables, heavy indentation) are dropped so what remains is
mostly running prose with punctuation, quotes, digits and the usual f-ligatures.
"""
import ast
import pathlib
import re
import sys
import sysconfig

out = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "corpus.txt")
stdlib = pathlib.Path(sysconfig.get_paths()["stdlib"])

paras, seen = [], set()
for path in sorted(stdlib.rglob("*.py")):
    if "test" in path.parts or "idlelib" in path.parts:
        continue
    try:
        tree = ast.parse(path.read_text(encoding="utf-8"))
    except Exception:
        continue
    for node in ast.walk(tree):
        if not isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        doc = ast.get_docstring(node)
        if not doc:
            continue
        for block in re.split(r"\n\s*\n", doc):
            lines = block.splitlines()
            if any(l.lstrip().startswith((">>>", "...", "$", "|", "+-")) for l in lines):
                continue
            if sum(l.startswith("    ") for l in lines) > len(lines) // 2:
                continue
            p = " ".join(block.split())
            words = p.split(" ")
            if len(words) < 12 or sum(w.isalpha() for w in words) < 0.6 * len(words):
                continue
            if p not in seen:
                seen.add(p)
                paras.append(p)

out.write_text("\n".join(paras) + "\n", encoding="utf-8")
print(f"{len(paras)} paragraphs, {sum(map(len, paras))/1e6:.2f} M chars -> {out}")
