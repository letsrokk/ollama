#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() {
  cat <<EOF
Usage:
  $0 models.list
  $0 model[:tag]
  $0 model[:tag],model[:tag]

Model list files support blank lines and comments beginning with #.
EOF
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

load_models_from_file() {
  local file="$1"
  local line model

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    model="$(trim "$line")"

    if [[ -n "$model" ]]; then
      printf '%s\n' "$model"
    fi
  done < "$file"
}

load_models_from_arg() {
  local input="$1"
  local model

  IFS=',' read -ra models <<< "$input"
  for model in "${models[@]}"; do
    model="$(trim "$model")"

    if [[ -n "$model" ]]; then
      printf '%s\n' "$model"
    fi
  done
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if (( $# != 1 )); then
  usage >&2
  exit 1
fi

input="$1"

if [[ -f "$input" ]]; then
  mapfile -t models < <(load_models_from_file "$input")
else
  mapfile -t models < <(load_models_from_arg "$input")
fi

if (( ${#models[@]} == 0 )); then
  echo "No models to pull." >&2
  exit 1
fi

for model in "${models[@]}"; do
  echo "Pulling $model"
  docker compose exec ollama ollama pull "$model"
done
