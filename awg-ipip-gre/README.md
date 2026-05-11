# awg-ipip-gre

AmneziaWG-сервер в облаке + IPIP/GRE туннели к **exit-нодам** за рубежом.

Поддержка: **Ubuntu 22.04 / 24.04**.

## Зачем это нужно

Если просто поставить AmneziaWG на иностранный сервер — это самое простое решение,
но у такой схемы есть минусы: handshake к удалённому серверу может быть медленным
из-за расстояния, и клиенты получают зарубежный IP даже для русского трафика.

Эта схема разносит две функции:

| Функция | Где живёт |
|---------|-----------|
| **Терминирование клиентов** AmneziaWG | Облачная VM в РФ или близко — быстрый handshake |
| **Выход в интернет** (NAT) | Удалённая VM за рубежом — нужный exit-IP |

Между AWG-машиной и exit-нодами — **IPIP** или **GRE** туннели.
На AWG-машине можно держать несколько туннелей, выбирать какой из них дефолтный
(через который уходит весь клиентский трафик), и переключать без перенастройки клиентов.

## Шпаргалка

**Установить с нуля (чистая Ubuntu):**
```bash
git clone <repo> ~/awg
cd ~/awg/awg-ipip-gre
sudo bash install.sh
# веб-панель: http://<host>:51821
```

**Добавить exit-ноду (туннель):**
```bash
sudo awg-tunnel add
# имя → тип (1 ipip / 2 gre) → IP → SSH (порт/логин/пароль) → подсеть /30 (напр. 10.200.0.0/30)
```

**Управление туннелями:**
```bash
sudo awg-tunnel list                 # список туннелей + статус
sudo awg-tunnel test                 # ping проверка (выбор по номеру)
sudo awg-tunnel default              # выбрать дефолтный (по номеру)
sudo awg-tunnel remove               # удалить (по номеру)
sudo awg-tunnel edit                 # пересоздать (по номеру)
sudo awg-tunnel help                 # все команды
```

С аргументом: `sudo awg-tunnel remove <name>` (без интерактивного выбора).

**Проверить что трафик идёт через дефолтный туннель:**
```bash
ip rule | grep 100                            # from 10.X.X.0/24 lookup awg-route
ip route show table awg-route                 # default via TUN_REMOTE dev <tunnel>
cat /etc/awg-tunnels/default                  # имя дефолтного
```

**Управление веб-панелью:**
```bash
sudo systemctl status amnezia-wg-easy         # статус
sudo systemctl restart amnezia-wg-easy        # рестарт после правки кода
sudo journalctl -u amnezia-wg-easy -f         # логи
sudo cat /etc/amnezia-wg-easy/env             # параметры
```

## Схема

```
                ┌──────────────────────────────────┐
   Клиент       │   AWG-машина (в облаке, не за NAT)│
  (телефон) ───▶│                                   │
  AmneziaWG     │   wg0 = 10.X.X.0/24               │
                │   ↓ policy routing                │
                │   ip rule from 10.X.X.0/24        │
                │       table awg-route             │
                │   ↓                               │
                │   table awg-route: default        │
                │       via TUN_REMOTE              │
                │       dev <default-tunnel>        │
                │   ↓                               │
                └────────────┬──────────────────────┘
                             │  IPIP / GRE поверх IPv4
                             │  (Internet)
                             ▼
                ┌──────────────────────────────────┐
                │   exit-нода (за рубежом)         │
                │                                  │
                │   ipip/gre интерфейс             │
                │   ↓ MASQUERADE на eth0           │
                │   ↓                              │
                └────────────┬─────────────────────┘
                             ▼
                         🌍 Internet
                  (с public IP exit-ноды)
```

Поверх можно поднять несколько exit-нод и переключаться между ними:

```
AWG-машина ─┬─ IPIP к Эстонии  (default)
            ├─ IPIP к Германии
            └─ GRE  к Нидерландам
```

Команда `awg-tunnel default` меняет дефолтный туннель «на лету» — текущие TCP-сессии
клиентов разрываются (через `conntrack -D`), и новые соединения уходят уже через
выбранный туннель. AmneziaWG-сессия клиента не разрывается.

## Структура

```
awg-ipip-gre/
├── install.sh                          # установщик AWG + UI + tunnel manager
├── tunnel.sh                           # менеджер туннелей (после установки = awg-tunnel)
├── templates/
│   ├── amnezia-wg-easy.service         # systemd unit веб-панели
│   ├── awg-tunnel.service              # systemd template per-tunnel
│   ├── tunnel-up.sh                    # подъём туннеля локально
│   ├── tunnel-down.sh                  # снятие локально
│   ├── tunnel-remote-up.sh             # подъём на exit-ноде (по SSH)
│   ├── tunnel-remote-down.sh           # снятие на exit-ноде
│   └── apply-default.sh                # policy routing + iptables + conntrack flush
└── vendor/
    └── amnezia-wg-easy/                # исходники веб-панели (w0rng/amnezia-wg-easy)
```

## Установка

На свежей Ubuntu VM (где будет AWG):

```bash
git clone <repo> ~/awg
cd ~/awg/awg-ipip-gre
sudo bash install.sh
```

Скрипт:
1. Ставит AmneziaWG из PPA `amnezia/ppa`
2. Ставит Node.js 20 LTS + зависимости (sshpass, conntrack)
3. Копирует `vendor/amnezia-wg-easy/` → `/opt/amnezia-wg-easy/`
4. Спрашивает: host, порты, подсеть `10.X.X.0/24`, пароль веб-панели
5. Регистрирует `amnezia-wg-easy.service` и `awg-tunnel@.service`
6. Опционально предлагает сразу добавить первый туннель к exit-ноде

После установки:
- Веб-панель: `http://<host>:<UI_PORT>` (по умолчанию `:51821`)
- Управление: `systemctl status amnezia-wg-easy`

## Управление туннелями: `awg-tunnel`

```bash
sudo awg-tunnel list              # список туннелей и статус
sudo awg-tunnel add               # интерактивно создать туннель
sudo awg-tunnel remove [<name>]   # удалить (без имени — выбор по номеру)
sudo awg-tunnel edit   [<name>]   # пересоздать (remove + add)
sudo awg-tunnel test   [<name>]   # ping проверка
sudo awg-tunnel default           # выбрать дефолтный туннель
```

Что спрашивает `add`:
- Имя туннеля (`pupa`, `lupa`...) — до 15 символов, начинается с буквы
- Тип: `1) ipip` / `2) gre`
- IP/домен exit-ноды
- SSH порт, логин, пароль (ключи не используются)
- Подсеть `/30` (например `10.200.0.0/30` — `.1` AWG-машине, `.2` exit-ноде)

Что делает `add`:
- Проверяет SSH-доступ
- Сохраняет `/etc/awg-tunnels/<name>.env`
- На exit-ноде ставит iproute2/iptables, поднимает туннель, регистрирует
  `awg-peer-<name>.service` с MASQUERADE и FORWARD-правилами (автозапуск при ребуте)
- Локально регистрирует и запускает `awg-tunnel@<name>.service`
- Проверяет ping до удалённого конца
- Если это **первый** туннель — делает его дефолтным **и применяет routing**

## Маршрутизация — как работает `default`

```
default = <name>  →  apply-default
                  │
                  ├─ создаёт таблицу маршрутизации awg-route (id 200)
                  │
                  ├─ ip rule from <WG_SUBNET> lookup awg-route priority 100
                  │
                  ├─ ip route add default via <TUN_REMOTE> dev <name>
                  │     table awg-route
                  │
                  ├─ iptables -t nat -A POSTROUTING
                  │     -s <WG_SUBNET> -o <name> -j MASQUERADE
                  │     (с комментом 'awg-default-route')
                  │
                  ├─ iptables FORWARD: wg0 ↔ <name> ACCEPT
                  │
                  └─ conntrack -D -s <WG_SUBNET>
                       (сброс старых TCP-сессий — переустановятся через новый путь)
```

Идемпотентно: правила помечены комментариями (`awg-default-route`, `awg-peer-<name>`),
повторный запуск чистит старое и ставит новое — без накопления дублей.

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
/usr/local/sbin/awg-tunnel-remote-up.sh
/usr/local/sbin/awg-tunnel-remote-down.sh
/usr/local/sbin/awg-tunnel-apply-default           # policy routing

/etc/systemd/system/amnezia-wg-easy.service        # веб-панель
/etc/systemd/system/awg-tunnel@.service            # template per-tunnel
```

На exit-ноде:
```
/etc/systemd/system/awg-peer-<name>.service        # туннель + iptables правила
```

## Требования и ограничения

- Только **Ubuntu 22.04 / 24.04** (PPA Amnezia)
- AWG-машина и exit-ноды должны иметь **публичные IPv4** (IPIP/GRE без обёртки не пробивают NAT)
- Если провайдер режет IPIP (protocol 4) или GRE (protocol 47) — туннель не поднимется. Облачные провайдеры часто это разрешают, но не всегда.
- Подсеть AmneziaWG — только **/24** (ограничение веб-панели, захардкожено в коде)

## Правка веб-панели

Исходники в `vendor/amnezia-wg-easy/`. После правок на сервере:

```bash
rsync -a vendor/amnezia-wg-easy/src/ root@server:/opt/amnezia-wg-easy/src/
ssh root@server "cd /opt/amnezia-wg-easy/src && npm ci --omit=dev && systemctl restart amnezia-wg-easy"
```

Текущие правки относительно upstream `w0rng/amnezia-wg-easy`:
- `src/lib/Server.js` — путь к статике сделан относительным (`__dirname/../www` вместо хардкода `/app/www`), работает и в Docker, и на хосте.

## Диагностика

```bash
# статус сервисов
systemctl status amnezia-wg-easy
systemctl status awg-tunnel@<name>

# логи
journalctl -u amnezia-wg-easy -f
journalctl -u awg-tunnel@<name> -n 20 --no-pager

# проверка туннеля
sudo awg-tunnel test <name>           # ping

# проверка маршрутизации
ip rule | grep 100                    # должно быть from <WG_SUBNET> lookup awg-route
ip route show table awg-route         # default via TUN_REMOTE dev <tunnel>
iptables -t nat -L POSTROUTING -n -v  # MASQUERADE с комментом awg-default-route
cat /etc/awg-tunnels/default          # имя дефолтного туннеля

# на exit-ноде
ssh root@<exit-node>
systemctl status awg-peer-<name>
ip a show <name>
iptables -t nat -L POSTROUTING -n -v | grep awg-peer
```
