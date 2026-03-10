#!/usr/bin/env python3

import multiprocessing as mp
import os
import signal
import sys
import time
from pathlib import Path


WORKDIR = Path("/home/user/workspace")
MARKER = WORKDIR / "marker.txt"
STATE = WORKDIR / "cpuram-state.txt"

CPU_WORKERS = int(os.environ.get("CPU_WORKERS", "2"))
MEM_WORKERS_MAX = int(os.environ.get("MEM_WORKERS_MAX", "16"))
MEM_STEP_MB = int(os.environ.get("MEM_STEP_MB", "32"))
TARGET_USED_MB = int(os.environ.get("TARGET_USED_MB", "440"))
TARGET_BAND_LOW_MB = int(os.environ.get("TARGET_BAND_LOW_MB", "350"))
TARGET_BAND_HIGH_MB = int(os.environ.get("TARGET_BAND_HIGH_MB", "500"))
SPAWN_INTERVAL_SEC = float(os.environ.get("SPAWN_INTERVAL_SEC", "0.25"))
SAMPLE_INTERVAL_SEC = float(os.environ.get("SAMPLE_INTERVAL_SEC", "0.5"))


def read_meminfo_mb() -> tuple[int, int, int]:
    total_kb = 0
    avail_kb = 0
    with open("/proc/meminfo", "r", encoding="utf-8") as f:
        for line in f:
            if line.startswith("MemTotal:"):
                total_kb = int(line.split()[1])
            elif line.startswith("MemAvailable:"):
                avail_kb = int(line.split()[1])
    used_kb = max(total_kb - avail_kb, 0)
    return total_kb // 1024, avail_kb // 1024, used_kb // 1024


def cpu_worker() -> None:
    x = 0
    while True:
        x = (x + 1) % 1000003


def mem_worker(step_mb: int) -> None:
    # Hold a fixed anonymous allocation alive in this worker process.
    chunk = bytearray(step_mb * 1024 * 1024)
    for i in range(0, len(chunk), 4096):
        chunk[i] = 1
    while True:
        time.sleep(1)


def write_state(message: str) -> None:
    STATE.write_text(message + "\n", encoding="utf-8")


def terminate_all(procs: list[mp.Process]) -> None:
    for proc in procs:
        if proc.is_alive():
            proc.terminate()
    for proc in procs:
        proc.join(timeout=2)
    for proc in procs:
        if proc.is_alive():
            proc.kill()
            proc.join(timeout=2)


def main() -> None:
    WORKDIR.mkdir(parents=True, exist_ok=True)
    MARKER.write_text("started\n", encoding="utf-8")

    cpu_procs: list[mp.Process] = []
    mem_procs: list[mp.Process] = []

    def handle_signal(signum: int, _frame) -> None:
        write_state(f"signal={signum}")
        terminate_all(cpu_procs + mem_procs)
        sys.exit(0)

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    for _ in range(CPU_WORKERS):
        proc = mp.Process(target=cpu_worker, daemon=False)
        proc.start()
        cpu_procs.append(proc)

    while len(mem_procs) < MEM_WORKERS_MAX:
        total_mb, avail_mb, used_mb = read_meminfo_mb()
        write_state(
            f"total_mb={total_mb} avail_mb={avail_mb} used_mb={used_mb} "
            f"cpu_workers={len(cpu_procs)} mem_workers={len(mem_procs)}"
        )
        if used_mb >= TARGET_USED_MB:
            break
        proc = mp.Process(target=mem_worker, args=(MEM_STEP_MB,), daemon=False)
        proc.start()
        mem_procs.append(proc)
        time.sleep(SPAWN_INTERVAL_SEC)

    while True:
        total_mb, avail_mb, used_mb = read_meminfo_mb()
        write_state(
            f"total_mb={total_mb} avail_mb={avail_mb} used_mb={used_mb} "
            f"cpu_workers={len(cpu_procs)} mem_workers={len(mem_procs)}"
        )

        if used_mb < TARGET_BAND_LOW_MB and len(mem_procs) < MEM_WORKERS_MAX:
            proc = mp.Process(target=mem_worker, args=(MEM_STEP_MB,), daemon=False)
            proc.start()
            mem_procs.append(proc)
        elif used_mb > TARGET_BAND_HIGH_MB and mem_procs:
            proc = mem_procs.pop()
            if proc.is_alive():
                proc.terminate()
                proc.join(timeout=2)
                if proc.is_alive():
                    proc.kill()
                    proc.join(timeout=2)

        time.sleep(SAMPLE_INTERVAL_SEC)


if __name__ == "__main__":
    main()
