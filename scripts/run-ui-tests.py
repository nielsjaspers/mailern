#!/usr/bin/env python3
"""Build once and run the UI and editor tests serially on one disposable Simulator."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from uuid import UUID


def run(*args, **kwargs):
    return subprocess.run(args, text=True, check=True, **kwargs)


def output(*args):
    return run(*args, stdout=subprocess.PIPE).stdout.strip()


def state(simulator):
    listing = json.loads(output("xcrun", "simctl", "list", "devices", "-j"))
    return next((device["state"] for group in listing["devices"].values() for device in group
                 if device["udid"] == simulator), None)


def shutdown(simulator):
    # Finish teardown even if cancellation arrives while the Simulator shuts down.
    previous = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM})
    try:
        if state(simulator) not in (None, "Shutdown"):
            subprocess.run(["xcrun", "simctl", "shutdown", simulator])
        if state(simulator) not in (None, "Shutdown"):
            raise RuntimeError(f"Simulator {simulator} is still running. Run scripts/check-ui.sh {simulator} --stop.")
        print("Simulator shut down", flush=True)
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous)


def test_names():
    """Every test method, so a full run can prove that nothing was skipped or lost."""
    names = set()
    for module, path in [("MailernUITests", "Tests/MailernUITests.swift"), ("MailernTests", "Tests/ComposerEditorTests.swift")]:
        cls = None
        for line in Path(path).read_text().splitlines():
            if match := re.match(r"(?:@MainActor )?(?:final )?class (\w+): (?:MailernUITestCase|XCTestCase)", line):
                cls = match[1]
            elif match := re.match(r"    func (test\w+)\(", line):
                names.add((module, cls, match[1]))
    return names


def interrupt(signum, frame):
    raise KeyboardInterrupt


def main():
    signal.signal(signal.SIGTERM, interrupt)
    parser = argparse.ArgumentParser(prog="scripts/check-ui.sh")
    parser.add_argument("simulator", type=UUID, metavar="DISPOSABLE_SIMULATOR_ID")
    parser.add_argument("--only-testing", action="append", metavar="XCTEST_IDENTIFIER")
    parser.add_argument("--keep-booted", action="store_true")
    parser.add_argument("--stop", action="store_true")
    args = parser.parse_args()
    if args.stop and (args.only_testing or args.keep_booted):
        parser.error("--stop must be used on its own")
    simulator = str(args.simulator).upper()
    if state(simulator) is None:
        parser.error(f"Simulator not found: {simulator}")
    if args.stop:
        shutdown(simulator)
        return 0

    started = time.monotonic()
    run_id = f"{time.strftime('%Y%m%d-%H%M%S')}-{os.getpid()}"
    derived = Path("build/ui-tests")
    derived.mkdir(parents=True, exist_ok=True)
    products = derived / "Build/Products"
    simulator_lock = Path(tempfile.gettempdir()) / f"mailern-ui-{simulator}.lock"
    with (derived / ".run.lock").open("a") as build_lock, simulator_lock.open("a") as lock:
        for held, resource in [(build_lock, "build products"), (lock, "Simulator")]:
            try:
                fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise RuntimeError(f"Another UI run is using these {resource}") from None
        succeeded = False
        try:
            # Boot while the build runs; bootstatus waits for it later.
            if state(simulator) == "Shutdown":
                run("xcrun", "simctl", "boot", simulator)
            run("xcodebuild", "-quiet", "-project", "Mailern.xcodeproj", "-scheme", "Mailern",
                "-destination", f"id={simulator}", "-derivedDataPath", derived, "ONLY_ACTIVE_ARCH=YES", "build-for-testing")
            # Active-architecture builds can leave older test runs for other architectures.
            test_run = max(products.glob("Mailern_*.xctestrun"), key=lambda path: path.stat().st_mtime_ns, default=None)
            if test_run is None:
                raise RuntimeError(f"No test run in {products}")
            plan = plistlib.loads(test_run.read_bytes())
            app = Path(plan["MailernUITests"]["UITargetAppPath"].replace("__TESTROOT__", str(products)))
            app_id = plistlib.loads((app / "Info.plist").read_bytes())["CFBundleIdentifier"]
            print(f"Build: {time.monotonic() - started:.0f}s", flush=True)

            run("xcrun", "simctl", "bootstatus", simulator, "-b", stdout=subprocess.DEVNULL)
            run("xcrun", "simctl", "install", simulator, str(app))
            documents = Path(output("xcrun", "simctl", "get_app_container", simulator, app_id, "data")) / "Documents"
            documents.mkdir(parents=True, exist_ok=True)
            shutil.copyfile("Tests/Fixtures/Sample attachment.txt", documents / "Sample attachment.txt")
            run("xcrun", "simctl", "addmedia", simulator, "Tests/Fixtures/Sample photo.png")

            for name in ["MailernUITests", "MailernTests"]:
                plan[name]["PreferredScreenCaptureFormat"] = "screenshots"
                plan[name]["SystemAttachmentLifetime"] = "keepNever"
            # The control file lets independent cases reset the fixture in one app process.
            # Tests forward these values to every launch, including ones that replace their environment.
            control = {
                "MAILERN_TEST_CONTROL_FILE": str(derived.resolve() / f"ui-control-{simulator}.json"),
                "MAILERN_TEST_CONTROL_NAME": f"{app_id}.ui-tests.{simulator}",
            }
            control["MAILERN_TEST_ANIMATIONS"] = os.environ.get("MAILERN_TEST_ANIMATIONS", "off")
            plan["MailernUITests"].setdefault("EnvironmentVariables", {}).update(control)
            ui_environment = plan["MailernUITests"].setdefault("UITargetAppEnvironmentVariables", {})
            ui_environment.update(control)
            ui_environment["OS_ACTIVITY_MODE"] = "disable"
            patched = products / f"Mailern-ui-{run_id}.xctestrun"
            patched.write_bytes(plistlib.dumps(plan))

            result = f"build/ui-{run_id}.xcresult"
            log = f"build/ui-{run_id}.log"
            selectors = args.only_testing or ["MailernUITests", "MailernTests"]
            print(f"Setup: {time.monotonic() - started:.0f}s. Testing, log in {log}", flush=True)
            with open(log, "w") as out:
                completed = subprocess.run(
                    ["xcodebuild", "-xctestrun", str(patched), "-destination", f"id={simulator}",
                     "-resultBundlePath", result, "test-without-building", "-parallel-testing-enabled", "NO",
                     *(f"-only-testing:{test}" for test in selectors)],
                    stdout=out, stderr=subprocess.STDOUT)
            summary = json.loads(output("xcrun", "xcresulttool", "get", "test-results", "summary", "--path", result))
            failed = re.findall(r"Test Case '-\[(\w+\.\w+ \w+)\]' failed", Path(log).read_text())
            if completed.returncode or summary["failedTests"] or summary["skippedTests"] or not summary["passedTests"]:
                raise RuntimeError(f"Tests failed: {', '.join(failed) or summary}. See {log} and {result}")
            if not args.only_testing:
                ran = set(re.findall(r"Test Case '-\[(\w+)\.(\w+) (\w+)\]' started\.", Path(log).read_text()))
                if ran != test_names() or summary["passedTests"] != len(ran):
                    raise RuntimeError(f"The run did not execute every test exactly once. See {log}")
            print(f"Passed {summary['passedTests']} tests", flush=True)
            succeeded = True
        finally:
            if not (args.keep_booted and succeeded):
                shutdown(simulator)
    print(f"UI tests completed in {time.monotonic() - started:.0f}s")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("UI test run interrupted", file=sys.stderr)
        sys.exit(130)
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
