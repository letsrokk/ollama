#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
container_name=searxng-config-test-$$
config_json=$(mktemp)
test_key=verification-only-not-a-real-key

cleanup() {
    docker rm -f "$container_name" >/dev/null 2>&1 || true
    rm -f "$config_json"
}
trap cleanup EXIT HUP INT TERM

docker run -d \
    --name "$container_name" \
    --publish 127.0.0.1::8080 \
    --volume "$repo_root/searxng:/etc/searxng:ro" \
    --env "BRAVE_SEARCH_API_KEY=$test_key" \
    --env FORCE_OWNERSHIP=false \
    --env SEARXNG_BASE_URL=http://localhost:8080/ \
    --env SEARXNG_SECRET=verification-only \
    --entrypoint /etc/searxng/entrypoint.sh \
    searxng/searxng:2026.5.29-780ee3256 >/dev/null

attempt=0
while [ "$attempt" -lt 80 ]; do
    state=$(docker inspect "$container_name" --format '{{.State.Status}}')
    if [ "$state" = exited ] || [ "$state" = dead ]; then
        docker logs "$container_name" >&2
        exit 1
    fi

    port=$(docker port "$container_name" 8080/tcp 2>/dev/null | sed -n 's/.*://p' | tail -1)
    if [ -n "$port" ] && curl -fsS "http://127.0.0.1:$port/config" >"$config_json" 2>/dev/null; then
        break
    fi

    attempt=$((attempt + 1))
    sleep 0.25
done

[ -s "$config_json" ]

jq -e '
    [.engines[] | select(.enabled == true) | .name] as $enabled
    | ($enabled | index("braveapi")) != null
      and ($enabled | index("google")) != null
      and ($enabled | index("openstreetmap")) != null
      and ($enabled | index("duckduckgo")) == null
      and ($enabled | index("bing")) == null
      and ($enabled | index("google news")) == null
      and ($enabled | index("bing news")) == null
' "$config_json" >/dev/null

docker exec -i "$container_name" /usr/local/searxng/.venv/bin/python - <<'PY'
import sys
from pathlib import Path

import yaml

settings = yaml.safe_load(Path("/tmp/searxng-settings.yml").read_text(encoding="utf-8"))
assert settings["outgoing"]["retries"] == 0
assert settings["search"]["suspended_times"] == {
    "SearxEngineAccessDenied": 3600,
    "SearxEngineCaptcha": 43200,
    "SearxEngineTooManyRequests": 1800,
    "cf_SearxEngineCaptcha": 1296000,
    "cf_SearxEngineAccessDenied": 86400,
    "recaptcha_SearxEngineCaptcha": 604800,
}
brave = next(engine for engine in settings["engines"] if engine["name"] == "braveapi")
assert brave["api_key"] == "verification-only-not-a-real-key"
assert brave["inactive"] is False
assert brave["disabled"] is False
assert Path("/tmp/searxng-settings.yml").stat().st_mode & 0o777 == 0o600
PY

compose_json=$(cd "$repo_root" && \
    BRAVE_SEARCH_API_KEY=$test_key \
    SEARXNG_SECRET=verification-only \
    docker compose config --format json)

printf '%s' "$compose_json" | jq -e '
    .services.searxng.entrypoint == ["/etc/searxng/entrypoint.sh"]
    and .services.searxng.environment.BRAVE_SEARCH_API_KEY == "verification-only-not-a-real-key"
' >/dev/null

printf '%s\n' 'searxng configuration tests passed'
