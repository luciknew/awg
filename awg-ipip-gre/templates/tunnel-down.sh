#!/bin/bash
# Опускание туннеля. Вызывается systemd при stop.

NAME="$1"
[ -z "$NAME" ] && echo "usage: $0 <tunnel-name>" && exit 1

# Чистим MSS clamping (по комментарию)
IPT_MSS_COMMENT="awg-tunnel-mss-${NAME}"
while iptables -t mangle -L FORWARD -n --line-numbers 2>/dev/null | grep -q "$IPT_MSS_COMMENT"; do
  n=$(iptables -t mangle -L FORWARD -n --line-numbers | grep "$IPT_MSS_COMMENT" | head -1 | awk '{print $1}')
  iptables -t mangle -D FORWARD "$n" 2>/dev/null || break
done

echo "[tunnel-down:$NAME] удаляю интерфейс"
ip link del "$NAME" 2>/dev/null || true
exit 0
