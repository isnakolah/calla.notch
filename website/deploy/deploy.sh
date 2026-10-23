#!/bin/sh
# Deploy the landing page and its waitlist to nomonhomelab.
set -eu

site=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
host=${CALLA_LANDING_HOST:-isnakolah@nomonhomelab}
remote=/srv/app/calla-landing
url=https://calla.nomonlab.com
password_file=${CALLA_LANDING_ADMIN_PASSWORD_FILE:-$HOME/.config/calla/landing-admin-password}
temporary_password=
cookie_file=

cleanup() {
  if [ -n "$temporary_password" ]; then
    rm -f "$temporary_password"
  fi
  if [ -n "$cookie_file" ]; then
    rm -f "$cookie_file"
  fi
}
trap cleanup 0

echo '==> validating landing page'
cd "$site"
npm ci
npm test
if [ ! -x .venv/bin/python ]; then
  python3 -m venv .venv
fi
.venv/bin/python -m pip install -q -r api/requirements.txt
.venv/bin/python -m unittest api/test_app.py
npm run build
docker compose -f deploy/compose.yml config -q

echo "==> syncing website to $host:$remote"
ssh "$host" "mkdir -p '$remote'"
rsync -az --delete \
  --include='/index.html' --include='/admin.html' \
  --include='/vite.config.js' --include='/package.json' --include='/package-lock.json' \
  --include='/src/***' --include='/public/***' --include='/api/***' --include='/deploy/***' \
  --exclude='*' \
  "$site/" "$host:$remote/"

echo '==> building and starting containers'
ssh "$host" sh -s <<'REMOTE'
set -eu
cd /srv/app/calla-landing
docker compose -f deploy/compose.yml up -d --build --remove-orphans
for attempt in $(seq 1 60); do
  if curl -fsS --max-time 3 http://127.0.0.1:4187/healthz >/dev/null 2>&1; then
    exit 0
  fi
  sleep 2
done
docker compose -f deploy/compose.yml logs --tail 60 web waitlist >&2
echo 'Landing page did not become healthy' >&2
exit 1
REMOTE

admin_state=$(ssh "$host" "cd '$remote' && docker compose -f deploy/compose.yml exec -T waitlist python -c 'import json; print(\"configured\" if json.load(open(\"/data/admin.json\")).get(\"password_hash\") else \"missing\")'")
case "$admin_state" in
  missing)
    if [ ! -s "$password_file" ]; then
      mkdir -p -m 700 "$(dirname "$password_file")"
      temporary_password=$(mktemp "${password_file}.tmp.XXXXXX")
      python3 -c 'import secrets; print(secrets.token_urlsafe(36))' > "$temporary_password"
      chmod 600 "$temporary_password"
      mv "$temporary_password" "$password_file"
      temporary_password=
    fi
    chmod 600 "$password_file"
    echo '==> configuring private dashboard password'
    ssh "$host" "cd '$remote' && docker compose -f deploy/compose.yml exec -T waitlist python api/app.py admin --password-stdin && docker compose -f deploy/compose.yml restart waitlist" < "$password_file"
    ;;
  configured)
    echo '==> preserving existing dashboard password'
    if [ -e "$password_file" ]; then
      chmod 600 "$password_file"
    fi
    ;;
  *)
    echo "Unexpected dashboard configuration state: $admin_state" >&2
    exit 1
    ;;
esac

echo '==> verifying local origin'
ssh "$host" sh -s <<'REMOTE'
set -eu
for attempt in $(seq 1 30); do
  if curl -fsS --max-time 3 http://127.0.0.1:4187/healthz >/dev/null 2>&1; then
    curl -fsS --max-time 5 http://127.0.0.1:4187/ | grep -qi 'calla'
    exit 0
  fi
  sleep 2
done
echo 'Landing page did not recover after admin setup' >&2
exit 1
REMOTE

echo '==> transferring hostname to the public tunnel'
ssh "$host" sh -s <<'REMOTE'
set -eu
cd /srv/app/cloudflare-dns
if grep -q '^"calla" = ' calla-control.toml; then
  set -a
  . ./.env
  set +a
  ./cf_dns.py --manifest calla-control.toml unexpose calla --yes
fi
~/.local/bin/cf-dns expose calla --service http://127.0.0.1:4187
~/.local/bin/cf-dns published | grep -F 'https://calla.nomonlab.com -> http://127.0.0.1:4187 (present)'
REMOTE

echo '==> verifying public HTTPS and dashboard login'
cf_ip=
curl_public() {
  if [ -n "$cf_ip" ]; then
    curl --resolve "calla.nomonlab.com:443:$cf_ip" "$@"
  else
    curl "$@"
  fi
}
ready=false
for attempt in $(seq 1 40); do
  if curl_public -fsS --max-time 8 "$url/healthz" >/dev/null 2>&1 && \
     curl_public -fsS --max-time 8 "$url/" | grep -qi 'calla'; then
    ready=true
    break
  fi
  if [ -z "$cf_ip" ]; then
    # A local resolver can cache the pre-publication NXDOMAIN result. Keep the
    # hostname for TLS while checking through Cloudflare's public DNS answer.
    cf_ip=$(dig +short @1.1.1.1 A calla.nomonlab.com 2>/dev/null | grep -E '^[0-9.]+$' | head -1 || true)
  fi
  sleep 3
done
if [ "$ready" != true ]; then
  echo "Public landing page did not become healthy at $url" >&2
  exit 1
fi

cookie_file=$(mktemp)
chmod 600 "$cookie_file"
session_json=$(curl_public -fsS --max-time 15 -c "$cookie_file" -b "$cookie_file" "$url/api/admin/session")
csrf=$(printf '%s' "$session_json" | python3 -c 'import json, sys; data=json.load(sys.stdin); assert not data["authenticated"] and not data["setup"], "dashboard must require a password"; print(data["csrf"])')
if [ -s "$password_file" ]; then
  login_json=$(python3 - "$password_file" "$csrf" <<'PY' | curl_public -fsS --max-time 15 -c "$cookie_file" -b "$cookie_file" -H 'Content-Type: application/json' -H "Origin: $url" --data-binary @- "$url/api/admin/login"
import json
import pathlib
import sys

print(json.dumps({'password': pathlib.Path(sys.argv[1]).read_text().strip(), 'csrf': sys.argv[2]}))
PY
  )
  printf '%s' "$login_json" | python3 -c 'import json, sys; assert json.load(sys.stdin).get("ok"), "dashboard login did not succeed"'
  curl_public -fsS --max-time 15 -b "$cookie_file" "$url/api/admin/report" >/dev/null
  echo 'Dashboard login verified'
else
  echo 'Dashboard password is configured on the server; local credential file is absent'
fi
rm -f "$cookie_file"
cookie_file=

invalid_status=$(curl_public -sS --max-time 15 -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -H "Origin: $url" --data-binary '{"email":"invalid","consent":"launch-notification-v1"}' "$url/api/waitlist")
if [ "$invalid_status" != 400 ]; then
  echo "Expected waitlist validation to return 400, got $invalid_status" >&2
  exit 1
fi

echo "Deployed $url"
echo "Dashboard password file: $password_file"
