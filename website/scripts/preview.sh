#!/bin/sh
# Run the built page and its real signup endpoint on one local origin.
set -eu
cd "$(dirname "$0")/.."
if [ ! -x .venv/bin/gunicorn ]; then
  python3 -m venv .venv
  .venv/bin/pip install -r api/requirements.txt
fi
[ -d node_modules ] || npm ci
npm run build
exec .venv/bin/gunicorn --bind 127.0.0.1:4187 --workers 1 --threads 4 --no-control-socket 'api.app:create_app()'
