# Test Pause Resume

This folder is the simplest way to run a single template through a pause/resume smoke flow with a Python workload.
Run the commands below from this directory.

Included workloads:
- `ffmpeg_thread_workload.py`
- `cpu_ram_proc_workload.py`

## Quick Start

Easy mode: low-pressure CPU/RAM test. This is the default workload and preset.

```bash
./test-pause-resume.sh $BASE_ID
```

Hard mode: higher-pressure CPU/RAM test.

```bash
./test-pause-resume.sh $BASE_ID --difficulty high
```

## How It Works

The script:
- defaults to `./cpu_ram_proc_workload.py` with `--difficulty low`
- base64-encodes the local Python file
- copies it into `/home/user/workspace` inside the resumed sandbox
- runs it with `python3`
- pauses the workload after `5s` by default
- resumes the paused snapshot and runs a simple check command
- uses `cmd/resume-build` under the hood

## Workloads

Use a different Python file by passing it as the second argument.

FFmpeg low preset:

```bash
./test-pause-resume.sh $BASE_ID ./ffmpeg_thread_workload.py
```

FFmpeg high preset:

```bash
./test-pause-resume.sh $BASE_ID ./ffmpeg_thread_workload.py --difficulty high
```

## CPU/RAM Presets

For `cpu_ram_proc_workload.py`, the script sets these automatically:

- `low`: `CPU_WORKERS=1`, `MEM_WORKERS_MAX=2`, `MEM_STEP_MB=32`, `TARGET_USED_MB=128`, `TARGET_BAND_LOW_MB=96`, `TARGET_BAND_HIGH_MB=160`
- `high`: `CPU_WORKERS=4`, `MEM_WORKERS_MAX=16`, `MEM_STEP_MB=32`, `TARGET_USED_MB=900`, `TARGET_BAND_LOW_MB=800`, `TARGET_BAND_HIGH_MB=980`

You can still override any of them inline if needed.

Example:

```bash
TARGET_USED_MB=256 \
TARGET_BAND_LOW_MB=224 \
TARGET_BAND_HIGH_MB=320 \
./test-pause-resume.sh $BASE_ID
```

## FFmpeg Presets

For `ffmpeg_thread_workload.py`, the script sets these automatically:

- `low`: `ROUNDS=2`, `JOBS_PER_ROUND=2`, `THREADS_PER_JOB=1`, `DURATION_SEC=10`, `STAGGER_SEC=0.5`, `OUTPUT_MODE=null`
- `high`: `ROUNDS=4`, `JOBS_PER_ROUND=8`, `THREADS_PER_JOB=8`, `DURATION_SEC=30`, `STAGGER_SEC=1`, `OUTPUT_MODE=mp4`

You can still override any of them inline if needed.

Example:

```bash
OUTPUT_MODE=null \
THREADS_PER_JOB=2 \
./test-pause-resume.sh $BASE_ID ./ffmpeg_thread_workload.py --difficulty high
```

## Notes

- Run as a user that can use `sudo`; the wrapper invokes `resume-build` with `sudo`.
- The resumed verification command defaults to `sleep 1` and can be overridden with `RESUME_CHECK_CMD`.
- Extra `resume-build` flags can be passed after `--`.
- `PAUSE_SECS` defaults to `5`.

Example:

```bash
  ./test-pause-resume.sh \
  $BASE_ID \
  ./ffmpeg_thread_workload.py \
  -- -cold -no-prefetch -v
```
