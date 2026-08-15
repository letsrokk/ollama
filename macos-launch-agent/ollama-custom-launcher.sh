#!/bin/zsh
# Managed by macos-install-launch-agent.sh.

set -eu

readonly LAUNCHCTL_BIN="/bin/launchctl"
readonly OPEN_BIN="/usr/bin/open"
readonly SLEEP_BIN="/bin/sleep"
readonly MAX_OPEN_ATTEMPTS=5

log() {
  print -r -- "[$(/bin/date '+%Y-%m-%d %H:%M:%S')] $*"
}

set_ollama_environment() {
  # Leave context selection to Ollama's VRAM-aware default.
  "$LAUNCHCTL_BIN" unsetenv OLLAMA_CONTEXT_LENGTH 2>/dev/null || true

  "$LAUNCHCTL_BIN" setenv OLLAMA_FLASH_ATTENTION "1"
  "$LAUNCHCTL_BIN" setenv OLLAMA_KV_CACHE_TYPE "q4_0"
  "$LAUNCHCTL_BIN" setenv OLLAMA_NUM_PARALLEL "2"
  "$LAUNCHCTL_BIN" setenv OLLAMA_MAX_LOADED_MODELS "2"
  "$LAUNCHCTL_BIN" setenv OLLAMA_KEEP_ALIVE "15m"
}

start_ollama() {
  local attempt=1

  while (( attempt <= MAX_OPEN_ATTEMPTS )); do
    log "Starting Ollama (attempt ${attempt}/${MAX_OPEN_ATTEMPTS})."
    if "$OPEN_BIN" -a "Ollama"; then
      log "Ollama launch request accepted."
      return 0
    fi

    if (( attempt < MAX_OPEN_ATTEMPTS )); then
      "$SLEEP_BIN" 2
    fi
    (( attempt += 1 ))
  done

  log "Failed to start Ollama after ${MAX_OPEN_ATTEMPTS} attempts."
  return 1
}

log "Applying Ollama launch environment."
set_ollama_environment
start_ollama
