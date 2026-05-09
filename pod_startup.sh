#!/usr/bin/env bash
set -Eeuo pipefail

#
# RunPod + Ollama bootstrap/start script
#
# Goals:
# - works on fresh pod OR restarted pod
# - survives repeated executions
# - keeps logs
# - avoids duplicate ollama servers
# - pulls model only if missing
# - useful diagnostics
#

########################################
# Config
########################################

export OLLAMA_HOST="${OLLAMA_HOST:-0.0.0.0:11434}"
export OLLAMA_MODELS="${OLLAMA_MODELS:-/workspace/ollama-models}"

# Stability knobs
export OLLAMA_DEBUG="${OLLAMA_DEBUG:-1}"
export OLLAMA_NUM_PARALLEL="${OLLAMA_NUM_PARALLEL:-1}"
export OLLAMA_MAX_LOADED_MODELS="${OLLAMA_MAX_LOADED_MODELS:-1}"

MODEL="${MODEL:-gemma4:e4b}"
OLLAMA_FORCE_INSTALL="${OLLAMA_FORCE_INSTALL:-0}"
OLLAMA_INSTALL_MAX_TIME="${OLLAMA_INSTALL_MAX_TIME:-1800}"
OLLAMA_SMOKE_PORT="${OLLAMA_SMOKE_PORT:-11435}"
OLLAMA_SMOKE_SECONDS="${OLLAMA_SMOKE_SECONDS:-30}"

# Fail fast on bad pods before paying to install/pull/load models.
RUNPOD_PREFLIGHT_CHECKS="${RUNPOD_PREFLIGHT_CHECKS:-1}"
RUNPOD_NETWORK_TEST_BYTES="${RUNPOD_NETWORK_TEST_BYTES:-104857600}"
RUNPOD_NETWORK_TEST_MAX_TIME="${RUNPOD_NETWORK_TEST_MAX_TIME:-30}"
RUNPOD_NETWORK_MIN_BPS="${RUNPOD_NETWORK_MIN_BPS:-5000000}"
RUNPOD_WORKSPACE_TEST_BYTES="${RUNPOD_WORKSPACE_TEST_BYTES:-536870912}"
RUNPOD_WORKSPACE_MIN_WRITE_BPS="${RUNPOD_WORKSPACE_MIN_WRITE_BPS:-200000000}"
RUNPOD_WORKSPACE_MIN_READ_BPS="${RUNPOD_WORKSPACE_MIN_READ_BPS:-200000000}"
RUNPOD_NETWORK_TEST_URL="${RUNPOD_NETWORK_TEST_URL:-}"

LOG_DIR="/workspace/logs"
LOG_FILE="$LOG_DIR/ollama.log"
PID_FILE="/workspace/ollama.pid"
INSTALL_LOG="$LOG_DIR/ollama-install.log"
SMOKE_LOG="$LOG_DIR/ollama-smoke.log"

mkdir -p "$OLLAMA_MODELS"
mkdir -p "$LOG_DIR"

########################################
# Helpers
########################################

log() {
  echo
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

ollama_healthy() {
  curl -fsS http://127.0.0.1:11434/api/tags >/dev/null 2>&1
}

wait_for_ollama() {
  for i in {1..60}; do
    if ollama_healthy; then
      return 0
    fi
    sleep 1
  done
  return 1
}

run_as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

install_apt_package() {
  local package="$1"

  if ! command -v apt-get >/dev/null 2>&1; then
    log "ERROR: apt-get not found. Please install $package in the pod image."
    exit 1
  fi

  run_as_root apt-get update
  run_as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "$package"
}

ollama_arch() {
  case "$(uname -m)" in
    x86_64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *)
      log "ERROR: Unsupported architecture: $(uname -m)"
      exit 1
      ;;
  esac
}

ollama_bundle_url() {
  local arch

  arch="$(ollama_arch)"
  curl -sSIL --max-time 20 -o /dev/null -w '%{url_effective}' \
    "https://ollama.com/download/ollama-linux-${arch}.tar.zst"
}

ollama_lib_dir() {
  local bin_dir
  local prefix

  bin_dir="$(dirname "$(command -v ollama)")"
  prefix="$(dirname "$bin_dir")"
  echo "$prefix/lib/ollama"
}

format_bps() {
  awk -v bps="$1" 'BEGIN {
    if (bps >= 1000000000) printf "%.1f GB/s", bps / 1000000000;
    else if (bps >= 1000000) printf "%.1f MB/s", bps / 1000000;
    else if (bps >= 1000) printf "%.1f KB/s", bps / 1000;
    else printf "%d B/s", bps;
  }'
}

elapsed_bps() {
  local bytes="$1"
  local start_ns="$2"
  local end_ns="$3"

  awk -v bytes="$bytes" -v start="$start_ns" -v end="$end_ns" 'BEGIN {
    elapsed = (end - start) / 1000000000;
    if (elapsed <= 0) elapsed = 0.001;
    printf "%d", bytes / elapsed;
  }'
}

fail_pod_preflight() {
  local reason="$1"

  log "ERROR: Pod preflight failed: $reason"
  cat <<EOF

This pod looks unhealthy for this workflow.

Recommendation:
  Stop this pod and create a new RunPod pod, preferably in a different host or
  region. The startup script is stopping before doing expensive install/model
  work so you do not keep paying for a bad pod.

To bypass these checks anyway:
  RUNPOD_PREFLIGHT_CHECKS=0 ./pod_startup.sh

EOF
  exit 42
}

run_network_preflight() {
  local url
  local tmp
  local speed
  local size
  local code

  url="$RUNPOD_NETWORK_TEST_URL"
  if [ -z "$url" ]; then
    url="$(ollama_bundle_url || true)"
  fi

  if [ -z "$url" ]; then
    fail_pod_preflight "could not resolve Ollama bundle URL for network test"
  fi

  tmp="$(mktemp /tmp/runpod-network-test.XXXXXX)"
  log "Testing network bandwidth against Ollama bundle path..."
  log "Network test bytes: $RUNPOD_NETWORK_TEST_BYTES"

  speed="$(
    curl \
      --fail \
      --silent \
      --show-error \
      --location \
      --range "0-$((RUNPOD_NETWORK_TEST_BYTES - 1))" \
      --connect-timeout 10 \
      --max-time "$RUNPOD_NETWORK_TEST_MAX_TIME" \
      -o "$tmp" \
      -w '%{http_code} %{size_download} %{speed_download}' \
      "$url" 2>/tmp/runpod-network-test.err || true
  )"

  code="$(printf '%s' "$speed" | awk '{print $1}')"
  size="$(printf '%s' "$speed" | awk '{print int($2)}')"
  speed="$(printf '%s' "$speed" | awk '{print int($3)}')"
  rm -f "$tmp"

  if [ "${code:-0}" -lt 200 ] || [ "${code:-0}" -ge 400 ] || [ "${size:-0}" -eq 0 ]; then
    cat /tmp/runpod-network-test.err || true
    fail_pod_preflight "network test failed before downloading data"
  fi

  log "Network bandwidth: $(format_bps "$speed")"
  if [ "$speed" -lt "$RUNPOD_NETWORK_MIN_BPS" ]; then
    fail_pod_preflight "network bandwidth $(format_bps "$speed") is below threshold $(format_bps "$RUNPOD_NETWORK_MIN_BPS")"
  fi
}

run_workspace_preflight() {
  local test_file
  local test_mb
  local test_bytes
  local start_ns
  local end_ns
  local write_bps
  local read_bps

  test_file="$LOG_DIR/workspace-bandwidth-test.bin"
  test_mb="$(( (RUNPOD_WORKSPACE_TEST_BYTES + 1048575) / 1048576 ))"
  if [ "$test_mb" -lt 1 ]; then
    test_mb=1
  fi
  test_bytes="$((test_mb * 1048576))"

  log "Testing /workspace write/read bandwidth..."
  log "Workspace test bytes: $test_bytes"

  start_ns="$(date +%s%N)"
  dd if=/dev/zero of="$test_file" bs=1M count="$test_mb" conv=fdatasync status=none
  end_ns="$(date +%s%N)"
  write_bps="$(elapsed_bps "$test_bytes" "$start_ns" "$end_ns")"
  log "/workspace write bandwidth: $(format_bps "$write_bps")"

  start_ns="$(date +%s%N)"
  dd if="$test_file" of=/dev/null bs=1M status=none
  end_ns="$(date +%s%N)"
  read_bps="$(elapsed_bps "$test_bytes" "$start_ns" "$end_ns")"
  log "/workspace read bandwidth: $(format_bps "$read_bps")"

  rm -f "$test_file"

  if [ "$write_bps" -lt "$RUNPOD_WORKSPACE_MIN_WRITE_BPS" ]; then
    fail_pod_preflight "/workspace write bandwidth $(format_bps "$write_bps") is below threshold $(format_bps "$RUNPOD_WORKSPACE_MIN_WRITE_BPS")"
  fi

  if [ "$read_bps" -lt "$RUNPOD_WORKSPACE_MIN_READ_BPS" ]; then
    fail_pod_preflight "/workspace read bandwidth $(format_bps "$read_bps") is below threshold $(format_bps "$RUNPOD_WORKSPACE_MIN_READ_BPS")"
  fi
}

run_pod_preflight() {
  if [ "$RUNPOD_PREFLIGHT_CHECKS" = "0" ] || [ "$RUNPOD_PREFLIGHT_CHECKS" = "false" ]; then
    log "Pod preflight checks disabled"
    return 0
  fi

  run_network_preflight
  run_workspace_preflight
}

install_ollama() {
  local installer

  installer="$(mktemp /tmp/ollama-install.XXXXXX.sh)"

  log "Downloading official Ollama installer..."
  log "Install log: $INSTALL_LOG"

  curl \
    --fail \
    --show-error \
    --location \
    --retry 5 \
    --retry-delay 2 \
    --connect-timeout 20 \
    --max-time "$OLLAMA_INSTALL_MAX_TIME" \
    --progress-bar \
    -o "$installer" \
    https://ollama.com/install.sh

  log "Running official Ollama installer..."
  sh "$installer" 2>&1 | tee "$INSTALL_LOG"
}

ollama_install_valid() {
  local lib_dir
  local smoke_pid
  local started_smoke
  local i
  local broken_link

  if ! command -v ollama >/dev/null 2>&1; then
    log "Ollama validation failed: ollama command is missing"
    return 1
  fi

  if ! timeout 20s ollama --version >/dev/null 2>&1; then
    log "Ollama validation failed: 'ollama --version' did not complete"
    return 1
  fi

  lib_dir="$(ollama_lib_dir)"
  if [ -d "$lib_dir" ]; then
    broken_link="$(find "$lib_dir" -xtype l -print -quit 2>/dev/null || true)"
    if [ -n "$broken_link" ]; then
      log "Ollama validation failed: broken library symlink: $broken_link"
      return 1
    fi
  fi

  if ollama_healthy; then
    log "Existing Ollama server is healthy; still running install smoke test"
  fi

  : > "$SMOKE_LOG"
  started_smoke=0

  log "Running Ollama smoke test on port $OLLAMA_SMOKE_PORT..."
  OLLAMA_HOST="127.0.0.1:$OLLAMA_SMOKE_PORT" \
    OLLAMA_MODELS="$OLLAMA_MODELS" \
    ollama serve >> "$SMOKE_LOG" 2>&1 &
  smoke_pid=$!
  started_smoke=1

  for i in $(seq 1 "$OLLAMA_SMOKE_SECONDS"); do
    if curl -fsS "http://127.0.0.1:$OLLAMA_SMOKE_PORT/api/tags" >/dev/null 2>&1; then
      break
    fi

    if ! ps -p "$smoke_pid" >/dev/null 2>&1; then
      log "Ollama validation failed: smoke server exited early"
      tail -100 "$SMOKE_LOG" || true
      return 1
    fi

    sleep 1
  done

  if ! curl -fsS "http://127.0.0.1:$OLLAMA_SMOKE_PORT/api/tags" >/dev/null 2>&1; then
    log "Ollama validation failed: smoke server did not become healthy"
    tail -100 "$SMOKE_LOG" || true
    if ps -p "$smoke_pid" >/dev/null 2>&1; then
      kill "$smoke_pid" >/dev/null 2>&1 || true
      wait "$smoke_pid" 2>/dev/null || true
    fi
    return 1
  fi

  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
    if grep -q 'inference compute.*id=cpu' "$SMOKE_LOG" &&
      ! grep -q 'inference compute.*library=cuda' "$SMOKE_LOG"; then
      log "Ollama validation failed: NVIDIA GPU is visible, but Ollama detected CPU only"
      tail -100 "$SMOKE_LOG" || true
      if ps -p "$smoke_pid" >/dev/null 2>&1; then
        kill "$smoke_pid" >/dev/null 2>&1 || true
        wait "$smoke_pid" 2>/dev/null || true
      fi
      return 1
    fi
  fi

  if [ "$started_smoke" -eq 1 ] && ps -p "$smoke_pid" >/dev/null 2>&1; then
    kill "$smoke_pid" >/dev/null 2>&1 || true
    wait "$smoke_pid" 2>/dev/null || true
  fi

  log "Ollama validation passed"
  return 0
}

########################################
# Basic tools
########################################

log "Checking dependencies..."

if ! command -v curl >/dev/null 2>&1; then
  install_apt_package curl
fi

if ! command -v zstd >/dev/null 2>&1; then
  install_apt_package zstd
fi

run_pod_preflight

if ! command -v nvidia-smi >/dev/null 2>&1; then
  log "WARNING: nvidia-smi not found"
elif [ "${NVIDIA_VISIBLE_DEVICES:-}" = "void" ]; then
  log "WARNING: NVIDIA_VISIBLE_DEVICES=void even though nvidia-smi is available; exporting NVIDIA_VISIBLE_DEVICES=all"
  export NVIDIA_VISIBLE_DEVICES=all
fi

########################################
# Install/validate Ollama
########################################

if [ "$OLLAMA_FORCE_INSTALL" = "1" ] || [ "$OLLAMA_FORCE_INSTALL" = "true" ]; then
  log "OLLAMA_FORCE_INSTALL is set; reinstalling Ollama"
  install_ollama
elif ollama_install_valid; then
  log "Ollama install looks healthy"
else
  log "Existing Ollama install is missing or unhealthy; reinstalling"
  install_ollama
  if ! ollama_install_valid; then
    log "ERROR: Ollama install still failed validation after reinstall"
    log "Install log:"
    tail -120 "$INSTALL_LOG" || true
    exit 1
  fi
fi

########################################
# GPU info
########################################

if command -v nvidia-smi >/dev/null 2>&1; then
  log "GPU status:"
  nvidia-smi || true
fi

########################################
# Start Ollama if not already running
########################################

if ollama_healthy; then
  log "Ollama already running"
else
  log "Starting Ollama server..."

  # Kill stale process if PID file exists
  if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE" || true)

    if [ -n "${OLD_PID:-}" ] && ps -p "$OLD_PID" >/dev/null 2>&1; then
      log "Stopping stale Ollama process $OLD_PID"
      kill "$OLD_PID" || true
      sleep 2
    fi
  fi

  nohup ollama serve >> "$LOG_FILE" 2>&1 &

  SERVER_PID=$!
  echo "$SERVER_PID" > "$PID_FILE"

  log "Ollama PID: $SERVER_PID"

  if ! wait_for_ollama; then
    log "ERROR: Ollama failed to start"
    tail -100 "$LOG_FILE" || true
    exit 1
  fi

  log "Ollama started successfully"
fi

########################################
# Pull model if missing
########################################

if ollama list | grep -q "^${MODEL%%:*}"; then
  log "Model already present: $MODEL"
else
  log "Pulling model: $MODEL"
  ollama pull "$MODEL"
fi

########################################
# Diagnostics
########################################

log "Loaded models:"
ollama list || true

log "Running models:"
curl -s http://127.0.0.1:11434/api/ps || true

log "Recent Ollama log:"
tail -50 "$LOG_FILE" || true

cat <<EOF

==================================================
Ollama is ready

API:
  http://0.0.0.0:11434

Useful commands:

  tail -f $LOG_FILE

  curl http://127.0.0.1:11434/api/tags

  curl http://127.0.0.1:11434/api/ps

  watch -n 1 nvidia-smi

==================================================

EOF
