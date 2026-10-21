#!/bin/sh
# Stop and remove the MT5-on-Linux container (MetaTrader refuses to run under Wine on this server).
set -e
cd /opt/twsiat-rooms/deploy
docker compose --profile bridge rm -sf mt5 || true
sed -i '/^COMPOSE_PROFILES=/d' .env 2>/dev/null || true
rm -rf /opt/mt5
docker image rm deploy-mt5 gmag11/metatrader5_vnc:1.1 gmag11/metatrader5_vnc:latest 2>/dev/null || true
docker compose ps
echo "MT5 container removed. The site keeps running."
