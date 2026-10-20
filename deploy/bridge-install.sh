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
EXP="/opt/mt5/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Experts"
i=0; while [ ! -d "$EXP" ] && [ $i -lt 120 ]; do sleep 10; i=$((i+1)); done
if [ -d "$EXP" ]; then
  cp /opt/twsiat-rooms/mt5/TwsiatPriceBridge.mq5 "$EXP/"
  chown -R "$(stat -c %u:%g "$EXP")" "$EXP/TwsiatPriceBridge.mq5"
  echo "Bridge code copied into MT5 (Experts/TwsiatPriceBridge.mq5)."
else
  echo "MT5 is still installing. Run this script again in a few minutes to copy the bridge code."
fi
docker compose ps
echo "Done. Open https://mt5.twsiat.com (user: trader + your password)."
