#!/bin/bash
# Station 2.4 — 8 pages instead of 18. Run inside the container from this folder.
set -e
APP=/root/station-app
[ -d "$APP/public" ] || { echo "STOPPED: can't find $APP/public"; exit 1; }
[ -d public ] || { echo "STOPPED: run this from the folder with public/ in it"; exit 1; }

echo "==> Backing up the old pages"
STAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p "$APP/backups"
tar czf "$APP/backups/before-$STAMP.tar.gz" -C "$APP" public 2>/dev/null || true
echo "    saved to $APP/backups/before-$STAMP.tar.gz"

echo "==> Clearing out the old page files"
rm -f "$APP/public"/*.html

echo "==> Copying the new ones in"
cp public/*.html "$APP/public/"
[ -f server.js ] && cp server.js "$APP/server.js"
echo "    $(ls -1 "$APP/public"/*.html | wc -l) files"

echo "==> Rebuilding"
cd "$APP"
docker compose up -d --build 2>&1 | tail -3

for i in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:8099/api/health >/dev/null 2>&1; then
    IP=$(hostname -I | awk '{print $1}')
    echo ""
    echo "  Done. http://$IP:8099"
    echo "  Your data is untouched — only the pages changed."
    exit 0
  fi
  sleep 2
done
echo "STOPPED: it didn't come back. Run: docker logs station"
exit 1
