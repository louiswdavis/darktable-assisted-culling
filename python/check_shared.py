# Run with: python python/check_shared.py
# Fails when a file shared by the assisted plugins differs between this repo and a sibling repo
# beside it (../darktable-assisted-<name>). The SHA256 pins inside each repo catch a change to
# one copy; this catches copies drifting apart. The same file lives in all three repos.

import hashlib
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PARENT = os.path.dirname(ROOT)
REPOS = ("culling", "grouping", "tagging")
SHARED = {
    "lua/plugin_common.lua": REPOS,
    "lua/test_preset_block.lua": REPOS,
    "python/launch.py": REPOS,
    "python/run_tests.py": REPOS,
    "python/check_shared.py": REPOS,
    "python/test_modules.py": REPOS,
    "python/common.py": ("culling", "tagging"),
    "python/vehicle_detect.py": ("culling", "tagging"),
}


def main() -> int:
    roots = repo_roots()
    if len(roots) < 2:
        print("ok   shared files: no siblings found")
        return 0
    bad = 0
    for path, owners in SHARED.items():
        problem = compare(path, {repo: roots[repo] for repo in owners if repo in roots})
        bad += bool(problem)
        print(f"FAIL {path}: {problem}" if problem else f"ok   {path}")
    print(f"shared files: {len(SHARED) - bad}/{len(SHARED)} identical across {', '.join(sorted(roots))}")
    return 1 if bad else 0


def repo_roots() -> dict:
    """{repo name: folder} for each darktable-assisted-<repo> folder beside this one, this repo
    included."""
    folders = {repo: os.path.join(PARENT, f"darktable-assisted-{repo}") for repo in REPOS}
    return {repo: folder for repo, folder in folders.items() if os.path.isdir(folder)}


def compare(path: str, roots: dict) -> str:
    """'' when every copy of path is identical, else which repos differ or miss it."""
    missing = sorted(repo for repo, folder in roots.items() if not os.path.isfile(os.path.join(folder, path)))
    if missing:
        return f"missing in {', '.join(missing)}"
    by_hash = {}
    for repo, folder in sorted(roots.items()):
        by_hash.setdefault(file_hash(os.path.join(folder, path)), []).append(repo)
    if len(by_hash) == 1:
        return ""
    groups = sorted(by_hash.values(), key=len, reverse=True)
    if len(groups[0]) == len(groups[1]):
        return "every copy differs: " + " | ".join(", ".join(group) for group in groups)
    return "; ".join(f"{', '.join(group)} differs from {', '.join(groups[0])}" for group in groups[1:])


def file_hash(path: str) -> str:
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


if __name__ == "__main__":
    sys.exit(main())
