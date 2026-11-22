#!/usr/bin/env python3
"""Sample combined RSS for this Stow build and allocated blocks in its engine staging."""
import argparse
from pathlib import Path
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--build", type=Path, required=True)
parser.add_argument("--staging", type=Path, required=True)
parser.add_argument("command", nargs=argparse.REMAINDER)
args = parser.parse_args()
if not args.command or args.command[0] != "--" or len(args.command) == 1:
    parser.error("supply the benchmark command after --")


def processes():
    """Track this build's app and XPC, and their children including 7zz."""
    output = subprocess.check_output(["/bin/ps", "-axo", "pid=,ppid=,rss=,comm="], text=True)
    rows = []
    for line in output.splitlines():
        fields = line.split(maxsplit=3)
        if len(fields) == 4:
            rows.append((int(fields[0]), int(fields[1]), int(fields[2]), fields[3]))
    build = str(args.build.resolve()) + "/"
    chosen = {pid for pid, _, _, path in rows if path.startswith(build) and
              Path(path).name in {"Stow", "StowEngine"}}
    while True:
        children = {pid for pid, parent, _, _ in rows if parent in chosen}
        if children <= chosen:
            break
        chosen.update(children)
    return sum(rss for pid, _, rss, _ in rows if pid in chosen)


def allocated_kib():
    result = subprocess.run(["/usr/bin/du", "-sk", str(args.staging)], text=True, capture_output=True)
    if result.returncode:
        return None
    return int(result.stdout.split()[0])


staging_start = allocated_kib()
peak_rss = 0
peak_disk = staging_start
disk_samples = 0
rss_samples = 0
with subprocess.Popen(args.command[1:]) as benchmark:
    while benchmark.poll() is None:
        rss = processes()
        if rss > 0:
            peak_rss = max(peak_rss, rss)
            rss_samples += 1
            observed = allocated_kib()
            if observed is not None:
                peak_disk = observed if peak_disk is None else max(peak_disk, observed)
                disk_samples += 1
        time.sleep(0.025)
    result = benchmark.returncode

disk = "unavailable" if peak_disk is None or not disk_samples else peak_disk
baseline = "unavailable" if staging_start is None else staging_start
print(f"STOW_BENCHMARK resources sampled_peak_rss_kib={peak_rss} rss_samples={rss_samples} "
      f"engine_staging_peak_allocated_kib={disk} engine_staging_start_allocated_kib={baseline} "
      f"engine_staging_samples={disk_samples}", flush=True)
raise SystemExit(result)
