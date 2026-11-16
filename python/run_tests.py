# Run with: python python/run_tests.py [name ...]
# Runs every python/test_*.py and lua/test_assisted_*.lua (or just the named ones, e.g. score_images
# assisted_culling) with this interpreter and writes each one's output to tests/<name>.txt in the repo
# root, then prints a one-line summary each. Lua suites run under a `lua` on PATH, else under lupa
# (`pip install lupa`); with neither they are reported as SKIP and the run fails.

import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
LUA_DIR = os.path.join(ROOT, "lua")
OUT = os.path.join(ROOT, "tests")
LUPA = ("import lupa; L=lupa.LuaRuntime(); "
        "L.execute('arg={[0]=[[%s]]}; package.path=[[./?.lua;]]..package.path; dofile([[%s]])')")


def main(names: list) -> int:
    tests = [(HERE, f) for f in sorted(os.listdir(HERE)) if f.startswith("test_") and f.endswith(".py")]
    if os.path.isdir(LUA_DIR):
        tests += [(LUA_DIR, f) for f in sorted(os.listdir(LUA_DIR))
                  if f.startswith("test_assisted_") and f.endswith(".lua")]
    if names:
        wanted = {n.removeprefix("test_").rsplit(".", 1)[0] for n in names}
        tests = [(d, t) for d, t in tests if t.removeprefix("test_").rsplit(".", 1)[0] in wanted]
    os.makedirs(OUT, exist_ok=True)
    bad = 0
    for folder, t in tests:
        label = os.path.join(os.path.basename(folder), t)
        cmd = command(folder, t)
        if cmd is None:
            bad += 1
            print(f"SKIP {label}: no lua on PATH and no lupa; run: {sys.executable} -m pip install lupa")
            continue
        run = subprocess.run(cmd, cwd=folder if t.endswith(".lua") else None, capture_output=True, text=True, encoding="utf-8", errors="replace")
        text = run.stdout + (("\n--- stderr ---\n" + run.stderr) if run.stderr else "")
        out = os.path.join(OUT, t.rsplit(".", 1)[0] + ".txt")
        with open(out, "w", encoding="utf-8") as f:
            f.write(text)
        fails = sum(1 for line in run.stdout.splitlines() if line.startswith("FAIL"))
        passed = sum(1 for line in run.stdout.splitlines() if line.startswith("ok"))
        failed = run.returncode != 0 or fails
        bad += bool(failed)
        print(f"{'FAIL' if failed else 'ok  '} {label}: {passed} ok, {fails} FAIL, exit {run.returncode} -> {out}")
    print(f"{len(tests) - bad}/{len(tests)} test files passed")
    return 1 if bad or not tests else 0


def command(folder: str, test: str):
    """Command that runs one test file (a Lua suite from inside lua/); None when a Lua suite has no runner."""
    if test.endswith(".py"):
        return [sys.executable, os.path.join(folder, test)]
    lua = shutil.which("lua") or shutil.which("lua5.4") or shutil.which("lua54")
    if lua:
        return [lua, test]
    try:
        import lupa  # noqa: F401
    except ImportError:
        return None
    return [sys.executable, "-c", LUPA % (test, test)]


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
