#!/bin/bash
# ============================================
# Поднятие туннеля на УДАЛЁННОЙ машине (через SSH)
# Принимает параметры через env:
#   NAME, TYPE, LOCAL_IP (RU VM), REMOTE_IP (this VM),
#   TUN_LOCAL (RU side), TUN_REMOTE (this side), TUN_PREFIX
#
# Note: с этой стороны "local" в командах ip — это REMOTE_IP параметра
# (т.е. этой машины), "remote" — это LOCAL_IP (другая сторона).
# ============================================
set -e

: "${NAME:?NAME required}"
: "${TYPE:?TYPE required}"
: "${LOCAL_IP:?LOCAL_IP required}"
: "${REMOTE_IP:?REMOTE_IP required}"
: "${TUN_LOCAL:?TUN_LOCAL required}"
: "${TUN_REMOTE:?TUN_REMOTE required}"
: "${TUN_PREFIX:=30}"

echo "[remote:$NAME] поднимаю $TYPE-туннель"
echo "[remote:$NAME]   This VM ($REMOTE_IP) tunnel-ip $TUN_REMOTE"
echo "[remote:$NAME]   Peer    ($LOCAL_IP)  tunnel-ip $TUN_LOCAL"

# Пакеты
if ! command -v ip >/dev/null 2>&1 || ! command -v iptables >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq iproute2 iptables >/dev/null 2>&1
fi

# Forwarding (пригодится потом, не мешает сейчас)
sysctl -q -w net.ipv4.ip_forward=1
grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf

# Модуль
case "$TYPE" in
  ipip) modprobe ipip 2>/dev/null || true
        grep -q '^ipip$' /etc/modules 2>/dev/null || echo 'ipip' >> /etc/modules ;;
  gre)  modprobe ip_gre 2>/dev/null || true
        grep -q '^ip_gre$' /etc/modules 2>/dev/null || echo 'ip_gre' >> /etc/modules ;;
  *)    echo "[remote:$NAME] неподдерживаемый TYPE: $TYPE"; exit 1 ;;
esac

# Снести старое
ip link del "$NAME" 2>/dev/null || true

# Создать
case "$TYPE" in
  ipip) ip tunnel add "$NAME" mode ipip remote "$LOCAL_IP" local "$REMOTE_IP" ttl 255 ;;
  gre)  ip tunnel add "$NAME" mode gre  remote "$LOCAL_IP" local "$REMOTE_IP" ttl 255 ;;
esac

ip addr add "${TUN_REMOTE}/${TUN_PREFIX}" dev "$NAME"
ip link set "$NAME" up mtu 1450
ip route replace "${TUN_LOCAL}/32" dev "$NAME" 2>/dev/null || true

echo "[remote:$NAME] $NAME up"

# systemd unit для автозапуска
SVC="/etc/systemd/system/awg-peer-${NAME}.service"
cat > "$SVC" << SVCEOF
[Unit]
Description=AWG peer tunnel ${NAME} (${TYPE}) to ${LOCAL_IP}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'modprobe ${TYPE/gre/ip_gre} 2>/dev/null; \\
  ip link del ${NAME} 2>/dev/null; \\
  ip tunnel add ${NAME} mode ${TYPE} remote ${LOCAL_IP} local ${REMOTE_IP} ttl 255 && \\
  ip addr add ${TUN_REMOTE}/${TUN_PREFIX} dev ${NAME} && \\
  ip link set ${NAME} up mtu 1450 && \\
  ip route replace ${TUN_LOCAL}/32 dev ${NAME}'
ExecStop=/bin/bash -c 'ip link del ${NAME} 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable "awg-peer-${NAME}.service" >/dev/null 2>&1 || true
echo "[remote:$NAME] systemd unit: $SVC (enabled)"
echo "[remote:$NAME] готово"
