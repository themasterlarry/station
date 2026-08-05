#!/bin/bash
# Adds Subscriptions and Journal to a running Station.
# Run inside the container, from the folder holding subs.html and journal.html:
#     bash add-modules.sh
set -e

APP=/root/station-app
[ -f subs.html ]    || { echo "STOPPED: subs.html isn't in this folder."; exit 1; }
[ -f journal.html ] || { echo "STOPPED: journal.html isn't in this folder."; exit 1; }
[ -d "$APP/public" ] || { echo "STOPPED: can't find $APP/public — is Station installed?"; exit 1; }

echo "==> Adding the two new pages"
cp subs.html journal.html "$APP/public/"

echo "==> Adding them to the menu on every page"
python3 - "$APP/public" <<'PYEOF'
import sys, glob, os
d = sys.argv[1]

OLD_NAV = '  {id:"vault",cd:"PW",label:"Passwords",file:"vault.html"}\n];'
NEW_NAV = ('  {id:"vault",cd:"PW",label:"Passwords",file:"vault.html"},\n'
           '  {id:"subs",cd:"SB",label:"Subscriptions",file:"subs.html"},\n'
           '  {id:"journal",cd:"JR",label:"Journal",file:"journal.html"}\n];')

OLD_MIG = '  H.habits=H.habits||[];H.things=H.things||[];H.contacts=H.contacts||[];'
NEW_MIG = (OLD_MIG + '\n  H.subs=H.subs||[];H.journal=H.journal||[];')

OLD_CNT = '  var lt=ledgerTotals(); c.money=lt?lt.late.length:0;'
NEW_CNT = (OLD_CNT + '\n  c.subs=(H.subs||[]).filter(function(x){'
           'return x.active!==false&&x.next&&daysBetween(ts,x.next)<=3;}).length;')

# dashboard: show charges landing in the next few days
OLD_DECK = '''  H.habits.filter(function(h){return !(h.days||{})[ts];}).forEach(function(h){
    deck.push(lineItem("HB",h.name,"not marked yet today",false,null,"mark",
      function(){toggleHabit(h.id,ts);}));});'''
NEW_DECK = OLD_DECK + '''
  (H.subs||[]).filter(function(s){
    return s.active!==false&&s.next&&daysBetween(ts,s.next)<=3;}).forEach(function(s){
    deck.push(lineItem("SB",(s.trial?"Trial ends: ":"Charging: ")+s.name+" — "+money(s.cents),
      relDay(s.next)+(s.trial?" · cancel before it bills":""),
      s.trial||s.next<=ts,"subs.html","open"));});'''

nav = mig = cnt = deck = 0
for p in sorted(glob.glob(os.path.join(d, "*.html"))):
    s = open(p).read()
    orig = s
    if OLD_NAV in s: s = s.replace(OLD_NAV, NEW_NAV); nav += 1
    if OLD_MIG in s: s = s.replace(OLD_MIG, NEW_MIG); mig += 1
    if OLD_CNT in s: s = s.replace(OLD_CNT, NEW_CNT); cnt += 1
    if OLD_DECK in s: s = s.replace(OLD_DECK, NEW_DECK); deck += 1
    if s != orig:
        open(p, "w").write(s)
print(f"    menu updated on {nav} pages")
print(f"    storage prepared on {mig} pages")
print(f"    badge counts on {cnt} pages")
print(f"    day sheet updated on {deck} page(s)")
if nav < 9:
    print("    NOTE: some pages already had the menu entry, or differ from expected — that's usually fine.")
PYEOF

echo "==> Restarting"
cd "$APP"
docker compose restart >/dev/null 2>&1 || docker compose up -d

for i in $(seq 1 20); do
  if curl -fsS http://127.0.0.1:8099/api/health >/dev/null 2>&1; then
    IP=$(hostname -I | awk '{print $1}')
    echo ""
    echo "  Done. Two new tabs in the menu: Subscriptions and Journal."
    echo "  http://$IP:8099/subs.html"
    echo "  http://$IP:8099/journal.html"
    exit 0
  fi
  sleep 2
done
echo "STOPPED: it didn't come back up. Run:  docker logs station"
exit 1
