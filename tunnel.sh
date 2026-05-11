#!/bin/bash
# ============================================
# AWG tunnels manager — IPIP/GRE туннели к удалённым машинам
#
# После установки скрипт копируется в /usr/local/sbin/awg-tunnel.
# Конфиги туннелей: /etc/awg-tunnels/<name>.env
# Дефолтный туннель: /etc/awg-tunnels/default (содержит имя)
#
# Команды:
#   awg-tunnel list             — список + статус
#   awg-tunnel add              — интерактивно создать новый
#   awg-tunnel remove <name>    — удалить
#   awg-tunnel edit <name>      — изменить параметры
#   awg-tunnel test <name>      — проверить ping
#   awg-tunnel default          — выбрать дефолтный (для будущей маршрутизации)
# ============================================
set -e

if [ "$EUID" -ne 0 ]; then
  echo "Запусти от root: sudo $0 $*"
  exit 1
fi

TUNNELS_DIR="/etc/awg-tunnels"
DEFAULT_FILE="${TUNNELS_DIR}/default"
APPLY_DEFAULT="/usr/local/sbin/awg-tunnel-apply-default"
# Запасной путь — если запускаем из репо
[ -x "$APPLY_DEFAULT" ] || APPLY_DEFAULT="$(dirname "$0")/templates/apply-default.sh"

# Применить policy routing (вызов apply-default)
apply_default_routing() {
  if [ -x "$APPLY_DEFAULT" ]; then
    "$APPLY_DEFAULT"
  else
    bash "$APPLY_DEFAULT" 2>/dev/null || warn "apply-default не найден"
  fi
}

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1" >&2; }
header(){ echo -e "\n${BLUE}── $1 ──${NC}"; }

mkdir -p "$TUNNELS_DIR"
chmod 700 "$TUNNELS_DIR"

# -------------------------------------------------
# Утилиты
# -------------------------------------------------

# Проверка SSH-инструментов
ensure_sshpass() {
  command -v sshpass >/dev/null 2>&1 && return
  info "Устанавливаю sshpass..."
  apt-get install -y -qq sshpass >/dev/null 2>&1
}

# Список имён туннелей
list_names() {
  local f
  for f in "$TUNNELS_DIR"/*.env; do
    [ -f "$f" ] || continue
    basename "$f" .env
  done
}

# Текущий дефолтный туннель (имя или пусто)
current_default() {
  [ -f "$DEFAULT_FILE" ] && cat "$DEFAULT_FILE" || echo ""
}

# Статус туннеля (up/down)
tun_status() {
  local name="$1"
  ip link show "$name" 2>/dev/null | grep -q "state UP\|state UNKNOWN" && echo "up" || echo "down"
}

# Валидация имени туннеля (разрешено для имени интерфейса Linux)
# IFNAMSIZ=16 (с null) → максимум 15 символов
# Первый символ — буква, дальше буквы/цифры/_/-
valid_name() {
  local n="$1"
  if [ -z "$n" ]; then
    echo "пусто"; return 1
  fi
  if [ "${#n}" -gt 15 ]; then
    echo "слишком длинное (${#n}, максимум 15 — ограничение Linux)"
    return 1
  fi
  if [[ ! "$n" =~ ^[a-zA-Z] ]]; then
    echo "должно начинаться с буквы"; return 1
  fi
  if [[ ! "$n" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "разрешены только буквы, цифры, '-' и '_'"; return 1
  fi
  return 0
}

# Конвертация IP в число
ip2int() {
  local IFS=. ip
  read -ra ip <<< "$1"
  echo $(( (ip[0] << 24) + (ip[1] << 16) + (ip[2] << 8) + ip[3] ))
}

# Конвертация числа в IP
int2ip() {
  local n=$1
  echo "$(( (n >> 24) & 255 )).$(( (n >> 16) & 255 )).$(( (n >> 8) & 255 )).$(( n & 255 ))"
}

# Проверка валидной /30 сети + расчёт host адресов
# Принимает: "10.200.0.0/30"
# Выводит: "TUN_LOCAL TUN_REMOTE" (меньший .1, больший .2)
parse_30() {
  local net="$1"
  if ! [[ "$net" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/30$ ]]; then
    return 1
  fi
  local base="${BASH_REMATCH[1]}"
  local base_int
  base_int=$(ip2int "$base")
  # /30: 4 адреса, base должна быть выровнена (base & 0x03 == 0)
  if [ $(( base_int & 0x3 )) -ne 0 ]; then
    return 2
  fi
  local low high
  low=$(int2ip $(( base_int + 1 )))
  high=$(int2ip $(( base_int + 2 )))
  echo "$low $high"
}

# Проверка что подсеть не пересекается с уже существующими туннелями
subnet_conflict() {
  local check_net="$1"  # base int
  local n f base
  for f in "$TUNNELS_DIR"/*.env; do
    [ -f "$f" ] || continue
    (
      source "$f"
      [ -n "$TUN_NETWORK" ] || exit 0
      if [[ "$TUN_NETWORK" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/30$ ]]; then
        existing=$(ip2int "${BASH_REMATCH[1]}")
        # /30 ↔ /30: пересекаются если base совпадает
        if [ "$existing" -eq "$check_net" ]; then
          echo "CONFLICT:$(basename "$f" .env)"
        fi
      fi
    )
  done
}

# Получить публичный IPv4 этой машины
# Приоритет:
#   1. WG_HOST из /etc/amnezia-wg-easy/env (то что юзер указал при install.sh)
#      — если домен, резолвим в IPv4; если IPv4 — берём как есть; IPv6 — пропускаем
#   2. curl ifconfig.me -4
#   3. локальный IP с дефолтного интерфейса
my_public_ip() {
  local wg_env="/etc/amnezia-wg-easy/env"
  if [ -f "$wg_env" ]; then
    local wh
    wh=$(grep -E '^WG_HOST=' "$wg_env" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' | tr -d "'")
    if [ -n "$wh" ]; then
      # Если это IPv4 — вернуть как есть
      if [[ "$wh" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$wh"; return
      fi
      # Если IPv6 — игнор, идём дальше
      if [[ "$wh" == *:* ]]; then :
      else
        # Иначе считаем что это домен — резолвим в IPv4
        local resolved
        resolved=$(getent ahostsv4 "$wh" 2>/dev/null | awk '{print $1; exit}')
        if [ -n "$resolved" ]; then
          echo "$resolved"; return
        fi
      fi
    fi
  fi

  curl -4 -s --max-time 3 https://ifconfig.me 2>/dev/null \
    || curl -4 -s --max-time 3 https://api.ipify.org 2>/dev/null \
    || ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}'
}

# SSH wrapper (sshpass + порт)
ssh_run() {
  local user="$1" host="$2" port="$3" pass="$4"
  shift 4
  sshpass -p "$pass" ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o PubkeyAuthentication=no \
    -o PreferredAuthentications=password \
    -o ConnectTimeout=10 \
    -o ServerAliveInterval=5 \
    -o ServerAliveCountMax=3 \
    -p "$port" \
    "${user}@${host}" "$@"
}

# Передать env + скрипт на remote и выполнить
ssh_apply_remote_up() {
  local env_file="$1"
  source "$env_file"

  local remote_up_path="/usr/local/sbin/awg-tunnel-remote-up.sh"
  [ -f "$remote_up_path" ] || remote_up_path="$(dirname "$0")/templates/tunnel-remote-up.sh"

  if [ ! -f "$remote_up_path" ]; then
    error "Не найден remote-up скрипт (искал /usr/local/sbin/awg-tunnel-remote-up.sh)"
    return 1
  fi

  sshpass -p "$REMOTE_PASS" ssh \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o PubkeyAuthentication=no -o PreferredAuthentications=password \
    -o ConnectTimeout=10 -p "$REMOTE_PORT" \
    -T "${REMOTE_USER}@${REMOTE_IP}" \
    "NAME='${NAME}' TYPE='${TYPE}' LOCAL_IP='${LOCAL_IP}' REMOTE_IP='${REMOTE_IP}' TUN_LOCAL='${TUN_LOCAL}' TUN_REMOTE='${TUN_REMOTE}' TUN_PREFIX='${TUN_PREFIX}' bash -s" \
    < "$remote_up_path"
}

# Интерактивный выбор туннеля из списка по номеру.
# Эхо в stderr (чтобы не попало в stdout), на stdout — выбранное имя.
# Если туннелей нет — вернёт 1.
pick_tunnel() {
  local prompt="${1:-Выбери туннель}"
  local names
  names=$(list_names)
  if [ -z "$names" ]; then
    error "Туннелей нет — используй: $0 add"
    return 1
  fi

  echo "$prompt:" >&2
  local i=0
  local -a name_arr=()
  while IFS= read -r n; do
    [ -z "$n" ] && continue
    i=$((i + 1))
    name_arr+=("$n")
    local mark=""
    [ "$n" = "$(current_default)" ] && mark="(default)"
    echo "  $i) $n $mark" >&2
  done <<< "$names"
  echo >&2

  local num
  read -rp "Номер [1]: " num </dev/tty >&2
  num="${num:-1}"
  if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "${#name_arr[@]}" ]; then
    error "Неверный номер"
    return 1
  fi
  echo "${name_arr[$((num - 1))]}"
}

ssh_apply_remote_down() {
  local env_file="$1"
  source "$env_file"

  local remote_down_path="/usr/local/sbin/awg-tunnel-remote-down.sh"
  [ -f "$remote_down_path" ] || remote_down_path="$(dirname "$0")/templates/tunnel-remote-down.sh"

  if [ ! -f "$remote_down_path" ]; then
    warn "Не найден remote-down скрипт, пропускаю удаление на remote"
    return 0
  fi

  sshpass -p "$REMOTE_PASS" ssh \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o PubkeyAuthentication=no -o PreferredAuthentications=password \
    -o ConnectTimeout=10 -p "$REMOTE_PORT" \
    -T "${REMOTE_USER}@${REMOTE_IP}" \
    "NAME='${NAME}' bash -s" \
    < "$remote_down_path" || warn "Удаление на remote не удалось (возможно недоступен)"
}

# -------------------------------------------------
# Команды
# -------------------------------------------------

cmd_list() {
  local def
  def=$(current_default)

  local names
  names=$(list_names)
  if [ -z "$names" ]; then
    echo "Туннелей нет."
    echo "Создай: $0 add"
    return 0
  fi

  printf "%-3s %-15s %-6s %-16s %-16s %-18s %-8s %s\n" "#" "NAME" "TYPE" "LOCAL" "REMOTE" "SUBNET" "STATUS" "DEFAULT"
  printf "%-3s %-15s %-6s %-16s %-16s %-18s %-8s %s\n" "---" "---------------" "------" "----------------" "----------------" "------------------" "--------" "-------"

  local i=0
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    i=$((i + 1))
    (
      source "$TUNNELS_DIR/${name}.env"
      local status
      status=$(tun_status "$name")
      local mark=""
      [ "$name" = "$def" ] && mark="*"
      printf "%-3s %-15s %-6s %-16s %-16s %-18s %-8s %s\n" \
        "$i" "$name" "$TYPE" "$LOCAL_IP" "$REMOTE_IP" "$TUN_NETWORK" "$status" "$mark"
    )
  done <<< "$names"
}

cmd_add() {
  ensure_sshpass

  # 1. Имя
  local name reason
  while true; do
    read -rp "Имя туннеля (буквы/цифры/-/_; до 15 символов, начало — буква): " name
    if ! reason=$(valid_name "$name"); then
      warn "Некорректное имя: $reason"
      continue
    fi
    if [ -f "${TUNNELS_DIR}/${name}.env" ]; then
      warn "Туннель '$name' уже существует"
      continue
    fi
    if ip link show "$name" >/dev/null 2>&1; then
      warn "В системе уже есть интерфейс '$name'"
      continue
    fi
    break
  done

  # 2. Тип
  local type type_num
  echo "Тип туннеля:"
  echo "  1) ipip"
  echo "  2) gre"
  while true; do
    read -rp "Выбор [1]: " type_num
    type_num="${type_num:-1}"
    case "$type_num" in
      1) type="ipip"; break ;;
      2) type="gre";  break ;;
      *) warn "Введи 1 или 2" ;;
    esac
  done
  info "Тип: $type"

  # 3. Адрес удалённой машины
  local remote_ip
  while true; do
    read -rp "IP/домен удалённой машины: " remote_ip
    [ -n "$remote_ip" ] && break
    warn "Адрес обязателен"
  done

  # 4. SSH параметры
  local remote_port remote_user remote_pass
  read -rp "SSH порт [22]: " remote_port
  remote_port="${remote_port:-22}"
  read -rp "SSH логин [root]: " remote_user
  remote_user="${remote_user:-root}"
  read -rsp "SSH пароль: " remote_pass; echo

  # 5. Проверка SSH
  info "Проверяю SSH..."
  if ! ssh_run "$remote_user" "$remote_ip" "$remote_port" "$remote_pass" "echo ok" 2>&1 | grep -q ok; then
    error "SSH не работает (проверь логин/пароль/порт)"
    return 1
  fi
  info "SSH работает"

  # 6. Локальный публичный IP — автоопределение
  local local_ip
  local_ip=$(my_public_ip)
  if [ -z "$local_ip" ]; then
    error "Не удалось определить публичный IPv4 этой машины"
    read -rp "Введи вручную: " local_ip
    [ -z "$local_ip" ] && return 1
  else
    info "Публичный IPv4 этой машины: $local_ip"
  fi

  # 7. Подсеть /30
  local tun_net tun_local tun_remote
  while true; do
    read -rp "Подсеть туннеля /30 (например 10.200.0.0/30): " tun_net
    local parsed
    parsed=$(parse_30 "$tun_net") || {
      case $? in
        1) warn "Формат: A.B.C.D/30" ;;
        2) warn "Сеть невыровнена. /30 базы должны быть кратны 4: .0, .4, .8, .12, ..." ;;
      esac
      continue
    }
    tun_local=$(echo "$parsed" | awk '{print $1}')
    tun_remote=$(echo "$parsed" | awk '{print $2}')

    # Проверка конфликта
    local base_int
    base_int=$(ip2int "${tun_net%/30}")
    local conflicts
    conflicts=$(subnet_conflict "$base_int")
    if [ -n "$conflicts" ]; then
      warn "Подсеть уже используется: $conflicts"
      continue
    fi
    break
  done

  info "Туннель ${tun_local} (RU) <-> ${tun_remote} (remote)"

  # 8. Сохраняем env
  local env_file="${TUNNELS_DIR}/${name}.env"
  cat > "$env_file" << EOF
# Автогенерация $(date)
NAME="${name}"
TYPE="${type}"
LOCAL_IP="${local_ip}"
REMOTE_IP="${remote_ip}"
REMOTE_PORT="${remote_port}"
REMOTE_USER="${remote_user}"
REMOTE_PASS="${remote_pass}"
TUN_NETWORK="${tun_net}"
TUN_LOCAL="${tun_local}"
TUN_REMOTE="${tun_remote}"
TUN_PREFIX="30"
EOF
  chmod 600 "$env_file"
  info "Конфиг: $env_file"

  # 9. Удалённая сторона
  header "Настройка удалённой машины ($remote_ip)"
  if ! ssh_apply_remote_up "$env_file"; then
    error "Не удалось настроить remote"
    rm -f "$env_file"
    return 1
  fi

  # 10. Локально — systemd
  header "systemd на этой машине"
  systemctl daemon-reload
  systemctl enable --now "awg-tunnel@${name}.service"
  sleep 1

  # 11. Проверка
  header "Проверка"
  if ping -c 2 -W 3 "$tun_remote" >/dev/null 2>&1; then
    info "✓ ping $tun_remote — работает"
  else
    warn "Ping $tun_remote не проходит. Возможно провайдер режет protocol $type."
    warn "Логи: journalctl -u awg-tunnel@${name} -n 20 --no-pager"
  fi

  # 12. Дефолт если первый туннель — применяем routing
  if [ -z "$(current_default)" ]; then
    echo "$name" > "$DEFAULT_FILE"
    info "Установлен как дефолтный туннель — применяю routing..."
    apply_default_routing
  fi

  echo
  info "Туннель '$name' добавлен"
}

cmd_remove() {
  local name="$1"
  if [ -z "$name" ]; then
    name=$(pick_tunnel "Какой туннель удалить") || return 1
  fi

  local env_file="${TUNNELS_DIR}/${name}.env"
  [ ! -f "$env_file" ] && error "Туннель '$name' не найден" && return 1

  read -rp "Удалить туннель '$name'? [y/N]: " conf
  [[ ! "$conf" =~ ^[Yy]$ ]] && echo "Отмена" && return 0

  # Local cleanup
  systemctl disable --now "awg-tunnel@${name}.service" 2>/dev/null || true
  ip link del "$name" 2>/dev/null || true

  # Remote cleanup
  header "Удаляю на remote"
  ensure_sshpass
  ssh_apply_remote_down "$env_file"

  # Если был дефолтным — сбросить + переприменить routing (теперь без дефолта)
  if [ "$(current_default)" = "$name" ]; then
    rm -f "$DEFAULT_FILE"
    warn "Дефолтный туннель сброшен (был '$name')"
    apply_default_routing
  fi

  rm -f "$env_file"
  info "Туннель '$name' удалён"
}

cmd_edit() {
  local name="$1"
  if [ -z "$name" ]; then
    name=$(pick_tunnel "Какой туннель редактировать") || return 1
  fi

  local env_file="${TUNNELS_DIR}/${name}.env"
  [ ! -f "$env_file" ] && error "Туннель '$name' не найден" && return 1

  echo "Редактирование выполняется как пересоздание (remove → add)."
  echo "Если хочешь только поменять пароль/порт SSH — отредактируй $env_file вручную и перезапусти:"
  echo "  systemctl restart awg-tunnel@${name}"
  echo
  read -rp "Пересоздать туннель '$name'? [y/N]: " conf
  [[ ! "$conf" =~ ^[Yy]$ ]] && echo "Отмена" && return 0

  cmd_remove "$name" <<< "y"
  cmd_add
}

cmd_test() {
  local name="$1"
  if [ -z "$name" ]; then
    name=$(pick_tunnel "Какой туннель проверить") || return 1
  fi

  local env_file="${TUNNELS_DIR}/${name}.env"
  [ ! -f "$env_file" ] && error "Туннель '$name' не найден" && return 1

  source "$env_file"

  echo "Туннель: $name ($TYPE)"
  echo "  $TUN_LOCAL → $TUN_REMOTE"
  echo
  echo "Локальный интерфейс:"
  ip -br addr show "$name" 2>&1 || echo "  (нет интерфейса)"
  echo
  echo "Ping $TUN_REMOTE:"
  ping -c 4 -W 2 "$TUN_REMOTE" || true
}

cmd_default() {
  local names
  names=$(list_names)
  if [ -z "$names" ]; then
    error "Туннелей нет"
    return 1
  fi

  # Своя версия выбора с опцией "0 = убрать дефолт"
  echo "Выбери дефолтный туннель (через него потом будет уходить трафик):"
  local i=0
  local -a name_arr=()
  while IFS= read -r n; do
    [ -z "$n" ] && continue
    i=$((i + 1))
    name_arr+=("$n")
    local mark=""
    [ "$n" = "$(current_default)" ] && mark="(текущий)"
    echo "  $i) $n $mark"
  done <<< "$names"
  echo "  0) убрать дефолт"
  echo

  local num
  read -rp "Номер: " num
  if [ "$num" = "0" ]; then
    rm -f "$DEFAULT_FILE"
    info "Дефолт сброшен — применяю routing..."
    apply_default_routing
    return 0
  fi
  if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "${#name_arr[@]}" ]; then
    error "Неверный номер"
    return 1
  fi

  local chosen="${name_arr[$((num - 1))]}"
  echo "$chosen" > "$DEFAULT_FILE"
  info "Дефолтный туннель: $chosen — применяю routing..."
  apply_default_routing
}

# -------------------------------------------------
# Main
# -------------------------------------------------
case "${1:-}" in
  list|ls)    cmd_list ;;
  add|new)    cmd_add ;;
  remove|rm|del) shift; cmd_remove "$@" ;;
  edit|mod)   shift; cmd_edit "$@" ;;
  test|ping)  shift; cmd_test "$@" ;;
  default|def) cmd_default ;;
  ""|help|-h|--help)
    cat << HELP
AWG tunnels manager

  $0 list                — список туннелей и статус
  $0 add                 — интерактивно создать туннель
  $0 remove [<name>]     — удалить туннель (без имени — выбор по номеру)
  $0 edit   [<name>]     — пересоздать туннель (без имени — выбор по номеру)
  $0 test   [<name>]     — ping проверка   (без имени — выбор по номеру)
  $0 default             — выбрать дефолтный туннель

Конфиги: ${TUNNELS_DIR}/<name>.env
Дефолт:  ${DEFAULT_FILE}
HELP
    ;;
  *) error "неизвестная команда: $1"; exit 1 ;;
esac
