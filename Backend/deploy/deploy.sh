#!/bin/sh
# Ship Backend/ to nomonhomelab and (re)start it.
#
#   Backend/deploy/deploy.sh            sync, build, restart, health-check
#   Backend/deploy/deploy.sh --expose   also publish it with cf-dns (first deploy)
#
# Env: CALLA_HOST (ssh host, default nomonhomelab), CALLA_HOSTNAME (public
# name under nomonlab.com, default calla-api; one label only, since the free
# Cloudflare certificate covers *.nomonlab.com but not *.calla.nomonlab.com).
set -eu

host=${CALLA_HOST:-nomonhomelab}
name=${CALLA_HOSTNAME:-calla-api}
remote=/srv/app/calla-backend
src=$(cd "$(dirname "$0")/.." && pwd)

expose=false
[ "${1:-}" = "--expose" ] && expose=true

echo "==> syncing $src to $host:$remote"
ssh "$host" "mkdir -p $remote"
rsync -az --delete \
  --exclude '/deploy/.env' --exclude '/data/' --exclude '*.test' \
  "$src/" "$host:$remote/"

echo "==> building and starting"
ssh "$host" REMOTE="$remote" sh -s <<'EOS'
set -eu
cd "$REMOTE/deploy"
if [ ! -f .env ]; then
  umask 077
  sed "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$(openssl rand -hex 24)|" .env.example > .env
  echo "created $REMOTE/deploy/.env"
fi
if ! grep -q '^CALLA_ENROLL_SECRET=.' .env; then
  sed -i '/^CALLA_ENROLL_SECRET=/d' .env
  echo "CALLA_ENROLL_SECRET=$(openssl rand -hex 32)" >> .env
  echo "added CALLA_ENROLL_SECRET to $REMOTE/deploy/.env"
fi
docker compose up -d --build --remove-orphans
mkdir -p "$HOME/.local/bin"
ln -sfn "$REMOTE/bin/calla-backend" "$HOME/.local/bin/calla-backend"
for i in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:18795/healthz >/dev/null 2>&1; then
    curl -fsS http://127.0.0.1:18795/healthz; echo
    exit 0
  fi
  sleep 2
done
docker compose logs --tail 50 backend
echo "backend did not become healthy" >&2
exit 1
EOS

if $expose; then
  echo "==> publishing https://$name.nomonlab.com via the calla-control tunnel"
  ssh "$host" NAME="$name" sh -s <<'EOS'
set -eu
cd /srv/app/cloudflare-dns
set -a; . ./.env; set +a
./cf_dns.py --manifest calla-control.toml expose "$NAME" --service http://127.0.0.1:18795
./cf_dns.py --manifest calla-control.toml published
EOS
fi

# scripts/package-private.sh bakes this into each private DMG.
secret_file="$HOME/.config/calla/enroll-secret"
remote_secret=$(ssh "$host" "sed -n 's/^CALLA_ENROLL_SECRET=//p' $remote/deploy/.env")
if [ -n "$remote_secret" ] && [ "$(cat "$secret_file" 2>/dev/null)" != "$remote_secret" ]; then
  mkdir -p "$(dirname "$secret_file")"
  (umask 077; printf '%s\n' "$remote_secret" > "$secret_file")
  echo "==> saved the enrollment secret to $secret_file"
fi

echo "==> public check"
curl -fsS --max-time 15 "https://$name.nomonlab.com/healthz" && echo || \
  echo "public URL not answering yet (DNS/TLS may take a minute; see Backend/README.md on second-level subdomains)" >&2
