#!/bin/bash
# ============================================
# Поднятие одного IPIP/GRE туннеля на хосте AWG
# Вызывается systemd-юнитом awg-tunnel-<name>.service
#
# Параметры читает из /etc/awg-tunnels/<name>.env
#   NAME, TYPE (ipip|gre), LOCAL_IP, REMOTE_IP, TUN_LOCAL, TUN_REMOTE, TUN_PREFIX
# ============================================
set -e

NAME="$1"
[ -z "$NAME" ] && echo "usage: $0 <tunnel-name>" && exit 1

ENV_FILE="/etc/awg-tunnels/${NAME}.env"
[ ! -f "$ENV_FILE" ] && echo "[tunnel-up:$NAME] $ENV_FILE не найден" && exit 1
source "$ENV_FILE"

: "${TYPE:?TYPE required}"
: "${LOCAL_IP:?LOCAL_IP required}"
: "${REMOTE_IP:?REMOTE_IP required}"
: "${TUN_LOCAL:?TUN_LOCAL required}"
: "${TUN_REMOTE:?TUN_REMOTE required}"
: "${TUN_PREFIX:=30}"

echo "[tunnel-up:$NAME] type=$TYPE local=$LOCAL_IP remote=$REMOTE_IP"
echo "[tunnel-up:$NAME] tunnel: $TUN_LOCAL <-> $TUN_REMOTE /$TUN_PREFIX"

# Загружаем модуль ядра
case "$TYPE" in
  ipip) modprobe ipip 2>/dev/null || true ;;
  gre)  modprobe ip_gre 2>/dev/null || true ;;
  *)    echo "[tunnel-up:$NAME] неподдерживаемый TYPE: $TYPE"; exit 1 ;;
esac

# Снести если уже есть
ip link del "$NAME" 2>/dev/null || true

# Создаём туннель
case "$TYPE" in
  ipip)
    ip tunnel add "$NAME" mode ipip remote "$REMOTE_IP" local "$LOCAL_IP" ttl 255
    ;;
  gre)
    ip tunnel add "$NAME" mode gre remote "$REMOTE_IP" local "$LOCAL_IP" ttl 255
    ;;
esac

ip addr add "${TUN_LOCAL}/${TUN_PREFIX}" dev "$NAME"
ip link set "$NAME" up mtu 1450

# Маршрут на peer
ip route replace "${TUN_REMOTE}/32" dev "$NAME" 2>/dev/null || true

echo "[tunnel-up:$NAME] $NAME up"

# Проверка связи (несколько попыток — модуль ядра / другая сторона может не сразу подняться)
for i in 1 2 3 4 5; do
  if ping -c 1 -W 2 "$TUN_REMOTE" >/dev/null 2>&1; then
    echo "[tunnel-up:$NAME] ✓ $TUN_REMOTE pingable"
    exit 0
  fi
  sleep 1
done
echo "[tunnel-up:$NAME] ⚠ $TUN_REMOTE пока не пингуется (проверь remote и провайдера: protocol $TYPE может быть заблокирован)"
exit 0
