# AmneziaWG host install

Установка AmneziaWG VPN с веб-панелью **на хост** (без Docker)
+ менеджер IPIP/GRE туннелей к удалённым машинам.

Поддержка: **Ubuntu 22.04 / 24.04**.

## Структура

```
.
├── install.sh                          # установщик AWG + UI + tunnel manager
├── tunnel.sh                           # менеджер туннелей (после установки: awg-tunnel)
├── templates/
│   ├── amnezia-wg-easy.service         # systemd unit веб-панели
│   ├── awg-tunnel.service              # systemd template для туннелей
│   ├── tunnel-up.sh                    # подъём туннеля локально
│   ├── tunnel-down.sh                  # снятие туннеля локально
│   ├── tunnel-remote-up.sh             # подъём на удалённой машине (по SSH)
│   └── tunnel-remote-down.sh           # снятие на удалённой машине
└── vendor/
    └── amnezia-wg-easy/                # исходники веб-панели (w0rng/amnezia-wg-easy)
```

## Установка

На свежей Ubuntu VM:

```bash
git clone -b IP-418 <repo> ~/awg
cd ~/awg
sudo bash install.sh
```

install.sh поставит AWG, веб-панель, и menager туннелей. В конце предложит сразу добавить первый туннель.

После установки:
- Веб-панель: `http://<host>:<UI_PORT>` (по умолчанию `:51821`)
- Управление: `systemctl status amnezia-wg-easy`

## Туннели (`awg-tunnel`)

```bash
sudo awg-tunnel list              # список туннелей
sudo awg-tunnel add               # интерактивно создать новый
sudo awg-tunnel remove <name>     # удалить
sudo awg-tunnel edit <name>       # пересоздать (remove + add)
sudo awg-tunnel test <name>       # ping
sudo awg-tunnel default           # выбрать дефолтный (для будущей маршрутизации)
```

Что спрашивает `add`:
- Имя туннеля (`pupa`, `lupa`, ...)
- Тип: `ipip` или `gre`
- IP/домен удалённой машины
- SSH порт, логин, пароль (только пароль; ключи не используются)
- Публичный IP этой машины (для туннеля)
- Подсеть `/30` (например `10.200.0.0/30` — `.1` назначается этой машине, `.2` — удалённой)

Что делает `add`:
- Проверяет SSH-доступ к удалённой машине
- Сохраняет конфиг в `/etc/awg-tunnels/<name>.env`
- На удалённой машине ставит iproute2/iptables, поднимает туннель, регистрирует `awg-peer-<name>.service` (автозапуск)
- Локально регистрирует и запускает `awg-tunnel@<name>.service`
- Проверяет ping до удалённого конца туннеля
- Если это первый туннель — делает его дефолтным

## Файлы на хосте после установки

```
/opt/amnezia-wg-easy/                              # код веб-панели
/etc/amnezia-wg-easy/env                           # параметры веб-панели
/etc/amnezia/amneziawg/wg0.conf                    # конфиг AWG (автогенерится UI)
/etc/amnezia/amneziawg/wg0.json                    # клиенты AWG

/etc/awg-tunnels/<name>.env                        # параметры туннеля
/etc/awg-tunnels/default                           # имя дефолтного туннеля

/usr/local/sbin/awg-tunnel                         # CLI менеджер
/usr/local/sbin/awg-tunnel-up                      # системные скрипты
/usr/local/sbin/awg-tunnel-down
/usr/local/sbin/awg-tunnel-remote-up.sh            # копируется на remote через SSH stdin
/usr/local/sbin/awg-tunnel-remote-down.sh

/etc/systemd/system/amnezia-wg-easy.service        # веб-панель
/etc/systemd/system/awg-tunnel@.service            # template per-tunnel
```

## Маршрутизация (отдельная задача)

`awg-tunnel default` сейчас только запоминает имя дефолтного туннеля. Сама маршрутизация трафика клиентов AWG через выбранный туннель будет в следующей задаче.

## Правка веб-панели

Исходники в `vendor/amnezia-wg-easy/`. После правок на сервере:

```bash
rsync -a vendor/amnezia-wg-easy/src/ root@server:/opt/amnezia-wg-easy/src/
ssh root@server "cd /opt/amnezia-wg-easy/src && npm ci --omit=dev && systemctl restart amnezia-wg-easy"
```

Текущие правки относительно upstream `w0rng/amnezia-wg-easy`:
- `src/lib/Server.js` — путь к статике сделан относительным (`__dirname/../www` вместо хардкода `/app/www`), работает и в Docker, и на хосте.
