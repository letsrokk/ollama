#!/bin/sh
set -eu

if [ -z "${BRAVE_SEARCH_API_KEY:-}" ]; then
    echo "BRAVE_SEARCH_API_KEY must be set" >&2
    exit 64
fi

settings_template=${SEARXNG_SETTINGS_TEMPLATE:-/etc/searxng/settings.yml}
rendered_settings=${SEARXNG_RENDERED_SETTINGS_PATH:-/tmp/searxng-settings.yml}
python_bin=${SEARXNG_PYTHON:-/usr/local/searxng/.venv/bin/python}
upstream_entrypoint=${SEARXNG_UPSTREAM_ENTRYPOINT:-/usr/local/searxng/entrypoint.sh}

"$python_bin" - "$settings_template" "$rendered_settings" <<'PY'
import json
import os
import sys
from pathlib import Path

placeholder = "__BRAVE_SEARCH_API_KEY_JSON__"
source = Path(sys.argv[1])
target = Path(sys.argv[2])
text = source.read_text(encoding="utf-8")
if text.count(placeholder) != 1:
    print(f"expected exactly one {placeholder} placeholder", file=sys.stderr)
    raise SystemExit(65)
rendered = text.replace(placeholder, json.dumps(os.environ["BRAVE_SEARCH_API_KEY"]))
target.write_text(rendered, encoding="utf-8")
target.chmod(0o600)
PY

export SEARXNG_SETTINGS_PATH=$rendered_settings
exec "$upstream_entrypoint" "$@"
