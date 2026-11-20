#!/usr/bin/env bash
# Run the test suites: ./run_tests.sh [name ...]   (names as for python/run_tests.py, e.g. identify match)
# Uses the repo's .venv; the first run creates it and installs python/requirements.txt.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
py="$root/.venv/bin/python"
if [ ! -x "$py" ]; then
  echo "Creating $root/.venv and installing python/requirements.txt (first run only)..."
  python3 -m venv "$root/.venv"
  "$py" -m pip install -q -r "$root/python/requirements.txt"
fi
if ! command -v lua >/dev/null 2>&1 && ! "$py" -c "import lupa" 2>/dev/null; then
  "$py" -m pip install -q lupa
fi
exec "$py" "$root/python/run_tests.py" "$@"
