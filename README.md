# xray-openwrt

Автономный shell-скрипт для установки [Xray-core](https://github.com/XTLS/Xray-core) на роутер OpenWrt с поддержкой VLESS-подписок.

- Работает на **OpenWrt 22.02+**, BusyBox ash (`#!/bin/sh`, без bash)
- Поддерживает архитектуры: `aarch64`, `armv7l`, `armv6l`, `x86_64`, `mips`, `mipsel`
- Выбирает **3 лучших сервера** по TCP-латентности из подписки
- Генерирует `config.json` с балансировщиком `leastPing` + автопереключением
- Трафик `geoip:ru` и `geosite:ru` идёт напрямую, остальное — через прокси

---

## Быстрый старт

```sh
wget --no-check-certificate -qO- \
  'https://raw.githubusercontent.com/Alex12571333/xray-openwrt/main/xray-setup.sh' \
  | sh -s -- 'https://your-subscription-url'
```

Или скачать и запустить вручную:

```sh
wget --no-check-certificate -O /tmp/xray-setup.sh \
  'https://raw.githubusercontent.com/Alex12571333/xray-openwrt/main/xray-setup.sh'
sh /tmp/xray-setup.sh 'https://your-subscription-url'
```

---

## Интерактивное меню

Запуск без аргументов открывает меню (после первой установки скрипт живёт в `/etc/xray/setup.sh`):

```sh
sh /etc/xray/setup.sh
```

```
╔══════════════════════════════════╗
║     Xray Setup / OpenWrt         ║
║     ▶ запущен                    ║
╠══════════════════════════════════╣
║  1  Установить / обновить        ║
║  2  Статус                       ║
║  3  Перезапустить                ║
║  4  Остановить                   ║
║  5  Автозапуск при загрузке      ║
║  6  Автообновление подписки      ║
║  7  Удалить всё                  ║
║  8  Тесты                        ║
║  0  Выход                        ║
╚══════════════════════════════════╝
Выбор:
```

---

## Пример вывода при установке

```
>>> === Установка Xray ===
>>> Xray не найден — устанавливаю из GitHub...
>>> Архитектура: aarch64 → Xray-linux-arm64-v8a.zip
>>> Скачиваю Xray-linux-arm64-v8a.zip...
>>> Xray установлен: Xray 25.1.1 (Xray, Penetrates Everything)

>>> === Загрузка подписки ===
>>> Скачиваю подписку...
>>> Найдено серверов: 86

>>> === Выбор лучших серверов ===
>>> Тестирую серверы (первые 20 из 86)...
  [ 1/20] cdn4-35.vk-cdnvideo.com:8443         120ms ✓
  [ 2/20] cdn3-87.vk-cdnvideo.com:8443         115ms ✓
  [ 3/20] cdn9-20.vk-cdnvideo.com:8443         130ms ✓
  [ 4/20] cdn3-25.vk-cdnvideo.com:8443         310ms ✓
  ...
>>> Доступно: 19 — беру топ-3 по латентности

>>> === Парсинг ===
>>>   Сервер 1: cdn3-87.vk-cdnvideo.com:8443  type=tcp  security=tls
>>>   Сервер 2: cdn4-35.vk-cdnvideo.com:8443  type=tcp  security=tls
>>>   Сервер 3: cdn9-20.vk-cdnvideo.com:8443  type=tcp  security=tls

>>> === Генерация конфига ===
>>> Конфиг записан

>>> === Запуск ===
>>> Xray запущен, PID 1234

  SOCKS5 : 127.0.0.1:1080
  HTTP   : 127.0.0.1:1081
  TProxy : 0.0.0.0:12345
```

---

## Статус

```sh
sh /etc/xray/setup.sh  # → пункт 2
```

```
  Xray        : Xray 25.1.1 (Xray, Penetrates Everything)
  Процесс     : запущен (PID 1234)
  Конфиг      : /etc/xray/config.json
  Подписка    : https://your-subscription-url
  Автозапуск  : включён
  Автообновл. : каждые 6 ч.
```

---

## Автозапуск при загрузке

Через меню → пункт **5**, или вручную:

```sh
# Включить
sh /etc/xray/setup.sh   # → 5 → 1

# Проверить
ls -la /etc/init.d/xray
/etc/init.d/xray enabled && echo "включён"
```

Устанавливает procd init-скрипт `/etc/init.d/xray` с автоперезапуском при падении.

---

## Автообновление подписки (cron)

Меню → пункт **6**:

```
Автообновление подписки: выключено

  1  Каждые 6 часов
  2  Каждые 12 часов
  3  Каждые 24 часа
  4  Выключить
  0  Назад
```

Записывает задание в `/etc/crontabs/root`. Логи обновлений: `/var/log/xray-update.log`.

---

## Удаление

Меню → пункт **7**:

```
Будет удалено:
  /usr/bin/xray, /etc/xray/,
  автозапуск (/etc/init.d/xray),
  автообновление (cron),
  логи /var/log/xray*.log

Подтвердите удаление [y/N]:
```

---

## Порты и маршрутизация

| Порт | Протокол | Назначение |
|------|----------|------------|
| 1080 | SOCKS5 | Прокси для приложений |
| 1081 | HTTP | HTTP-прокси |
| 12345 | TProxy | Прозрачный прокси (iptables) |

**Правила маршрутизации:**
- `geoip:private` (192.168.x.x, 10.x.x.x и т.д.) → direct
- `geosite:ru` + `geoip:ru` → direct
- Всё остальное → балансировщик `leastPing` (3 сервера)

---

## Проверка работы

```sh
# Через SOCKS5
curl -x socks5://127.0.0.1:1080 https://ipinfo.io

# Через HTTP-прокси
curl -x http://127.0.0.1:1081 https://ipinfo.io

# Логи Xray (макс. 256 КБ, ротация автоматически)
tail -f /var/log/xray.log
tail -100 /var/log/xray.log
```

---

## Тесты

```sh
sh xray-setup.sh test
```

```
-- urldecode
  [PASS] путь %2F
  [PASS] запятая %2C
  [PASS] пробел %20
  [PASS] знак равно %3D
  [PASS] процент %25
  [PASS] без кодирования

-- alpn_to_json
  [PASS] два значения
  [PASS] одно значение
  [PASS] три значения

-- detect_arch
  [PASS] detect_arch: arm64-v8a

-- parse_vless (tls+ws)
  [PASS] uuid
  [PASS] host
  [PASS] port
  [PASS] type
  [PASS] security
  [PASS] path
  [PASS] sni
  [PASS] alpn
  [PASS] host_hdr

-- parse_vless (reality+tcp)
  [PASS] host
  [PASS] port
  [PASS] security
  [PASS] fp
  [PASS] pbk
  [PASS] sid
  [PASS] flow

-- интеграция
  [PASS] бинарник: /usr/bin/xray
  [PASS] конфиг: /etc/xray/config.json
  [PASS] процесс запущен (PID 1234)
  [PASS] SOCKS5 :1080 работает (IP: 1.2.3.4)

  Итог: 27 пройдено, 0 провалено
```

На не-OpenWrt машине интеграционные тесты пропускаются (`[SKIP]`).

---

## Файлы

| Путь | Описание |
|------|----------|
| `/usr/bin/xray` | Бинарник Xray-core |
| `/etc/xray/config.json` | Конфигурация |
| `/etc/xray/sub_url` | URL подписки |
| `/etc/xray/setup.sh` | Скрипт (постоянная копия) |
| `/etc/init.d/xray` | Procd init-скрипт автозапуска |
| `/var/run/xray.pid` | PID запущенного процесса |
| `/var/log/xray.log` | Лог (макс. 256 КБ, ротация при запуске) |

---

## Требования

- OpenWrt 22.02+ (проверено на 23.05)
- BusyBox: `wget`, `base64`, `unzip`, `nc`, `grep`, `sed`, `awk`, `mktemp`
- Архитектуры: aarch64 (Brume 3), armv7l, x86_64, mips и другие

---

## Тестирование в QEMU (для разработчиков)

Запускает OpenWrt 23.05 aarch64 в эмуляторе и прогоняет тесты:

```sh
# Установить QEMU (macOS)
brew install qemu

# Запустить тесты
sh test-qemu.sh
```

Образы скачиваются автоматически при первом запуске (~80 МБ). Повторные запуски используют кэш.
