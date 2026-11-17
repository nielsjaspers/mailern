#!/usr/bin/env python3
"""Run duration-balanced UI batches on a dedicated disposable Simulator pool."""
import concurrent.futures
import fcntl
import json
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


_children = set()
_child_lock = threading.RLock()
_stopping = threading.Event()


def interrupt(signum, frame):
    _stopping.set()
    with _child_lock:
        for child in list(_children):
            child.terminate()
    raise KeyboardInterrupt


def run(*args, **kwargs):
    if _stopping.is_set():
        raise InterruptedError("UI run stopped")
    with subprocess.Popen(args, text=True, **kwargs) as child:
        with _child_lock:
            _children.add(child)
            if _stopping.is_set():
                child.terminate()
        try:
            stdout, stderr = child.communicate()
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
    return [{**device, "runtime": runtime} for runtime, group in json.loads(output("xcrun", "simctl", "list", "devices", "-j"))["devices"].items() for device in group]


def timings(log):
    cases = re.findall(r"Test Case '-\[(MailernUITests|MailernTests)\.(\w+) (\w+)\]' started.\(([\d.]+) seconds\)", log)
    result = {}
    for (module, cls, method), seconds in {(m, c, t): float(s) for m, c, t, s in cases}.items():
        key = cls if module == "MailernUITests" else "MailernTests"
        result[key] = result.get(key, 0) + seconds
    return result


def main():
    signal.signal(signal.SIGINT, interrupt)
    signal.signal(signal.SIGTERM, interrupt)
    simulator = sys.argv[1]
    pool_lock_path = Path(tempfile.gettempdir()) / f"mailern-ui-{simulator}.lock"
    if sys.argv[2] == "--stop":
        with pool_lock_path.open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            selected = [d for d in devices() if d["udid"] == simulator or re.fullmatch(rf"Mailern UI {re.escape(simulator)} worker [1-9][0-9]*", d["name"])]
            for device in selected:
                if device["state"] != "Shutdown":
                    run("xcrun", "simctl", "shutdown", device["udid"])
            print(f"Stopped the disposable pool for {simulator}")
        return 0
    simulator, workers, derived_data, run_id = sys.argv[1:]
    started = time.monotonic()
    workers = int(workers)
    derived = Path(derived_data)
    derived.mkdir(parents=True, exist_ok=True)
    products = derived / "Build/Products"
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
    with (derived / ".run.lock").open("a") as build_lock, pool_lock_path.open("a") as pool_lock:
        for lock, resource in [(build_lock, "build products"), (pool_lock, "Simulator pool")]:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise RuntimeError(f"Another UI run is using these {resource}") from None
        pool = []
        prepared = False
        try:
            run("xcodebuild", "-project", "Mailern.xcodeproj", "-scheme", "Mailern", "-destination", f"id={simulator}",
                "-derivedDataPath", derived_data, "ONLY_ACTIVE_ARCH=YES", "build-for-testing")
            test_runs = list(products.glob("Mailern_*.xctestrun"))
            if not test_runs:
                raise RuntimeError(f"No test run in {products}")
            # Active-architecture builds can leave older test runs for other architectures.
            plan = plistlib.loads(max(test_runs, key=lambda path: path.stat().st_mtime_ns).read_bytes())
            for name in ["MailernUITests", "MailernTests"]:
                plan[name]["PreferredScreenCaptureFormat"] = "screenshots"
                plan[name]["SystemAttachmentLifetime"] = "keepNever"
            test_run = products / f"Mailern-ui-{run_id}.xctestrun"
            test_run.write_bytes(plistlib.dumps(plan))
            app = Path(plan["MailernUITests"]["UITargetAppPath"].replace("__TESTROOT__", str(products)))
            app_id = plistlib.loads((app / "Info.plist").read_bytes())["CFBundleIdentifier"]
            run("xcrun", "simctl", "bootstatus", simulator, "-b")
            run("xcrun", "simctl", "install", simulator, str(app))
            documents = Path(output("xcrun", "simctl", "get_app_container", simulator, app_id, "data")) / "Documents"
            documents.mkdir(parents=True, exist_ok=True)
            shutil.copyfile("Tests/Fixtures/Sample attachment.txt", documents / "Sample attachment.txt")
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
            prepared = True
            print(f"Pool preparation: {time.monotonic() - started:.1f}s", flush=True)
            cache = derived / "test-durations.json"
            costs = json.loads(cache.read_text()) if cache.exists() else {}
            # The fixture Simulator also takes ordinary cases instead of sitting idle after imports.
            batches = [pickers.copy(), *[[] for _ in pool]]
            loads = [sum(costs.get(name, 60) for name in pickers), *[0.0 for _ in pool]]
            jobs = [name for name in classes if name not in pickers] + ["MailernTests"]
            known = [costs[name] for name in classes if name in costs]
            fallback = sum(known) / len(known) if known else 1
            for name in sorted(jobs, key=lambda name: costs.get(name, fallback), reverse=True):
                index = min(range(workers + 1), key=loads.__getitem__)
                batches[index].append(name)
                loads[index] += costs.get(name, fallback)

            def batch(name, destination, tests):
                batch_started = time.monotonic()
                prefix = f"build/ui-{run_id}-{name}"
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
                return f"{prefix}.xcresult", timings(Path(f"{prefix}.log").read_text())

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
            return 0
        finally:
            # Prepared workers stay ready for reruns. Interrupted setup must not leak active devices.
            if not prepared or _stopping.is_set():
                for device in [simulator, *pool]:
                    if device:
                        subprocess.run(["xcrun", "simctl", "shutdown", device], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("UI test run interrupted", file=sys.stderr)
        sys.exit(130)
