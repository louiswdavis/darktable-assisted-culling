"""Every python/ module as the plugin really runs it, on whatever Python runs the suite.

Shared by the three darktable plugins (python/check_shared.py keeps the copies identical).

The Windows install ran `identify.py` on a Python that evaluates annotations when a `def` runs, while the suite ran
on 3.14, which defers them. `apply_exact_reads(result: BoxResult ...)` sat above `class BoxResult`, so every
reload and search died with a NameError the suite never saw. This file closes that class of gap:
- each module imports in its own fresh interpreter, the way identify.py imports it (a real run, no test doubles)
- each command-line script starts and answers --help
- no annotation names a class or function defined further down the file (fails on any Python version)
- every file parses as Python 3.10, the README's minimum
- every def and class method is named in at least one test; the ones that are not yet are listed in
  untested_defs.txt, which may only shrink
"""
import ast
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
BASELINE = os.path.join(HERE, "untested_defs.txt")
MIN_PYTHON = (3, 10)
NOT_MODULES = {"run_tests.py"}

failures = 0


def check(name, got, want):
    global failures
    if got != want:
        failures += 1
        print(f"FAIL {name}: got {got!r}, want {want!r}")
    else:
        print(f"ok   {name}")


def module_files() -> list:
    return [f for f in sorted(os.listdir(HERE)) if f.endswith(".py") and not f.startswith("test_") and f not in NOT_MODULES]


def test_files() -> list:
    return [f for f in sorted(os.listdir(HERE)) if f.startswith("test_") and f.endswith(".py")]


def source_of(filename: str, folder: str = HERE) -> str:
    with open(os.path.join(folder, filename), encoding="utf-8") as f:
        return f.read()


def run_python(args: list, cwd: str, isolated: bool = True) -> tuple:
    """(exit code, last non-blank stderr line) of a fresh interpreter. isolated (-I) keeps the cwd and user site off
    sys.path; a script run is not isolated, as the panel's isn't: its own folder is on the path."""
    done = subprocess.run([sys.executable] + (["-I"] if isolated else []) + args, cwd=cwd, capture_output=True, text=True, timeout=120)
    lines = [ln for ln in done.stderr.splitlines() if ln.strip()]
    return done.returncode, (lines[-1] if lines else "")


def check_imports(tmp: str):
    for filename in module_files():
        module = filename[:-3]
        code, why = run_python(["-c", f"import sys; sys.path.insert(0, {HERE!r}); import {module}"], tmp)
        check(f"{filename} imports in a fresh interpreter" + (f" ({why})" if code else ""), code, 0)


def takes_arguments(filename: str) -> bool:
    """A module that is also a command-line script: it parses arguments and has a __main__ guard."""
    source = source_of(filename)
    return "argparse" in source and "__name__ == \"__main__\"" in source


def check_scripts_start(tmp: str):
    """Each command-line script answers --help, run the way the panel runs it (not isolated: its own folder is on
    sys.path), so a failing import in it, or in anything it imports, is caught."""
    for filename in module_files():
        if takes_arguments(filename):
            code, why = run_python([os.path.join(HERE, filename), "--help"], tmp, False)
            check(f"{filename} --help exits 0" + (f" ({why})" if code else ""), code, 0)


def annotation_nodes(node) -> list:
    """The annotation expressions a def or a class-level assignment evaluates when it runs."""
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
        args = node.args
        every = args.posonlyargs + args.args + args.kwonlyargs + [a for a in (args.vararg, args.kwarg) if a]
        return [a.annotation for a in every if a.annotation] + ([node.returns] if node.returns else [])
    if isinstance(node, ast.AnnAssign):
        return [node.annotation]
    return []


def forward_annotations(filename: str, folder: str = HERE) -> list:
    """['file:line name'] for each annotation that names a top-level class, def or constant defined further down.
    Python 3.14 defers annotations and hides these; 3.10 to 3.13 raise NameError on import."""
    source = source_of(filename, folder)
    if "from __future__ import annotations" in source:
        return []
    tree = ast.parse(source)
    defined = {}
    for node in tree.body:
        if isinstance(node, (ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
            defined.setdefault(node.name, node.lineno)
        elif isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name):
                    defined.setdefault(target.id, node.lineno)
    found = []
    scopes = [tree.body] + [n.body for n in tree.body if isinstance(n, ast.ClassDef)]
    for body in scopes:
        for node in body:
            for annotation in annotation_nodes(node):
                if isinstance(annotation, ast.Constant):
                    continue  # a quoted annotation is never evaluated
                for name in (n.id for n in ast.walk(annotation) if isinstance(n, ast.Name)):
                    if defined.get(name, 0) > node.lineno:
                        found.append(f"{filename}:{node.lineno} {name}")
    return found


def check_forward_annotations():
    found = [hit for filename in module_files() + test_files() for hit in forward_annotations(filename)]
    check("no annotation names something defined further down its file" + (f" ({found})" if found else ""), found, [])
    with tempfile.TemporaryDirectory() as folder:
        with open(os.path.join(folder, "planted.py"), "w", encoding="utf-8") as f:
            f.write("def early(x: Late) -> Late:\n    return x\n\n\nclass Late:\n    pass\n")
        check("the scan catches a planted forward annotation (both of its uses)", len(forward_annotations("planted.py", folder)), 2)


def check_python_minimum():
    for filename in module_files() + test_files():
        try:
            ast.parse(source_of(filename), feature_version=MIN_PYTHON)
            problem = ""
        except SyntaxError as e:
            problem = f"{filename}:{e.lineno} {e.msg}"
        check(f"{filename} parses as Python {MIN_PYTHON[0]}.{MIN_PYTHON[1]}" + (f" ({problem})" if problem else ""), problem, "")
    check(f"the suite runs on Python {MIN_PYTHON[0]}.{MIN_PYTHON[1]} or newer (this is {sys.version.split()[0]})",
          sys.version_info >= MIN_PYTHON, True)


def defs_of(filename: str) -> list:
    """Top-level defs and classes plus the public methods of those classes, by name."""
    names = []
    for node in ast.parse(source_of(filename)).body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            names.append(node.name)
        if isinstance(node, ast.ClassDef):
            names += [m.name for m in node.body if isinstance(m, ast.FunctionDef) and not m.name.startswith("__")]
    return names


def untested_defs() -> list:
    """['module.py:name'] for each def no test file names. A name match is the floor: it proves a test mentions the
    def, not that it covers every branch."""
    tests = "\n".join(source_of(f) for f in test_files() if f != os.path.basename(__file__))
    return [f"{filename}:{name}" for filename in module_files() for name in defs_of(filename)
            if not re.search(r"\b" + re.escape(name) + r"\b", tests)]


def check_every_def_is_tested():
    with open(BASELINE, encoding="utf-8") as f:
        allowed = {ln.strip() for ln in f if ln.strip() and not ln.startswith("#")}
    now = set(untested_defs())
    new = sorted(now - allowed)
    check("every new def is named in a test (add one, or the def is untested)" + (f" ({new})" if new else ""), new, [])
    stale = sorted(allowed - now)
    check("untested_defs.txt lists only defs still untested (delete the lines now covered)" + (f" ({stale})" if stale else ""),
          stale, [])
    print(f"info {len(now)} of {sum(len(defs_of(f)) for f in module_files())} defs are not yet named in a test")


def run_tests():
    print(f"python {sys.version.split()[0]} at {sys.executable}")
    with tempfile.TemporaryDirectory() as tmp:
        check_imports(tmp)
        check_scripts_start(tmp)
    check_forward_annotations()
    check_python_minimum()
    check_every_def_is_tested()
    print("")
    if failures == 0:
        print("all tests passed")
        sys.exit(0)
    print(f"{failures} test(s) failed")
    sys.exit(1)


if __name__ == "__main__":
    if "--write-baseline" in sys.argv:
        with open(BASELINE, "w", encoding="utf-8") as f:
            f.write("# defs no test names yet (module:def). Only shrinks: test one, delete its line.\n")
            f.writelines(line + "\n" for line in untested_defs())
        sys.exit(0)
    run_tests()
