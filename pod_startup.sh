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
OLLAMA_RELEASE_ASSETS_IP="${OLLAMA_RELEASE_ASSETS_IP:-auto}"
OLLAMA_RELEASE_ASSETS_PROBE_BYTES="${OLLAMA_RELEASE_ASSETS_PROBE_BYTES:-1048576}"
OLLAMA_RELEASE_ASSETS_PROBE_SECONDS="${OLLAMA_RELEASE_ASSETS_PROBE_SECONDS:-8}"

LOG_DIR="/workspace/logs"
LOG_FILE="$LOG_DIR/ollama.log"
PID_FILE="/workspace/ollama.pid"
INSTALL_LOG="$LOG_DIR/ollama-install.log"
SMOKE_LOG="$LOG_DIR/ollama-smoke.log"
HOSTS_PIN_MARKER="# hallmark_runpod_tools ollama release-assets pin"

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

remove_release_assets_pin() {
  local tmp

  if ! grep -qF "$HOSTS_PIN_MARKER" /etc/hosts 2>/dev/null; then
    return 0
  fi

  tmp="$(mktemp /tmp/hosts.XXXXXX)"
  grep -vF "$HOSTS_PIN_MARKER" /etc/hosts > "$tmp" || true
  run_as_root cp "$tmp" /etc/hosts
  rm -f "$tmp"
}

pin_release_assets_ip() {
  local ip="$1"

  remove_release_assets_pin
  log "Temporarily pinning release-assets.githubusercontent.com to $ip"
  printf '%s release-assets.githubusercontent.com %s\n' "$ip" "$HOSTS_PIN_MARKER" |
    run_as_root tee -a /etc/hosts >/dev/null
}

release_assets_ips() {
  local ips

  ips="$(getent ahostsv4 release-assets.githubusercontent.com 2>/dev/null |
    awk '{print $1}' |
    sort -u || true)"

  if [ -n "$ips" ]; then
    echo "$ips"
  else
    printf '%s\n' \
      185.199.108.133 \
      185.199.109.133 \
      185.199.110.133 \
      185.199.111.133
  fi
}

select_release_assets_ip() {
  local url
  local ip
  local tmp
  local speed
  local best_ip
  local best_speed

  url="$(curl -sSIL --max-time 20 -o /dev/null -w '%{url_effective}' \
    https://ollama.com/download/ollama-linux-amd64.tar.zst || true)"
  if [ -z "$url" ]; then
    return 1
  fi

  best_ip=""
  best_speed=0

  for ip in $(release_assets_ips); do
    tmp="$(mktemp /tmp/ollama-release-assets.XXXXXX)"
    speed="$(
      curl \
        --resolve "release-assets.githubusercontent.com:443:$ip" \
        --range "0-$((OLLAMA_RELEASE_ASSETS_PROBE_BYTES - 1))" \
        --fail \
        --silent \
        --show-error \
        --location \
        --connect-timeout 10 \
        --max-time "$OLLAMA_RELEASE_ASSETS_PROBE_SECONDS" \
        -o "$tmp" \
        -w '%{speed_download}' \
        "$url" 2>/dev/null || true
    )"
    rm -f "$tmp"

    speed="${speed%.*}"
    if [ -n "$speed" ] && [ "$speed" -gt "$best_speed" ] 2>/dev/null; then
      best_ip="$ip"
      best_speed="$speed"
    fi
  done

  if [ -n "$best_ip" ]; then
    echo "$best_ip"
    return 0
  fi

  return 1
}

configure_release_assets_route() {
  local ip

  case "$OLLAMA_RELEASE_ASSETS_IP" in
    ""|0|false|off|none)
      log "GitHub release-assets IP pinning disabled"
      return 0
      ;;
    auto)
      log "Probing GitHub release-assets IPs before Ollama install..."
      if ip="$(select_release_assets_ip)"; then
        log "Fastest release-assets.githubusercontent.com probe: $ip"
        pin_release_assets_ip "$ip"
      else
        log "WARNING: Could not select a release-assets IP; continuing without pinning"
      fi
      ;;
    *)
      pin_release_assets_ip "$OLLAMA_RELEASE_ASSETS_IP"
      ;;
  esac
}

ollama_lib_dir() {
  local bin_dir
  local prefix

  bin_dir="$(dirname "$(command -v ollama)")"
  prefix="$(dirname "$bin_dir")"
  echo "$prefix/lib/ollama"
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
  configure_release_assets_route
  trap remove_release_assets_pin EXIT
  sh "$installer" 2>&1 | tee "$INSTALL_LOG"
  remove_release_assets_pin
  trap - EXIT
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
