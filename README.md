# VLESS-туннель для OpenWrt

Shell-скрипт для подключения OpenWrt к одному VLESS-серверу через
[sing-box](https://github.com/SagerNet/sing-box).

Интернет-трафик клиентов локальной сети перенаправляется на промежуточный
VLESS-сервер. Дальнейшую маршрутизацию выполняет сервер.

## Возможности

- OpenWrt 22.02+ и BusyBox `ash`
- прямая `vless://`-ссылка или HTTP(S)-подписка
- один VLESS-сервер без балансировки
- прозрачный прокси TCP и UDP через TPROXY
- локальные SOCKS5- и HTTP-прокси
- watchdog через cron
- обновление скрипта из GitHub
- `sing-box` 1.12.8 со статическими сборками для OpenWrt

## Быстрый запуск

С подпиской:

```sh
wget --no-check-certificate -qO- \
  'https://raw.githubusercontent.com/Alex12571333/xray-openwrt/main/xray-setup.sh' \
  | sh -s -- 'https://example.com/subscription'
```

С готовой VLESS-ссылкой:

```sh
wget --no-check-certificate -qO- \
  'https://raw.githubusercontent.com/Alex12571333/xray-openwrt/main/xray-setup.sh' \
  | sh -s -- 'vless://UUID@SERVER:PORT?...'
```

Скрипт сохраняется на роутере в `/etc/sing-box/setup.sh`.

## Как это работает

1. Скрипт определяет архитектуру роутера и устанавливает совместимую сборку
   `sing-box`.
2. Из прямой ссылки или подписки извлекается один VLESS-сервер. Для подписки
   используется первая найденная `vless://`-ссылка.
3. Создаётся единственный VLESS-outbound с тегом `proxy`.
4. `sing-box` принимает SOCKS5, HTTP и TPROXY-трафик.
5. Правила `iptables` перенаправляют TCP и UDP клиентов локальной сети в
   TPROXY.
6. Весь принятый внешний трафик отправляется через `proxy`; приватные адреса
   идут напрямую.

## Маршрутизация

| Трафик | Маршрут |
|---|---|
| Приватные и служебные IPv4-сети | напрямую |
| TCP с портом назначения `22` | напрямую |
| Остальной TCP/UDP с `br-lan`, `br0`, `eth1` | VLESS-сервер |
| Трафик, созданный самим роутером | напрямую |

Скрипт настраивает только IPv4. Для другой схемы интерфейсов измените список
`br-lan br0 eth1` в функции `setup_iptables`.

## Порты

| Порт | Протокол | Назначение |
|---|---|---|
| `1080` | SOCKS5 | прокси для приложений |
| `1081` | HTTP | HTTP-прокси |
| `12345` | TPROXY | прозрачный прокси для `iptables` |

Все три входа слушают `0.0.0.0`. Ограничьте доступ к портам правилами firewall
роутера.

## Управление

Интерактивное меню:

```sh
sh /etc/sing-box/setup.sh
```

Команды:

```sh
sh /etc/sing-box/setup.sh status
sh /etc/sing-box/setup.sh restart
sh /etc/sing-box/setup.sh stop
sh /etc/sing-box/setup.sh self-update
```

В меню можно запустить или остановить туннель, сменить VLESS-сервер, посмотреть
лог и обновить скрипт.

## Проверка

Статус процесса:

```sh
sh /etc/sing-box/setup.sh status
```

Правила TPROXY:

```sh
iptables -t mangle -L SBOX_TP -n -v
```

Проверка через SOCKS5, если установлен `curl`:

```sh
curl --socks5-hostname 127.0.0.1:1080 https://api.ipify.org
```

Лог:

```sh
tail -f /var/log/sing-box.log
```

## Файлы на роутере

| Путь | Назначение |
|---|---|
| `/usr/bin/sing-box` | исполняемый файл |
| `/etc/sing-box/config.json` | активная конфигурация |
| `/etc/sing-box/vless_url` | выбранная VLESS-ссылка |
| `/etc/sing-box/sub_url` | URL подписки |
| `/etc/sing-box/setup.sh` | установленная копия скрипта |
| `/var/run/sing-box.pid` | PID процесса |
| `/var/log/sing-box.log` | журнал |
| `/etc/crontabs/root` | watchdog |

## Требования

- OpenWrt 22.02+
- `iptables` с поддержкой TPROXY
- `ip`, `tar`, `grep`, `sed`, `awk`, `find`, `mktemp`
- `curl`, `uclient-fetch` или `wget`
- `base64` или `openssl` для закодированных подписок

Поддерживаемые архитектуры: `aarch64`, `armv7l`, `armv6l`, `x86_64`,
`i686`, `i386`, `mips` и `mipsel`.
