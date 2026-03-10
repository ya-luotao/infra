#!/usr/bin/env python3

import os
import subprocess
import time
from pathlib import Path


WORKDIR = Path("/home/user/workspace")
MARKER = WORKDIR / "marker.txt"

ROUNDS = int(os.environ.get("ROUNDS", "4"))
JOBS_PER_ROUND = int(os.environ.get("JOBS_PER_ROUND", "8"))
THREADS_PER_JOB = int(os.environ.get("THREADS_PER_JOB", "8"))
FILTER_THREADS = int(os.environ.get("FILTER_THREADS", str(THREADS_PER_JOB)))
FILTER_COMPLEX_THREADS = int(os.environ.get("FILTER_COMPLEX_THREADS", str(THREADS_PER_JOB)))
FILTER = os.environ.get("FILTER", "crop=960:1080:480:0,scale=1080:1920")
DURATION_SEC = int(os.environ.get("DURATION_SEC", "30"))
STAGGER_SEC = float(os.environ.get("STAGGER_SEC", "1"))
PRESET = os.environ.get("PRESET", "medium")
INPUT_SIZE = os.environ.get("INPUT_SIZE", "1920x1080")
INPUT_RATE = os.environ.get("INPUT_RATE", "30")
OUTPUT_MODE = os.environ.get("OUTPUT_MODE", "mp4").lower()
OUTPUT_PREFIX = os.environ.get("OUTPUT_PREFIX", "thread-grid")


def start(cmd: list[str]) -> subprocess.Popen[bytes]:
    return subprocess.Popen(cmd)


def output_args(round_idx: int, job_idx: int) -> list[str]:
    if OUTPUT_MODE == "null":
        return ["-f", "null", "-"]

    out = WORKDIR / f"{OUTPUT_PREFIX}-{round_idx:02d}-{job_idx:02d}.mp4"
    return [str(out)]


def main() -> None:
    WORKDIR.mkdir(parents=True, exist_ok=True)
    MARKER.write_text("started\n", encoding="utf-8")

    procs = []
    for round_idx in range(ROUNDS):
        for job_idx in range(JOBS_PER_ROUND):
            procs.append(
                start(
                    [
                        "ffmpeg",
                        "-y",
                        "-threads",
                        str(THREADS_PER_JOB),
                        "-filter_threads",
                        str(FILTER_THREADS),
                        "-filter_complex_threads",
                        str(FILTER_COMPLEX_THREADS),
                        "-f",
                        "lavfi",
                        "-i",
                        f"testsrc2=size={INPUT_SIZE}:rate={INPUT_RATE}",
                        "-vf",
                        FILTER,
                        "-preset",
                        PRESET,
                        "-t",
                        str(DURATION_SEC),
                        *output_args(round_idx, job_idx),
                    ]
                )
            )

        time.sleep(STAGGER_SEC)

    while True:
        alive = [proc for proc in procs if proc.poll() is None]
        if not alive:
            break
        time.sleep(1)


if __name__ == "__main__":
    main()
