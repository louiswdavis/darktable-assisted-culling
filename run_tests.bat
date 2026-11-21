@echo off
rem Run the test suites: run_tests.bat [name ...]   (names as for python\run_tests.py, e.g. identify match)
rem Uses the repo's .venv; the first run creates it and installs python\requirements.txt.
set "ROOT=%~dp0"
set "PY=%ROOT%.venv\Scripts\python.exe"
if not exist "%PY%" (
  echo Creating %ROOT%.venv and installing python\requirements.txt, first run only...
  python -m venv "%ROOT%.venv" || exit /b 1
  "%PY%" -m pip install -q -r "%ROOT%python\requirements.txt" || exit /b 1
)
where lua >nul 2>nul || "%PY%" -c "import lupa" 2>nul || "%PY%" -m pip install -q lupa
"%PY%" "%ROOT%python\run_tests.py" %*
