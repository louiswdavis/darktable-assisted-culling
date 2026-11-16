"""Static bookkeeping checks: reads the source, imports nothing, so it runs anywhere
with plain Python (no cv2, numpy or onnx). It catches a constant left out of
score_images.py's CACHE_INPUTS / CACHE_NEUTRAL before the full test run does.

Run with: python python/check_registries.py   (exit 1 and a list when something is unfiled)"""

import ast
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def module_constants(tree: ast.Module) -> set:
    """The public UPPER_CASE names score_images defines or imports at module level,
    as test_score_images.py's fingerprint check sees them in vars(score_images)."""
    names = set()
    for node in tree.body:
        if isinstance(node, (ast.Assign, ast.AnnAssign)):
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            names |= {t.id for t in targets if isinstance(t, ast.Name)}
        elif isinstance(node, ast.ImportFrom):
            names |= {a.asname or a.name for a in node.names}
    return {n for n in names if n.isupper() and not n.startswith("_")}


def string_tuple(tree: ast.Module, name: str) -> list:
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == name for t in node.targets):
            return [e.value for e in node.value.elts]
    raise SystemExit(f"{name} not found")


def problems() -> list:
    with open(os.path.join(HERE, "score_images.py"), encoding="utf-8") as f:
        tree = ast.parse(f.read())
    constants = module_constants(tree)
    inputs, neutral = string_tuple(tree, "CACHE_INPUTS"), string_tuple(tree, "CACHE_NEUTRAL")
    filed = inputs + neutral
    out = [f"score_images: {n} is in neither CACHE_INPUTS nor CACHE_NEUTRAL" for n in sorted(constants - set(filed))]
    out += [f"score_images: {n} is filed twice" for n in sorted({n for n in filed if filed.count(n) > 1})]
    out += [f"score_images: {n} is filed but doesn't exist" for n in sorted(set(filed) - constants)]
    return out


if __name__ == "__main__":
    found = problems()
    print("\n".join(found) if found else "registries ok")
    sys.exit(1 if found else 0)
