#!/usr/bin/env python3
"""Run duration-balanced UI batches on a dedicated disposable Simulator pool."""
import argparse
import concurrent.futures
import copy
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
import threading
import time
from uuid import UUID


WORKER_NAME = re.compile(r"Mailern UI ([A-F0-9-]{36}) worker [1-9][0-9]*", re.IGNORECASE)

_children = set()
_child_lock = threading.RLock()
_stopping = threading.Event()


def interrupt(signum, frame):
    _stopping.set()
    with _child_lock:
        for child in list(_children):
            child.terminate()


def run(*args, **kwargs):
    if _stopping.is_set():
        raise KeyboardInterrupt
    with subprocess.Popen(args, text=True, **kwargs) as child:
        with _child_lock:
            _children.add(child)
            if _stopping.is_set():
                child.terminate()
        try:
            stdout, stderr = child.communicate()
            if _stopping.is_set():
                raise KeyboardInterrupt
            if child.returncode:
                raise subprocess.CalledProcessError(child.returncode, args, stdout, stderr)
            return subprocess.CompletedProcess(args, child.returncode, stdout, stderr)
        except BaseException:
            if child.poll() is None:
                child.terminate()
            child.wait()
            raise
        finally:
            with _child_lock:
                _children.discard(child)


def output(*args):
    return run(*args, stdout=subprocess.PIPE).stdout.strip()


def devices():
    listing = subprocess.check_output(["xcrun", "simctl", "list", "devices", "-j"], text=True)
    return [
        {**device, "runtime": runtime}
        for runtime, group in json.loads(listing)["devices"].items()
        for device in group
    ]


def timings(log):
    cases = re.findall(r"Test Case '-\[(MailernUITests|MailernTests)\.(\w+) (\w+)\]' passed \(([\d.]+) seconds\)", log)
    result = {}
    for (module, cls, method), seconds in {(m, c, t): float(s) for m, c, t, s in cases}.items():
        key = cls if module == "MailernUITests" else "MailernTests"
        result[key] = result.get(key, 0) + seconds
    return result


def worker_fixture(device):
    match = WORKER_NAME.fullmatch(device["name"])
    return match[1].upper() if match else None


def stop_simulators(simulator, include_workers):

    def active_devices():
        return [
            device for device in devices()
            if device["state"] != "Shutdown" and (
                device["udid"] == simulator or (include_workers and worker_fixture(device) == simulator)
            )
        ]

    # Finish teardown if cancellation arrives while the pool is shutting down.
    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM})
    try:
        for device in active_devices():
            subprocess.run(["xcrun", "simctl", "shutdown", device["udid"]])
        remaining = active_devices()
        if remaining:
            names = ", ".join(device["name"] for device in remaining)
            raise RuntimeError(f"Simulators still running: {names}. Run scripts/check-ui.sh {simulator} --stop.")
        print("Simulator cleanup complete", flush=True)
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)


def main():
    parser = argparse.ArgumentParser(prog="scripts/check-ui.sh")
    parser.add_argument("simulator", type=UUID, metavar="DISPOSABLE_SIMULATOR_ID")
    parser.add_argument("workers", type=int, choices=range(1, 11), nargs="?", metavar="WORKERS")
    parser.add_argument("--only-testing", action="append", metavar="XCTEST_IDENTIFIER")
    parser.add_argument("--keep-booted", action="store_true")
    parser.add_argument("--stop", action="store_true")
    args = parser.parse_args()
    if args.stop and (args.workers or args.only_testing or args.keep_booted):
        parser.error("--stop must be used on its own")
    if args.workers and args.only_testing:
        parser.error("WORKERS applies to the full suite only")

    signal.signal(signal.SIGINT, interrupt)
    signal.signal(signal.SIGTERM, interrupt)
    simulator = str(args.simulator).upper()
    fixture = next((device for device in devices() if device["udid"] == simulator), None)
    if fixture is None and not args.stop:
        parser.error(f"Simulator not found: {simulator}")
    if fixture is not None and (parent := worker_fixture(fixture)):
        parser.error(f"{fixture['name']} is a managed worker. Use its fixture ID {parent}.")

    pool_lock_path = Path(tempfile.gettempdir()) / f"mailern-ui-{simulator}.lock"
    if args.stop:
        with pool_lock_path.open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            stop_simulators(simulator, include_workers=True)
        return 0

    started = time.monotonic()
    run_id = f"{time.strftime('%Y%m%d-%H%M%S')}-{os.getpid()}"
    workers = args.workers or 4
    derived = Path("build/ui-tests")
    derived.mkdir(parents=True, exist_ok=True)
    products = derived / "Build/Products"
    with (derived / ".run.lock").open("a") as build_lock, pool_lock_path.open("a") as pool_lock:
        for lock, resource in [(build_lock, "build products"), (pool_lock, "Simulator pool")]:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise RuntimeError(f"Another UI run is using these {resource}") from None
        pool = []
        succeeded = False
        try:
            run("xcodebuild", "-project", "Mailern.xcodeproj", "-scheme", "Mailern", "-destination", f"id={simulator}",
                "-derivedDataPath", derived, "ONLY_ACTIVE_ARCH=YES", "build-for-testing")
            test_runs = list(products.glob("Mailern_*.xctestrun"))
            if not test_runs:
                raise RuntimeError(f"No test run in {products}")
            # Active-architecture builds can leave older test runs for other architectures.
            test_run = max(test_runs, key=lambda path: path.stat().st_mtime_ns)
            plan = plistlib.loads(test_run.read_bytes())
            app = Path(plan["MailernUITests"]["UITargetAppPath"].replace("__TESTROOT__", str(products)))
            app_id = plistlib.loads((app / "Info.plist").read_bytes())["CFBundleIdentifier"]
            run("xcrun", "simctl", "bootstatus", simulator, "-b")
            run("xcrun", "simctl", "install", simulator, str(app))
            documents = Path(output("xcrun", "simctl", "get_app_container", simulator, app_id, "data")) / "Documents"
            documents.mkdir(parents=True, exist_ok=True)
            shutil.copyfile("Tests/Fixtures/Sample attachment.txt", documents / "Sample attachment.txt")
            if args.only_testing:
                run("xcrun", "simctl", "addmedia", simulator, "Tests/Fixtures/Sample photo.png")
                result = f"build/ui-{run_id}-focused.xcresult"
                run("xcodebuild", "-xctestrun", str(test_run), "-destination", f"id={simulator}",
                    "-resultBundlePath", result, "test-without-building", "-parallel-testing-enabled", "NO",
                    *(f"-only-testing:{test}" for test in args.only_testing))
                summary = json.loads(output("xcrun", "xcresulttool", "get", "test-results", "summary", "--path", result))
                if not summary["passedTests"] or summary["failedTests"]:
                    raise RuntimeError(f"No tests passed or some tests failed: {result}")
                succeeded = True
                return 0

            source = Path("Tests/MailernUITests.swift").read_text()
            classes = re.findall(r"^final class (\w+): MailernUITestCase \{", source, re.M)
            if not classes or len(classes) != len(re.findall(r"^    func test\w+\(", source, re.M)):
                raise RuntimeError("Each UI test must have its own class")
            methods = re.findall(r"^    func (test\w+)\(", source, re.M)
            ui_cases = dict(zip(classes, methods))
            pickers = ["ComposerFileAttachmentUITests", "ComposerPhotoAttachmentUITests"]
            if not set(pickers) <= set(classes):
                raise RuntimeError("Native picker test classes are missing")
            editor_methods = re.findall(r"^    func (test\w+)\(", Path("Tests/ComposerEditorTests.swift").read_text(), re.M)
            editor_count = len(editor_methods)

            for name in ["MailernUITests", "MailernTests"]:
                plan[name]["PreferredScreenCaptureFormat"] = "screenshots"
                plan[name]["SystemAttachmentLifetime"] = "keepNever"
            plan["MailernUITests"].setdefault("UITargetAppEnvironmentVariables", {})["OS_ACTIVITY_MODE"] = "disable"
            available = devices()
            template = next(device for device in available if device["udid"] == simulator)
            names = [f"Mailern UI {simulator} worker {i + 1}" for i in range(workers)]
            for name in names:
                matches = [device for device in available if device["name"] == name]
                if len(matches) > 1:
                    raise RuntimeError(f"Multiple Simulators named {name}")
                if matches:
                    device = matches[0]
                    if not device["isAvailable"] or any(device[key] != template[key] for key in ["runtime", "deviceTypeIdentifier"]):
                        raise RuntimeError(f"Simulator {name} does not match the supplied template")
                    pool.append(device["udid"])
                else:
                    pool.append(None)
            missing = [i for i, device in enumerate(pool) if device is None]
            cold_start = bool(missing) or any(device["udid"] in pool and device["state"] != "Booted" for device in available)
            if missing:
                print(f"Creating {len(missing)} disposable workers; later runs reuse them", flush=True)
                run("xcrun", "simctl", "shutdown", simulator)
                errors = []
                with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
                    futures = {executor.submit(output, "xcrun", "simctl", "clone", simulator, names[i]): i for i in missing}
                    for future in concurrent.futures.as_completed(futures):
                        try:
                            pool[futures[future]] = future.result()
                        except Exception as error:
                            errors.append(error)
                if errors:
                    raise errors[0]
            else:
                print(f"Reusing {workers} disposable workers", flush=True)

            def boot(index, device):
                with open(f"build/ui-{run_id}-boot-{index}.log", "w") as log:
                    run("xcrun", "simctl", "bootstatus", device, "-b", stdout=log, stderr=log)

            # Finish booting before UI gestures compete with Simulator setup.
            with concurrent.futures.ThreadPoolExecutor(max_workers=workers + 1) as executor:
                futures = [executor.submit(boot, i, device) for i, device in enumerate([simulator, *pool])]
                for future in concurrent.futures.as_completed(futures):
                    future.result()
            run("xcrun", "simctl", "addmedia", simulator, "Tests/Fixtures/Sample photo.png")
            print(f"Pool preparation: {time.monotonic() - started:.1f}s", flush=True)
            cache = derived / "test-durations.json"
            costs = json.loads(cache.read_text()) if cache.exists() else {}
            # The fixture Simulator also takes ordinary cases instead of sitting idle after imports.
            batches = [pickers.copy(), *[[] for _ in pool]]
            jobs = [name for name in classes if name not in pickers] + ["MailernTests"]
            known = [costs[name] for name in classes if name in costs]
            fallback = sum(known) / len(known) if known else 1
            loads = [sum(costs.get(name, fallback) for name in pickers), *[0.0 for _ in pool]]
            for name in sorted(jobs, key=lambda name: costs.get(name, fallback), reverse=True):
                index = min(range(workers + 1), key=loads.__getitem__)
                batches[index].append(name)
                loads[index] += costs.get(name, fallback)

            def batch(name, destination, tests):
                batch_started = time.monotonic()
                prefix = f"build/ui-{run_id}-{name}"
                batch_plan = copy.deepcopy(plan)
                control_directory = derived.resolve() / "ui-control"
                control_directory.mkdir(exist_ok=True)
                control = {
                    "MAILERN_TEST_CONTROL_FILE": str(control_directory / f"{destination}.json"),
                    "MAILERN_TEST_CONTROL_NAME": f"{app_id}.ui-tests.{destination}",
                }
                for key in ["EnvironmentVariables", "UITargetAppEnvironmentVariables"]:
                    batch_plan["MailernUITests"].setdefault(key, {}).update(control)
                test_run = products / f"Mailern-ui-{run_id}-{name}.xctestrun"
                test_run.write_bytes(plistlib.dumps(batch_plan))
                expected = sum(editor_count if test == "MailernTests" else 1 for test in tests)
                selectors = [f"-only-testing:{test}" if test == "MailernTests" else f"-only-testing:MailernUITests/{test}" for test in tests]
                with open(f"{prefix}.log", "w") as log:
                    print(f"Starting {name}: {expected} tests", flush=True)
                    run("xcodebuild", "-xctestrun", str(test_run), "-destination", f"id={destination}",
                        "-resultBundlePath", f"{prefix}.xcresult", "test-without-building",
                        "-parallel-testing-enabled", "NO", *selectors, stdout=log, stderr=log)
                    summary = json.loads(output("xcrun", "xcresulttool", "get", "test-results", "summary", "--path", f"{prefix}.xcresult"))
                    if summary["passedTests"] != expected or summary["failedTests"] or summary["skippedTests"]:
                        raise RuntimeError(f"{name}: expected {expected} passes, got {summary}")
                    expected_cases = {
                        ("MailernTests", "ComposerEditorTests", method)
                        for method in editor_methods if "MailernTests" in tests
                    } | {
                        ("MailernUITests", test, ui_cases[test])
                        for test in tests if test != "MailernTests"
                    }
                    started_cases = re.findall(
                        r"Test Case '-\[(MailernUITests|MailernTests)\.(\w+) (\w+)\]' started\.",
                        Path(f"{prefix}.log").read_text(),
                    )
                    if len(started_cases) != expected or set(started_cases) != expected_cases:
                        raise RuntimeError(f"{name}: missing, duplicate, or unexpected test executions")
                    print(f"Passed {name}: {expected} unique tests, no retries, {time.monotonic() - batch_started:.1f}s including validation", flush=True)
                durations = timings(Path(f"{prefix}.log").read_text())
                if set(durations) != set(tests):
                    raise RuntimeError(f"{name}: missing test durations; refusing an incomplete timing cache")
                return f"{prefix}.xcresult", durations

            failures = []
            results = []
            measured = {}
            # Cold runner startup can stall the native Photos transfer service.
            if cold_start:
                print("Running native pickers before cold worker startup", flush=True)
                result, durations = batch("pickers", simulator, pickers)
                results.append(result)
                measured.update(durations)
                batches[0] = [name for name in batches[0] if name not in pickers]
            with concurrent.futures.ThreadPoolExecutor(max_workers=min(workers, 3) if cold_start else workers + 1) as executor:
                futures = {
                    executor.submit(batch, "fixture-worker" if i == 0 else f"worker-{i}", device, batches[i]):
                    "fixture-worker" if i == 0 else f"worker-{i}"
                    for i, device in enumerate([simulator, *pool]) if batches[i]
                }
                for future in concurrent.futures.as_completed(futures):
                    try:
                        result, durations = future.result()
                        results.append(result)
                        measured.update(durations)
                    except Exception as error:
                        name = futures[future]
                        failures.append(name)
                        print(f"{name} failed: {error}. See build/ui-{run_id}-{name}.log", file=sys.stderr, flush=True)
            if failures:
                return 1
            next_cache = cache.with_name(f"test-durations-{run_id}.tmp")
            next_cache.write_text(json.dumps(measured, sort_keys=True, indent=2) + "\n")
            next_cache.replace(cache)
            run("xcrun", "xcresulttool", "merge", "--output-path", f"build/ui-{run_id}.xcresult", *results)
            summary = json.loads(output("xcrun", "xcresulttool", "get", "test-results", "summary", "--path", f"build/ui-{run_id}.xcresult"))
            if summary["passedTests"] != len(classes) + editor_count or summary["failedTests"] or summary["skippedTests"]:
                raise RuntimeError(f"Merged suite has incomplete coverage: {summary}")
            print(f"Passed {len(classes)} UI tests and {editor_count} editor tests", flush=True)
            succeeded = True
        finally:
            if not (args.keep_booted and succeeded and not _stopping.is_set()):
                stop_simulators(simulator, include_workers=not args.only_testing)

    print(f"Full UI suite completed in {time.monotonic() - started:.0f}s")
    return 0


if __name__ == "__main__":
    try:
        result = main()
        if _stopping.is_set():
            raise KeyboardInterrupt
        sys.exit(result)
    except KeyboardInterrupt:
        print("UI test run interrupted", file=sys.stderr)
        sys.exit(130)
