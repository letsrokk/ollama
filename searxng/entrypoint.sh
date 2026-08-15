#!/bin/sh
set -eu

if [ -z "${BRAVE_SEARCH_API_KEY:-}" ]; then
    echo "BRAVE_SEARCH_API_KEY must be set" >&2
    exit 64
fi

settings_template=${SEARXNG_SETTINGS_TEMPLATE:-/etc/searxng/settings.yml}
rendered_settings=${SEARXNG_RENDERED_SETTINGS_PATH:-/tmp/searxng-settings.yml}
limiter_template=${SEARXNG_LIMITER_TEMPLATE:-/etc/searxng/limiter.toml}
python_bin=${SEARXNG_PYTHON:-/usr/local/searxng/.venv/bin/python}
upstream_entrypoint=${SEARXNG_UPSTREAM_ENTRYPOINT:-/usr/local/searxng/entrypoint.sh}

if [ ! -f "$settings_template" ]; then
    echo "SearXNG settings configuration not found: $settings_template" >&2
    exit 66
fi

if [ ! -f "$limiter_template" ]; then
    echo "SearXNG limiter configuration not found: $limiter_template" >&2
    exit 66
fi

"$python_bin" - "$settings_template" "$rendered_settings" <<'PY'
import json
import os
import sys
import tempfile
from pathlib import Path

placeholder = "__BRAVE_SEARCH_API_KEY_JSON__"
source = Path(sys.argv[1])
target = Path(sys.argv[2])
text = source.read_text(encoding="utf-8")
if text.count(placeholder) != 1:
    print(f"expected exactly one {placeholder} placeholder", file=sys.stderr)
    raise SystemExit(65)
rendered = text.replace(placeholder, json.dumps(os.environ["BRAVE_SEARCH_API_KEY"]))

fd, temporary_name = tempfile.mkstemp(prefix=f".{target.name}.", dir=target.parent)
try:
    os.fchmod(fd, 0o600)
    stream = os.fdopen(fd, "w", encoding="utf-8")
    fd = -1
    with stream:
        stream.write(rendered)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary_name, target)
except BaseException:
    if fd >= 0:
        os.close(fd)
    try:
        os.unlink(temporary_name)
    except FileNotFoundError:
        pass
    raise
PY

rendered_limiter=$(dirname "$rendered_settings")/limiter.toml
cp "$limiter_template" "$rendered_limiter"
chmod 600 "$rendered_limiter"

export SEARXNG_SETTINGS_PATH=$rendered_settings
exec "$upstream_entrypoint" "$@"
