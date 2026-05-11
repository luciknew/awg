#!/bin/bash
# ============================================
# AmneziaWG + web-UI установщик НА ХОСТ (без Docker)
# Поддержка: Ubuntu 22.04 / 24.04
#
# Что делает:
#   1. Ставит AmneziaWG (kernel module + tools) из PPA Amnezia
#   2. Ставит Node.js 20 (NodeSource)
#   3. Копирует vendor/amnezia-wg-easy → /opt/amnezia-wg-easy
#   4. npm ci --omit=dev
#   5. Спрашивает параметры интерактивно
#   6. Создаёт /etc/amnezia-wg-easy/env
#   7. Регистрирует systemd unit и запускает
# ============================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

if [ "$EUID" -ne 0 ]; then
  echo "Запусти от root: sudo bash install.sh"
  exit 1
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1"; }
header(){ echo -e "\n${BLUE}══════════════════════════════════════${NC}"; echo -e "${BLUE}  $1${NC}"; echo -e "${BLUE}══════════════════════════════════════${NC}\n"; }

APP_DIR="/opt/amnezia-wg-easy"
ENV_DIR="/etc/amnezia-wg-easy"
ENV_FILE="${ENV_DIR}/env"
SERVICE_NAME="amnezia-wg-easy"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
VENDOR_DIR="${SCRIPT_DIR}/vendor/amnezia-wg-easy"
TEMPLATE_DIR="${SCRIPT_DIR}/templates"

header "AmneziaWG + web-UI установка на хост"

# ==============================================
# 1. Проверка OS
# ==============================================
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS_ID="$ID"
  OS_VER="$VERSION_ID"
else
  error "Не удалось определить ОС"
  exit 1
fi

if [ "$OS_ID" != "ubuntu" ]; then
  error "Поддерживается только Ubuntu (обнаружено: $OS_ID $OS_VER)"
  exit 1
fi

case "$OS_VER" in
  22.04|24.04) info "Ubuntu $OS_VER — OK" ;;
  *) warn "Ubuntu $OS_VER не тестировался, попробуем..." ;;
esac

# ==============================================
# 2. Проверка наличия исходников веб-панели
# ==============================================
if [ ! -d "$VENDOR_DIR/src" ]; then
  error "Не найден ${VENDOR_DIR}/src — отсутствуют исходники веб-панели"
  echo "  Запусти: git clone https://github.com/w0rng/amnezia-wg-easy.git ${VENDOR_DIR}"
  exit 1
fi
info "Исходники веб-панели: ${VENDOR_DIR}"

# ==============================================
# 3. Параметры (интерактивно)
# ==============================================
header "Параметры"

# Внешний адрес
DEFAULT_IP=$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null || curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "")
read -rp "Домен или внешний IP [$DEFAULT_IP]: " WG_HOST
WG_HOST="${WG_HOST:-$DEFAULT_IP}"
[ -z "$WG_HOST" ] && error "Нужен внешний IP/домен" && exit 1
info "Хост: $WG_HOST"

# Порты
read -rp "Порт WireGuard UDP [777]: " WG_PORT
WG_PORT="${WG_PORT:-777}"

read -rp "Порт веб-панели TCP [51821]: " UI_PORT
UI_PORT="${UI_PORT:-51821}"
info "WG: $WG_PORT/udp, UI: $UI_PORT/tcp"

# Подсеть клиентов
# Пользователь вводит в формате 10.25.13.0/24 (или просто 10.25.13.0).
# Внутри код веб-панели работает с форматом 'N.N.N.x' — конвертируем.
while true; do
  read -rp "Подсеть клиентов /24 [10.25.13.0/24]: " WG_SUBNET_INPUT
  WG_SUBNET_INPUT="${WG_SUBNET_INPUT:-10.25.13.0/24}"
  # Принимаем форматы: 10.25.13.0/24 или 10.25.13.0
  if [[ "$WG_SUBNET_INPUT" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.0(/24)?$ ]]; then
    WG_SUBNET="${BASH_REMATCH[1]}.x"
    break
  fi
  warn "Неверный формат. Нужно как '10.25.13.0/24' (последний октет = 0, маска /24 опционально)"
done
info "Подсеть: ${WG_SUBNET_INPUT%/*}/24 (внутренний формат: $WG_SUBNET)"

# Язык
read -rp "Язык веб-панели (en/ru) [ru]: " UI_LANG
UI_LANG="${UI_LANG:-ru}"

# Внешний сетевой интерфейс (для MASQUERADE)
DEFAULT_DEV=$(ip route show default | awk '/default/ {print $5; exit}')
read -rp "Внешний сетевой интерфейс [$DEFAULT_DEV]: " WG_DEVICE
WG_DEVICE="${WG_DEVICE:-$DEFAULT_DEV}"
[ -z "$WG_DEVICE" ] && error "Не удалось определить интерфейс" && exit 1
info "Интерфейс: $WG_DEVICE"

# Пароль
echo
echo "Пароль для веб-панели:"
while true; do
  read -rsp "  пароль: " PASSWORD; echo
  read -rsp "  повтори: " PASSWORD2; echo
  [ "$PASSWORD" = "$PASSWORD2" ] && [ -n "$PASSWORD" ] && break
  warn "Пароли не совпадают или пустые"
done
echo

# ==============================================
# 4. Установка системных пакетов
# ==============================================
header "Системные пакеты"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

info "Базовые пакеты..."
apt-get install -y -qq \
  curl ca-certificates gnupg software-properties-common \
  build-essential dkms \
  "linux-headers-$(uname -r)" \
  iptables iproute2 \
  resolvconf \
  >/dev/null

# iptables-legacy (как в Docker образе)
if update-alternatives --list iptables 2>/dev/null | grep -q iptables-legacy; then
  update-alternatives --set iptables /usr/sbin/iptables-legacy >/dev/null 2>&1 || true
  info "iptables: переключено на legacy"
fi

# ==============================================
# 5. AmneziaWG из PPA
# ==============================================
header "AmneziaWG (PPA)"

if ! grep -q "amnezia" /etc/apt/sources.list.d/*.list 2>/dev/null; then
  info "Добавляю PPA amnezia/ppa..."
  add-apt-repository -y ppa:amnezia/ppa >/dev/null 2>&1
  apt-get update -qq
fi

info "Устанавливаю amneziawg + amneziawg-tools..."
apt-get install -y -qq amneziawg amneziawg-tools >/dev/null

# Загружаем модуль ядра
modprobe amneziawg 2>/dev/null || warn "modprobe amneziawg не сработал (возможно DKMS ещё собирается)"

# Симлинки awg → wg, awg-quick → wg-quick (т.к. web-panel вызывает wg/wg-quick)
if ! command -v wg >/dev/null 2>&1; then
  if command -v awg >/dev/null 2>&1; then
    ln -sf "$(command -v awg)" /usr/local/bin/wg
    info "Симлинк: /usr/local/bin/wg → awg"
  fi
fi
if ! command -v wg-quick >/dev/null 2>&1; then
  if command -v awg-quick >/dev/null 2>&1; then
    ln -sf "$(command -v awg-quick)" /usr/local/bin/wg-quick
    info "Симлинк: /usr/local/bin/wg-quick → awg-quick"
  fi
fi

# Если уже есть wg/wg-quick (обычный WireGuard), нужно убедиться что
# AmneziaWG версия имеет приоритет. Обычно amneziawg-tools ставит свои
# бинарники /usr/bin которые поддерживают AWG поля. Проверим:
if wg --version 2>&1 | grep -qi amnezia; then
  info "wg: AmneziaWG-патч обнаружен"
else
  warn "wg: НЕ выглядит как AmneziaWG. Возможно установлен обычный wireguard-tools."
  warn "Проверь: которая wg ($(which wg))"
fi

# Каталог конфигов AWG
mkdir -p /etc/amnezia/amneziawg
chmod 700 /etc/amnezia/amneziawg
# WG_PATH в config.js — /etc/wireguard. amneziawg-tools читает из /etc/amnezia/amneziawg.
# Можем работать через /etc/wireguard (как WG-easy ожидает) — wg-quick поддерживает оба.
mkdir -p /etc/wireguard
chmod 700 /etc/wireguard

# ==============================================
# 6. Node.js 20 LTS (NodeSource)
# ==============================================
header "Node.js"

if ! command -v node >/dev/null 2>&1 || [ "$(node -v 2>/dev/null | cut -d. -f1 | tr -d v)" -lt 18 ]; then
  info "Устанавливаю Node.js 20 LTS..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null 2>&1
  apt-get install -y -qq nodejs >/dev/null
fi
info "Node.js: $(node -v)"
info "npm: $(npm -v)"

# ==============================================
# 7. Копируем веб-панель в /opt
# ==============================================
header "Установка веб-панели"

if [ -d "$APP_DIR" ]; then
  warn "$APP_DIR уже существует — заменяю"
  rm -rf "$APP_DIR"
fi

mkdir -p "$APP_DIR"
cp -a "$VENDOR_DIR"/. "$APP_DIR"/
info "Скопировано: $VENDOR_DIR → $APP_DIR"

# npm install
info "npm ci (production)..."
cd "$APP_DIR/src"
npm ci --omit=dev >/dev/null 2>&1 || npm install --omit=dev >/dev/null 2>&1
info "Зависимости установлены"

# ==============================================
# 8. Генерация PASSWORD_HASH
# ==============================================
PASSWORD_HASH=$(node "$APP_DIR/src/wgpw.mjs" "$PASSWORD" 2>&1 | grep -oP "PASSWORD_HASH='\K[^']+" || true)
if [ -z "$PASSWORD_HASH" ]; then
  error "Не удалось сгенерировать PASSWORD_HASH"
  exit 1
fi
info "PASSWORD_HASH сгенерирован"

# ==============================================
# 9. /etc/amnezia-wg-easy/env
# ==============================================
header "Конфигурация"

mkdir -p "$ENV_DIR"
cat > "$ENV_FILE" << EOF
# Автогенерация $(date)
# Веб-панель
PORT=${UI_PORT}
WEBUI_HOST=0.0.0.0
LANG=${UI_LANG}
PASSWORD_HASH=${PASSWORD_HASH}

# WireGuard / AmneziaWG
WG_HOST=${WG_HOST}
WG_PORT=${WG_PORT}
WG_DEVICE=${WG_DEVICE}
# awg-quick по умолчанию ищет конфиг здесь, поэтому используем именно этот путь
WG_PATH=/etc/amnezia/amneziawg/
WG_DEFAULT_ADDRESS=${WG_SUBNET}
WG_DEFAULT_DNS=1.1.1.1
WG_ALLOWED_IPS=0.0.0.0/0
WG_PERSISTENT_KEEPALIVE=25
WG_ENABLE_EXPIRES_TIME=true
UI_TRAFFIC_STATS=true

DEBUG=Server,WireGuard
EOF
chmod 600 "$ENV_FILE"
info "Параметры: $ENV_FILE"

# ==============================================
# 10. sysctl (forwarding)
# ==============================================
SYSCTL_FILE=/etc/sysctl.d/99-amnezia-wg.conf
cat > "$SYSCTL_FILE" << 'EOF'
net.ipv4.ip_forward=1
net.ipv4.conf.all.src_valid_mark=1
EOF
sysctl -q --system >/dev/null
info "sysctl: ip_forward + src_valid_mark"

# ==============================================
# 11. systemd unit
# ==============================================
header "systemd"

sed -e "s|__APP_DIR__|${APP_DIR}|g" \
    -e "s|__ENV_FILE__|${ENV_FILE}|g" \
    "$TEMPLATE_DIR/amnezia-wg-easy.service" > "$SERVICE_FILE"

systemctl daemon-reload
systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
info "systemd unit: $SERVICE_FILE"

# ==============================================
# 12. Запуск
# ==============================================
header "Запуск"

systemctl restart "$SERVICE_NAME"
sleep 3

if systemctl is-active --quiet "$SERVICE_NAME"; then
  info "$SERVICE_NAME — работает"
else
  error "$SERVICE_NAME не запустился"
  echo "  Логи: journalctl -u $SERVICE_NAME -n 30 --no-pager"
  exit 1
fi

# Проверка что wg0 поднялся
sleep 2
if ip link show wg0 &>/dev/null; then
  info "wg0 интерфейс активен"
else
  warn "wg0 пока нет — посмотри логи: journalctl -u $SERVICE_NAME -f"
fi

# ==============================================
# 13. Tunnel manager (IPIP/GRE к удалённым машинам)
# ==============================================
header "Tunnel manager"

# Подсистема туннелей
mkdir -p /etc/awg-tunnels
chmod 700 /etc/awg-tunnels

# Копируем скрипты
install -m 755 "$SCRIPT_DIR/tunnel.sh"                     /usr/local/sbin/awg-tunnel
install -m 755 "$SCRIPT_DIR/templates/tunnel-up.sh"        /usr/local/sbin/awg-tunnel-up
install -m 755 "$SCRIPT_DIR/templates/tunnel-down.sh"      /usr/local/sbin/awg-tunnel-down
install -m 755 "$SCRIPT_DIR/templates/tunnel-remote-up.sh" /usr/local/sbin/awg-tunnel-remote-up.sh
install -m 755 "$SCRIPT_DIR/templates/tunnel-remote-down.sh" /usr/local/sbin/awg-tunnel-remote-down.sh

# systemd template
install -m 644 "$SCRIPT_DIR/templates/awg-tunnel.service" /etc/systemd/system/awg-tunnel@.service
systemctl daemon-reload

# Зависимости для управления (sshpass — нужен tunnel.sh add)
if ! command -v sshpass >/dev/null 2>&1; then
  apt-get install -y -qq sshpass >/dev/null 2>&1 || true
fi

info "awg-tunnel установлен в /usr/local/sbin/"
info "Используй:  sudo awg-tunnel add | list | remove | test | default"
echo

# Предложение добавить туннель прямо сейчас
read -rp "Добавить туннель к удалённой машине сейчас? [y/N]: " ADD_NOW
if [[ "$ADD_NOW" =~ ^[Yy]$ ]]; then
  echo
  /usr/local/sbin/awg-tunnel add || warn "Добавление туннеля прервано — можешь повторить позже: sudo awg-tunnel add"
fi

# ==============================================
# Готово
# ==============================================
header "Готово!"

echo "  Веб-панель: http://${WG_HOST}:${UI_PORT}"
echo "  AWG порт:   ${WG_PORT}/udp"
echo "  Подсеть:    ${WG_SUBNET}"
echo
echo "  Управление AWG:"
echo "    systemctl status $SERVICE_NAME"
echo "    journalctl -u $SERVICE_NAME -f"
echo "    cat $ENV_FILE"
echo
echo "  Управление туннелями:"
echo "    sudo awg-tunnel list      # список туннелей"
echo "    sudo awg-tunnel add       # добавить туннель"
echo "    sudo awg-tunnel default   # выбрать дефолтный"
echo
echo "  Файлы:"
echo "    Код:        $APP_DIR"
echo "    AWG конфиг: /etc/amnezia/amneziawg/wg0.conf"
echo "    Параметры:  $ENV_FILE"
echo "    Туннели:    /etc/awg-tunnels/*.env"
echo
