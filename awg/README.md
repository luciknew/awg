# awg

Простая установка AmneziaWG-сервера с веб-панелью **на хост** (без Docker).
Только сам AWG — без туннелей к exit-нодам, без менеджера туннелей.

Поддержка: **Ubuntu 22.04 / 24.04**.

## Зачем эта версия

Этот вариант — для случая когда **AWG-машина за NAT**, а маршрутизация трафика
клиентов делается **на роутере** (например MikroTik, через mangle/routing-mark).
Машине нужно только терминировать AmneziaWG — дальше трафик уйдёт через её
обычный default gateway (= роутер).

Для случая когда AWG-машина в облаке с публичным IP и нужно поднимать
IPIP/GRE туннели — смотри [`../awg-ipip-gre/`](../awg-ipip-gre/).

## Шпаргалка

**Установить с нуля:**
```bash
git clone <repo> ~/awg
cd ~/awg/awg
sudo bash install.sh
# веб-панель: http://<host>:51821
```

**Управление:**
```bash
sudo systemctl status amnezia-wg-easy         # статус
sudo systemctl restart amnezia-wg-easy        # рестарт после правки кода
sudo journalctl -u amnezia-wg-easy -f         # логи
sudo cat /etc/amnezia-wg-easy/env             # параметры
```

## Структура

```
awg/
├── install.sh                          # установщик AWG + UI
├── templates/
│   └── amnezia-wg-easy.service         # systemd unit веб-панели
└── vendor/
    └── amnezia-wg-easy/                # исходники веб-панели (w0rng/amnezia-wg-easy)
```

## Что делает install.sh

1. Проверяет Ubuntu 22.04/24.04
2. Ставит AmneziaWG из PPA `amnezia/ppa` (kernel module + tools)
3. Ставит Node.js 20 LTS (NodeSource)
4. Копирует `vendor/amnezia-wg-easy/` → `/opt/amnezia-wg-easy/`
5. `npm ci --omit=dev`
6. Спрашивает: host, порты, подсеть `10.X.X.0/24`, пароль веб-панели
7. Создаёт `/etc/amnezia-wg-easy/env`
8. Регистрирует и запускает `amnezia-wg-easy.service`

После установки:
- Веб-панель: `http://<host>:<UI_PORT>` (по умолчанию `:51821`)
- AWG слушает на `<WG_PORT>/udp` (по умолчанию `777`)

## Файлы на хосте

```
/opt/amnezia-wg-easy/                              # код веб-панели
/etc/amnezia-wg-easy/env                           # параметры
/etc/amnezia/amneziawg/wg0.conf                    # конфиг AWG (автогенерится UI)
/etc/amnezia/amneziawg/wg0.json                    # клиенты AWG
/etc/systemd/system/amnezia-wg-easy.service        # systemd unit
```

## Требования и ограничения

- Только **Ubuntu 22.04 / 24.04**
- Подсеть AmneziaWG — только **/24** (ограничение веб-панели, в коде захардкожено)
- Эта версия не настраивает маршрутизацию через туннели. Если нужны exit-ноды — используй [`awg-ipip-gre`](../awg-ipip-gre/)

## Правка веб-панели

Исходники в `vendor/amnezia-wg-easy/`. После правок на сервере:

```bash
rsync -a vendor/amnezia-wg-easy/src/ root@server:/opt/amnezia-wg-easy/src/
ssh root@server "cd /opt/amnezia-wg-easy/src && npm ci --omit=dev && systemctl restart amnezia-wg-easy"
```

Текущие правки относительно upstream `w0rng/amnezia-wg-easy`:
- `src/lib/Server.js` — путь к статике сделан относительным (`__dirname/../www` вместо хардкода `/app/www`), работает и в Docker, и на хосте.
