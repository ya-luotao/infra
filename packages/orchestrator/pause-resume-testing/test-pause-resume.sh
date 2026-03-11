#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: ./test-pause-resume.sh <build-id> [python-file] [--difficulty <low|high>] [--orchestrator-dir <path>] [--storage <path>] [--pause-seconds <n>] [-- <resume-build args...>]

This script:
1. resumes a base build
2. runs the Python workload in the guest
3. waits N seconds
4. pauses into a new snapshot
5. resumes that paused snapshot to verify it comes back

Defaults:
- workload: ./cpu_ram_proc_workload.py
- difficulty: low
EOF
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
DEFAULT_ORCH_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"

BUILD_ID=""
PY_FILE=""
ORCH_DIR="${ORCH_DIR:-$DEFAULT_ORCH_DIR}"
STORAGE_PATH=""
PAUSE_SECS="${PAUSE_SECS:-5}"
DIFFICULTY="${DIFFICULTY:-low}"
RESUME_BUILD_ARGS=()

POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --orchestrator-dir)
      ORCH_DIR="$2"
      shift 2
      ;;
    --storage)
      STORAGE_PATH="$2"
      shift 2
      ;;
    --pause-seconds)
      PAUSE_SECS="$2"
      shift 2
      ;;
    --difficulty)
      DIFFICULTY="$2"
      shift 2
      ;;
    --)
      shift
      RESUME_BUILD_ARGS+=("$@")
      break
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

if [[ ${#POSITIONAL[@]} -lt 1 || ${#POSITIONAL[@]} -gt 2 ]]; then
  usage >&2
  exit 1
fi

BUILD_ID="${POSITIONAL[0]}"
PY_FILE="${POSITIONAL[1]:-$SCRIPT_DIR/cpu_ram_proc_workload.py}"

case "$DIFFICULTY" in
  low)
    CPU_PRESET_WORKERS=1
    CPU_PRESET_MEM_WORKERS_MAX=2
    CPU_PRESET_MEM_STEP_MB=32
    CPU_PRESET_TARGET_USED_MB=128
    CPU_PRESET_TARGET_BAND_LOW_MB=96
    CPU_PRESET_TARGET_BAND_HIGH_MB=160
    FFMPEG_PRESET_ROUNDS=2
    FFMPEG_PRESET_JOBS_PER_ROUND=2
    FFMPEG_PRESET_THREADS_PER_JOB=1
    FFMPEG_PRESET_DURATION_SEC=10
    FFMPEG_PRESET_STAGGER_SEC=0.5
    FFMPEG_PRESET_OUTPUT_MODE=null
    ;;
  high)
    CPU_PRESET_WORKERS=4
    CPU_PRESET_MEM_WORKERS_MAX=16
    CPU_PRESET_MEM_STEP_MB=32
    CPU_PRESET_TARGET_USED_MB=900
    CPU_PRESET_TARGET_BAND_LOW_MB=800
    CPU_PRESET_TARGET_BAND_HIGH_MB=980
    FFMPEG_PRESET_ROUNDS=4
    FFMPEG_PRESET_JOBS_PER_ROUND=8
    FFMPEG_PRESET_THREADS_PER_JOB=8
    FFMPEG_PRESET_DURATION_SEC=30
    FFMPEG_PRESET_STAGGER_SEC=1
    FFMPEG_PRESET_OUTPUT_MODE=mp4
    ;;
  *)
    echo "invalid difficulty: $DIFFICULTY (expected low or high)" >&2
    exit 1
    ;;
esac

case "$(basename "$PY_FILE")" in
  cpu_ram_proc_workload.py)
    : "${CPU_WORKERS:=$CPU_PRESET_WORKERS}"
    : "${MEM_WORKERS_MAX:=$CPU_PRESET_MEM_WORKERS_MAX}"
    : "${MEM_STEP_MB:=$CPU_PRESET_MEM_STEP_MB}"
    : "${TARGET_USED_MB:=$CPU_PRESET_TARGET_USED_MB}"
    : "${TARGET_BAND_LOW_MB:=$CPU_PRESET_TARGET_BAND_LOW_MB}"
    : "${TARGET_BAND_HIGH_MB:=$CPU_PRESET_TARGET_BAND_HIGH_MB}"
    WORKLOAD_ENV_VARS="${WORKLOAD_ENV_VARS:-CPU_WORKERS MEM_WORKERS_MAX MEM_STEP_MB TARGET_USED_MB TARGET_BAND_LOW_MB TARGET_BAND_HIGH_MB}"
    ;;
  ffmpeg_thread_workload.py)
    : "${ROUNDS:=$FFMPEG_PRESET_ROUNDS}"
    : "${JOBS_PER_ROUND:=$FFMPEG_PRESET_JOBS_PER_ROUND}"
    : "${THREADS_PER_JOB:=$FFMPEG_PRESET_THREADS_PER_JOB}"
    : "${DURATION_SEC:=$FFMPEG_PRESET_DURATION_SEC}"
    : "${STAGGER_SEC:=$FFMPEG_PRESET_STAGGER_SEC}"
    : "${OUTPUT_MODE:=$FFMPEG_PRESET_OUTPUT_MODE}"
    WORKLOAD_ENV_VARS="${WORKLOAD_ENV_VARS:-ROUNDS JOBS_PER_ROUND THREADS_PER_JOB DURATION_SEC STAGGER_SEC OUTPUT_MODE}"
    ;;
esac

if [[ ! -f "$PY_FILE" ]]; then
  echo "python file not found: $PY_FILE" >&2
  exit 1
fi

if [[ ! -d "$ORCH_DIR" || ! -f "$ORCH_DIR/go.mod" ]]; then
  echo "orchestrator directory does not look valid: $ORCH_DIR" >&2
  exit 1
fi

if [[ -z "$STORAGE_PATH" ]]; then
  STORAGE_PATH="$ORCH_DIR/.local-build"
fi

build_guest_env_prefix() {
  local name value prefix=""

  for name in ${WORKLOAD_ENV_VARS:-}; do
    if [[ -v "$name" ]]; then
      value="${!name}"
      printf -v prefix '%s%s=%q ' "$prefix" "$name" "$value"
    fi
  done

  printf '%s' "$prefix"
}

SCRIPT_B64="$(base64 -w0 "$PY_FILE")"
GUEST_ENV_PREFIX="$(build_guest_env_prefix)"
PY_BASENAME="$(basename "$PY_FILE")"
PAUSED_ID="${PAUSED_ID:-$(python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
)}"
PAUSE_LOG_PATH="${PAUSE_LOG_PATH:-/tmp/cmd-signal-pause-${PAUSED_ID}.log}"
RESUME_LOG_PATH="${RESUME_LOG_PATH:-/tmp/cmd-resume-${PAUSED_ID}.log}"
RESUME_CHECK_CMD="${RESUME_CHECK_CMD:-sleep 1}"

CMD="mkdir -p /home/user/workspace && base64 -d > /home/user/workspace/${PY_BASENAME} <<< '$SCRIPT_B64' && chmod 755 /home/user/workspace/${PY_BASENAME} && ${GUEST_ENV_PREFIX}python3 /home/user/workspace/${PY_BASENAME}"

echo "paused_id=$PAUSED_ID"
echo "from_build=$BUILD_ID"
echo "workload=$PY_FILE"
echo "difficulty=$DIFFICULTY"
echo "pause_after=${PAUSE_SECS}s"
echo "pause_log=$PAUSE_LOG_PATH"
echo "resume_log=$RESUME_LOG_PATH"

sudo env "PATH=$PATH" "ENVIRONMENT=local" \
  go -C "$ORCH_DIR" run ./cmd/resume-build \
  -from-build "$BUILD_ID" \
  -to-build "$PAUSED_ID" \
  -storage "$STORAGE_PATH" \
  -cmd-signal-pause "$CMD" \
  -v \
  "${RESUME_BUILD_ARGS[@]}" >"$PAUSE_LOG_PATH" 2>&1 &

RUNNER_PID=$!
echo "launcher_pid=$RUNNER_PID"

sleep "$PAUSE_SECS"

MATCHING_PIDS=""
for _ in $(seq 1 20); do
  MATCHING_PIDS="$(pgrep -af "/resume-build .*${PAUSED_ID}" | awk '{print $1}' || true)"
  if [[ -n "$MATCHING_PIDS" ]]; then
    break
  fi
  sleep 0.25
done

if [[ -z "$MATCHING_PIDS" ]]; then
  echo "failed to find live compiled resume-build pid for paused_id=$PAUSED_ID" >&2
  tail -n 40 "$PAUSE_LOG_PATH" >&2 || true
  exit 1
fi

echo "signal_pids=$(echo "$MATCHING_PIDS" | tr '\n' ' ')"
echo "$MATCHING_PIDS" | xargs -r sudo kill -SIGUSR1

wait "$RUNNER_PID"

if ! grep -q "📨 Received SIGUSR1 signal" "$PAUSE_LOG_PATH"; then
  echo "pause signal was not observed in log for paused_id=$PAUSED_ID" >&2
  tail -n 60 "$PAUSE_LOG_PATH" >&2 || true
  exit 1
fi

if ! grep -q "✅ Build finished: $PAUSED_ID" "$PAUSE_LOG_PATH"; then
  echo "snapshot did not complete for paused_id=$PAUSED_ID" >&2
  tail -n 80 "$PAUSE_LOG_PATH" >&2 || true
  exit 1
fi

echo "snapshot complete: $PAUSED_ID"

sudo env "PATH=$PATH" "ENVIRONMENT=local" \
  go -C "$ORCH_DIR" run ./cmd/resume-build \
  -from-build "$PAUSED_ID" \
  -storage "$STORAGE_PATH" \
  -cmd "$RESUME_CHECK_CMD" \
  -v \
  "${RESUME_BUILD_ARGS[@]}" >"$RESUME_LOG_PATH" 2>&1

echo "resume complete: $PAUSED_ID"
echo "pause_log: $PAUSE_LOG_PATH"
echo "resume_log: $RESUME_LOG_PATH"
