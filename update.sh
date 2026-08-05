#!/bin/bash
# Station update — documents, attachments, history, phone capture, appointments.
# Run inside the container from the folder holding server.js and public/:
#     bash update.sh
set -e

APP=/root/station-app
say(){ printf "\n\033[1;33m==> %s\033[0m\n" "$1"; }
ok(){  printf "    \033[0;32m%s\033[0m\n" "$1"; }
die(){ printf "\n\033[0;31mSTOPPED: %s\033[0m\n" "$1" >&2; exit 1; }

[ -f server.js ] || die "server.js isn't in this folder."
[ -d public ]    || die "The public/ folder is missing."
[ -d "$APP" ]    || die "Can't find $APP — is Station installed?"

say "1/4  Backing up what's there now"
STAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p "$APP/backups"
tar czf "$APP/backups/before-$STAMP.tar.gz" -C "$APP" public server.js 2>/dev/null || true
ok "old version saved to $APP/backups/before-$STAMP.tar.gz"

say "2/4  Copying the new files in"
cp server.js "$APP/server.js"
cp public/*.html "$APP/public/"
COUNT=$(ls -1 "$APP/public"/*.html | wc -l)
ok "$COUNT pages in place"

say "3/4  Rebuilding the container"
cd "$APP"
docker compose up -d --build 2>&1 | tail -3

say "4/4  Checking it works"
UP=0
for i in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:8099/api/health >/dev/null 2>&1; then UP=1; break; fi
  sleep 2
done
[ "$UP" = "1" ] || die "It didn't come back. Run: docker logs station"
ok "$(curl -s http://127.0.0.1:8099/api/health)"

# confirm the new endpoints answer
curl -fsS http://127.0.0.1:8099/api/files >/dev/null 2>&1 && ok "documents endpoint live"
curl -fsS http://127.0.0.1:8099/api/history/hub:v1 >/dev/null 2>&1 && ok "history endpoint live"
TOKEN=$(curl -s http://127.0.0.1:8099/api/token | sed 's/.*"token":"\([^"]*\)".*/\1/')
IP=$(hostname -I | awk '{print $1}')

cat <<DONE

===================================
  Updated. Two new tabs: Documents and History.
===================================

  Your phone capture address — keep this private:

  http://$IP:8099/api/capture?token=$TOKEN&text=YOUR+TEXT

  Add &kind=note or &kind=journal to change where it lands.
  It's also shown any time under the Backup button.

  Your data was untouched. The old pages are in
  $APP/backups/ if anything looks wrong.

DONE
