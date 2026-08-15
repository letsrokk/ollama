#!/bin/zsh
# Managed source for the native macOS Ollama LaunchAgent installer.

set -eu
setopt PIPE_FAIL

readonly MANAGED_MARKER="Managed by macos-install-launch-agent.sh."
readonly CUSTOM_LABEL="local.ollama.configured-launch"
readonly OLLAMA_LOGIN_LABEL="com.ollama.ollama"
readonly SCRIPT_DIR="${0:A:h}"
readonly SOURCE_DIR="$SCRIPT_DIR/macos-launch-agent"
readonly SOURCE_LAUNCH_SCRIPT="$SOURCE_DIR/ollama-custom-launcher.sh"
readonly SOURCE_PLIST="$SOURCE_DIR/local.ollama.configured-launch.plist"

readonly LAUNCHCTL_BIN="/bin/launchctl"
readonly MKDIR_BIN="/bin/mkdir"
readonly RM_BIN="/bin/rm"
readonly SLEEP_BIN="/bin/sleep"
readonly CP_BIN="/bin/cp"
readonly DATE_BIN="/bin/date"
readonly GREP_BIN="/usr/bin/grep"
readonly ID_BIN="/usr/bin/id"
readonly INSTALL_BIN="/usr/bin/install"
readonly MKTEMP_BIN="/usr/bin/mktemp"
readonly OSASCRIPT_BIN="/usr/bin/osascript"
readonly PLUTIL_BIN="/usr/bin/plutil"
readonly UNAME_BIN="/usr/bin/uname"
readonly ZSH_BIN="/bin/zsh"

MODE=""
DISABLE_LOGIN_ITEM=0
ENABLE_LOGIN_ITEM=0
STAGE_DIR=""
CLEANUP_IN_PROGRESS=0
INSTALL_TRANSACTION_ACTIVE=0
LOGIN_ITEM_TOUCHED=0
PREVIOUS_AGENT_LOADED=0
PREVIOUS_LAUNCH_SCRIPT_PRESENT=0
PREVIOUS_LEGACY_LAUNCH_SCRIPT_PRESENT=0
PREVIOUS_PLIST_PRESENT=0
PREVIOUS_LOGIN_ITEM_DISABLED=0
PREVIOUS_OLLAMA_RUNNING=0
LEGACY_LAUNCH_SCRIPT_REMOVAL_STARTED=0
PREVIOUS_CONTEXT_LENGTH=""
PREVIOUS_FLASH_ATTENTION=""
PREVIOUS_KV_CACHE_TYPE=""
PREVIOUS_NUM_PARALLEL=""
PREVIOUS_MAX_LOADED_MODELS=""
PREVIOUS_KEEP_ALIVE=""

usage() {
  cat <<'EOF'
Usage:
  ./macos-install-launch-agent.sh --install [--disable-login-item]
  ./macos-install-launch-agent.sh --uninstall [--enable-login-item]
  ./macos-install-launch-agent.sh --help

Options:
  --install             Install, load, and immediately activate the LaunchAgent.
  --uninstall           Unload and remove files managed by this installer.
  --disable-login-item  Disable Ollama's stock login item during installation.
  --enable-login-item   Re-enable Ollama's stock login item during uninstall.
  -h, --help            Show this help text.
EOF
}

log() {
  print -r -- "[$("$DATE_BIN" '+%Y-%m-%d %H:%M:%S')] $*"
}

warn() {
  print -ru2 -- "Warning: $*"
}

die() {
  print -ru2 -- "Error: $*"
  exit 1
}

usage_error() {
  print -ru2 -- "Error: $*"
  print -ru2 -- ""
  usage >&2
  exit 2
}

finish() {
  local exit_code="$1"

  if (( CLEANUP_IN_PROGRESS )); then
    exit "$exit_code"
  fi
  CLEANUP_IN_PROGRESS=1
  trap - EXIT HUP INT TERM
  if (( INSTALL_TRANSACTION_ACTIVE && exit_code != 0 )); then
    rollback_install
  fi
  if [[ -n "$STAGE_DIR" && -d "$STAGE_DIR" ]]; then
    "$RM_BIN" -rf -- "$STAGE_DIR"
  fi
  exit "$exit_code"
}

cleanup() {
  local exit_code=$?
  finish "$exit_code"
}

handle_signal() {
  finish "$1"
}

trap cleanup EXIT
trap 'handle_signal 129' HUP
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

set_mode() {
  local requested_mode="$1"

  if [[ -n "$MODE" && "$MODE" != "$requested_mode" ]]; then
    usage_error "--install and --uninstall are mutually exclusive."
  fi
  MODE="$requested_mode"
}

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      --install)
        set_mode install
        ;;
      --uninstall)
        set_mode uninstall
        ;;
      --disable-login-item)
        DISABLE_LOGIN_ITEM=1
        ;;
      --enable-login-item)
        ENABLE_LOGIN_ITEM=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        usage_error "Unknown option: $1"
        ;;
    esac
    shift
  done

  [[ -n "$MODE" ]] || usage_error "Exactly one of --install or --uninstall is required."

  if (( DISABLE_LOGIN_ITEM )) && [[ "$MODE" != "install" ]]; then
    usage_error "--disable-login-item requires --install."
  fi
  if (( ENABLE_LOGIN_ITEM )) && [[ "$MODE" != "uninstall" ]]; then
    usage_error "--enable-login-item requires --uninstall."
  fi
}

require_macos() {
  [[ "$("$UNAME_BIN" -s)" == "Darwin" ]] || die "This installer supports macOS only."
}

require_safe_home() {
  [[ -n "${HOME:-}" && "$HOME" != "/" ]] || die "HOME must identify a user home directory."
}

is_managed_file() {
  local path="$1"
  [[ -f "$path" ]] && "$GREP_BIN" -Fq "$MANAGED_MARKER" "$path"
}

refuse_unmanaged_target() {
  local path="$1"

  if [[ -L "$path" ]]; then
    die "Refusing to replace symbolic link: $path"
  fi
  if [[ -e "$path" && ! -f "$path" ]]; then
    die "Refusing to replace non-file path: $path"
  fi
  if [[ -f "$path" ]] && ! is_managed_file "$path"; then
    die "Refusing to overwrite file not managed by this installer: $path"
  fi
}

ollama_is_running() {
  local result

  result=$("$OSASCRIPT_BIN" -e 'application "Ollama" is running' 2>/dev/null) || \
    die "Unable to determine whether the Ollama application is running."
  [[ "$result" == "true" ]]
}

custom_agent_is_loaded() {
  "$LAUNCHCTL_BIN" print "$LAUNCH_DOMAIN/$CUSTOM_LABEL" >/dev/null 2>&1
}

unload_custom_agent() {
  if custom_agent_is_loaded; then
    log "Unloading existing $CUSTOM_LABEL LaunchAgent."
    "$LAUNCHCTL_BIN" bootout "$LAUNCH_DOMAIN/$CUSTOM_LABEL" || \
      die "Failed to unload $CUSTOM_LABEL."
  fi
}

login_item_is_disabled() {
  local state
  state=$("$LAUNCHCTL_BIN" print-disabled "$LAUNCH_DOMAIN") || return 1
  print -r -- "$state" | "$GREP_BIN" -Fq "\"$OLLAMA_LOGIN_LABEL\" => disabled"
}

disable_stock_login_item() {
  log "Disabling stock Ollama login item $OLLAMA_LOGIN_LABEL."
  LOGIN_ITEM_TOUCHED=1
  "$LAUNCHCTL_BIN" disable "$LAUNCH_DOMAIN/$OLLAMA_LOGIN_LABEL" || \
    die "Failed to disable $OLLAMA_LOGIN_LABEL."

  login_item_is_disabled || \
    die "$OLLAMA_LOGIN_LABEL is not reported disabled; use System Settings > General > Login Items."
}

enable_stock_login_item() {
  log "Re-enabling stock Ollama login item $OLLAMA_LOGIN_LABEL."
  "$LAUNCHCTL_BIN" enable "$LAUNCH_DOMAIN/$OLLAMA_LOGIN_LABEL" || \
    die "Failed to enable $OLLAMA_LOGIN_LABEL."

  if login_item_is_disabled; then
    die "$OLLAMA_LOGIN_LABEL is still reported disabled; enable Ollama under System Settings > General > Login Items."
  fi
}

prepare_staged_files() {
  local staged_script="$STAGE_DIR/ollama-custom-launcher.sh"
  local staged_plist="$STAGE_DIR/$CUSTOM_LABEL.plist"

  "$CP_BIN" "$SOURCE_LAUNCH_SCRIPT" "$staged_script"
  "$CP_BIN" "$SOURCE_PLIST" "$staged_plist"

  "$PLUTIL_BIN" -remove ProgramArguments.0 "$staged_plist"
  "$PLUTIL_BIN" -insert ProgramArguments.0 -string "$INSTALLED_LAUNCH_SCRIPT" "$staged_plist"
  "$PLUTIL_BIN" -replace StandardOutPath -string "$LAUNCH_STDOUT" "$staged_plist"
  "$PLUTIL_BIN" -replace StandardErrorPath -string "$LAUNCH_STDERR" "$staged_plist"

  "$ZSH_BIN" -n "$staged_script"
  "$PLUTIL_BIN" -lint "$staged_plist" >/dev/null
}

capture_environment_value() {
  "$LAUNCHCTL_BIN" getenv "$1" 2>/dev/null || true
}

capture_managed_legacy_launcher() {
  if [[ ! -L "$LEGACY_INSTALLED_LAUNCH_SCRIPT" ]] && is_managed_file "$LEGACY_INSTALLED_LAUNCH_SCRIPT"; then
    PREVIOUS_LEGACY_LAUNCH_SCRIPT_PRESENT=1
    "$CP_BIN" -p "$LEGACY_INSTALLED_LAUNCH_SCRIPT" "$STAGE_DIR/previous-legacy-launch.sh"
  fi
}

capture_install_state() {
  local running_state

  if [[ -f "$INSTALLED_LAUNCH_SCRIPT" ]]; then
    PREVIOUS_LAUNCH_SCRIPT_PRESENT=1
    "$CP_BIN" -p "$INSTALLED_LAUNCH_SCRIPT" "$STAGE_DIR/previous-launch.sh"
  fi
  capture_managed_legacy_launcher
  if [[ -f "$INSTALLED_PLIST" ]]; then
    PREVIOUS_PLIST_PRESENT=1
    "$CP_BIN" -p "$INSTALLED_PLIST" "$STAGE_DIR/previous-agent.plist"
  fi
  if custom_agent_is_loaded; then
    PREVIOUS_AGENT_LOADED=1
  fi
  if login_item_is_disabled; then
    PREVIOUS_LOGIN_ITEM_DISABLED=1
  fi

  running_state=$("$OSASCRIPT_BIN" -e 'application "Ollama" is running' 2>/dev/null) || \
    die "Unable to capture the current Ollama application state."
  if [[ "$running_state" == "true" ]]; then
    PREVIOUS_OLLAMA_RUNNING=1
  fi

  PREVIOUS_CONTEXT_LENGTH=$(capture_environment_value OLLAMA_CONTEXT_LENGTH)
  PREVIOUS_FLASH_ATTENTION=$(capture_environment_value OLLAMA_FLASH_ATTENTION)
  PREVIOUS_KV_CACHE_TYPE=$(capture_environment_value OLLAMA_KV_CACHE_TYPE)
  PREVIOUS_NUM_PARALLEL=$(capture_environment_value OLLAMA_NUM_PARALLEL)
  PREVIOUS_MAX_LOADED_MODELS=$(capture_environment_value OLLAMA_MAX_LOADED_MODELS)
  PREVIOUS_KEEP_ALIVE=$(capture_environment_value OLLAMA_KEEP_ALIVE)
}

restore_environment_value() {
  local variable="$1"
  local value="$2"

  if [[ -n "$value" ]]; then
    "$LAUNCHCTL_BIN" setenv "$variable" "$value" || warn "Could not restore $variable."
  else
    "$LAUNCHCTL_BIN" unsetenv "$variable" 2>/dev/null || true
  fi
}

best_effort_stop_ollama() {
  local attempt=1
  local running_state

  running_state=$("$OSASCRIPT_BIN" -e 'application "Ollama" is running' 2>/dev/null) || return 0
  [[ "$running_state" == "true" ]] || return 0

  "$OSASCRIPT_BIN" -e 'quit app "Ollama"' >/dev/null 2>&1 || return 0
  while (( attempt <= 10 )); do
    running_state=$("$OSASCRIPT_BIN" -e 'application "Ollama" is running' 2>/dev/null) || return 0
    [[ "$running_state" == "false" ]] && return 0
    "$SLEEP_BIN" 1
    (( attempt += 1 ))
  done
}

restore_managed_legacy_launcher() {
  if (( LEGACY_LAUNCH_SCRIPT_REMOVAL_STARTED && PREVIOUS_LEGACY_LAUNCH_SCRIPT_PRESENT )); then
    "$INSTALL_BIN" -m 0755 "$STAGE_DIR/previous-legacy-launch.sh" "$LEGACY_INSTALLED_LAUNCH_SCRIPT" || \
      warn "Could not restore legacy launcher $LEGACY_INSTALLED_LAUNCH_SCRIPT."
  fi
}

rollback_install() {
  warn "Installation failed; restoring the previous Ollama launch configuration."

  if custom_agent_is_loaded; then
    "$LAUNCHCTL_BIN" bootout "$LAUNCH_DOMAIN/$CUSTOM_LABEL" >/dev/null 2>&1 || \
      warn "Could not unload the failed $CUSTOM_LABEL job during rollback."
  fi
  best_effort_stop_ollama

  if (( PREVIOUS_LAUNCH_SCRIPT_PRESENT )); then
    "$INSTALL_BIN" -m 0755 "$STAGE_DIR/previous-launch.sh" "$INSTALLED_LAUNCH_SCRIPT" || \
      warn "Could not restore $INSTALLED_LAUNCH_SCRIPT."
  else
    "$RM_BIN" -f -- "$INSTALLED_LAUNCH_SCRIPT" || \
      warn "Could not remove failed launcher $INSTALLED_LAUNCH_SCRIPT."
  fi
  if (( PREVIOUS_PLIST_PRESENT )); then
    "$INSTALL_BIN" -m 0644 "$STAGE_DIR/previous-agent.plist" "$INSTALLED_PLIST" || \
      warn "Could not restore $INSTALLED_PLIST."
  else
    "$RM_BIN" -f -- "$INSTALLED_PLIST" || \
      warn "Could not remove failed plist $INSTALLED_PLIST."
  fi

  restore_managed_legacy_launcher

  restore_environment_value OLLAMA_CONTEXT_LENGTH "$PREVIOUS_CONTEXT_LENGTH"
  restore_environment_value OLLAMA_FLASH_ATTENTION "$PREVIOUS_FLASH_ATTENTION"
  restore_environment_value OLLAMA_KV_CACHE_TYPE "$PREVIOUS_KV_CACHE_TYPE"
  restore_environment_value OLLAMA_NUM_PARALLEL "$PREVIOUS_NUM_PARALLEL"
  restore_environment_value OLLAMA_MAX_LOADED_MODELS "$PREVIOUS_MAX_LOADED_MODELS"
  restore_environment_value OLLAMA_KEEP_ALIVE "$PREVIOUS_KEEP_ALIVE"

  if (( LOGIN_ITEM_TOUCHED )); then
    if (( PREVIOUS_LOGIN_ITEM_DISABLED )); then
      "$LAUNCHCTL_BIN" disable "$LAUNCH_DOMAIN/$OLLAMA_LOGIN_LABEL" >/dev/null 2>&1 || \
        warn "Could not restore the disabled stock login-item state."
    else
      "$LAUNCHCTL_BIN" enable "$LAUNCH_DOMAIN/$OLLAMA_LOGIN_LABEL" >/dev/null 2>&1 || \
        warn "Could not restore the enabled stock login-item state."
    fi
  fi

  if (( PREVIOUS_AGENT_LOADED && PREVIOUS_PLIST_PRESENT )); then
    "$LAUNCHCTL_BIN" bootstrap "$LAUNCH_DOMAIN" "$INSTALLED_PLIST" >/dev/null 2>&1 || \
      warn "Could not reload the previous $CUSTOM_LABEL job."
  fi

  if (( PREVIOUS_OLLAMA_RUNNING )); then
    /usr/bin/open -a "Ollama" >/dev/null 2>&1 || warn "Could not restart Ollama during rollback."
  else
    best_effort_stop_ollama
  fi
}

environment_is_ready() {
  local context_length flash_attention kv_cache parallel loaded keep_alive

  context_length=$("$LAUNCHCTL_BIN" getenv OLLAMA_CONTEXT_LENGTH 2>/dev/null || true)
  flash_attention=$("$LAUNCHCTL_BIN" getenv OLLAMA_FLASH_ATTENTION 2>/dev/null || true)
  kv_cache=$("$LAUNCHCTL_BIN" getenv OLLAMA_KV_CACHE_TYPE 2>/dev/null || true)
  parallel=$("$LAUNCHCTL_BIN" getenv OLLAMA_NUM_PARALLEL 2>/dev/null || true)
  loaded=$("$LAUNCHCTL_BIN" getenv OLLAMA_MAX_LOADED_MODELS 2>/dev/null || true)
  keep_alive=$("$LAUNCHCTL_BIN" getenv OLLAMA_KEEP_ALIVE 2>/dev/null || true)

  [[ -z "$context_length" && "$flash_attention" == "1" && "$kv_cache" == "q4_0" && \
    "$parallel" == "2" && "$loaded" == "2" && "$keep_alive" == "15m" ]]
}

wait_for_environment() {
  local attempt=1

  while (( attempt <= 10 )); do
    if environment_is_ready; then
      return 0
    fi
    "$SLEEP_BIN" 1
    (( attempt += 1 ))
  done

  return 1
}

wait_for_ollama_running() {
  local attempt=1

  while (( attempt <= 10 )); do
    if ollama_is_running; then
      return 0
    fi
    "$SLEEP_BIN" 1
    (( attempt += 1 ))
  done

  return 1
}

remove_managed_legacy_launcher() {
  if (( PREVIOUS_LEGACY_LAUNCH_SCRIPT_PRESENT )); then
    log "Removing managed legacy launcher $LEGACY_INSTALLED_LAUNCH_SCRIPT."
    LEGACY_LAUNCH_SCRIPT_REMOVAL_STARTED=1
    "$RM_BIN" -f -- "$LEGACY_INSTALLED_LAUNCH_SCRIPT" || \
      die "Failed to remove legacy launcher $LEGACY_INSTALLED_LAUNCH_SCRIPT."
  fi
}

install_agent() {
  [[ -d "/Applications/Ollama.app" ]] || die "Ollama.app was not found under /Applications."
  [[ -f "$SOURCE_LAUNCH_SCRIPT" ]] || die "Missing source launcher: $SOURCE_LAUNCH_SCRIPT"
  [[ -f "$SOURCE_PLIST" ]] || die "Missing source plist: $SOURCE_PLIST"

  refuse_unmanaged_target "$INSTALLED_LAUNCH_SCRIPT"
  refuse_unmanaged_target "$INSTALLED_PLIST"

  STAGE_DIR=$("$MKTEMP_BIN" -d "${TMPDIR:-/tmp}/ollama-launch-agent.XXXXXX")
  prepare_staged_files
  capture_install_state
  INSTALL_TRANSACTION_ACTIVE=1

  "$MKDIR_BIN" -p "$OLLAMA_DIR" "$LAUNCH_LOG_DIR" "$USER_LAUNCH_AGENTS_DIR"
  unload_custom_agent

  "$INSTALL_BIN" -m 0755 "$STAGE_DIR/ollama-custom-launcher.sh" "$INSTALLED_LAUNCH_SCRIPT"
  "$INSTALL_BIN" -m 0644 "$STAGE_DIR/$CUSTOM_LABEL.plist" "$INSTALLED_PLIST"

  if (( DISABLE_LOGIN_ITEM )); then
    disable_stock_login_item
  elif ! login_item_is_disabled; then
    warn "The stock Ollama login item is enabled. Re-run with --disable-login-item or disable it manually to avoid a startup race."
  fi

  log "Loading $CUSTOM_LABEL."
  "$LAUNCHCTL_BIN" bootstrap "$LAUNCH_DOMAIN" "$INSTALLED_PLIST" || \
    die "Failed to bootstrap $INSTALLED_PLIST."
  custom_agent_is_loaded || die "$CUSTOM_LABEL was not loaded after bootstrap."
  wait_for_environment || die "$CUSTOM_LABEL loaded, but its Ollama environment did not become ready. Check $LAUNCH_STDERR."
  wait_for_ollama_running || die "$CUSTOM_LABEL loaded, but the Ollama application did not start. Check $LAUNCH_STDERR."
  remove_managed_legacy_launcher

  INSTALL_TRANSACTION_ACTIVE=0

  log "Installed and activated $CUSTOM_LABEL."
  log "Launcher logs: $LAUNCH_STDOUT and $LAUNCH_STDERR"
  if (( PREVIOUS_OLLAMA_RUNNING )); then
    warn "Restart required: choose Quit Ollama from the menu-bar icon, then open Ollama again."
  fi
}

unset_ollama_environment() {
  local variable

  for variable in \
    OLLAMA_CONTEXT_LENGTH \
    OLLAMA_FLASH_ATTENTION \
    OLLAMA_KV_CACHE_TYPE \
    OLLAMA_NUM_PARALLEL \
    OLLAMA_MAX_LOADED_MODELS \
    OLLAMA_KEEP_ALIVE; do
    "$LAUNCHCTL_BIN" unsetenv "$variable" 2>/dev/null || true
  done
}

uninstall_agent() {
  refuse_unmanaged_target "$INSTALLED_LAUNCH_SCRIPT"
  refuse_unmanaged_target "$INSTALLED_PLIST"

  unload_custom_agent

  if [[ -f "$INSTALLED_LAUNCH_SCRIPT" ]]; then
    "$RM_BIN" -f -- "$INSTALLED_LAUNCH_SCRIPT"
  fi
  if [[ ! -L "$LEGACY_INSTALLED_LAUNCH_SCRIPT" ]] && is_managed_file "$LEGACY_INSTALLED_LAUNCH_SCRIPT"; then
    "$RM_BIN" -f -- "$LEGACY_INSTALLED_LAUNCH_SCRIPT"
  fi
  if [[ -f "$INSTALLED_PLIST" ]]; then
    "$RM_BIN" -f -- "$INSTALLED_PLIST"
  fi

  unset_ollama_environment

  if (( ENABLE_LOGIN_ITEM )); then
    enable_stock_login_item
  fi

  log "Uninstalled $CUSTOM_LABEL. Ollama data and logs were preserved."
  if ollama_is_running; then
    warn "Ollama is still running with its inherited environment; restart it to use stock defaults."
  fi
}

parse_args "$@"
require_macos
require_safe_home

readonly USER_ID="$("$ID_BIN" -u)"
readonly LAUNCH_DOMAIN="gui/$USER_ID"
readonly OLLAMA_DIR="$HOME/.ollama"
readonly LAUNCH_LOG_DIR="$OLLAMA_DIR/logs"
readonly USER_LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
readonly INSTALLED_LAUNCH_SCRIPT="$OLLAMA_DIR/ollama-custom-launcher.sh"
readonly LEGACY_INSTALLED_LAUNCH_SCRIPT="$OLLAMA_DIR/launch.sh"
readonly INSTALLED_PLIST="$USER_LAUNCH_AGENTS_DIR/$CUSTOM_LABEL.plist"
readonly LAUNCH_STDOUT="$LAUNCH_LOG_DIR/launch-agent.stdout.log"
readonly LAUNCH_STDERR="$LAUNCH_LOG_DIR/launch-agent.stderr.log"

case "$MODE" in
  install)
    install_agent
    ;;
  uninstall)
    uninstall_agent
    ;;
esac
