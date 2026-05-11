#!/bin/bash
# Снять туннель на УДАЛЁННОЙ машине через SSH
set -e
: "${NAME:?NAME required}"

systemctl stop "awg-peer-${NAME}.service" 2>/dev/null || true
systemctl disable "awg-peer-${NAME}.service" 2>/dev/null || true
rm -f "/etc/systemd/system/awg-peer-${NAME}.service"
systemctl daemon-reload 2>/dev/null || true

ip link del "$NAME" 2>/dev/null || true

echo "[remote:$NAME] удалено"
