#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
wrapper=$repo_root/searxng/entrypoint.sh
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM

template=$test_dir/settings.yml
rendered=$test_dir/rendered.yml
limiter_template=$test_dir/input-limiter.toml
rendered_limiter=$test_dir/limiter.toml
capture_path=$test_dir/captured-path
capture_args=$test_dir/captured-args
fake_upstream=$test_dir/upstream.sh

cat >"$fake_upstream" <<'SH'
#!/bin/sh
printf '%s\n' "$SEARXNG_SETTINGS_PATH" >"$CAPTURE_PATH"
printf '%s\n' "$@" >"$CAPTURE_ARGS"
SH
chmod +x "$fake_upstream"

run_wrapper() {
    CAPTURE_PATH=$capture_path \
    CAPTURE_ARGS=$capture_args \
    SEARXNG_SETTINGS_TEMPLATE=$template \
    SEARXNG_RENDERED_SETTINGS_PATH=$rendered \
    SEARXNG_LIMITER_TEMPLATE=$limiter_template \
    SEARXNG_PYTHON=python3 \
    SEARXNG_UPSTREAM_ENTRYPOINT=$fake_upstream \
    "$wrapper" "$@"
}

set +e
BRAVE_SEARCH_API_KEY= run_wrapper >"$test_dir/missing.out" 2>"$test_dir/missing.err"
status=$?
set -e
[ "$status" -eq 64 ]
grep -q 'BRAVE_SEARCH_API_KEY' "$test_dir/missing.err"

printf '%s\n' 'api_key: no-placeholder' >"$template"
set +e
BRAVE_SEARCH_API_KEY=test run_wrapper >"$test_dir/zero.out" 2>"$test_dir/zero.err"
status=$?
set -e
[ "$status" -eq 65 ]

printf '%s\n' '__BRAVE_SEARCH_API_KEY_JSON__ __BRAVE_SEARCH_API_KEY_JSON__' >"$template"
set +e
BRAVE_SEARCH_API_KEY=test run_wrapper >"$test_dir/two.out" 2>"$test_dir/two.err"
status=$?
set -e
[ "$status" -eq 65 ]

printf '%s\n' 'api_key: __BRAVE_SEARCH_API_KEY_JSON__' >"$template"
printf '%s\n' '[botdetection.ip_limit]' 'filter_link_local = false' >"$limiter_template"
special_key='quote"and\backslash&dollar$'
BRAVE_SEARCH_API_KEY=$special_key run_wrapper alpha 'two words'

python3 - "$rendered" "$special_key" <<'PY'
import json
import sys
from pathlib import Path

scalar = Path(sys.argv[1]).read_text(encoding="utf-8").split(": ", 1)[1].strip()
assert json.loads(scalar) == sys.argv[2]
assert oct(Path(sys.argv[1]).stat().st_mode & 0o777) == "0o600"
PY

cmp "$limiter_template" "$rendered_limiter"
python3 - "$rendered_limiter" <<'PY'
import sys
from pathlib import Path

assert oct(Path(sys.argv[1]).stat().st_mode & 0o777) == "0o600"
PY
[ "$(cat "$capture_path")" = "$rendered" ]
[ "$(sed -n '1p' "$capture_args")" = 'alpha' ]
[ "$(sed -n '2p' "$capture_args")" = 'two words' ]
printf '%s\n' 'searxng entrypoint tests passed'
