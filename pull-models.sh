#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_COMPOSE_FILE="$SCRIPT_DIR/docker-compose-ollama.yaml"

usage() {
  cat <<EOF
Usage:
  $0 [--native|--docker]
  $0 [--native|--docker] list-file
  $0 [--native|--docker] model[:tag]
  $0 [--native|--docker] model[:tag],model[:tag]

Without an input, Apple Silicon Macs use models-mlx.list and all other
platforms use models-gguf.list. On macOS, native Ollama is used when it is
available; otherwise Docker Compose is used. Other platforms default to
Docker Compose. Use --native or --docker to override backend detection.

Model list files support blank lines and comments beginning with #.
EOF
}

die() {
  echo "$*" >&2
  exit 1
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

models=()

append_model() {
  local model
  model="$(trim "$1")"

  if [[ -n "$model" ]]; then
    models+=("$model")
  fi
}

load_models_from_file() {
  local file="$1"
  local line

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    append_model "$line"
  done < "$file"
}

load_models_from_arg() {
  local input="$1"
  local model
  local parsed_models

  IFS=',' read -ra parsed_models <<< "$input"
  for model in "${parsed_models[@]}"; do
    append_model "$model"
  done
}

backend_override=""
input=""

while (( $# > 0 )); do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --native)
      [[ "$backend_override" != "docker" ]] || die "--native and --docker cannot be used together."
      backend_override="native"
      ;;
    --docker)
      [[ "$backend_override" != "native" ]] || die "--native and --docker cannot be used together."
      backend_override="docker"
      ;;
    -*)
      die "Unknown option: $1"
      ;;
    *)
      [[ -z "$input" ]] || die "Only one model list or model argument may be provided."
      input="$1"
      ;;
  esac
  shift
done

os="$(uname -s)"
arch="$(uname -m)"

if [[ "$os" == "Darwin" && "$arch" == "arm64" ]]; then
  default_list="$SCRIPT_DIR/models-mlx.list"
else
  default_list="$SCRIPT_DIR/models-gguf.list"
fi

case "$backend_override" in
  native)
    command -v ollama >/dev/null 2>&1 || die "Native Ollama was requested, but 'ollama' was not found in PATH."
    backend="native"
    ;;
  docker)
    command -v docker >/dev/null 2>&1 || die "Docker was requested, but 'docker' was not found in PATH."
    backend="docker"
    ;;
  "")
    if [[ "$os" == "Darwin" ]] && command -v ollama >/dev/null 2>&1; then
      backend="native"
    else
      command -v docker >/dev/null 2>&1 || die "Neither an automatic native Ollama backend nor Docker is available."
      backend="docker"
    fi
    ;;
esac

if [[ -z "$input" ]]; then
  [[ -f "$default_list" ]] || die "Default model list not found: $default_list"
  model_source="$(basename "$default_list")"
  load_models_from_file "$default_list"
elif [[ -f "$input" ]]; then
  model_source="$input"
  load_models_from_file "$input"
else
  model_source="command line"
  load_models_from_arg "$input"
fi

(( ${#models[@]} > 0 )) || die "No models to pull."

total_models="${#models[@]}"
current_model=0

echo "Backend: $backend"
echo "Model list: $model_source"
echo "Models to pull: $total_models"
echo

for model in "${models[@]}"; do
  current_model=$((current_model + 1))
  echo "[$current_model/$total_models] Pulling $model"
  if [[ "$backend" == "native" ]]; then
    ollama pull "$model"
  else
    docker compose -f "$DOCKER_COMPOSE_FILE" exec ollama ollama pull "$model"
  fi
done

echo
echo "Successfully pulled $current_model of $total_models models."
