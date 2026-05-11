#!/bin/bash
# Опускание туннеля. Вызывается systemd при stop.

NAME="$1"
[ -z "$NAME" ] && echo "usage: $0 <tunnel-name>" && exit 1

echo "[tunnel-down:$NAME] удаляю интерфейс"
ip link del "$NAME" 2>/dev/null || true
exit 0
