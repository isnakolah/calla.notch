#!/bin/sh
# Local-only: no SSH, publishing or outgoing emails.
set -eu
cd "$(dirname "$0")/.."
if [ ! -x .venv/bin/gunicorn ]; then
  python3 -m venv .venv
  .venv/bin/pip install -r api/requirements.txt
fi
[ -d node_modules ] || npm ci
.venv/bin/gunicorn --bind 127.0.0.1:4188 --workers 1 --threads 4 --no-control-socket 'api.app:create_app()' &
api_pid=$!
trap 'kill "$api_pid" 2>/dev/null || true' EXIT INT TERM
npm run dev
