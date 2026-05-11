# AmneziaWG host install

Установка AmneziaWG VPN с веб-панелью **на хост** (без Docker).
Поддержка: **Ubuntu 22.04 / 24.04**.

## Структура

```
.
├── install.sh                          # интерактивный установщик
├── templates/
│   └── amnezia-wg-easy.service         # systemd unit template
└── vendor/
    └── amnezia-wg-easy/                # исходники веб-панели
                                        # (form w0rng/amnezia-wg-easy, можно править)
```

## Что делает install.sh

1. Проверяет Ubuntu (22.04/24.04)
2. Ставит `amneziawg` + `amneziawg-tools` из `ppa:amnezia/ppa`
3. Ставит Node.js 20 LTS (NodeSource)
4. Копирует `vendor/amnezia-wg-easy/` → `/opt/amnezia-wg-easy/`
5. `npm ci --omit=dev`
6. Интерактивно спрашивает: host, порты, подсеть, пароль
7. Создаёт `/etc/amnezia-wg-easy/env`
8. Регистрирует systemd unit `amnezia-wg-easy.service` и запускает

## Запуск

На чистой Ubuntu VM:

```bash
git clone <repo> awg
cd awg
sudo bash install.sh
```

## После установки

- Веб-панель: `http://<host>:<UI_PORT>` (по умолчанию `:51821`)
- AWG порт: `<WG_PORT>/udp` (по умолчанию `777`)
- Конфиги клиентов: `/etc/wireguard/wg0.conf`, `wg0.json`
- Параметры (env): `/etc/amnezia-wg-easy/env`
- Логи: `journalctl -u amnezia-wg-easy -f`

## Правка веб-панели

Исходники веб-панели в `vendor/amnezia-wg-easy/`. При правках:

```bash
# на dev-машине: правишь vendor/amnezia-wg-easy/src/...
# деплой на сервер:
rsync -a vendor/amnezia-wg-easy/src/ root@server:/opt/amnezia-wg-easy/src/
ssh root@server "cd /opt/amnezia-wg-easy/src && npm ci --omit=dev && systemctl restart amnezia-wg-easy"
```

## Ветка

Развитие в ветке `host-install`.
