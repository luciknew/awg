# AmneziaWG проекты

Сборка решений для AmneziaWG VPN с разными топологиями.

## Каталоги

### [awg-ipip-gre](./awg-ipip-gre/)

AmneziaWG-сервер в облаке + IPIP/GRE туннели к exit-нодам за рубежом.

- AWG-машина в облаке (с публичным IPv4, не за NAT)
- Веб-панель `amnezia-wg-easy` (форк w0rng) на хосте, **без Docker**
- Менеджер туннелей `awg-tunnel` — добавлять/удалять exit-ноды
- Можно переключать дефолтный туннель «на лету», текущие клиенты не теряют сессию AWG

Поддержка: **Ubuntu 22.04 / 24.04**

См. [awg-ipip-gre/README.md](./awg-ipip-gre/README.md).
