"""Keeps a Switchboard process running on Windows: runs the script given on the command line and starts it again
(after 5 s) whenever it exits. Task Scheduler's "restart on failure" only covers a task that fails to start, not a
program that exits later. Usage: pythonw sbrun.py <script.py> [args...]   (log: <switchboard home>/sbrun.log)"""
import os
import subprocess
import sys
import time


def main():
    home = os.path.join(os.environ.get("LOCALAPPDATA", os.path.expanduser("~")), "switchboard")
    os.makedirs(home, exist_ok=True)
    log = open(os.path.join(home, "sbrun.log"), "a", buffering=1)
    cmd = [sys.executable, *sys.argv[1:]]
    while True:
        start = time.time()
        rc = subprocess.run(cmd, cwd=os.path.dirname(os.path.abspath(sys.argv[1]))).returncode
        log.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {os.path.basename(sys.argv[1])} exited {rc} "
                  f"after {time.time() - start:.0f} s, restarting\n")
        time.sleep(5 if time.time() - start > 30 else 20)  # back off when it dies right away


if __name__ == "__main__":
    main()
