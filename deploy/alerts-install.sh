#!/bin/sh
# Pivot alerts app on this server (https://alerts.twsiat.com). Run with:
#   ssh -t root@SERVER "curl -fsSL https://raw.githubusercontent.com/MorissSarkis/twsiat-rooms/main/deploy/alerts-install.sh | sh"
# Before: run db/020_alerts.sql in Supabase (it prints the ALERTS_TOKEN) and point alerts.twsiat.com to this server.
set -e
cd /opt/twsiat-rooms && git pull --ff-only
cd deploy
touch .env && chmod 600 .env
ask() {  # ask KEY "question" [hidden]
  if ! grep -q "^$1=." .env; then
    printf '%s\n' "$2"
    if [ "$3" = hidden ]; then stty -echo < /dev/tty; fi
    read V < /dev/tty
    if [ "$3" = hidden ]; then stty echo < /dev/tty; echo; fi
    [ -n "$V" ] || { echo "Empty value, stopping."; exit 1; }
    V=$(printf '%s' "$V" | sed 's/\$/$$/g')   # docker compose reads $ as a variable: escape it
    sed -i "/^$1=/d" .env
    printf '%s=%s\n' "$1" "$V" >> .env
  fi
}
ask ALERTS_TOKEN "Paste the alerts token (the value printed by db/020_alerts.sql in Supabase):" hidden
ask ALERTS_PASSWORD "Choose the login password for the alerts app (at least 8 characters):" hidden
grep -q '^ALERTS_CONTACT=' .env || printf 'ALERTS_CONTACT=mailto:info@twsiat.com\n' >> .env
mkdir -p /opt/alerts-data
docker compose up -d --build alerts
docker compose restart caddy >/dev/null
sleep 5
docker compose ps alerts caddy
docker compose logs --tail 15 alerts
echo "Done. Open https://alerts.twsiat.com (the DNS record must point to this server)."
