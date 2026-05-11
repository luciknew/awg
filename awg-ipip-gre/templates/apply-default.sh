#!/bin/bash
# ============================================
# Применить policy routing: трафик WG-клиентов → дефолтный туннель
#
# Источники:
#   /etc/awg-tunnels/default        — имя дефолтного туннеля (или нет = сброс)
#   /etc/awg-tunnels/<name>.env     — параметры туннеля
#   /etc/amnezia-wg-easy/env        — WG_DEFAULT_ADDRESS (формат A.B.C.x)
#
# Что делает:
#   - снимает старые правила (по комментарию iptables 'awg-default-route')
#   - снимает старое ip rule с тэгом priority 100
#   - очищает таблицу awg-route (id 200)
#   - если есть дефолт:
#       * добавляет default через интерфейс туннеля в таблицу awg-route
#       * ip rule: from WG_SUBNET → awg-route (priority 100)
#       * MASQUERADE -s WG_SUBNET -o <tunnel> с комментарием
#       * flush conntrack для WG_SUBNET (чтобы сессии переустановились)
# ============================================
set -e

TUNNELS_DIR="/etc/awg-tunnels"
DEFAULT_FILE="${TUNNELS_DIR}/default"
WG_ENV="/etc/amnezia-wg-easy/env"

ROUTE_TABLE="awg-route"
ROUTE_TABLE_ID=200
RULE_PRIO=100
IPT_COMMENT="awg-default-route"

# --- определяем WG-подсеть ---
if [ ! -f "$WG_ENV" ]; then
  echo "[apply-default] $WG_ENV не найден — без AWG настройки нечего маршрутить"
  exit 1
fi
WG_DEFAULT_ADDRESS=$(grep -E '^WG_DEFAULT_ADDRESS=' "$WG_ENV" | tail -1 | cut -d= -f2- | tr -d '"' | tr -d "'")
if [[ "$WG_DEFAULT_ADDRESS" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.x$ ]]; then
  WG_SUBNET="${BASH_REMATCH[1]}.0/24"
else
  echo "[apply-default] не могу распарсить WG_DEFAULT_ADDRESS='$WG_DEFAULT_ADDRESS'"
  exit 1
fi
echo "[apply-default] WG_SUBNET=$WG_SUBNET"

# --- регистрируем таблицу маршрутизации если нет ---
if ! grep -qE "^${ROUTE_TABLE_ID}\s+${ROUTE_TABLE}\s*$" /etc/iproute2/rt_tables 2>/dev/null; then
  echo "${ROUTE_TABLE_ID} ${ROUTE_TABLE}" >> /etc/iproute2/rt_tables
fi

# --- cleanup старого ---
echo "[apply-default] cleanup..."

# ip rule (может быть несколько на разный source — снять всё с priority RULE_PRIO)
while ip rule list priority "$RULE_PRIO" 2>/dev/null | grep -q .; do
  ip rule del priority "$RULE_PRIO" 2>/dev/null || break
done

# таблица маршрутов
ip route flush table "$ROUTE_TABLE" 2>/dev/null || true

# iptables NAT — удалить все наши правила (по комментарию)
while iptables -t nat -L POSTROUTING -n --line-numbers 2>/dev/null | grep -q "$IPT_COMMENT"; do
  num=$(iptables -t nat -L POSTROUTING -n --line-numbers | grep "$IPT_COMMENT" | head -1 | awk '{print $1}')
  iptables -t nat -D POSTROUTING "$num" 2>/dev/null || break
done

# --- если дефолтного туннеля нет — на этом всё ---
if [ ! -s "$DEFAULT_FILE" ]; then
  echo "[apply-default] дефолтный туннель не задан — routing сброшен"
  exit 0
fi

DEFAULT_TUNNEL=$(cat "$DEFAULT_FILE")
ENV_FILE="${TUNNELS_DIR}/${DEFAULT_TUNNEL}.env"
if [ ! -f "$ENV_FILE" ]; then
  echo "[apply-default] $ENV_FILE не найден (битый default-файл)"
  rm -f "$DEFAULT_FILE"
  exit 1
fi
# shellcheck source=/dev/null
source "$ENV_FILE"
: "${NAME:?NAME not set in $ENV_FILE}"

# Проверяем что интерфейс туннеля поднят
if ! ip link show "$NAME" >/dev/null 2>&1; then
  echo "[apply-default] интерфейс $NAME не поднят, запускаю..."
  systemctl start "awg-tunnel@${NAME}.service" 2>/dev/null || true
  sleep 1
fi

echo "[apply-default] применяю: WG ($WG_SUBNET) → $NAME → $TUN_REMOTE"

# default route в нашей таблице
ip route add default via "$TUN_REMOTE" dev "$NAME" table "$ROUTE_TABLE"

# ip rule: трафик пришедший через wg0 → наша таблица
# (важно: НЕ "from $WG_SUBNET" — иначе ответы сервера со своего адреса
#  10.X.X.1 тоже улетят в туннель, и iperf3/SSH к 10.X.X.1 ломаются)
ip rule add iif wg0 table "$ROUTE_TABLE" priority "$RULE_PRIO"

# MASQUERADE для WG-трафика через туннель (с комментарием для идемпотентности)
iptables -t nat -A POSTROUTING -s "$WG_SUBNET" -o "$NAME" -j MASQUERADE -m comment --comment "$IPT_COMMENT"

# FORWARD: разрешаем (на случай если default DROP)
iptables -C FORWARD -i wg0 -o "$NAME" -j ACCEPT 2>/dev/null || iptables -A FORWARD -i wg0 -o "$NAME" -j ACCEPT
iptables -C FORWARD -i "$NAME" -o wg0 -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$NAME" -o wg0 -j ACCEPT

# flush conntrack чтобы старые соединения переустановились через новый путь
if command -v conntrack >/dev/null 2>&1; then
  conntrack -D -s "$WG_SUBNET" >/dev/null 2>&1 || true
fi

echo "[apply-default] OK — трафик $WG_SUBNET идёт через $NAME"
