#!/usr/bin/env python3
"""Observe DMG lifetime without Homebrew extraction on disposable fork runners."""

from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time


def timestamp():
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


def command(args, **kwargs):
    return subprocess.run(args, capture_output=True, timeout=60, **kwargs)


def simulator_pids():
    result = command(["/usr/bin/pgrep", "-x", "simdiskimaged"], text=True)
    return [int(pid) for pid in result.stdout.split()]


def record(event, **details):
    entry = {"time": timestamp(), "event": event, **details}
    print(json.dumps(entry), flush=True)
    with (results_directory / "events.jsonl").open("a") as log:
        log.write(json.dumps(entry) + "\n")


def probe(attempt, image):
    import plistlib

    outcome = {"attempt": attempt, "attach_status": None, "lost_mount": False}
    with tempfile.TemporaryDirectory(prefix="dmg-causality-") as directory:
        try:
            result = command([
                "/usr/bin/hdiutil", "attach", "-plist", "-nobrowse", "-readonly",
                "-mountrandom", directory, str(image),
            ], input=b"qn\n")
        except subprocess.TimeoutExpired:
            outcome["attach_status"] = "timeout"
            record("inconclusive", reason="attach timed out", attempt=attempt)
            return outcome
        outcome["attach_status"] = result.returncode
        (results_directory / f"attach-{attempt}.plist").write_bytes(result.stdout)
        record("attach", attempt=attempt, status=result.returncode,
               stderr=result.stderr.decode(errors="replace"), simulator_pids=simulator_pids())
        if result.returncode:
            return outcome

        mounts = [Path(entity["mount-point"])
                  for entity in plistlib.loads(result.stdout).get("system-entities", [])
                  if "mount-point" in entity]
        if not mounts:
            outcome["no_mounts"] = True
        for mount in mounts:
            record("mount_returned", attempt=attempt, path=str(mount))
            try:
                device = mount.stat().st_dev
                listing = command(["/usr/bin/find", ".", "-print0"], cwd=mount)
                outcome["find_status"] = listing.returncode
                record("find", attempt=attempt, status=listing.returncode,
                       bytes=len(listing.stdout), stderr=listing.stderr.decode(errors="replace"))
                deadline = time.monotonic() + 8
                while time.monotonic() < deadline:
                    if mount.stat().st_dev != device:
                        outcome["lost_mount"] = True
                        record("mount_device_changed", attempt=attempt, path=str(mount))
                        break
                    time.sleep(0.1)
            except FileNotFoundError as error:
                outcome["lost_mount"] = True
                record("mount_missing", attempt=attempt, path=str(mount), error=str(error))
            finally:
                record("before_cleanup", attempt=attempt, path=str(mount), exists=mount.exists())
                # Never eject a cached disk number: another image may already own it.
                if mount.exists():
                    cleanup = command(["/usr/bin/hdiutil", "detach", str(mount)])
                    record("cleanup", attempt=attempt, status=cleanup.returncode,
                           stderr=cleanup.stderr.decode(errors="replace"))
    return outcome


if os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("GITHUB_REPOSITORY") != "SSakutaro/brew":
    raise SystemExit("Only run on disposable SSakutaro/brew Actions runners.")

results_directory = Path(os.environ["RUNNER_TEMP"]) / "dmg-causality-results"
results_directory.mkdir(exist_ok=True)
mode = os.environ["DMG_SIMULATOR_MODE"]
if mode not in {"running", "paused"}:
    raise SystemExit("Unknown Simulator mode")

record("environment", mode=mode, image=os.environ.get("ImageVersion"),
       image_os=os.environ.get("ImageOS"),
       macos=command(["/usr/bin/sw_vers"], text=True).stdout,
       xcode=command(["/usr/bin/xcodebuild", "-version"], text=True).stdout)
image = Path(os.environ["RUNNER_TEMP"]) / "Keet-4.24.0.dmg"
subprocess.run([
    "/usr/bin/curl", "--fail", "--location", "--retry", "3", "--silent", "--show-error",
    "https://static.keet.io/downloads/4.24.0/Keet.dmg", "--output", str(image),
], check=True)
with image.open("rb") as downloaded:
    digest = hashlib.file_digest(downloaded, "sha256").hexdigest()
if digest != "dad2f606a3a1b888cb013104908c8be839c11b762b3a4fb58daf97c292730e16":
    raise SystemExit("Downloaded image does not match the original Cask checksum")
record("download_verified", sha256=digest)
record("before_brew_config", simulator_pids=simulator_pids())
config = command(["./bin/brew", "config"], text=True)
(results_directory / "brew-config.log").write_text(config.stdout + config.stderr)
record("after_brew_config", status=config.returncode, simulator_pids=simulator_pids())

paused = []
outcomes = []
try:
    pids = simulator_pids()
    if mode == "paused":
        for _ in range(30):
            if pids:
                break
            time.sleep(0.5)
            pids = simulator_pids()
        if not pids:
            record("inconclusive", reason="simdiskimaged was not running; no intervention possible")
            raise SystemExit(2)
        for pid in pids:
            subprocess.run(["/usr/bin/sudo", "-n", "/bin/kill", "-STOP", str(pid)], check=True)
            paused.append(pid)
    for attempt in range(1, 7):
        states = command(["/bin/ps", "-o", "pid=,stat=,comm=", "-p",
                          ",".join(map(str, simulator_pids())) or "0"], text=True).stdout
        record("simulator_state", attempt=attempt, states=states)
        if mode == "paused" and (set(simulator_pids()) != set(paused)
                                 or any("T" not in line.split()[1] for line in states.splitlines())):
            record("inconclusive", reason="Simulator suspension did not remain effective")
            raise SystemExit(2)
        outcomes.append(probe(attempt, image))
        if outcomes[-1]["attach_status"] == "timeout":
            break
finally:
    for pid in paused:
        subprocess.run(["/usr/bin/sudo", "-n", "/bin/kill", "-CONT", str(pid)], check=False)
    record("completed", outcomes=outcomes, resumed_pids=paused)
    (results_directory / "outcomes.json").write_text(json.dumps(outcomes, indent=2) + "\n")
    system_log = command([
        "/usr/bin/log", "show", "--last", "5m", "--style", "compact", "--info", "--debug",
        "--predicate", 'process == "simdiskimaged" OR process == "diskarbitrationd" OR process == "hdiutil"',
    ])
    (results_directory / "system.log").write_bytes(system_log.stdout + system_log.stderr)

raise SystemExit(int(any(item["attach_status"] != 0 or item["lost_mount"] or item.get("no_mounts")
                        or item.get("find_status", 0) != 0 for item in outcomes)))
