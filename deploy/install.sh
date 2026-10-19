#!/bin/sh
# Twsiat Rooms — install / update on a fresh Ubuntu server (Hetzner). Run as root:
#   curl -fsSL https://raw.githubusercontent.com/MorissSarkis/twsiat-rooms/main/deploy/install.sh | sh
set -e
if ! command -v docker >/dev/null 2>&1; then curl -fsSL https://get.docker.com | sh; fi
if [ -d /opt/twsiat-rooms/.git ]; then
  git -C /opt/twsiat-rooms pull --ff-only
else
  apt-get update -y && apt-get install -y git
  git clone https://github.com/MorissSarkis/twsiat-rooms.git /opt/twsiat-rooms
fi
cd /opt/twsiat-rooms/deploy
docker compose up -d --build
docker compose ps
echo "Done. Open https://rooms.twsiat.com (DNS must point to this server)."
