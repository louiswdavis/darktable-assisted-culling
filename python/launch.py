"""Runs one plugin script for darktable on Windows, with no console window.

darktable starts this with pythonw.exe and doesn't wait for it. The one argument
is a job file of UTF-8 lines: the done path, the stderr path, the stderr mode
("a" appends, "w" replaces), then the script and its arguments, one per line.
Runs the script with this interpreter, waits, then writes its exit code to the
done path via a .tmp file and a rename, so the done file never exists without it.

The script runs as its own process, not inside this one: its worker processes
re-import __main__, which must be the script itself.
"""
import os
import subprocess
import sys
import traceback


def main():
    job = sys.argv[1]
    with open(job, encoding="utf-8") as f:
        lines = f.read().splitlines()
    os.remove(job)
    done, err_path, mode, argv = lines[0], lines[1], lines[2], lines[3:]
    try:
        with open(err_path, mode + "b") as err:
            code = subprocess.call(
                [sys.executable, "-u"] + argv,
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=err,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    except Exception:
        code = 1
        with open(err_path, "a", encoding="utf-8") as err:
            err.write("launch.py couldn't run " + " ".join(argv) + "\n" + traceback.format_exc())
    tmp = done + ".tmp"
    with open(tmp, "w") as f:
        f.write(str(code))
    os.replace(tmp, done)


if __name__ == "__main__":
    main()
