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
OLLAMA_INSTALL_PREFIX="${OLLAMA_INSTALL_PREFIX:-/usr}"
OLLAMA_DOWNLOAD_MAX_TIME="${OLLAMA_DOWNLOAD_MAX_TIME:-900}"

LOG_DIR="/workspace/logs"
LOG_FILE="$LOG_DIR/ollama.log"
PID_FILE="/workspace/ollama.pid"

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

install_ollama_bundle() {
  local arch
  local ver_param
  local archive_url

  case "$(uname -m)" in
    x86_64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *)
      log "ERROR: Unsupported architecture: $(uname -m)"
      exit 1
      ;;
  esac

  if ! command -v zstd >/dev/null 2>&1; then
    log "Installing zstd for Ollama bundle extraction..."
    install_apt_package zstd
  fi

  ver_param=""
  if [ -n "${OLLAMA_VERSION:-}" ]; then
    ver_param="?version=$OLLAMA_VERSION"
  fi

  archive_url="https://ollama.com/download/ollama-linux-${arch}.tar.zst${ver_param}"

  log "Installing Ollama runtime bundle..."
  log "Download URL: $archive_url"
  log "Install prefix: $OLLAMA_INSTALL_PREFIX"

  run_as_root install -o0 -g0 -m755 -d "$OLLAMA_INSTALL_PREFIX/bin"
  run_as_root install -o0 -g0 -m755 -d "$OLLAMA_INSTALL_PREFIX/lib/ollama"

  curl \
    --fail \
    --show-error \
    --location \
    --retry 5 \
    --retry-delay 2 \
    --connect-timeout 20 \
    --max-time "$OLLAMA_DOWNLOAD_MAX_TIME" \
    --progress-bar \
    "$archive_url" |
    zstd -d |
    run_as_root tar -xf - -C "$OLLAMA_INSTALL_PREFIX"

  if ! command -v ollama >/dev/null 2>&1; then
    log "ERROR: Ollama installed, but 'ollama' is not on PATH."
    log "Try: export PATH=\"$OLLAMA_INSTALL_PREFIX/bin:\$PATH\""
    exit 1
  fi
}

########################################
# Basic tools
########################################

log "Checking dependencies..."

if ! command -v curl >/dev/null 2>&1; then
  install_apt_package curl
fi

if ! command -v nvidia-smi >/dev/null 2>&1; then
  log "WARNING: nvidia-smi not found"
fi

########################################
# Install Ollama if needed
########################################

if ! command -v ollama >/dev/null 2>&1; then
  install_ollama_bundle
else
  log "Ollama already installed"
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
