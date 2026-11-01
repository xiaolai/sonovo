#!/usr/bin/env python3
"""Run actual-app acceptance only on an explicitly named dedicated Mac.

The probe build must already be packaged. Preferences are backed up privately
and restored on every exit. Session checks use an isolated tmux socket; no
terminal capture or direct tmux kill is performed.
"""
from pathlib import Path
import argparse
import json
import os
import plistlib
import re
import signal
import socket
import subprocess
import time

DOMAIN = "com.lixiaolai.sonovo"


def run(argv, **kwargs):
    return subprocess.run(argv, check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs)


def own_pids(executable):
    result = run(["/bin/ps", "-axo", "pid=,command="])
    found = []
    for line in result.stdout.decode().splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and (parts[1] == str(executable) or parts[1].startswith(str(executable) + " ")):
            found.append(int(parts[0]))
    return found


def wait_for(predicate, timeout, tick=None):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if tick: tick()
        if predicate(): return True
        time.sleep(0.25)
    return predicate()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("app", type=Path)
    parser.add_argument("--dedicated-hostname", required=True)
    args = parser.parse_args()
    if socket.gethostname() != args.dedicated_hostname:
        raise SystemExit("refusing a machine other than the explicitly selected dedicated host")
    root, app = args.root.expanduser().resolve(), args.app.expanduser().resolve()
    if root.name != "e2e" or (root / ".sonovo-modular-e2e").read_text() != "synthetic-only\n":
        raise SystemExit("refusing unmarked fixture directory")
    if not app.is_relative_to(root.parent / "main/.build"):
        raise SystemExit("expected a scratch development bundle in this isolated checkout")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != DOMAIN: raise SystemExit("unexpected bundle identifier")
    if run(["/usr/bin/codesign", "--verify", "--strict", str(app)]).returncode:
        raise SystemExit("invalid staged signature")
    executable = app / "Contents/MacOS/Sonovo"
    if own_pids(executable): raise SystemExit("this acceptance app is already running")
    log = root / "acceptance.log"
    if log.exists(): log.unlink()
    for acknowledgement in root.glob("*.captured"): acknowledgement.unlink()
    request = root / "capture-request.json"
    if request.exists(): request.unlink()
    export = run(["/usr/bin/defaults", "export", DOMAIN, "-"])
    original = plistlib.loads(export.stdout) if export.returncode == 0 else None
    recovery = root / "preferences-recovery.plist"
    if original is not None:
        recovery.write_bytes(plistlib.dumps(original)); recovery.chmod(0o600)
    controller = []
    def record(text):
        controller.append(text); (root / "controller.log").write_text("\n".join(controller) + "\n"); print(text, flush=True)
    def text(): return log.read_text() if log.exists() else ""
    captured = set()
    def capture():
        try: request = json.loads((root / "capture-request.json").read_text())
        except (OSError, ValueError): return
        name, window = request.get("name", ""), request.get("window")
        if name in captured or not re.fullmatch(r"[0-9][a-z0-9-]+", name) or not isinstance(window, int) or window <= 0: return
        result = run(["/usr/sbin/screencapture", "-x", "-l", str(window), str(root / (name + ".png"))], timeout=10)
        (root / (name + ".captured")).write_text("ok\n" if result.returncode == 0 else "failed\n")
        captured.add(name)
        record(("PASS " if result.returncode == 0 else "FAIL ") + "external window capture " + name)
    env = dict(os.environ, TMUX_TMPDIR=str(root / "tmux"), PATH=os.path.expanduser("~/bin") + ":/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    tmux = "/opt/homebrew/bin/tmux"
    def identity(name):
        result = run([tmux, "-S", str(root / ("tmux/tmux-" + str(os.getuid()) + "/default")), "display-message", "-p", "-t", "=" + name + ":", "#{socket_path}|#{pid}|#{session_id}"], env=env, timeout=5)
        return result.stdout.strip() if result.returncode == 0 else None
    def launch(phase):
        options = ["/usr/bin/open", "-n"]
        settings = {
            "SONOVO_MODULAR_E2E_ROOT": str(root), "SONOVO_MODULAR_E2E_PHASE": phase,
            "SONOVO_DEMO_TAB": "render-1080", "SONOVO_APPEARANCE": "light",
            "TMUX_TMPDIR": str(root / "tmux"), "TMUX": "", "PATH": env["PATH"], "SHELL": "/bin/sh", "ENV": "/dev/null",
        }
        for key, value in settings.items(): options += ["--env", key + "=" + value]
        result = run(options + [str(app), "--args", "-ApplePersistenceIgnoreState", "YES"])
        if result.returncode: raise RuntimeError("development app launch failed")
    try:
        for key, kind, value in [("sonovo.terminals.tmux", "-bool", "true"), ("sonovo.shell", "-string", "/bin/sh"),
                                 ("sonovo.loginShell", "-bool", "false"), ("sonovo.appearance", "-string", "light")]:
            if run(["/usr/bin/defaults", "write", DOMAIN, key, kind, value]).returncode:
                raise RuntimeError("could not configure temporary acceptance preferences")
        run(["/usr/bin/defaults", "delete", DOMAIN, "sonovo.tmux.hygiene.settings"])
        launch("initial"); record("launched actual acceptance app on dedicated host")
        if not wait_for(lambda: "READY-FOR-FORCE-QUIT" in text(), 240, tick=capture):
            raise RuntimeError("initial actual-app matrix did not finish")
        name = (root / "session-name.txt").read_text()
        if not re.fullmatch(r"sonovo-modular-a-[a-f0-9]{8}-[0-9]+", name):
            raise RuntimeError("unexpected fixture session name")
        before = identity(name)
        if before is None or not before.decode().startswith(str(root)):
            raise RuntimeError("session is not on the isolated fixture socket")
        pids = own_pids(executable)
        if len(pids) != 1: raise RuntimeError("expected one acceptance application process")
        os.kill(pids[0], signal.SIGKILL)
        if not wait_for(lambda: not own_pids(executable), 10): raise RuntimeError("acceptance process did not stop")
        time.sleep(1)
        if identity(name) != before: raise RuntimeError("force quit changed the fixture tmux identity")
        record("PASS force quit detaches without changing tmux server/session identity")
        launch("resume"); record("relaunched acceptance app for reattach and guarded End checks")
        if not wait_for(lambda: "COMPLETE failures=" in text(), 120, tick=capture):
            raise RuntimeError("reattach and cleanup matrix did not finish")
        wait_for(lambda: not own_pids(executable), 15)
        if any(line.startswith("FAIL ") for line in text().splitlines()):
            raise RuntimeError("actual-app matrix contains failed assertions")
        record("PASS actual-app matrix and guarded fixture cleanup")
    finally:
        for pid in own_pids(executable): os.kill(pid, signal.SIGKILL)
        wait_for(lambda: not own_pids(executable), 10)
        # defaults import merges keys, so clear only this backed-up domain
        # before restoring it; otherwise temporary acceptance keys survive.
        run(["/usr/bin/defaults", "delete", DOMAIN])
        if original is not None:
            if run(["/usr/bin/defaults", "import", DOMAIN, str(recovery)]).returncode:
                raise RuntimeError("preference restore failed; private recovery file retained")
        time.sleep(1)
        verify = run(["/usr/bin/defaults", "export", DOMAIN, "-"])
        restored = plistlib.loads(verify.stdout) if verify.returncode == 0 else None
        if restored != original: raise RuntimeError("preference restore differs; private recovery file retained")
        if recovery.exists(): recovery.unlink()
        record("PASS original preference domain restored exactly")


if __name__ == "__main__": main()
