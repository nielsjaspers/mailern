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


def run_group(*args, timeout, **kwargs):
    """Run an Xcode phase in its own process group, so a timeout or Ctrl-C also stops its compilers and runners."""
    child = subprocess.Popen(args, text=True, start_new_session=True, **kwargs)
    try:
        return child.wait(timeout=timeout)
    except BaseException:
        stop_group(child)
        raise


def stop_group(child):
    """Ask the whole group to exit, then kill whatever outlives the grace period, even if the leader exited."""
    def signal_group(sig):
        try:
            os.killpg(child.pid, sig)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
    # A second Ctrl-C must not cut cleanup short and leave Xcode processes behind.
    previous = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM})
    try:
        if signal_group(signal.SIGTERM):
            deadline = time.monotonic() + 10
            while signal_group(0) and time.monotonic() < deadline:
                child.poll()
                time.sleep(0.2)
            signal_group(signal.SIGKILL)
        child.wait()
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous)


def output(*args, timeout=120):
    return run(*args, stdout=subprocess.PIPE, timeout=timeout).stdout.strip()


def state(simulator):
    listing = json.loads(output("xcrun", "simctl", "list", "devices", "-j", timeout=30))
    return next((device["state"] for group in listing["devices"].values() for device in group
                 if device["udid"] == simulator), None)


def shutdown(simulator):
    """Return whether the Simulator is off. Reports a failure itself, before cancellation can interrupt it."""
    # Finish teardown even if cancellation arrives, but never wait on CoreSimulator forever.
    previous = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM})
    try:
        # Shut down without a prior status probe, which could itself fail; the probe below checks the result.
        try:
            subprocess.run(["xcrun", "simctl", "shutdown", simulator], timeout=60,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except subprocess.TimeoutExpired:
            pass
        try:
            current = state(simulator)
        except Exception:
            current = "unknown"
        running = current not in (None, "Shutdown")
        if current is None:
            print(f"Simulator not found: {simulator}", file=sys.stderr, flush=True)
        elif running:
            print(f"Simulator {simulator} may still be running. Run scripts/check-ui.sh {simulator} --stop.",
                  file=sys.stderr, flush=True)
        else:
            print("Simulator shut down", flush=True)
        return current == "Shutdown"
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous)


def lock(path, resource):
    held = path.open("a")
    try:
        fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        held.close()
        raise RuntimeError(f"Another UI run is using the {resource}") from None
    return held


def test_names():
    """Every test method, so each run can prove that it ran exactly the selected tests."""
    names = set()
    for module, path in [("MailernUITests", "Tests/MailernUITests.swift"), ("MailernTests", "Tests/ComposerEditorTests.swift")]:
        cls = None
        for line in Path(path).read_text().splitlines():
            if match := re.match(r"(?:@MainActor )?(?:final )?class (\w+): (?:MailernUITestCase|XCTestCase)", line):
                cls = match[1]
            elif match := re.match(r"    func (test\w+)\(", line):
                names.add((module, cls, match[1]))
    return names


def selected(selectors):
    names = test_names()
    expected = set()
    for selector in selectors:
        parts = tuple(selector.split("/"))
        matches = {name for name in names if name[:len(parts)] == parts}
        if not matches:
            raise RuntimeError(f"No test matches {selector}")
        expected |= matches
    return expected


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
    simulator_lock = Path(tempfile.gettempdir()) / f"mailern-ui-{simulator}.lock"
    if args.stop:
        # Recovery must not depend on listing devices first.
        with lock(simulator_lock, "Simulator"):
            return 0 if shutdown(simulator) else 1
    selectors = args.only_testing or ["MailernUITests", "MailernTests"]
    expected = selected(selectors)

    started = time.monotonic()
    run_id = f"{time.strftime('%Y%m%d-%H%M%S')}-{os.getpid()}"
    derived = Path("build/ui-tests")
    derived.mkdir(parents=True, exist_ok=True)
    products = derived / "Build/Products"
    with lock(derived / ".run.lock", "build products"), lock(simulator_lock, "Simulator"):
        succeeded = False
        try:
            initial = state(simulator)
            if initial is None:
                raise RuntimeError(f"Simulator not found: {simulator}")
            # Boot while the build runs; bootstatus waits for it later.
            if initial == "Shutdown":
                run("xcrun", "simctl", "boot", simulator, timeout=120)
            build = ["xcodebuild", "-quiet", "-project", "Mailern.xcodeproj", "-scheme", "Mailern", "-destination",
                     f"id={simulator}", "-derivedDataPath", str(derived), "ONLY_ACTIVE_ARCH=YES", "build-for-testing"]
            if run_group(*build, timeout=1800):
                raise RuntimeError("Build failed")
            # Active-architecture builds can leave older test runs for other architectures.
            test_run = max(products.glob("Mailern_*.xctestrun"), key=lambda path: path.stat().st_mtime_ns, default=None)
            if test_run is None:
                raise RuntimeError(f"No test run in {products}")
            plan = plistlib.loads(test_run.read_bytes())
            app = Path(plan["MailernUITests"]["UITargetAppPath"].replace("__TESTROOT__", str(products)))
            app_id = plistlib.loads((app / "Info.plist").read_bytes())["CFBundleIdentifier"]
            print(f"Build: {time.monotonic() - started:.0f}s", flush=True)

            run("xcrun", "simctl", "bootstatus", simulator, "-b", stdout=subprocess.DEVNULL, timeout=300)
            run("xcrun", "simctl", "install", simulator, str(app), timeout=120)
            documents = Path(output("xcrun", "simctl", "get_app_container", simulator, app_id, "data")) / "Documents"
            documents.mkdir(parents=True, exist_ok=True)
            shutil.copyfile("Tests/Fixtures/Sample attachment.txt", documents / "Sample attachment.txt")
            run("xcrun", "simctl", "addmedia", simulator, "Tests/Fixtures/Sample photo.png", timeout=120)

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
            print(f"Setup: {time.monotonic() - started:.0f}s. Testing, log in {log}", flush=True)
            # XCTest limits each case once it runs. This bounds a stall before or between cases.
            with open(log, "w") as out:
                try:
                    code = run_group(
                        "xcodebuild", "-xctestrun", str(patched), "-destination", f"id={simulator}",
                        "-resultBundlePath", result, "test-without-building", "-parallel-testing-enabled", "NO",
                        # A hung case fails on its own instead of stalling the serial run.
                        "-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", "120",
                        "-maximum-test-execution-time-allowance", "180",
                        *(f"-only-testing:{test}" for test in selectors),
                        stdout=out, stderr=subprocess.STDOUT, timeout=600)
                except subprocess.TimeoutExpired:
                    raise RuntimeError(f"Tests timed out. See {log}") from None
            if not Path(result).exists():
                raise RuntimeError(f"xcodebuild failed before testing. See {log}")
            summary = json.loads(output("xcrun", "xcresulttool", "get", "test-results", "summary", "--path", result))
            failed = re.findall(r"Test Case '-\[(\w+\.\w+ \w+)\]' failed", Path(log).read_text())
            if code or summary["failedTests"] or summary["skippedTests"]:
                raise RuntimeError(f"Tests failed: {', '.join(failed) or summary}. See {log} and {result}")
            ran = re.findall(r"Test Case '-\[(\w+)\.(\w+) (\w+)\]' started\.", Path(log).read_text())
            if sorted(ran) != sorted(expected) or summary["passedTests"] != len(expected):
                raise RuntimeError(f"The run did not execute each selected test exactly once. See {log}")
            print(f"Passed {summary['passedTests']} tests", flush=True)
            succeeded = True
        finally:
            if not (args.keep_booted and succeeded):
                try:
                    stopped = shutdown(simulator)
                except BaseException:
                    if succeeded:
                        raise
                    # Keep the build or test failure as the reported error, even after a second Ctrl-C.
                    stopped = True
                if succeeded and not stopped:
                    raise RuntimeError("Tests passed, but the Simulator did not shut down")
    print(f"UI tests completed in {time.monotonic() - started:.0f}s")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("UI test run interrupted", file=sys.stderr)
        sys.exit(130)
    except (RuntimeError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
