#!/bin/bash
# ============================================
# Поднятие туннеля на УДАЛЁННОЙ машине (через SSH).
# Принимает env: NAME, TYPE, LOCAL_IP (RU VM), REMOTE_IP (this VM),
#   TUN_LOCAL (RU side), TUN_REMOTE (this side), TUN_PREFIX
#
# Делает:
#   1. ip forwarding включён
#   2. модуль ipip/gre загружен и в /etc/modules
#   3. сам туннельный интерфейс поднят
#   4. NAT для трафика приходящего ИЗ туннеля → MASQUERADE на eth0
#      (на основе входного интерфейса = туннель — безопасно, активируется
#      только когда туннель используется как exit-node для AWG)
#   5. FORWARD: туннель ↔ внешний интерфейс
#   6. systemd unit awg-peer-<name>.service для автозапуска (включая правила)
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

# ip forwarding
sysctl -q -w net.ipv4.ip_forward=1
grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf

# Модуль
MODULE=""
case "$TYPE" in
  ipip) MODULE="ipip" ;;
  gre)  MODULE="ip_gre" ;;
  *) echo "[remote:$NAME] неподдерживаемый TYPE: $TYPE"; exit 1 ;;
esac
modprobe "$MODULE" 2>/dev/null || true
grep -q "^${MODULE}\$" /etc/modules 2>/dev/null || echo "$MODULE" >> /etc/modules

# Снести старое, создать туннель
ip link del "$NAME" 2>/dev/null || true
case "$TYPE" in
  ipip) ip tunnel add "$NAME" mode ipip remote "$LOCAL_IP" local "$REMOTE_IP" ttl 255 ;;
  gre)  ip tunnel add "$NAME" mode gre  remote "$LOCAL_IP" local "$REMOTE_IP" ttl 255 ;;
esac
ip addr add "${TUN_REMOTE}/${TUN_PREFIX}" dev "$NAME"
ip link set "$NAME" up mtu 1450
ip route replace "${TUN_LOCAL}/32" dev "$NAME" 2>/dev/null || true
echo "[remote:$NAME] $NAME up"

# Внешний интерфейс
EXT_IFACE=$(ip route show default | awk '/default/ {print $5; exit}')
if [ -z "$EXT_IFACE" ]; then
  echo "[remote:$NAME] ОШИБКА: не удалось определить внешний интерфейс"
  exit 1
fi
echo "[remote:$NAME] внешний интерфейс: $EXT_IFACE"

# NAT/FORWARD для трафика идущего ИЗ туннеля на eth0
# Эти правила безопасны даже если туннель сейчас не используется как exit:
# пакеты в туннель просто не приходят, MASQUERADE не срабатывает.
IPT_COMMENT="awg-peer-${NAME}"

# Сначала чистим старые правила (по комментарию) — идемпотентность
while iptables -t nat -L POSTROUTING -n --line-numbers 2>/dev/null | grep -q "$IPT_COMMENT"; do
  num=$(iptables -t nat -L POSTROUTING -n --line-numbers | grep "$IPT_COMMENT" | head -1 | awk '{print $1}')
  iptables -t nat -D POSTROUTING "$num" 2>/dev/null || break
done
while iptables -L FORWARD -n --line-numbers 2>/dev/null | grep -q "$IPT_COMMENT"; do
  num=$(iptables -L FORWARD -n --line-numbers | grep "$IPT_COMMENT" | head -1 | awk '{print $1}')
  iptables -D FORWARD "$num" 2>/dev/null || break
done

# MASQUERADE: всё что идёт из туннеля на eth0 — замаскарадить на наш public IP
iptables -t nat -A POSTROUTING -i "$NAME" -o "$EXT_IFACE" -j MASQUERADE -m comment --comment "$IPT_COMMENT" 2>/dev/null \
  || iptables -t nat -A POSTROUTING -o "$EXT_IFACE" -s "${TUN_LOCAL}/32" -j MASQUERADE -m comment --comment "$IPT_COMMENT"
# Note: nf_tables в современном ядре не поддерживает -i в POSTROUTING. Если -i не сработал,
#       используем fallback по source (только для самого peer-IP — это меньше, но работает).

# FORWARD правила
iptables -A FORWARD -i "$NAME" -o "$EXT_IFACE" -j ACCEPT -m comment --comment "$IPT_COMMENT"
iptables -A FORWARD -i "$EXT_IFACE" -o "$NAME" -m state --state RELATED,ESTABLISHED -j ACCEPT -m comment --comment "$IPT_COMMENT"

if command -v netfilter-persistent >/dev/null 2>&1; then
  netfilter-persistent save >/dev/null 2>&1 || true
fi

echo "[remote:$NAME] iptables: MASQUERADE + FORWARD настроены"

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
ExecStart=/bin/bash -c 'modprobe ${MODULE} 2>/dev/null; \\
  ip link del ${NAME} 2>/dev/null; \\
  ip tunnel add ${NAME} mode ${TYPE} remote ${LOCAL_IP} local ${REMOTE_IP} ttl 255 && \\
  ip addr add ${TUN_REMOTE}/${TUN_PREFIX} dev ${NAME} && \\
  ip link set ${NAME} up mtu 1450 && \\
  ip route replace ${TUN_LOCAL}/32 dev ${NAME} && \\
  EXT=\$(ip route show default | awk "/default/ {print \\\$5; exit}") && \\
  ( iptables -t nat -C POSTROUTING -i ${NAME} -o \$EXT -j MASQUERADE -m comment --comment "${IPT_COMMENT}" 2>/dev/null \\
    || iptables -t nat -A POSTROUTING -i ${NAME} -o \$EXT -j MASQUERADE -m comment --comment "${IPT_COMMENT}" 2>/dev/null \\
    || iptables -t nat -A POSTROUTING -o \$EXT -s ${TUN_LOCAL}/32 -j MASQUERADE -m comment --comment "${IPT_COMMENT}" ) && \\
  ( iptables -C FORWARD -i ${NAME} -o \$EXT -j ACCEPT 2>/dev/null \\
    || iptables -A FORWARD -i ${NAME} -o \$EXT -j ACCEPT -m comment --comment "${IPT_COMMENT}" ) && \\
  ( iptables -C FORWARD -i \$EXT -o ${NAME} -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \\
    || iptables -A FORWARD -i \$EXT -o ${NAME} -m state --state RELATED,ESTABLISHED -j ACCEPT -m comment --comment "${IPT_COMMENT}" )'
ExecStop=/bin/bash -c 'ip link del ${NAME} 2>/dev/null; \\
  while iptables -t nat -L POSTROUTING -n --line-numbers 2>/dev/null | grep -q "${IPT_COMMENT}"; do \\
    n=\$(iptables -t nat -L POSTROUTING -n --line-numbers | grep "${IPT_COMMENT}" | head -1 | awk "{print \\\$1}"); \\
    iptables -t nat -D POSTROUTING \$n 2>/dev/null || break; \\
  done; \\
  while iptables -L FORWARD -n --line-numbers 2>/dev/null | grep -q "${IPT_COMMENT}"; do \\
    n=\$(iptables -L FORWARD -n --line-numbers | grep "${IPT_COMMENT}" | head -1 | awk "{print \\\$1}"); \\
    iptables -D FORWARD \$n 2>/dev/null || break; \\
  done; \\
  true'

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable "awg-peer-${NAME}.service" >/dev/null 2>&1 || true
echo "[remote:$NAME] systemd unit: $SVC (enabled)"
echo "[remote:$NAME] готово"
