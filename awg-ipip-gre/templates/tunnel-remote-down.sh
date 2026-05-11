#!/bin/bash
# Снять туннель и iptables-правила на УДАЛЁННОЙ машине
set -e
: "${NAME:?NAME required}"

IPT_COMMENT="awg-peer-${NAME}"

systemctl stop "awg-peer-${NAME}.service" 2>/dev/null || true
systemctl disable "awg-peer-${NAME}.service" 2>/dev/null || true
rm -f "/etc/systemd/system/awg-peer-${NAME}.service"
systemctl daemon-reload 2>/dev/null || true

# Снять iptables-правила (по комментарию)
while iptables -t nat -L POSTROUTING -n --line-numbers 2>/dev/null | grep -q "$IPT_COMMENT"; do
  n=$(iptables -t nat -L POSTROUTING -n --line-numbers | grep "$IPT_COMMENT" | head -1 | awk '{print $1}')
  iptables -t nat -D POSTROUTING "$n" 2>/dev/null || break
done
while iptables -L FORWARD -n --line-numbers 2>/dev/null | grep -q "$IPT_COMMENT"; do
  n=$(iptables -L FORWARD -n --line-numbers | grep "$IPT_COMMENT" | head -1 | awk '{print $1}')
  iptables -D FORWARD "$n" 2>/dev/null || break
done

ip link del "$NAME" 2>/dev/null || true

if command -v netfilter-persistent >/dev/null 2>&1; then
  netfilter-persistent save >/dev/null 2>&1 || true
fi

echo "[remote:$NAME] удалено"
