#!/usr/bin/env python3
"""Sample an existing Resim process tree; never launch or attach to another app."""
from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import os
import pathlib
import plistlib
import statistics
import subprocess
import sys
import time
from dataclasses import dataclass

ROOT = pathlib.Path(__file__).resolve().parent.parent
HELPERS = ("oxipng", "gifsicle", "gifdiff", "resim-svg")
METHOD = (
    "Periodic /bin/ps RSS snapshots of one selected, already running Resim executable "
    "and its current descendants. Peaks are sampled resident-set sizes, not maximum "
    "allocations; short-lived helpers and between-sample peaks may be missed. Shared "
    "pages may be counted by more than one process. In-process codecs are included "
    "in app RSS. The monitor never launches an app."
)


@dataclass(frozen=True)
class Process:
    pid: int
    ppid: int
    rss_bytes: int
    executable: str


def parse_processes(output: str) -> list[Process]:
    """Parse ps's fixed numeric prefix without splitting paths containing spaces."""
    processes = []
    for line in output.splitlines():
        fields = line.strip().split(None, 3)
        if len(fields) != 4:
            continue
        try:
            pid, ppid, rss_kib = map(int, fields[:3])
        except ValueError:
            continue
        if pid > 0 and ppid >= 0 and rss_kib >= 0:
            processes.append(Process(pid, ppid, rss_kib * 1024, fields[3]))
    return processes


def read_processes() -> list[Process]:
    result = subprocess.run(
        ["/bin/ps", "-axo", "pid=,ppid=,rss=,comm="],
        capture_output=True, text=True, check=True,
    )
    return parse_processes(result.stdout)


def canonical_executable(value: str) -> str:
    return str(pathlib.Path(value).resolve()) if value.startswith("/") else value


def select_app(processes: list[Process], executable: str, pid: int | None) -> Process:
    executable = canonical_executable(executable)
    matches = [p for p in processes if canonical_executable(p.executable) == executable]
    if pid is not None:
        matches = [p for p in matches if p.pid == pid]
    if not matches:
        detail = f" (PID {pid})" if pid is not None else ""
        raise ValueError(f"No running process matches {executable}{detail}. Open that app before sampling.")
    if len(matches) > 1:
        raise ValueError(
            f"Multiple matching app processes: {', '.join(str(p.pid) for p in matches)}. "
            "Select exactly one with --pid."
        )
    return matches[0]


def descendants(processes: list[Process], app_pid: int) -> list[Process]:
    by_parent: dict[int, list[Process]] = {}
    for process in processes:
        by_parent.setdefault(process.ppid, []).append(process)
    result, pending, seen = [], [app_pid], {app_pid}
    while pending:
        for process in by_parent.get(pending.pop(), []):
            if process.pid not in seen:
                seen.add(process.pid)
                pending.append(process.pid)
                result.append(process)
    return sorted(result, key=lambda p: p.pid)


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def sample(processes: list[Process], app: Process, bundle: pathlib.Path, elapsed: float) -> dict:
    current = next((p for p in processes if p.pid == app.pid), None)
    if current is None or canonical_executable(current.executable) != canonical_executable(app.executable):
        raise ValueError(f"Selected app PID {app.pid} exited or changed executable; monitoring stopped.")
    children = descendants(processes, app.pid)
    helper_paths = {str((bundle / "Contents/Resources/Codecs" / name).resolve()): name for name in HELPERS}
    helper_rss = dict.fromkeys(HELPERS, 0)
    helper_pids = {name: [] for name in HELPERS}
    process_rows = []
    for process in [current, *children]:
        helper = helper_paths.get(canonical_executable(process.executable))
        role = "app" if process.pid == app.pid else ("helper" if helper else "other_descendant")
        process_rows.append(dict(pid=process.pid, ppid=process.ppid, rss_bytes=process.rss_bytes,
                                 executable=process.executable, role=role, helper=helper))
        if helper:
            helper_rss[helper] += process.rss_bytes
            helper_pids[helper].append(process.pid)
    descendants_rss = sum(p.rss_bytes for p in children)
    return dict(
        timestamp=utc_now(), elapsed_s=elapsed, app_pid=app.pid,
        app_executable=current.executable, processes=process_rows,
        app_rss_bytes=current.rss_bytes, descendant_rss_bytes=descendants_rss,
        codec_rss_bytes=sum(helper_rss.values()),
        aggregate_rss_bytes=current.rss_bytes + descendants_rss,
        helper_rss_bytes=helper_rss, helper_pids=helper_pids,
        codec_pids=sorted(pid for pids in helper_pids.values() for pid in pids),
    )


def peak(rows: list[dict], field: str, helper: str | None = None) -> dict:
    def value(row: dict) -> int:
        return row[field][helper] if helper else row[field]
    row = max(rows, key=value)
    if helper:
        pids = row["helper_pids"][helper]
    elif field == "app_rss_bytes":
        pids = [row["app_pid"]]
    elif field == "codec_rss_bytes":
        pids = row["codec_pids"]
    else:
        pids = [p["pid"] for p in row["processes"] if field != "descendant_rss_bytes" or p["role"] != "app"]
    return dict(rss_bytes=value(row), timestamp=row["timestamp"], elapsed_s=row["elapsed_s"], pids=pids)


def positive_seconds(value: str) -> float:
    result = float(value)
    if not math.isfinite(result) or result <= 0:
        raise argparse.ArgumentTypeError("must be a finite number greater than zero")
    return result


def resolve_app(path: pathlib.Path) -> tuple[pathlib.Path, str]:
    bundle = path.expanduser().resolve()
    info_path = bundle / "Contents/Info.plist"
    if not info_path.is_file():
        raise ValueError(f"App bundle does not exist or has no Info.plist: {bundle}")
    with info_path.open("rb") as handle:
        info = plistlib.load(handle)
    if not isinstance(info, dict):
        raise ValueError(f"Invalid app Info.plist: {info_path}")
    name = info.get("CFBundleExecutable")
    if not isinstance(name, str) or not name or pathlib.Path(name).name != name:
        raise ValueError(f"Invalid CFBundleExecutable in {info_path}")
    executable = bundle / "Contents/MacOS" / name
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise ValueError(f"App executable is missing or is not executable: {executable}")
    return bundle, str(executable.resolve())


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=pathlib.Path, default=ROOT / "dist/Resim.app",
                        help="existing app bundle to monitor (default: dist/Resim.app)")
    parser.add_argument("--pid", type=int, help="select one PID when multiple copies of the selected app are running")
    parser.add_argument("--seconds", type=positive_seconds, default=300)
    parser.add_argument("--interval", type=positive_seconds, default=0.2)
    parser.add_argument("--stop-file", type=pathlib.Path,
                        help="finish successfully when this new local marker appears")
    parser.add_argument("--output-prefix", type=pathlib.Path, default=ROOT / ".build/ui-resource",
                        help="local output prefix for -samples.jsonl and -summary.json")
    args = parser.parse_args()
    if args.pid is not None and args.pid <= 0:
        parser.error("--pid must be greater than zero")
    if args.stop_file is not None:
        args.stop_file = args.stop_file.expanduser().resolve()
        if args.stop_file.exists():
            parser.error("--stop-file must not exist before sampling starts")
    try:
        bundle, executable = resolve_app(args.app)
        initial_processes = read_processes()
        app = select_app(initial_processes, executable, args.pid)
    except (ValueError, OSError, plistlib.InvalidFileException, subprocess.SubprocessError) as error:
        parser.exit(1, f"monitor-resources: {error}\n")

    prefix = args.output_prefix.expanduser().resolve()
    samples_path = prefix.with_name(prefix.name + "-samples.jsonl")
    summary_path = prefix.with_name(prefix.name + "-summary.json")
    samples_path.parent.mkdir(parents=True, exist_ok=True)
    rows, status, error_message = [], "completed", None
    stop_reason = "duration"
    started, started_at = time.monotonic(), utc_now()
    deadline = started + args.seconds
    processes = initial_processes
    try:
        with samples_path.open("w") as handle:
            while True:
                before = time.monotonic()
                row = sample(processes, app, bundle, before - started)
                rows.append(row)
                handle.write(json.dumps(row, sort_keys=True) + "\n")
                handle.flush()
                if args.stop_file is not None and args.stop_file.exists():
                    stop_reason = "stop_file"
                    break
                if time.monotonic() >= deadline:
                    break
                delay = min(max(0, args.interval - (time.monotonic() - before)),
                            max(0, deadline - time.monotonic()))
                time.sleep(delay)
                if time.monotonic() >= deadline:
                    break
                processes = read_processes()
    except KeyboardInterrupt:
        status = "interrupted"
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        status, error_message = "failed", str(error)
    if not rows:
        print(f"monitor-resources: {error_message or 'No samples recorded.'}", file=sys.stderr)
        return 1
    gaps = [later["elapsed_s"] - earlier["elapsed_s"] for earlier, later in zip(rows, rows[1:])]
    summary = dict(
        started_at=started_at, completed_at=utc_now(), last_sample_timestamp=rows[-1]["timestamp"],
        status=status, error=error_message, method=METHOD,
        stop_reason=stop_reason, stop_file=str(args.stop_file) if args.stop_file else None,
        app_bundle=str(bundle), app_pid=app.pid, app_executable=app.executable,
        interval_seconds=args.interval, requested_duration_seconds=args.seconds,
        observed_interval_seconds=(dict(min=min(gaps), median=statistics.median(gaps), max=max(gaps))
                                   if gaps else None),
        actual_duration_seconds=time.monotonic() - started,
        sample_window_seconds=rows[-1]["elapsed_s"] - rows[0]["elapsed_s"],
        samples=len(rows), samples_path=str(samples_path),
        samples_with_codec=sum(bool(row["codec_pids"]) for row in rows),
        samples_with_helper={name: sum(bool(row["helper_pids"][name]) for row in rows) for name in HELPERS},
        baseline=rows[0], last_sample=rows[-1],
        peaks={field: peak(rows, field) for field in (
            "app_rss_bytes", "descendant_rss_bytes", "codec_rss_bytes", "aggregate_rss_bytes")},
        helper_peaks={name: peak(rows, "helper_rss_bytes", name) for name in HELPERS},
    )
    summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    print(json.dumps({key: value for key, value in summary.items() if key not in ("baseline", "last_sample")},
                     indent=2, sort_keys=True))
    if error_message:
        print(f"monitor-resources: {error_message}", file=sys.stderr)
    return 0 if status == "completed" else (130 if status == "interrupted" else 1)


if __name__ == "__main__":
    raise SystemExit(main())
