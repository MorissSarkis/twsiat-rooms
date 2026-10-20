#!/bin/sh
# Twsiat price bridge on this server: MT5 in Docker (Wine), opened in the browser at https://mt5.twsiat.com
# Run with:  ssh -t root@SERVER "curl -fsSL https://raw.githubusercontent.com/MorissSarkis/twsiat-rooms/main/deploy/bridge-install.sh | sh"
set -e
cd /opt/twsiat-rooms && git pull --ff-only
cd deploy
if ! grep -q '^MT5_PASSWORD=' .env 2>/dev/null; then
  echo "Choose a password for the MT5 browser screen (user: trader). It will not be shown:"
  stty -echo < /dev/tty; read PW < /dev/tty; stty echo < /dev/tty; echo
  [ ${#PW} -ge 8 ] || { echo "Password must be at least 8 characters"; exit 1; }
  printf 'COMPOSE_PROFILES=bridge\nMT5_USER=trader\nMT5_PASSWORD=%s\n' "$PW" > .env
  chmod 600 .env
fi
mkdir -p /opt/mt5
docker compose up -d --build
echo "Waiting for MetaTrader 5 to install inside the container (first time 5-10 minutes)..."
docker compose restart caddy >/dev/null 2>&1 || true
findexp() { docker compose exec -T mt5 sh -c "find / \( -path /proc -o -path /sys \) -prune -o -type d -path '*MQL5/Experts' -print 2>/dev/null | head -1"; }
i=0; EXP=$(findexp); while [ -z "$EXP" ] && [ $i -lt 30 ]; do sleep 10; i=$((i+1)); EXP=$(findexp); done
if [ -n "$EXP" ]; then
  docker compose cp /opt/twsiat-rooms/mt5/TwsiatPriceBridge.mq5 "mt5:$EXP/TwsiatPriceBridge.mq5"
  docker compose exec -T mt5 sh -c "chown \$(stat -c %u:%g '$EXP') '$EXP/TwsiatPriceBridge.mq5'" || true
  echo "Bridge code copied into: $EXP"
else
  echo "Could not find the MT5 Experts folder yet. Open https://mt5.twsiat.com once, then run this script again."
fi
docker compose ps
echo "Done. Open https://mt5.twsiat.com (user: trader + your password)."
