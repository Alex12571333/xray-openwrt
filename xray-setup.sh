#!/bin/sh
# xray-setup.sh — Xray + VLESS подписка для OpenWrt 21.02+ (GL-iNet, OpenWrt)
# Зависимости: wget/uclient-fetch, openssl/base64, unzip, grep, sed, awk, nc (BusyBox)
# Использование: sh xray-setup.sh [sub_url|test|update|self-update]  или без аргументов — меню

SCRIPT_VERSION="20260628"
SCRIPT_URL="https://raw.githubusercontent.com/Alex12571333/xray-openwrt/main/xray-setup.sh"
SCRIPT_VERSION_URL="https://raw.githubusercontent.com/Alex12571333/xray-openwrt/main/version"
SCRIPT_REMOTE_CMD_URL="https://raw.githubusercontent.com/Alex12571333/xray-openwrt/main/remote_cmd"
XRAY_LAST_CMD_FILE="/tmp/xray-last-cmd"
XRAY_REMOTE_LOG="/var/log/xray-remote.log"
XRAY_TUNNEL_PID="/tmp/xray-sstunnel.pid"
XRAY_TUNNEL_CONF="/etc/xray/ssh_tunnel.conf"
XRAY_TUNNEL_KEY="/etc/xray/tunnel_id_rsa"
XRAY_TG_TOKEN_FILE="/etc/xray/tg_token"
XRAY_TG_CHAT_FILE="/etc/xray/tg_chat"
XRAY_TG_BOT_PID="/tmp/xray-tgbot.pid"
XRAY_TG_OFFSET_FILE="/tmp/xray-tg-offset"
# Дефолтные значения (перекрываются файлами)
_TG_TOKEN_DEFAULT="7843072353:AAHDdmRz11W8LdlIXO9mwwAQxmEB5suwrcQ"
_TG_CHAT_DEFAULT="1485347990"
DEFAULT_SUB_URL=""  # Хранится локально в /etc/xray/sub_url — не нужно указывать здесь

XRAY_BIN="/usr/bin/xray"
XRAY_CONFIG="/etc/xray/config.json"
XRAY_PID="/var/run/xray.pid"
XRAY_INTENT="/var/run/xray-running"  # Флаг: пользователь хочет чтобы Xray работал
XRAY_SUB_FILE="/etc/xray/sub_url"
XRAY_SELF="/etc/xray/setup.sh"
XRAY_INIT="/etc/init.d/xray"
XRAY_CRON="/etc/crontabs/root"
CRON_MARKER="# xray-autoupdate"
GITHUB_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
GEODATA_GEOIP="https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geoip.dat"
GEODATA_GEOSITE="https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat"
XRAY_LOG="/var/log/xray.log"
XRAY_LOG_MAX=262144    # 256 КБ — при превышении оставляем последние 128 КБ
XRAY_UPDLOG="/var/log/xray-update.log"
XRAY_UPDLOG_MAX=51200  # 50 КБ — ротируем до 25 КБ
XRAY_CONFIG_BAK="${XRAY_CONFIG}.bak"
XRAY_WATCHDOG_SCRIPT="/tmp/xray-watchdog.sh"
XRAY_WATCHDOG_OK="/tmp/xray-watchdog-ok"
XRAY_WATCHDOG_PID="/tmp/xray-watchdog.pid"
XRAY_UPDATER_PID="/tmp/xray-updater.pid"
IPTABLES_CHAIN="XRAY_TP"
FIREWALL_MARK="# xray-tproxy"
FIREWALL_USER="/etc/firewall.user"
XRAY_SERVERS_FILE="/etc/xray/servers.txt"
XRAY_EXCLUDED_IPS_FILE="/etc/xray/excluded_ips"

WORK_DIR=$(mktemp -d /tmp/xray-XXXXXX)
trap 'rm -rf "$WORK_DIR" /tmp/xray_sv_*.env /tmp/xray_ping*.txt 2>/dev/null' EXIT INT TERM

die()  { printf 'ОШИБКА: %s\n' "$*" >&2; exit 1; }
info() { printf '>>> %s\n' "$*" >&2; }
warn() { printf 'ПРЕДУПРЕЖДЕНИЕ: %s\n' "$*" >&2; }

# ─── Backup / Rollback / Watchdog ────────────────────────────────────────────
_save_backup() {
    [ -f "$XRAY_CONFIG" ] || return 0
    cp "$XRAY_CONFIG" "$XRAY_CONFIG_BAK"
    info "Резервная копия конфига сохранена → $XRAY_CONFIG_BAK"
}

# Проверяем что прокси поднят и пропускает трафик (SOCKS5 → HTTP fallback)
_test_proxy() {
    local url="https://www.gstatic.com/generate_204"
    if command -v curl >/dev/null 2>&1; then
        curl -s --max-time 10 -x socks5://127.0.0.1:1080 "$url" >/dev/null 2>&1 && return 0
        curl -s --max-time 10 -x http://127.0.0.1:1081   "$url" >/dev/null 2>&1 && return 0
    fi
    http_proxy="http://127.0.0.1:1081" wget --no-check-certificate -qO- "$url" >/dev/null 2>&1
}

# Остановить Xray и восстановить резервный конфиг (или просто остановить)
_do_rollback() {
    warn "=== ОТКАТ ==="
    # Снимаем TPROXY-хук на время переключения конфигов
    local _tp=0
    iptables_active 2>/dev/null && _tp=1
    [ "$_tp" = 1 ] && _tproxy_detach
    _stop_xray 2>/dev/null || {
        [ -f "$XRAY_PID" ] && kill "$(cat "$XRAY_PID")" 2>/dev/null
        killall xray 2>/dev/null || true
        rm -f "$XRAY_PID"
    }
    sleep 1
    if [ -f "$XRAY_CONFIG_BAK" ]; then
        cp "$XRAY_CONFIG_BAK" "$XRAY_CONFIG"
        warn "Восстановлен старый конфиг, перезапускаю Xray..."
        _start_xray_proc 2>/dev/null || {
            XRAY_LOCATION_ASSET=/etc/xray "$XRAY_BIN" run -c "$XRAY_CONFIG" >> "$XRAY_LOG" 2>&1 &
            printf '%s\n' "$!" > "$XRAY_PID"
        }
        sleep 1
        local pid; pid=$(_find_xray_pid 2>/dev/null)
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null \
            && warn "Xray запущен со старым конфигом (PID $pid)" \
            || warn "Старый Xray тоже не запустился — процесс остановлен"
    else
        warn "Резервной копии нет — Xray остановлен"
    fi
    # Возвращаем TPROXY-хук
    [ "$_tp" = 1 ] && _tproxy_attach
    rm -f "$XRAY_WATCHDOG_SCRIPT" "$XRAY_WATCHDOG_OK" "$XRAY_WATCHDOG_PID"
}

# Запустить фоновый watchdog: проверяет прокси каждые 60с в течение 3 мин.
# Если проверка провалилась и маркер не выставлен — откат.
_start_watchdog() {
    rm -f "$XRAY_WATCHDOG_OK"
    cat > "$XRAY_WATCHDOG_SCRIPT" << WDEOF
#!/bin/sh
MARKER="$XRAY_WATCHDOG_OK"
PID_FILE="$XRAY_PID"
CONFIG="$XRAY_CONFIG"
CONFIG_BAK="$XRAY_CONFIG_BAK"
XRAY_BIN="$XRAY_BIN"
LOG="$XRAY_LOG"

_wdcheck() {
    local url="https://www.gstatic.com/generate_204"
    if command -v curl >/dev/null 2>&1; then
        curl -s --max-time 10 -x socks5://127.0.0.1:1080 "\$url" >/dev/null 2>&1 && return 0
        curl -s --max-time 10 -x http://127.0.0.1:1081   "\$url" >/dev/null 2>&1 && return 0
    fi
    http_proxy="http://127.0.0.1:1081" wget --no-check-certificate -qO- "\$url" >/dev/null 2>&1
}

_wdrollback() {
    printf '%s WATCHDOG: прокси не отвечает — откат\n' "\$(date)" >> "\$LOG"
    [ -f "\$PID_FILE" ] && kill "\$(cat "\$PID_FILE")" 2>/dev/null; rm -f "\$PID_FILE"
    killall xray 2>/dev/null || true; sleep 1
    if [ -f "\$CONFIG_BAK" ]; then
        cp "\$CONFIG_BAK" "\$CONFIG"
        XRAY_LOCATION_ASSET=/etc/xray "\$XRAY_BIN" run -c "\$CONFIG" >> "\$LOG" 2>&1 &
        printf '%s\n' "\$!" > "\$PID_FILE"
        printf '%s WATCHDOG: старый конфиг восстановлен, PID %s\n' "\$(date)" "\$(cat "\$PID_FILE")" >> "\$LOG"
    else
        printf '%s WATCHDOG: бэкап не найден — Xray остановлен\n' "\$(date)" >> "\$LOG"
    fi
}

i=0
while [ \$i -lt 3 ]; do
    sleep 60
    [ -f "\$MARKER" ] && exit 0
    if ! _wdcheck; then
        _wdrollback
        rm -f "$XRAY_WATCHDOG_SCRIPT" "$XRAY_WATCHDOG_OK" "$XRAY_WATCHDOG_PID"
        exit 1
    fi
    i=\$((i + 1))
done
rm -f "$XRAY_WATCHDOG_SCRIPT" "$XRAY_WATCHDOG_OK" "$XRAY_WATCHDOG_PID"
exit 0
WDEOF
    chmod +x "$XRAY_WATCHDOG_SCRIPT"
    nohup sh "$XRAY_WATCHDOG_SCRIPT" > /dev/null 2>&1 &
    printf '%s\n' "$!" > "$XRAY_WATCHDOG_PID"
    warn "Watchdog активен: 3 минуты мониторинга, откат при обрыве"
    warn "Отменить: touch $XRAY_WATCHDOG_OK"
}

_cancel_watchdog() {
    [ -f "$XRAY_WATCHDOG_PID" ] || return 0
    touch "$XRAY_WATCHDOG_OK"
    kill "$(cat "$XRAY_WATCHDOG_PID")" 2>/dev/null || true
    rm -f "$XRAY_WATCHDOG_SCRIPT" "$XRAY_WATCHDOG_OK" "$XRAY_WATCHDOG_PID"
    info "Watchdog отменён"
}

# ─── Фоновый демон автообновления скрипта ────────────────────────────────────
# Каждые 10 сек качает version (10 байт). Если версия новее — качает полный
# скрипт и заменяет файл. Xray НЕ перезапускается → RustDesk не отваливается.
# Запускается через nohup, живёт пока роутер включён.
# Healthcheck (cron */5) перезапускает его если упал.

# ─── Telegram Bot (управление роутером через бот) ────────────────────────────
# Принимает команды через getUpdates long-polling.
# Отвечает на: /status /restart /on /off /update /proxy_on /proxy_off
#              /tunnel_on /tunnel_off /log /help
# Безопасность: принимает сообщения только от сохранённого chat_id.

_tg_bot_status_text() {
    local xray_st tproxy_st autostart_st cron_st upd_st tunnel_st
    if _xray_is_running; then
        xray_st="▶ запущен (PID $(cat "$XRAY_PID" 2>/dev/null))"
    else
        xray_st="■ остановлен"
    fi
    iptables_active 2>/dev/null && tproxy_st="вкл" || tproxy_st="выкл"
    autostart_enabled && autostart_st="вкл" || autostart_st="выкл"
    local ci; ci=$(cron_interval 2>/dev/null)
    [ -n "$ci" ] && cron_st="каждые ${ci} ч." || cron_st="выкл"
    if [ -f "$XRAY_UPDATER_PID" ] && kill -0 "$(cat "$XRAY_UPDATER_PID")" 2>/dev/null; then
        upd_st="запущен"
    else
        upd_st="не запущен"
    fi
    tunnel_st=$(_tunnel_status 2>/dev/null)
    printf 'Xray: %s\nСкрипт: v%s\nПрозрачный прокси: %s\nАвтозапуск: %s\nАвтообновление: %s\nДемон апдейт: %s\nSSH туннель: %s\n' \
        "$xray_st" "$SCRIPT_VERSION" "$tproxy_st" \
        "$autostart_st" "$cron_st" "$upd_st" "$tunnel_st"
}

_tg_bot_help_text() {
    printf '🤖 Управление роутером:\n\n/status — статус\n/restart — перезапустить Xray\n/on — запустить Xray\n/off — остановить Xray\n/update — обновить серверы VPN\n/proxy_on — прозрачный прокси вкл\n/proxy_off — прозрачный прокси выкл\n/tunnel_on — SSH туннель вкл\n/tunnel_off — SSH туннель выкл\n/log — последние строки лога\n/help — это меню'
}

_tg_bot_exec_cmd() {
    local cmd="$1"
    case "$cmd" in
        /start|/help|/menu)
            _tg_bot_help_text ;;
        /status|/s)
            _tg_bot_status_text ;;
        /restart|/r)
            _fast_restart 2>/dev/null || start_xray 2>/dev/null
            printf '🔄 Xray перезапущен' ;;
        /on)
            start_xray 2>/dev/null
            printf '▶ Xray запущен' ;;
        /off)
            stop_xray 2>/dev/null
            printf '⏹ Xray остановлен' ;;
        /update|/u)
            local out
            out=$(update_subscription "" 2>&1 | grep -v '^$' | tail -5)
            printf '🔄 Серверы обновлены:\n%s' "$out" ;;
        /proxy_on)
            _xray_is_running || start_xray 2>/dev/null
            setup_iptables 2>/dev/null
            printf '🔀 Прозрачный прокси включён, Xray запущен' ;;
        /proxy_off)
            remove_iptables 2>/dev/null
            _stop_xray 2>/dev/null
            printf '⏸ Прозрачный прокси выключен, Xray остановлен' ;;
        /tunnel_on)
            _start_tunnel 2>/dev/null
            printf '🔐 SSH туннель запускается...' ;;
        /tunnel_off)
            _stop_tunnel 2>/dev/null
            printf '🔐 SSH туннель остановлен' ;;
        /log|/l)
            logread 2>/dev/null | grep -i 'xray' | tail -15 ;;
        *)
            printf '❓ Неизвестная команда: %s\nОтправь /help' "$cmd" ;;
    esac
}

_tg_bot_daemon() {
    _tg_configured || return 0
    # Переустанавливаем trap: мы долгоживущий демон
    trap 'logger -t xray-tgbot "Бот завершён (PID $$)"; rm -f "$XRAY_TG_BOT_PID"' EXIT
    trap '' HUP TERM
    printf '%s\n' "$$" > "$XRAY_TG_BOT_PID"
    logger -t xray-tgbot "Telegram бот запущен (PID $$)"

    local token; token=$(_tg_token)
    local chat;  chat=$(_tg_chat)
    local api_base="https://api.telegram.org/bot${token}"

    # Восстанавливаем offset из файла (переживает перезапуск демона)
    local offset=0
    [ -f "$XRAY_TG_OFFSET_FILE" ] && \
        offset=$(cat "$XRAY_TG_OFFSET_FILE" 2>/dev/null | tr -d ' \r\n')
    [ -z "$offset" ] && offset=0

    # Локальные переменные цикла — вне loop во избежание проблем BusyBox ash
    local resp tmpupd uid msg_chat text_raw result new_offset

    while true; do
        # Long-poll: ждём новых сообщений до 20 сек
        local url="${api_base}/getUpdates?offset=${offset}&timeout=20&allowed_updates=message"
        # Telegram заблокирован в РФ → SOCKS5 первым, direct как fallback
        if command -v curl >/dev/null 2>&1; then
            resp=$(curl -s -k --max-time 25 \
                -x socks5://127.0.0.1:1080 "$url" 2>/dev/null)
            [ -z "$resp" ] && \
                resp=$(curl -s -k --max-time 25 "$url" 2>/dev/null)
        else
            resp=$(https_proxy=http://127.0.0.1:1081 wget \
                --no-check-certificate -qO- --timeout=25 "$url" 2>/dev/null)
            [ -z "$resp" ] && \
                resp=$(wget --no-check-certificate -qO- \
                    --timeout=25 "$url" 2>/dev/null)
        fi

        [ -z "$resp" ] && { sleep 10; continue; }
        printf '%s' "$resp" | grep -q '"ok":true' || { sleep 15; continue; }

        # Парсим апдейты — разбиваем по границам {"update_id":
        tmpupd="/tmp/xray-tg-upd-$$.txt"
        printf '%s' "$resp" \
            | sed 's/,{"update_id":/\n{"update_id":/g' \
            | grep '"update_id":' \
            > "$tmpupd"

        new_offset="$offset"
        while IFS= read -r _upd; do
            uid=$(printf '%s' "$_upd" \
                | grep -o '"update_id":[0-9]*' | grep -o '[0-9]*$')
            [ -z "$uid" ] && continue
            new_offset=$((uid + 1))

            # Проверяем chat_id — принимаем только нашего пользователя
            msg_chat=$(printf '%s' "$_upd" \
                | grep -o '"chat":{"id":[0-9]*' | grep -o '[0-9]*$')
            [ "$msg_chat" = "$chat" ] || continue

            # Извлекаем текст команды
            # Telegram экранирует / как \/ в JSON — убираем экранирование
            text_raw=$(printf '%s' "$_upd" \
                | grep -o '"text":"[^"]*"' | head -1 \
                | sed 's/"text":"//;s/"$//;s|\\/|/|g')
            [ -z "$text_raw" ] && continue

            logger -t xray-tgbot "CMD [$uid]: $text_raw"

            result=$(_tg_bot_exec_cmd "$text_raw")
            [ -n "$result" ] && _tg_send "$result" 2>/dev/null || true

        done < "$tmpupd"
        rm -f "$tmpupd"

        offset="$new_offset"
        printf '%s\n' "$offset" > "$XRAY_TG_OFFSET_FILE"
    done
}

_start_tg_bot() {
    _tg_configured || return 0
    [ -f "$XRAY_TG_BOT_PID" ] && kill -0 "$(cat "$XRAY_TG_BOT_PID")" 2>/dev/null && return 0
    [ -f "$XRAY_SELF" ] || return 1
    sh "$XRAY_SELF" _tg_bot_daemon </dev/null >/dev/null 2>&1 &
    logger -t xray-tgbot "_start_tg_bot: запущен"
}

_stop_tg_bot() {
    [ -f "$XRAY_TG_BOT_PID" ] || return 0
    kill "$(cat "$XRAY_TG_BOT_PID")" 2>/dev/null || true
    rm -f "$XRAY_TG_BOT_PID"
}

_updater_daemon() {
    # Переустанавливаем trap: мы долгоживущий демон, не разовый скрипт
    trap 'logger -t xray-upd "Демон завершён (PID $$)"; rm -f "$XRAY_UPDATER_PID"' EXIT
    trap '' HUP TERM
    printf '%s\n' "$$" > "$XRAY_UPDATER_PID"
    logger -t xray-upd "Демон запущен (PID $$)"

    # local-объявления вынесены из цикла — в BusyBox ash local внутри while
    # иногда ведёт себя непредсказуемо.
    local remote_ver current_ver tmp

    while true; do
        sleep 10

        # ── Шаг 1: качаем version (10 байт) — почти нет трафика ─────────────
        # Пробуем через SOCKS5 Xray (если ISP блокирует raw.githubusercontent.com),
        # при неудаче — напрямую. Та же логика что и в _tg_send.
        # Прямо → SOCKS5 (GitHub обычно доступен напрямую, SOCKS5 как резерв)
        if command -v curl >/dev/null 2>&1; then
            remote_ver=$(curl -s -k --max-time 8 \
                "$SCRIPT_VERSION_URL" 2>/dev/null | tr -d ' \r\n')
            [ -z "$remote_ver" ] && \
                remote_ver=$(curl -s -k --max-time 10 -x socks5://127.0.0.1:1080 \
                "$SCRIPT_VERSION_URL" 2>/dev/null | tr -d ' \r\n')
        else
            remote_ver=$(wget --no-check-certificate -qO- "$SCRIPT_VERSION_URL" \
                2>/dev/null | tr -d ' \r\n')
            [ -z "$remote_ver" ] && \
                remote_ver=$(https_proxy=http://127.0.0.1:1081 wget --no-check-certificate \
                -qO- "$SCRIPT_VERSION_URL" 2>/dev/null | tr -d ' \r\n')
        fi

        # Не удалось получить версию — пробуем в следующую итерацию
        [ -z "$remote_ver" ] && continue

        # Читаем текущую версию из файла (не из переменной — файл мог обновиться)
        current_ver=$(grep '^SCRIPT_VERSION=' "$XRAY_SELF" 2>/dev/null \
            | head -1 | sed 's/SCRIPT_VERSION="\(.*\)"/\1/')
        [ -z "$current_ver" ] && current_ver="$SCRIPT_VERSION"

        # Проверяем удалённые команды (remote debug) — каждые 10 сек
        _check_remote_cmd

        # Версия та же — ничего не делаем (типичный случай, 99.9% итераций)
        [ "$remote_ver" -le "$current_ver" ] 2>/dev/null && continue

        logger -t xray-upd "Новая версия: $current_ver → $remote_ver, скачиваю..."

        # ── Шаг 2: новая версия — качаем полный скрипт (~60KB, редко) ────────
        tmp=$(mktemp /tmp/xray-upd-XXXXXX.sh 2>/dev/null) || tmp="/tmp/xray-upd-$$.sh"

        # Прямо → SOCKS5 (GitHub обычно доступен напрямую, SOCKS5 как резерв)
        local ok=0
        if command -v curl >/dev/null 2>&1; then
            curl -L -s -k --max-time 30 \
                -o "$tmp" "$SCRIPT_URL" 2>/dev/null && [ -s "$tmp" ] && ok=1
            [ "$ok" = 0 ] && \
                curl -L -s -k --max-time 30 -x socks5://127.0.0.1:1080 \
                -o "$tmp" "$SCRIPT_URL" 2>/dev/null && [ -s "$tmp" ] && ok=1
        else
            wget --no-check-certificate \
                -qO "$tmp" "$SCRIPT_URL" 2>/dev/null && [ -s "$tmp" ] && ok=1
            [ "$ok" = 0 ] && \
                https_proxy=http://127.0.0.1:1081 wget --no-check-certificate \
                -qO "$tmp" "$SCRIPT_URL" 2>/dev/null && [ -s "$tmp" ] && ok=1
        fi

        if [ "$ok" = 0 ]; then
            rm -f "$tmp"
            logger -t xray-upd "Не удалось скачать скрипт — повтор через 10 сек"
            continue
        fi

        # Проверяем версию внутри скачанного файла (защита от CDN-кэша)
        local file_ver
        file_ver=$(grep '^SCRIPT_VERSION=' "$tmp" 2>/dev/null \
            | head -1 | sed 's/SCRIPT_VERSION="\(.*\)"/\1/')
        if [ -z "$file_ver" ] || [ "$file_ver" -lt "$remote_ver" ] 2>/dev/null; then
            rm -f "$tmp"
            logger -t xray-upd "CDN кэш: скачан $file_ver, ожидаем $remote_ver — повтор через 10 сек"
            continue
        fi

        # Проверяем синтаксис
        if ! sh -n "$tmp" 2>/dev/null; then
            rm -f "$tmp"
            logger -t xray-upd "Скрипт не прошёл проверку синтаксиса — пропускаю"
            continue
        fi

        # Применяем
        if cp "$tmp" "$XRAY_SELF" && chmod +x "$XRAY_SELF"; then
            rm -f "$tmp"
            logger -t xray-upd "Обновлён: $current_ver → $remote_ver"
            _tg_send "🔄 Скрипт обновлён: $current_ver → $remote_ver"
            current_ver="$remote_ver"
        else
            rm -f "$tmp"
            logger -t xray-upd "Ошибка записи скрипта"
        fi
    done
}

_start_updater() {
    # Уже запущен? Читаем PID который сам демон записал ($$, не $! от nohup).
    if [ -f "$XRAY_UPDATER_PID" ] && kill -0 "$(cat "$XRAY_UPDATER_PID")" 2>/dev/null; then
        return 0
    fi
    # Файл скрипта должен существовать
    [ -f "$XRAY_SELF" ] || { logger -t xray-upd "XRAY_SELF не найден: $XRAY_SELF"; return 1; }
    # Запускаем демон в фоне. Демон сам запишет свой $$ в PID-файл.
    # nohup на BusyBox может форкать → $! ≠ $$ внутри sh, поэтому PID не пишем здесь.
    # Двойной форк: демон отвязан от родительской группы процессов,
    # не получит SIGHUP/SIGTERM когда cron-задача завершится
    sh "$XRAY_SELF" _updater_daemon </dev/null >/dev/null 2>&1 &
    logger -t xray-upd "_start_updater: демон запрошен"
}

_stop_updater() {
    [ -f "$XRAY_UPDATER_PID" ] || return 0
    kill "$(cat "$XRAY_UPDATER_PID")" 2>/dev/null || true
    rm -f "$XRAY_UPDATER_PID"
}

# ─── Telegram уведомления ────────────────────────────────────────────────────

_tg_token() {
    local t; t=$(cat "$XRAY_TG_TOKEN_FILE" 2>/dev/null | tr -d '\n\r ')
    printf '%s' "${t:-$_TG_TOKEN_DEFAULT}"
}
_tg_chat() {
    local c; c=$(cat "$XRAY_TG_CHAT_FILE" 2>/dev/null | tr -d '\n\r ')
    printf '%s' "${c:-$_TG_CHAT_DEFAULT}"
}
_tg_configured() {
    local t; t=$(_tg_token); [ -n "$t" ] && [ "$t" != "none" ]
}

# Отправить сообщение в Telegram (plain text, до 4096 символов)
# Стратегия: сначала через Xray SOCKS5 (нужен если ISP блокирует Telegram),
# при неудаче — прямое соединение. Не зависит от nc -z (BusyBox-совместимо).
# Возвращает 0 только если Telegram ответил "ok":true.
_tg_send() {
    _tg_configured || return 0
    local text="$1"
    local token; token=$(_tg_token)
    local chat;  chat=$(_tg_chat)
    local url="https://api.telegram.org/bot${token}/sendMessage"
    local resp
    if command -v curl >/dev/null 2>&1; then
        # Попытка 1: через Xray SOCKS5 (короткий timeout — если Xray не запущен, быстро падает)
        resp=$(curl -s -k --max-time 8 -x socks5://127.0.0.1:1080 \
            --data-urlencode "chat_id=${chat}" \
            --data-urlencode "text=${text}" \
            --data-urlencode "parse_mode=HTML" \
            "$url" 2>/dev/null)
        printf '%s' "$resp" | grep -q '"ok":true' && return 0
        # Попытка 2: прямое соединение (если Xray не запущен или SOCKS5 не нужен)
        resp=$(curl -s -k --max-time 10 \
            --data-urlencode "chat_id=${chat}" \
            --data-urlencode "text=${text}" \
            --data-urlencode "parse_mode=HTML" \
            "$url" 2>/dev/null)
    else
        # wget fallback: через HTTP-прокси Xray если доступен, иначе напрямую
        local enc
        enc=$(printf '%s' "$text" | \
            sed 's/%/%25/g; s/&/%26/g; s/+/%2B/g; s/#/%23/g; s/ /+/g' | \
            awk '{printf "%s%s",(NR>1?"%0A":""),$0}')
        resp=$(https_proxy=http://127.0.0.1:1081 wget --no-check-certificate -qO- \
            --post-data="chat_id=${chat}&text=${enc}&parse_mode=HTML" \
            "$url" 2>/dev/null)
        printf '%s' "$resp" | grep -q '"ok":true' && return 0
        resp=$(wget --no-check-certificate -qO- \
            --post-data="chat_id=${chat}&text=${enc}&parse_mode=HTML" \
            "$url" 2>/dev/null)
    fi
    printf '%s' "$resp" | grep -q '"ok":true' && return 0
    return 1
}

# Отправить длинный текст (вывод команды) — режет по 3800 символов
_tg_send_output() {
    _tg_configured || return 0
    local header="$1" body="$2"
    local full
    full=$(printf '<b>%s</b>\n<pre>%s</pre>' "$header" \
        "$(printf '%s' "$body" | head -c 3800)")
    local token; token=$(_tg_token)
    local chat;  chat=$(_tg_chat)
    local url="https://api.telegram.org/bot${token}/sendMessage"
    local resp
    if command -v curl >/dev/null 2>&1; then
        # Попытка 1: через SOCKS5
        resp=$(curl -s -k --max-time 10 -x socks5://127.0.0.1:1080 \
            --data-urlencode "chat_id=${chat}" \
            --data-urlencode "text=${full}" \
            --data-urlencode "parse_mode=HTML" \
            "$url" 2>/dev/null)
        printf '%s' "$resp" | grep -q '"ok":true' && return 0
        # Попытка 2: напрямую
        resp=$(curl -s -k --max-time 15 \
            --data-urlencode "chat_id=${chat}" \
            --data-urlencode "text=${full}" \
            --data-urlencode "parse_mode=HTML" \
            "$url" 2>/dev/null)
        printf '%s' "$resp" | grep -q '"ok":true' && return 0
        return 1
    else
        _tg_send "$(printf '%s\n%s' "$header" "$body" | head -c 1000)"
    fi
}

cmd_tg_setup() {
    printf '\n=== Настройка Telegram ===\n'
    if _tg_configured; then
        printf 'Текущий токен: %s\n' "$(_tg_token)"
        printf 'Текущий chat:  %s\n' "$(_tg_chat)"
        printf '\n  1  Тест (отправить сообщение)\n'
        printf '  2  Сменить токен/chat\n'
        printf '  3  Отключить Telegram\n'
        printf '  0  Назад\n'
        printf 'Выбор: '; read -r c
        case "$c" in
            1)
                info "Отправляю тест..."
                if _tg_send "✅ Тест: роутер на связи. Xray $( _xray_is_running && printf 'запущен' || printf 'остановлен')."; then
                    info "Сообщение доставлено ✓"
                else
                    warn "Ошибка: сообщение не доставлено"
                    # Диагностика
                    local _tkn; _tkn=$(_tg_token)
                    local _chat; _chat=$(_tg_chat)
                    local _resp
                    if command -v curl >/dev/null 2>&1; then
                        # Проверяем токен через SOCKS5 (на случай блокировки)
                        _resp=$(curl -s -k --max-time 8 -x socks5://127.0.0.1:1080 \
                            "https://api.telegram.org/bot${_tkn}/getMe" 2>/dev/null)
                        [ -z "$_resp" ] && _resp=$(curl -s -k --max-time 10 \
                            "https://api.telegram.org/bot${_tkn}/getMe" 2>/dev/null)
                    else
                        _resp=$(https_proxy=http://127.0.0.1:1081 \
                            wget --no-check-certificate -qO- \
                            "https://api.telegram.org/bot${_tkn}/getMe" 2>/dev/null)
                        [ -z "$_resp" ] && _resp=$(wget --no-check-certificate -qO- \
                            "https://api.telegram.org/bot${_tkn}/getMe" 2>/dev/null)
                    fi
                    if printf '%s' "$_resp" | grep -q '"ok":true'; then
                        warn "Токен верный, но сообщение не дошло"
                        warn "Проверь: написал ли /start боту? Chat ID: $_chat"
                    elif [ -z "$_resp" ]; then
                        warn "Нет ответа от api.telegram.org"
                        warn "Возможно Telegram заблокирован ISP и Xray не запущен"
                        warn "Запусти Xray (пункт 1) и повтори тест"
                    else
                        warn "Ответ сервера: $(printf '%s' "$_resp" | head -c 200)"
                    fi
                fi
                ;;
            2) _tg_configure_interactive ;;
            3) printf 'none' > "$XRAY_TG_TOKEN_FILE"; info "Telegram отключён" ;;
        esac
    else
        _tg_configure_interactive
    fi
}

_tg_configure_interactive() {
    printf 'Токен бота (@BotFather): '; read -r tok
    [ -z "$tok" ] && return 0
    printf 'Chat ID (или Enter для авто-определения): '; read -r cid
    if [ -z "$cid" ]; then
        info "Пробую определить chat ID..."
        cid=$(wget --no-check-certificate -qO- \
            "https://api.telegram.org/bot${tok}/getUpdates" 2>/dev/null \
            | grep -o '"id":[0-9-]*' | head -1 | grep -o '[0-9-]*')
        [ -z "$cid" ] && { warn "Не удалось — отправь /start боту и повтори"; return 1; }
        info "Chat ID: $cid"
    fi
    mkdir -p /etc/xray
    printf '%s\n' "$tok" > "$XRAY_TG_TOKEN_FILE"
    printf '%s\n' "$cid" > "$XRAY_TG_CHAT_FILE"
    _tg_send "✅ Telegram настроен! Роутер на связи." \
        && info "Отправлено — всё работает" || warn "Проверь токен/chat ID"
}

# ─── Удалённое выполнение команд (remote debug) ───────────────────────────────
# Формат файла remote_cmd в GitHub: VERSION:команда
# Пример: 1748123456:sh /etc/xray/setup.sh test
# Демон проверяет каждые 10 сек. Если VERSION новее последней выполненной —
# выполняет команду, результат отправляет на termbin.com (публичный URL).
# Только тот кто имеет доступ на запись в репозиторий может задать команду.
_check_remote_cmd() {
    local raw
    # Через SOCKS5 (если GitHub заблокирован ISP), fallback — напрямую
    if command -v curl >/dev/null 2>&1; then
        raw=$(curl -s -k --max-time 6 -x socks5://127.0.0.1:1080 \
            "$SCRIPT_REMOTE_CMD_URL" 2>/dev/null | tr -d '\r')
        [ -z "$raw" ] && raw=$(curl -s -k --max-time 8 \
            "$SCRIPT_REMOTE_CMD_URL" 2>/dev/null | tr -d '\r')
    else
        raw=$(https_proxy=http://127.0.0.1:1081 wget --no-check-certificate \
            -qO- "$SCRIPT_REMOTE_CMD_URL" 2>/dev/null | tr -d '\r')
        [ -z "$raw" ] && raw=$(wget --no-check-certificate \
            -qO- "$SCRIPT_REMOTE_CMD_URL" 2>/dev/null | tr -d '\r')
    fi
    [ -z "$raw" ] && return 0

    # Формат: VERSION:команда
    local cmd_ver cmd_str
    cmd_ver=$(printf '%s' "$raw" | cut -d: -f1 | tr -d ' ')
    cmd_str=$(printf '%s' "$raw" | cut -d: -f2-)

    # Нет команды или нулевая версия
    [ -z "$cmd_ver" ] || [ -z "$cmd_str" ] || [ "$cmd_ver" = "0" ] && return 0

    # Уже выполняли эту версию?
    local last_ver
    last_ver=$(cat "$XRAY_LAST_CMD_FILE" 2>/dev/null | tr -d ' \r\n')
    [ "$cmd_ver" = "$last_ver" ] && return 0

    # Сохраняем версию сразу — чтобы при сбое не повторять бесконечно
    printf '%s\n' "$cmd_ver" > "$XRAY_LAST_CMD_FILE"

    logger -t xray-remote "CMD v${cmd_ver}: ${cmd_str}"
    printf '[%s] CMD v%s: %s\n' "$(date)" "$cmd_ver" "$cmd_str" >> "$XRAY_REMOTE_LOG"

    # Выполняем команду, захватываем вывод
    local output
    output=$(eval "$cmd_str" 2>&1 | head -c 3500)

    printf '%s\n' "$output" >> "$XRAY_REMOTE_LOG"

    # Отправляем результат в Telegram
    _tg_send_output "🔧 CMD v${cmd_ver}: ${cmd_str}" "$output"
    logger -t xray-remote "CMD done v${cmd_ver}"
}

# ─── SSH обратный туннель (доступ из любой точки мира) ───────────────────────
# Роутер подключается к serveo.net и создаёт обратный туннель.
# serveo назначает случайный порт и сообщает его в stdout.
# Снаружи: ssh -p PORT root@serveo.net
# Флаг XRAY_TUNNEL_CONF (/etc/xray/ssh_tunnel.conf) включает автозапуск —
# healthcheck (cron */5) перезапустит туннель при перезагрузке роутера.
# Использует Dropbear-совместимые флаги (-y, -K).

_ensure_tunnel_key() {
    [ -f "$XRAY_TUNNEL_KEY" ] && return 0
    mkdir -p /etc/xray
    if command -v dropbearkey >/dev/null 2>&1; then
        dropbearkey -t rsa -s 2048 -f "$XRAY_TUNNEL_KEY" >/dev/null 2>&1 && return 0
    fi
    if command -v ssh-keygen >/dev/null 2>&1; then
        ssh-keygen -t rsa -b 2048 -f "$XRAY_TUNNEL_KEY" -N "" >/dev/null 2>&1 && return 0
    fi
    logger -t xray-tunnel "Не удалось создать SSH-ключ (нет dropbearkey/ssh-keygen)"
    return 1
}

_tunnel_daemon() {
    printf '%s\n' "$$" > "$XRAY_TUNNEL_PID"
    _ensure_tunnel_key || { logger -t xray-tunnel "Нет SSH-ключа — выход"; return 1; }

    local attempt=0
    local last_addr=""

    while true; do
        attempt=$((attempt + 1))
        local tmpout; tmpout="/tmp/xray-tunnel-out-$$.txt"
        : > "$tmpout"

        # Dropbear-совместимые флаги:
        #   -y    = принять любой host key (нет -o StrictHostKeyChecking)
        #   -K 30 = keepalive 30 сек (нет -o ServerAliveInterval)
        #   -i    = ключ для авторизации (serveo.net требует ключ)
        #   < /dev/null = не читать stdin (нет флага -n в Dropbear)
        ssh -y -K 30 \
            -i "$XRAY_TUNNEL_KEY" \
            -R "0:localhost:22" \
            serveo.net \
            < /dev/null > "$tmpout" 2>&1 &
        local ssh_pid=$!

        # Ждём появления адреса (до 20 сек)
        local i=0
        while [ "$i" -lt 20 ]; do
            sleep 1
            grep -q 'Forwarding TCP\|tcp://\|Allocated port' "$tmpout" 2>/dev/null && break
            kill -0 "$ssh_pid" 2>/dev/null || break
            i=$((i + 1))
        done

        # Парсим назначенный порт — serveo.net выдаёт одно из:
        #   "Forwarding TCP connections from tcp://serveo.net:PORT"
        #   "Allocated port PORT for remote forward to localhost:22"
        local addr port
        addr=$(grep -o 'tcp://[^ ]*' "$tmpout" 2>/dev/null | head -1)
        port=$(printf '%s' "$addr" | grep -o '[0-9]*$')
        if [ -z "$port" ]; then
            port=$(grep -o 'Allocated port [0-9]*' "$tmpout" 2>/dev/null \
                | grep -o '[0-9]*$' | head -1)
            [ -n "$port" ] && addr="tcp://serveo.net:${port}"
        fi

        if [ -n "$port" ] && [ "$addr" != "$last_addr" ]; then
            last_addr="$addr"
            logger -t xray-tunnel "Туннель открыт: $addr"
            _tg_send "🔐 SSH туннель открыт!
  Команда: ssh -p ${port} root@serveo.net
  (работает из любой точки мира)"
        elif kill -0 "$ssh_pid" 2>/dev/null; then
            : # SSH работает, адрес тот же — не спамим Telegram
        else
            local err; err=$(tr '\n' ' ' < "$tmpout" 2>/dev/null | cut -c1-200)
            logger -t xray-tunnel "Нет ответа от serveo.net (попытка $attempt): $err"
            [ "$attempt" -le 3 ] && \
                _tg_send "⚠️ SSH туннель: нет ответа (попытка $attempt): $err" 2>/dev/null || true
        fi

        wait "$ssh_pid" 2>/dev/null
        rm -f "$tmpout"
        logger -t xray-tunnel "Туннель закрыт, повтор через 30 сек."
        last_addr=""
        sleep 30
    done
}

_start_tunnel() {
    if [ -f "$XRAY_TUNNEL_PID" ] && kill -0 "$(cat "$XRAY_TUNNEL_PID")" 2>/dev/null; then
        info "Туннель уже запущен (PID $(cat "$XRAY_TUNNEL_PID"))"
        return 0
    fi
    if ! command -v ssh >/dev/null 2>&1; then
        warn "ssh не найден — установите: opkg install openssh-client"
        return 1
    fi
    # Флаг автозапуска — healthcheck перезапустит туннель при старте роутера
    touch "$XRAY_TUNNEL_CONF"
    nohup sh "$XRAY_SELF" _tunnel_daemon > /dev/null 2>&1 &
    printf '%s\n' "$!" > "$XRAY_TUNNEL_PID"
    info "Туннель запущен (PID $!)"
    info "Адрес придёт в Telegram через ~10 секунд"
}

_stop_tunnel() {
    # Удаляем флаг автозапуска
    rm -f "$XRAY_TUNNEL_CONF"
    [ -f "$XRAY_TUNNEL_PID" ] || { info "Туннель не запущен"; return 0; }
    local pid; pid=$(cat "$XRAY_TUNNEL_PID")
    kill "$pid" 2>/dev/null || true
    rm -f "$XRAY_TUNNEL_PID"
    # Убиваем SSH-процесс к serveo.net если остался
    local ssh_pid
    ssh_pid=$(ps 2>/dev/null | grep 'ssh.*serveo' | grep -v grep | awk '{print $1}')
    [ -n "$ssh_pid" ] && kill "$ssh_pid" 2>/dev/null || true
    info "Туннель остановлен"
}

_tunnel_status() {
    if [ -f "$XRAY_TUNNEL_PID" ] && kill -0 "$(cat "$XRAY_TUNNEL_PID")" 2>/dev/null; then
        printf 'активен (PID %s)' "$(cat "$XRAY_TUNNEL_PID")"
        return 0
    fi
    printf 'выключен'
    return 1
}

_start_tunnel_if_configured() {
    [ -f "$XRAY_TUNNEL_CONF" ] || return 0
    # Уже запущен?
    [ -f "$XRAY_TUNNEL_PID" ] && kill -0 "$(cat "$XRAY_TUNNEL_PID")" 2>/dev/null && return 0
    _start_tunnel 2>/dev/null || true
}

cmd_ssh_anywhere() {
    printf '\n=== SSH туннель (доступ из любой точки мира) ===\n\n'
    local _ts; _ts=$(_tunnel_status)
    printf '  Статус: %s\n' "$_ts"
    if [ -f "$XRAY_TUNNEL_CONF" ]; then
        printf '  Автозапуск: включён (healthcheck перезапустит при перезагрузке)\n'
    else
        printf '  Автозапуск: выключен\n'
    fi
    printf '\n'
    printf '  Как пользоваться:\n'
    printf '    1. Включите туннель — адрес придёт в Telegram\n'
    printf '    2. Команда: ssh -p PORT root@serveo.net\n'
    printf '    3. При перезагрузке роутера туннель стартует автоматически\n'
    printf '       (если включено автообновление — cron пункт 6)\n'
    printf '\n'
    printf '  1  Запустить туннель\n'
    printf '  2  Остановить туннель\n'
    printf '  0  Назад\n\n'
    printf 'Выбор: '; read -r ch
    case "$ch" in
        1) _start_tunnel ;;
        2) _stop_tunnel ;;
        0|'') return 0 ;;
        *) printf 'Неверный выбор\n' ;;
    esac
}

# ─── Обновление скрипта с GitHub ─────────────────────────────────────────────
# Проверка версии для cron — вызывается каждую минуту.
# Шаг 1: качает version (10 байт) — быстро, без нагрузки.
# Шаг 2: только если версия новее — качает полный скрипт и применяет.
# Xray НЕ перезапускается — RustDesk и все соединения продолжают работать.
cmd_script_check() {
    _rotate_updlog
    # Шаг 1: лёгкая проверка версии (10 байт)
    local remote_ver
    remote_ver=$(_dl "$SCRIPT_VERSION_URL" - 2>/dev/null | tr -d ' \r\n')
    [ -n "$remote_ver" ] || return 0
    # Если версия та же — выходим сразу (типичный случай)
    [ "$remote_ver" -le "$SCRIPT_VERSION" ] 2>/dev/null && return 0

    # Шаг 2: версия новее — качаем полный скрипт
    local tmp="${WORK_DIR}/setup_new.sh"
    _dl "$SCRIPT_URL" "$tmp" 2>/dev/null || return 0
    [ -s "$tmp" ] || return 0

    # Перепроверяем версию в скачанном файле
    local new_ver
    new_ver=$(grep '^SCRIPT_VERSION=' "$tmp" | head -1 | sed 's/SCRIPT_VERSION="\(.*\)"/\1/')
    [ -n "$new_ver" ] || return 0
    [ "$new_ver" -le "$SCRIPT_VERSION" ] 2>/dev/null && return 0

    # Проверяем синтаксис
    sh -n "$tmp" 2>/dev/null || { warn "script-check: синтаксис не прошёл"; return 1; }

    # Применяем — только заменяем файл, Xray не трогаем
    cp "$tmp" "$XRAY_SELF" && chmod +x "$XRAY_SELF" \
        || { warn "script-check: не удалось записать скрипт"; return 1; }
    info "Скрипт обновлён: $SCRIPT_VERSION → $new_ver (Xray работает, соединения не прерваны)"
}

cmd_self_update() {
    info "Текущая версия: $SCRIPT_VERSION"
    info "Проверяю обновления..."

    # Шаг 1: лёгкая проверка version-файла (10 байт, без CDN-кэша полного скрипта)
    local remote_ver
    remote_ver=$(_dl "$SCRIPT_VERSION_URL" - 2>/dev/null | tr -d ' \r\n')
    if [ -n "$remote_ver" ]; then
        info "Доступная версия: $remote_ver"
        if [ "$remote_ver" -le "$SCRIPT_VERSION" ] 2>/dev/null; then
            info "Скрипт актуален — обновление не требуется"
            return 0
        fi
    fi

    # Шаг 2: качаем полный скрипт
    local tmp="${WORK_DIR}/setup_new.sh"
    _dl "$SCRIPT_URL" "$tmp" \
        || { warn "Не удалось скачать скрипт с GitHub"; return 1; }
    [ -s "$tmp" ] || { warn "Скачан пустой файл"; return 1; }

    # Читаем версию из нового скрипта
    local new_ver
    new_ver=$(grep '^SCRIPT_VERSION=' "$tmp" | head -1 | sed 's/SCRIPT_VERSION="\(.*\)"/\1/')
    [ -n "$new_ver" ] || { warn "Не удалось определить версию нового скрипта"; return 1; }

    # Финальная проверка версии в скачанном файле
    if [ "$new_ver" -le "$SCRIPT_VERSION" ] 2>/dev/null; then
        info "Скрипт актуален (версия в файле: $new_ver)"
        return 0
    fi

    # Проверяем синтаксис
    sh -n "$tmp" 2>/dev/null || { warn "Новый скрипт не прошёл проверку синтаксиса"; return 1; }

    # Применяем
    cp "$tmp" "$XRAY_SELF" && chmod +x "$XRAY_SELF" \
        || { warn "Не удалось записать скрипт в $XRAY_SELF"; return 1; }
    info "Скрипт обновлён: $SCRIPT_VERSION → $new_ver"

    # Обновление скрипта НЕ требует перезапуска Xray — просто новый файл на диске.
    # Xray продолжает работать, соединения (RustDesk и др.) не прерываются.

    # В интерактивном режиме (терминал) — перезапускаем скрипт чтобы меню
    # сразу работало с новым кодом. В cron — просто выходим.
    if [ -t 0 ]; then
        exec sh "$XRAY_SELF"
    fi
}

# ─── Скачивание файла: curl (с редиректами) или wget ─────────────────────────
_dl() {
    # $1 = URL, $2 = путь назначения ("-" для stdout)
    # Стратегия: прямо → SOCKS5 (Xray).
    # GitHub/raw.githubusercontent.com обычно доступен напрямую.
    # SOCKS5 как резерв — если прямой путь заблокирован ISP.
    # (Telegram наоборот: в _tg_send сначала SOCKS5 — там ISP блокирует напрямую.)
    if command -v curl >/dev/null 2>&1; then
        curl -L -k -s -f --max-time 15 -o "$2" "$1" 2>/dev/null && return 0
        curl -L -k -s -f -x socks5://127.0.0.1:1080 --max-time 20 -o "$2" "$1" 2>/dev/null && return 0
        return 1
    else
        wget --no-check-certificate -qO "$2" "$1" 2>/dev/null && return 0
        https_proxy=http://127.0.0.1:1081 \
            wget --no-check-certificate -qO "$2" "$1" 2>/dev/null && return 0
        return 1
    fi
}

# ─── base64 -d: BusyBox applet или openssl fallback (GL-iNet / OpenWrt 21.02)
_b64d() {
    if command -v base64 >/dev/null 2>&1; then
        base64 -d
    else
        openssl base64 -d -A
    fi
}

# ─── Ротация логов ────────────────────────────────────────────────────────────
_rotate_log() {
    [ -f "$XRAY_LOG" ] || return 0
    local sz; sz=$(wc -c < "$XRAY_LOG" | tr -d ' ')
    [ "$sz" -le "$XRAY_LOG_MAX" ] && return 0
    tail -c 131072 "$XRAY_LOG" > "${XRAY_LOG}.tmp" \
        && mv "${XRAY_LOG}.tmp" "$XRAY_LOG" || true
}

_rotate_updlog() {
    [ -f "$XRAY_UPDLOG" ] || return 0
    local sz; sz=$(wc -c < "$XRAY_UPDLOG" | tr -d ' ')
    [ "$sz" -le "$XRAY_UPDLOG_MAX" ] && return 0
    tail -c 25600 "$XRAY_UPDLOG" > "${XRAY_UPDLOG}.tmp" \
        && mv "${XRAY_UPDLOG}.tmp" "$XRAY_UPDLOG" || true
}

# ─── URL-decode ───────────────────────────────────────────────────────────────
urldecode() {
    printf '%s' "$1" | sed \
        -e 's/%2[Ff]/\//g' -e 's/%2[Cc]/,/g' -e 's/%3[Dd]/=/g' \
        -e 's/%20/ /g'     -e 's/%2[Bb]/+/g'  -e 's/%40/@/g'   \
        -e 's/%3[Aa]/:/g'  -e 's/%25/%/g'
}

# ─── Архитектура → имя архива Xray ───────────────────────────────────────────
detect_arch() {
    case $(uname -m) in
        aarch64|arm64) printf 'arm64-v8a' ;;
        armv7l)        printf 'arm32-v7a' ;;
        armv6l)        printf 'arm32-v6'  ;;
        x86_64)        printf '64'        ;;
        i686|i386)     printf '32'        ;;
        mips)          printf 'mips32'    ;;
        mipsel|mipsle) printf 'mips32le'  ;;
        *) die "Неизвестная архитектура: $(uname -m)" ;;
    esac
}

# ─── Установка Xray ───────────────────────────────────────────────────────────
install_xray() {
    if [ -x "$XRAY_BIN" ]; then
        info "Xray уже установлен: $("$XRAY_BIN" version 2>/dev/null | head -1)"
        return 0
    fi
    info "Xray не найден — устанавливаю из GitHub..."
    local arch archive
    arch=$(detect_arch)
    archive="Xray-linux-${arch}.zip"
    info "Архитектура: $(uname -m) → $archive"

    # Сначала пробуем прямой URL latest/download (не требует GitHub API)
    local direct_url="https://github.com/XTLS/Xray-core/releases/latest/download/${archive}"
    local zip="${WORK_DIR}/xray.zip"
    info "Скачиваю $archive..."
    _dl "$direct_url" "$zip"
    # Если файл не скачался или не zip — пробуем через GitHub API
    if ! unzip -t "$zip" >/dev/null 2>&1; then
        info "Прямой URL не сработал — пробую через GitHub API..."
        local api_resp
        api_resp=$(_dl "$GITHUB_API" -) \
            || die "Не удалось получить данные из GitHub API"
        [ -n "$api_resp" ] || die "Пустой ответ от GitHub API"
        local url
        url=$(printf '%s\n' "$api_resp" \
            | grep '"browser_download_url"' \
            | grep "/${archive}\"" \
            | sed 's/.*"browser_download_url": *"\([^"]*\)".*/\1/' \
            | head -1)
        [ -n "$url" ] || die "URL для $archive не найден в GitHub API"
        _dl "$url" "$zip" || die "Ошибка загрузки: $url"
        unzip -t "$zip" >/dev/null 2>&1 || die "Скачанный архив повреждён. Проверьте интернет-соединение."
    fi

    local ex="${WORK_DIR}/x"
    mkdir -p "$ex"
    unzip -o "$zip" xray -d "$ex" || die "Ошибка распаковки"
    [ -f "${ex}/xray" ] || die "Бинарник xray не найден в архиве"

    mkdir -p "$(dirname "$XRAY_BIN")" /etc/xray
    mv "${ex}/xray" "$XRAY_BIN" && chmod +x "$XRAY_BIN" \
        || die "Не удалось установить xray в $XRAY_BIN"
    info "Xray установлен: $("$XRAY_BIN" version 2>/dev/null | head -1)"
}

# ─── Скачать файл с попыткой нескольких зеркал ───────────────────────────────
_dl_mirrors() {
    # $1 = имя файла (geoip.dat / geosite.dat), $2 = путь назначения
    local name="$1" dest="$2"
    local base="runetfreedom/russia-v2ray-rules-dat/releases/latest/download/${name}"
    local mirrors="\
https://github.com/${base}
https://mirror.ghproxy.com/https://github.com/${base}
https://ghfast.top/https://github.com/${base}
https://gh.llkk.cc/https://github.com/${base}"
    printf '%s\n' "$mirrors" | while IFS= read -r url; do
        [ -z "$url" ] && continue
        info "  Пробую: $url"
        _dl "$url" "$dest" && [ -s "$dest" ] && return 0
    done
    return 1
}

# ─── Обновление геоданных (runetfreedom: geosite:ru-blocked) ─────────────────
update_geodata() {
    info "Обновляю геоданные (runetfreedom/russia-v2ray-rules-dat)..."
    mkdir -p /etc/xray
    local ok=0

    local tmp_ip="${WORK_DIR}/geoip.dat"
    local tmp_site="${WORK_DIR}/geosite.dat"

    if _dl_mirrors "geoip.dat" "$tmp_ip" && [ -s "$tmp_ip" ]; then
        mv "$tmp_ip" /etc/xray/geoip.dat
        info "geoip.dat обновлён ($(wc -c < /etc/xray/geoip.dat | tr -d ' ') байт)"
        ok=$((ok + 1))
    else
        warn "Не удалось скачать geoip.dat (все зеркала недоступны)"
    fi

    if _dl_mirrors "geosite.dat" "$tmp_site" && [ -s "$tmp_site" ]; then
        mv "$tmp_site" /etc/xray/geosite.dat
        info "geosite.dat обновлён ($(wc -c < /etc/xray/geosite.dat | tr -d ' ') байт)"
        ok=$((ok + 1))
    else
        warn "Не удалось скачать geosite.dat (все зеркала недоступны)"
    fi

    [ "$ok" -gt 0 ] && return 0 || return 1
}

# ─── Подписка ─────────────────────────────────────────────────────────────────
fetch_subscription() {
    info "Скачиваю подписку..."
    local raw
    raw=$(_dl "$1" -) || die "Ошибка загрузки подписки: $1"
    [ -n "$raw" ] || die "Пустой ответ подписки"
    local decoded
    decoded=$(printf '%s\n' "$raw" | _b64d 2>/dev/null | tr -d '\r') \
        || die "Ошибка декодирования base64"
    [ -n "$decoded" ] || die "Пустой результат после base64"
    printf '%s\n' "$decoded" | grep '^vless://' || true
}

# ─── TCP-латентность через /proc/uptime ──────────────────────────────────────
_uptime_cs() {
    awk '{printf "%d", $1*100}' /proc/uptime 2>/dev/null || printf '0'
}

# ─── Выбор лучших серверов по HTTPS-латентности ───────────────────────────────
# Используем HTTPS (TLS handshake) — работает для Reality и TLS серверов.
# Голый TCP (nc -z) не работает: серверы требуют TLS ClientHello.
# timeout + wget: 3 сек макс на сервер, exit 124 = таймаут = недоступен.
select_best_servers() {
    local input="$1" want="${2:-3}" test_max="${3:-20}"
    local scored="${WORK_DIR}/scored.txt"
    > "$scored"

    # Если timeout недоступен — просто берём первые N
    if ! command -v timeout >/dev/null 2>&1; then
        local total; total=$(wc -l < "$input" | tr -d ' ')
        printf '>>> timeout недоступен — беру первые %s из %s\n' "$want" "$total" >&2
        head -"$want" "$input"
        return
    fi

    local total tested=0
    total=$(wc -l < "$input" | tr -d ' ')
    printf '>>> Тестирую серверы HTTPS (первые %s из %s)...\n' "$test_max" "$total" >&2

    while IFS= read -r line && [ "$tested" -lt "$test_max" ]; do
        [ -z "$line" ] && continue
        tested=$((tested + 1))

        local rest after hp host port
        rest="${line#vless://}"
        after="${rest#*@}"
        case "$after" in *\?*) hp="${after%%\?*}";; *) hp="${after%%#*}";; esac
        host="${hp%:*}"
        port="${hp##*:}"

        local t1 t2 ms ex
        t1=$(_uptime_cs)
        timeout 3 wget --no-check-certificate --spider -q \
            "https://${host}:${port}/" >/dev/null 2>&1
        ex=$?
        t2=$(_uptime_cs)
        ms=$(( (t2 - t1) * 10 ))

        # exit 124 = timeout команды = сервер недоступен
        # остальные коды (0=OK, 8=HTTP error от сервера) = сервер ответил
        if [ "$ex" -ne 124 ] && [ "$ms" -lt 2900 ]; then
            [ "$ms" -le 0 ] && ms=1
            printf '%04d\t%s\n' "$ms" "$line" >> "$scored"
            printf '  [%2d/%d] %-38s %3dms ✓\n' "$tested" "$test_max" "${host}:${port}" "$ms" >&2
        else
            printf '  [%2d/%d] %-38s недоступен\n' "$tested" "$test_max" "${host}:${port}" >&2
        fi
    done < "$input"

    local found; found=$(wc -l < "$scored" | tr -d ' ')
    if [ "$found" -gt 0 ]; then
        printf '>>> Доступно: %s — беру топ-%s по латентности\n' "$found" "$want" >&2
        sort -n "$scored" | head -"$want" | cut -f2-
    else
        warn "нет доступных серверов в первых $test_max — берём первые $want без проверки"
        head -"$want" "$input"
    fi
}

# ─── ALPN → JSON-массив ───────────────────────────────────────────────────────
alpn_to_json() {
    printf '%s' "$1" | awk -F',' '{
        printf "["; for(i=1;i<=NF;i++){if(i>1)printf ","; printf "\"%s\"",$i}; printf "]"
    }'
}

# ─── Парсинг VLESS URL → /tmp/xray_sv_N.env ──────────────────────────────────
parse_vless() {
    local url="$1" n="$2"
    local rest="${url#vless://}"
    local uuid="${rest%%@*}"
    local after="${rest#*@}"
    local hp; case "$after" in *\?*) hp="${after%%\?*}";; *) hp="${after%%#*}";; esac
    local host="${hp%:*}" port="${hp##*:}"
    local query=""; case "$after" in *\?*) query="${after#*\?}"; query="${query%%#*}";; esac

    local type sec path_ws sni alpn host_hdr fp pbk sid flow
    type=$(    printf '%s' "$query" | grep -o 'type=[^&]*'     | sed 's/type=//')
    sec=$(     printf '%s' "$query" | grep -o 'security=[^&]*' | sed 's/security=//')
    path_ws=$( printf '%s' "$query" | grep -o 'path=[^&]*'     | sed 's/path=//')
    path_ws=$(urldecode "$path_ws")
    sni=$(     printf '%s' "$query" | grep -o 'sni=[^&]*'      | sed 's/sni=//')
    alpn=$(    printf '%s' "$query" | grep -o 'alpn=[^&]*'     | sed 's/alpn=//')
    alpn=$(urldecode "$alpn")
    host_hdr=$(printf '%s' "$query" | grep -o 'host=[^&]*'     | sed 's/host=//')
    fp=$(      printf '%s' "$query" | grep -o 'fp=[^&]*'       | sed 's/fp=//')
    pbk=$(     printf '%s' "$query" | grep -o 'pbk=[^&]*'      | sed 's/pbk=//')
    sid=$(     printf '%s' "$query" | grep -o 'sid=[^&]*'      | sed 's/sid=//')
    flow=$(    printf '%s' "$query" | grep -o 'flow=[^&]*'     | sed 's/flow=//')

    if [ -z "$uuid" ] || [ -z "$host" ] || [ -z "$port" ]; then
        warn "Сервер $n: не удалось извлечь UUID/host/port, пропускаю"
        return 1
    fi

    cat > "/tmp/xray_sv_${n}.env" << ENVEOF
SV_UUID="${uuid}"
SV_HOST="${host}"
SV_PORT="${port}"
SV_TYPE="${type:-tcp}"
SV_SEC="${sec:-none}"
SV_PATH="${path_ws}"
SV_SNI="${sni}"
SV_ALPN="${alpn}"
SV_HOST_HDR="${host_hdr}"
SV_FP="${fp:-chrome}"
SV_PBK="${pbk}"
SV_SID="${sid}"
SV_FLOW="${flow}"
ENVEOF
    info "  Сервер $n: ${host}:${port}  type=${type:-tcp}  security=${sec:-none}"
}

# ─── JSON-блок одного outbound ────────────────────────────────────────────────
gen_outbound() {
    local tag="$1" envfile="$2"
    . "$envfile"

    local user_json
    if [ -n "$SV_FLOW" ]; then
        user_json="{\"id\":\"${SV_UUID}\",\"encryption\":\"none\",\"flow\":\"${SV_FLOW}\"}"
    else
        user_json="{\"id\":\"${SV_UUID}\",\"encryption\":\"none\"}"
    fi

    # mux+xudp: туннелируем UDP (Telegram звонки) через TCP VLESS.
    # concurrency:-1 = TCP mux выключен, только XUDP для UDP.
    # Нельзя с flow (Reality xtls-rprx-vision).
    local mux_json=""
    [ -z "$SV_FLOW" ] && mux_json=',
      "mux": {"enabled": true, "concurrency": -1, "xudpConcurrency": 16, "xudpProxyUDP443": "reject"}'

    local effective_sni="${SV_SNI:-${SV_HOST}}"
    local security_json
    case "$SV_SEC" in
        tls)
            local alpn_part=""
            [ -n "$SV_ALPN" ] && alpn_part=",\"alpn\":$(alpn_to_json "$SV_ALPN")"
            security_json="\"security\":\"tls\",\"tlsSettings\":{\"serverName\":\"${effective_sni}\"${alpn_part}}"
            ;;
        reality)
            security_json="\"security\":\"reality\",\"realitySettings\":{\"serverName\":\"${effective_sni}\",\"fingerprint\":\"${SV_FP}\",\"publicKey\":\"${SV_PBK}\",\"shortId\":\"${SV_SID}\"}"
            ;;
        *)
            security_json="\"security\":\"none\""
            ;;
    esac

    local network_json
    case "$SV_TYPE" in
        ws)
            local wh="${SV_HOST_HDR:-${effective_sni}}"
            network_json="\"network\":\"ws\",\"wsSettings\":{\"path\":\"${SV_PATH}\",\"headers\":{\"Host\":\"${wh}\"}}"
            ;;
        grpc)
            network_json="\"network\":\"grpc\",\"grpcSettings\":{\"serviceName\":\"${SV_PATH}\"}"
            ;;
        *)
            network_json="\"network\":\"tcp\""
            ;;
    esac

    cat << OUTJSON
    {
      "tag": "${tag}",
      "protocol": "vless",
      "settings": {
        "vnext": [{"address":"${SV_HOST}","port":${SV_PORT},"users":[${user_json}]}]
      },
      "streamSettings": { ${network_json}, ${security_json} }${mux_json}
    }
OUTJSON
}

# ─── Проверка: есть ли geosite:ru-blocked в текущем geosite.dat ──────────────
_has_geosite_ru_blocked() {
    [ -x "$XRAY_BIN" ] || return 1
    [ -f /etc/xray/geosite.dat ] || return 1
    local _tc="/tmp/xray_test_geo_$$.json"
    printf '%s\n' '{"log":{"loglevel":"none"},"inbounds":[{"port":19998,"protocol":"dokodemo-door","settings":{"address":"127.0.0.1","network":"tcp"}}],"outbounds":[{"protocol":"freedom"}],"routing":{"rules":[{"type":"field","domain":["geosite:ru-blocked"],"outboundTag":"direct"}]}}' > "$_tc"
    XRAY_LOCATION_ASSET=/etc/xray "$XRAY_BIN" run -test -c "$_tc" >/dev/null 2>&1
    local rc=$?
    rm -f "$_tc"
    return $rc
}

# ─── Генерация config.json ────────────────────────────────────────────────────
gen_config() {
    # $1 — путь назначения (по умолчанию $XRAY_CONFIG)
    local dest="${1:-$XRAY_CONFIG}"
    info "Генерирую конфиг: $dest"
    mkdir -p /etc/xray

    local ob1 ob2 ob3
    ob1=$(gen_outbound "proxy1" "/tmp/xray_sv_1.env")
    ob2=$(gen_outbound "proxy2" "$([ -f /tmp/xray_sv_2.env ] && echo /tmp/xray_sv_2.env || echo /tmp/xray_sv_1.env)")
    ob3=$(gen_outbound "proxy3" "$([ -f /tmp/xray_sv_3.env ] && echo /tmp/xray_sv_3.env || echo /tmp/xray_sv_1.env)")

    cat > "$dest" << CFGEOF
{
  "log": {"loglevel":"warning"},
  "inbounds": [
    {"tag":"socks","listen":"0.0.0.0","port":1080,"protocol":"socks",
     "settings":{"auth":"noauth","udp":true}},
    {"tag":"http","listen":"0.0.0.0","port":1081,"protocol":"http","settings":{}},
    {"tag":"tproxy","listen":"::","port":12345,"protocol":"dokodemo-door",
     "settings":{"network":"tcp,udp","followRedirect":true},
     "streamSettings":{"sockopt":{"tproxy":"tproxy"}},
     "sniffing":{"enabled":true,"destOverride":["http","tls"],"routeOnly":true}}
  ],
  "outbounds": [
${ob1},
${ob2},
${ob3},
    {"tag":"direct","protocol":"freedom","settings":{}},
    {"tag":"block","protocol":"blackhole","settings":{}}
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "balancers": [{"tag":"balancer","selector":["proxy1","proxy2","proxy3"],
                   "strategy":{"type":"leastPing"}}],
    "rules": [
      {"type":"field","ip":["0.0.0.0/8","10.0.0.0/8","127.0.0.0/8","169.254.0.0/16","172.16.0.0/12","192.168.0.0/16","224.0.0.0/4","240.0.0.0/4"],"outboundTag":"direct"},
      {"type":"field","ip":["109.105.128.0/17"],"outboundTag":"direct"},
      {"type":"field","domain":["regexp:[.]ru$","regexp:[.]su$","regexp:[.]xn--p1ai$","domain:rustdesk.com","domain:4game.com","domain:4game.ru","domain:innova.ru","domain:ncsoft.com","domain:lineage2.com"],"outboundTag":"direct"},
      {"type":"field","ip":["91.108.4.0/22","91.108.8.0/22","91.108.12.0/22","91.108.16.0/22","91.108.56.0/22","149.154.160.0/20","149.154.164.0/22"],"balancerTag":"balancer"},
      {"type":"field","network":"tcp,udp","balancerTag":"balancer"}
    ]
  },
  "observatory": {
    "subjectSelector":["proxy1","proxy2","proxy3"],
    "probeURL":"https://www.gstatic.com/generate_204",
    "probeInterval":"3m"
  }
}
CFGEOF
    info "Конфиг записан"
}

# ─── Найти PID запущенного Xray (procd или ручной запуск) ────────────────────
_find_xray_pid() {
    # 1. Наш PID-файл ещё актуален?
    if [ -f "$XRAY_PID" ] && kill -0 "$(cat "$XRAY_PID")" 2>/dev/null; then
        cat "$XRAY_PID"; return 0
    fi
    # 2. Ищем через pidof (BusyBox)
    local p; p=$(pidof xray 2>/dev/null | awk '{print $1}')
    [ -n "$p" ] && printf '%s' "$p"
}

# Проверка: запущен ли Xray (порт + PID)
_xray_is_running() {
    local pid; pid=$(_find_xray_pid)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# ─── Остановить Xray с учётом procd ──────────────────────────────────────────
_stop_xray() {
    # Если procd управляет Xray — используем init-скрипт чтобы procd не respawn'ил
    if autostart_enabled 2>/dev/null; then
        "$XRAY_INIT" stop 2>/dev/null || true
        sleep 1
    fi
    # Добиваем на случай если procd ещё не успел или автозапуск выключен
    local pid; pid=$(_find_xray_pid)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    killall xray 2>/dev/null || true
    rm -f "$XRAY_PID" "$XRAY_INTENT"
}

# ─── Запустить Xray с учётом procd ───────────────────────────────────────────
_start_xray_proc() {
    mkdir -p /var/run "$(dirname "$XRAY_LOG")"
    _rotate_log
    if autostart_enabled 2>/dev/null; then
        # procd запускает и отслеживает процесс сам
        "$XRAY_INIT" start 2>/dev/null
        sleep 2
    else
        XRAY_LOCATION_ASSET=/etc/xray "$XRAY_BIN" run -c "$XRAY_CONFIG" >> "$XRAY_LOG" 2>&1 &
        printf '%s\n' "$!" > "$XRAY_PID"
        sleep 1
    fi
    # Обновляем PID-файл (нужно если procd стартовал процесс)
    local pid; pid=$(_find_xray_pid)
    [ -n "$pid" ] && printf '%s\n' "$pid" > "$XRAY_PID"
}

# ─── Запуск Xray (полный — stop + start) ─────────────────────────────────────
start_xray() {
    # Временно снимаем TPROXY-хук чтобы LAN-трафик не прерывался пока Xray не запущен
    local _tp=0
    iptables_active 2>/dev/null && _tp=1
    [ "$_tp" = 1 ] && _tproxy_detach
    _stop_xray
    _start_xray_proc
    [ "$_tp" = 1 ] && _tproxy_attach
    local pid; pid=$(_find_xray_pid)
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
        warn "=== Xray упал сразу. Последние строки лога ==="
        tail -20 "$XRAY_LOG" 2>/dev/null || warn "(лог пуст)"
        die "Xray не запустился — см. лог выше"
    fi
    touch "$XRAY_INTENT"   # Пользователь явно запустил — помним это до перезагрузки
    info "Xray запущен, PID $pid"
    _tg_send "✅ Xray запущен (PID $pid)"
}

# ─── Быстрый рестарт — минимальный разрыв (~300 мс) ─────────────────────────
# Используется при обновлении подписки когда серверы изменились.
# TPROXY НЕ отцепляем: пока Xray не поднялся (< 500мс), браузер получает
# ECONNREFUSED и сам делает retry — для пользователя это незаметно.
# Отцепление TPROXY хуже: ISP-блокировки сразу закрывают трафик на 2-5с.
_fast_restart() {
    _stop_xray
    _start_xray_proc
    # Ждём готовности порта (до 5 с)
    local i=0
    while [ $i -lt 5 ]; do
        echo "" | nc -w 1 127.0.0.1 1080 >/dev/null 2>&1 && break
        sleep 1; i=$((i + 1))
    done
    local pid; pid=$(_find_xray_pid)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null \
        || die "Xray не запустился — проверьте лог: $XRAY_LOG"
    printf '%s\n' "$pid" > "$XRAY_PID"
    info "Xray перезапущен, PID $pid"
}

# ─── Горячая перезагрузка конфига через SIGHUP (без разрыва соединений) ──────
# Xray подхватывает новый config.json и продолжает работу.
# Если конфиг невалиден — Xray сам остаётся на старом (встроенная защита).
# Fallback на _fast_restart если процесс не ответил.
_reload_xray() {
    local pid; pid=$(_find_xray_pid)
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
        info "Xray не запущен — конфиг сохранён, применится при следующем запуске"
        return 0
    fi
    kill -HUP "$pid" 2>/dev/null || {
        warn "SIGHUP не удался — делаю быстрый рестарт"
        _fast_restart
        return
    }
    # Ждём чтобы Xray успел применить новый конфиг
    sleep 2
    # Проверяем что порт отвечает
    local i=0
    while [ $i -lt 5 ]; do
        echo "" | nc -w 1 127.0.0.1 1080 >/dev/null 2>&1 && break
        sleep 1; i=$((i + 1))
    done
    if ! echo "" | nc -w 1 127.0.0.1 1080 >/dev/null 2>&1; then
        warn "Xray не отвечает после SIGHUP — делаю быстрый рестарт"
        _fast_restart
        return
    fi
    info "Конфиг перезагружен без обрыва соединений (SIGHUP, PID $pid)"
}

# ─── Сравнение серверов: 0 = серверы изменились, 1 = те же ──────────────────
_servers_changed() {
    local new_config="$1"
    [ -f "$XRAY_CONFIG" ] || return 0
    local old_hosts new_hosts
    old_hosts=$(grep '"address"' "$XRAY_CONFIG"  | sed 's/.*"address": *"\([^"]*\)".*/\1/' | sort)
    new_hosts=$(grep '"address"' "$new_config" | sed 's/.*"address": *"\([^"]*\)".*/\1/' | sort)
    [ "$old_hosts" = "$new_hosts" ] && return 1 || return 0
}

# ─── Проверка доступности текущего proxy1 ────────────────────────────────────
# Возвращает 0 если сервер принимает TCP-соединения (порт открыт).
_proxy1_reachable() {
    [ -f "$XRAY_CONFIG" ] || return 1
    local host port
    host=$(grep '"address"' "$XRAY_CONFIG" | head -1 \
        | sed 's/.*"address": *"\([^"]*\)".*/\1/')
    port=$(grep '"port"' "$XRAY_CONFIG" | head -1 \
        | sed 's/[^0-9]//g')
    [ -z "$host" ] || [ -z "$port" ] && return 1
    echo "" | nc -w 5 "$host" "$port" >/dev/null 2>&1
}

# ─── Обновление подписки без разрыва соединений ───────────────────────────────
update_subscription() {
    local sub_url="$1"
    [ -n "$sub_url" ] || { [ -f "$XRAY_SUB_FILE" ] && sub_url=$(cat "$XRAY_SUB_FILE"); }
    [ -n "$sub_url" ] || die "URL подписки не задан"

    info "=== Обновление подписки ==="
    local vless_lines
    vless_lines=$(fetch_subscription "$sub_url")
    [ -n "$vless_lines" ] || die "В подписке не найдено серверов"

    local total; total=$(printf '%s\n' "$vless_lines" | grep -c '^vless://' || true)
    info "Найдено серверов: $total"
    printf '%s\n' "$vless_lines" > "${WORK_DIR}/vless.txt"

    info "=== Выбор лучших серверов ==="
    local best
    best=$(select_best_servers "${WORK_DIR}/vless.txt" 3 20)
    [ -n "$best" ] || die "Не удалось выбрать серверы"
    printf '%s\n' "$best" > "${WORK_DIR}/best.txt"

    info "=== Парсинг ==="
    local i=0
    while IFS= read -r line && [ "$i" -lt 3 ]; do
        [ -z "$line" ] && continue
        i=$((i + 1))
        parse_vless "$line" "$i" || i=$((i - 1))
    done < "${WORK_DIR}/best.txt"
    [ "$i" -gt 0 ] || die "Не удалось распарсить ни один сервер"

    # Сохраняем серверы для последующей перегенерации
    cp "${WORK_DIR}/best.txt" "$XRAY_SERVERS_FILE" 2>/dev/null || true

    info "=== Генерация конфига ==="
    local new_cfg="${WORK_DIR}/config_new.json"
    gen_config "$new_cfg"

    # Валидация нового конфига
    if ! XRAY_LOCATION_ASSET=/etc/xray "$XRAY_BIN" run -test -c "$new_cfg" >/dev/null 2>&1; then
        warn "Новый конфиг невалиден — текущий конфиг не изменён"
        return 1
    fi

    _save_backup

    if ! _servers_changed "$new_cfg" 2>/dev/null; then
        # Серверы те же — перезапуск не нужен вообще
        info "Серверы не изменились — Xray продолжает работу без перезапуска"
        cp "$new_cfg" "$XRAY_CONFIG"
        info "Обновление подписки завершено (без перезапуска)"
        return 0
    fi

    # Серверы изменились в подписке — проверяем текущий сервер
    if _proxy1_reachable 2>/dev/null; then
        # Текущий сервер работает — сохраняем новый конфиг но не переключаемся
        info "Серверы обновились в подписке, но текущий proxy1 работает — не переключаем"
        cp "$new_cfg" "$XRAY_CONFIG"
        info "Новый конфиг сохранён. Xray продолжает работу на текущем сервере."
        info "Новые серверы применятся при следующем перезапуске Xray."
        return 0
    fi

    # Текущий сервер недоступен — применяем новые серверы
    info "Текущий сервер недоступен — переключаемся на новые серверы"
    cp "$new_cfg" "$XRAY_CONFIG"
    _reload_xray
    info "Обновление подписки завершено"
}

# ─── Автозапуск (procd init-скрипт) ──────────────────────────────────────────
install_init_script() {
    info "Устанавливаю автозапуск..."
    mkdir -p /etc/xray

    # Копируем скрипт на постоянное место
    if [ "$0" != "$XRAY_SELF" ]; then
        cp "$0" "$XRAY_SELF" 2>/dev/null && chmod +x "$XRAY_SELF" || true
    fi

    cat > "$XRAY_INIT" << 'INITEOF'
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=99
STOP=01

start_service() {
    procd_open_instance
    procd_set_param env XRAY_LOCATION_ASSET=/etc/xray
    procd_set_param command /usr/bin/xray run -c /etc/xray/config.json
    procd_set_param respawn 3600 5 5
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

stop_service() {
    killall xray 2>/dev/null || true
}
INITEOF
    chmod +x "$XRAY_INIT"
    "$XRAY_INIT" enable 2>/dev/null && info "Автозапуск включён" || warn "Не удалось включить автозапуск"
}

remove_init_script() {
    [ -f "$XRAY_INIT" ] || return 0
    "$XRAY_INIT" disable 2>/dev/null || true
    rm -f "$XRAY_INIT"
    info "Автозапуск отключён"
}

autostart_enabled() {
    [ -f "$XRAY_INIT" ]
}

# ─── Автообновление подписки (cron) ──────────────────────────────────────────
install_cron() {
    local hours="${1:-6}"
    mkdir -p /etc/crontabs
    remove_cron
    # Самовосстановление tproxy — каждые 5 минут (без сети, мгновенно)
    printf '*/5 * * * * sh %s healthcheck %s\n' \
        "$XRAY_SELF" "$CRON_MARKER" >> "$XRAY_CRON"
    # Обновление серверов подписки — каждые N часов через SIGHUP (без обрыва соединений)
    printf '0 */%s * * * sh %s update >> %s 2>&1 %s\n' \
        "$hours" "$XRAY_SELF" "$XRAY_UPDLOG" "$CRON_MARKER" >> "$XRAY_CRON"
    /etc/init.d/cron restart 2>/dev/null || true
    # Запускаем демоны немедленно — не ждём первого healthcheck
    _start_updater
    _start_tg_bot
    info "Автообновление: демон проверяет скрипт каждые 10 сек., подписка каждые ${hours} ч."
}

remove_cron() {
    [ -f "$XRAY_CRON" ] || return 0
    local tmp
    tmp=$(grep -v "$CRON_MARKER" "$XRAY_CRON")
    printf '%s\n' "$tmp" > "$XRAY_CRON"
    /etc/init.d/cron restart 2>/dev/null || true
}

cron_interval() {
    [ -f "$XRAY_CRON" ] || { printf 'выключено'; return; }
    # Ищем строку с "update" — она содержит */N в поле часов (не healthcheck с */5 в минутах)
    local entry
    entry=$(grep "$CRON_MARKER" "$XRAY_CRON" 2>/dev/null | grep ' update' | head -1)
    [ -z "$entry" ] && { printf 'выключено'; return; }
    # Формат: "0 */N * * * ..." → извлекаем N из второго поля
    printf '%s' "$entry" | awk '{n=substr($2,3); if(n~/^[0-9]+$/) printf "каждые %s ч.", n; else printf "вкл"}'
}

# ─── iptables прозрачный прокси (TPROXY TCP+UDP) ────────────────────────────
_lan_iface() {
    ip link show br-lan >/dev/null 2>&1 && printf 'br-lan' || printf 'eth0'
}

iptables_active() {
    iptables -t mangle -L "$IPTABLES_CHAIN" >/dev/null 2>&1
}

# Быстро отцепить / прицепить цепочку от PREROUTING (TPROXY)
_tproxy_detach() {
    local iface; iface=$(_lan_iface)
    iptables -t mangle -D PREROUTING -i "$iface" -j "$IPTABLES_CHAIN" 2>/dev/null || true
}
_tproxy_attach() {
    local iface; iface=$(_lan_iface)
    ip rule add fwmark 0x1 table 100 2>/dev/null || true
    ip route add local 0.0.0.0/0 dev lo table 100 2>/dev/null || true
    iptables -t mangle -D PREROUTING -i "$iface" -j "$IPTABLES_CHAIN" 2>/dev/null || true
    iptables -t mangle -A PREROUTING -i "$iface" -j "$IPTABLES_CHAIN" 2>/dev/null || true
}

_apply_excluded_ips() {
    [ -f "$XRAY_EXCLUDED_IPS_FILE" ] || return 0
    while IFS= read -r _ip; do
        [ -z "$_ip" ] && continue
        case "$_ip" in '#'*) continue ;; esac
        iptables -t mangle -A "$IPTABLES_CHAIN" -s "$_ip" -j RETURN 2>/dev/null || true
    done < "$XRAY_EXCLUDED_IPS_FILE"
}

# ─── Прозрачный прокси: TPROXY (TCP + UDP) ──────────────────────────────────
# TCP + весь UDP → TPROXY :12345 (включая Telegram звонки/видео).
# Требует xt_TPROXY (встроен в OpenWrt 21+) + ip rule/route для policy routing.
# Xray снифает SNI/Host чтобы роутить .ru по домену.
setup_iptables() {
    local iface; iface=$(_lan_iface)
    info "Настраиваю прозрачный прокси (TPROXY, TCP+UDP, $iface → :12345)..."

    remove_iptables 2>/dev/null || true

    # Загружаем модуль TPROXY (если не встроен)
    modprobe xt_TPROXY 2>/dev/null || true

    # Policy routing: помеченные пакеты (fwmark 1) → loopback → Xray
    ip rule add fwmark 0x1 table 100 2>/dev/null || true
    ip route add local 0.0.0.0/0 dev lo table 100 2>/dev/null || true

    # Цепочка в таблице mangle
    iptables -t mangle -N "$IPTABLES_CHAIN" 2>/dev/null || true

    # Исключённые устройства (по IP источника)
    _apply_excluded_ips

    # Приватные/зарезервированные адреса — напрямую
    iptables -t mangle -A "$IPTABLES_CHAIN" -d 0.0.0.0/8      -j RETURN
    iptables -t mangle -A "$IPTABLES_CHAIN" -d 10.0.0.0/8     -j RETURN
    iptables -t mangle -A "$IPTABLES_CHAIN" -d 127.0.0.0/8    -j RETURN
    iptables -t mangle -A "$IPTABLES_CHAIN" -d 169.254.0.0/16 -j RETURN
    iptables -t mangle -A "$IPTABLES_CHAIN" -d 172.16.0.0/12  -j RETURN
    iptables -t mangle -A "$IPTABLES_CHAIN" -d 192.168.0.0/16 -j RETURN
    iptables -t mangle -A "$IPTABLES_CHAIN" -d 224.0.0.0/4    -j RETURN
    iptables -t mangle -A "$IPTABLES_CHAIN" -d 240.0.0.0/4    -j RETURN
    # SSH — не трогаем управляющий трафик
    iptables -t mangle -A "$IPTABLES_CHAIN" -p tcp --dport 22 -j RETURN

    # Весь TCP + UDP → TPROXY :12345 с меткой 1
    iptables -t mangle -A "$IPTABLES_CHAIN" -p tcp -j TPROXY --on-port 12345 --tproxy-mark 1
    iptables -t mangle -A "$IPTABLES_CHAIN" -p udp -j TPROXY --on-port 12345 --tproxy-mark 1

    # Применяем к LAN-трафику
    iptables -t mangle -A PREROUTING -i "$iface" -j "$IPTABLES_CHAIN"

    # IPv6 TPROXY — перехватываем IPv6 трафик с LAN
    # Если ip6t_TPROXY недоступен — fallback на DROP (браузер переключится на IPv4)
    ip -6 rule add fwmark 0x1 table 100 2>/dev/null || true
    ip -6 route add local ::/0 dev lo table 100 2>/dev/null || true
    ip6tables -t mangle -N "$IPTABLES_CHAIN" 2>/dev/null || true
    # Исключаем link-local, loopback, ULA, multicast
    ip6tables -t mangle -A "$IPTABLES_CHAIN" -d ::1/128        -j RETURN 2>/dev/null || true
    ip6tables -t mangle -A "$IPTABLES_CHAIN" -d fe80::/10      -j RETURN 2>/dev/null || true
    ip6tables -t mangle -A "$IPTABLES_CHAIN" -d fc00::/7       -j RETURN 2>/dev/null || true
    ip6tables -t mangle -A "$IPTABLES_CHAIN" -d ff00::/8       -j RETURN 2>/dev/null || true
    ip6tables -t mangle -A "$IPTABLES_CHAIN" -p tcp --dport 22 -j RETURN 2>/dev/null || true
    if ip6tables -t mangle -A "$IPTABLES_CHAIN" -p tcp -j TPROXY --on-port 12345 --tproxy-mark 1 2>/dev/null \
    && ip6tables -t mangle -A "$IPTABLES_CHAIN" -p udp -j TPROXY --on-port 12345 --tproxy-mark 1 2>/dev/null; then
        ip6tables -t mangle -A PREROUTING -i "$iface" -j "$IPTABLES_CHAIN" 2>/dev/null || true
        info "IPv6 TPROXY включён"
    else
        # TPROXY не поддерживается — блокируем IPv6 форвардинг с LAN
        ip6tables -t mangle -F "$IPTABLES_CHAIN" 2>/dev/null || true
        ip6tables -t mangle -X "$IPTABLES_CHAIN" 2>/dev/null || true
        ip6tables -I FORWARD -i "$iface" -j DROP 2>/dev/null || true
        warn "ip6t_TPROXY недоступен — IPv6 с LAN заблокирован (fallback)"
    fi

    conntrack -F 2>/dev/null || true
    info "Прозрачный прокси включён (TPROXY TCP+UDP IPv4+IPv6, $iface)"
    _persist_iptables "$iface"
}

remove_iptables() {
    # Убираем оба варианта: nat (новый) и mangle (старый TPROXY — для чистоты)
    for _if in br-lan eth0 eth1; do
        iptables -t nat    -D PREROUTING -i "$_if" -j "$IPTABLES_CHAIN" 2>/dev/null || true
        iptables -t mangle -D PREROUTING -i "$_if" -j "$IPTABLES_CHAIN" 2>/dev/null || true
    done
    iptables -t nat    -F "$IPTABLES_CHAIN" 2>/dev/null || true
    iptables -t nat    -X "$IPTABLES_CHAIN" 2>/dev/null || true
    iptables -t mangle -F "$IPTABLES_CHAIN" 2>/dev/null || true
    iptables -t mangle -X "$IPTABLES_CHAIN" 2>/dev/null || true
    # Удаляем IPv4 policy routing
    while ip rule del fwmark 0x1 lookup 100     2>/dev/null; do :; done
    while ip rule del fwmark 0x1/0x1 lookup 100 2>/dev/null; do :; done
    ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null || true
    # Убираем IPv6 TPROXY цепочку
    for _if in br-lan eth0 eth1; do
        ip6tables -t mangle -D PREROUTING -i "$_if" -j "$IPTABLES_CHAIN" 2>/dev/null || true
    done
    ip6tables -t mangle -F "$IPTABLES_CHAIN" 2>/dev/null || true
    ip6tables -t mangle -X "$IPTABLES_CHAIN" 2>/dev/null || true
    # Убираем IPv6 policy routing
    while ip -6 rule del fwmark 0x1 lookup 100 2>/dev/null; do :; done
    ip -6 route del local ::/0 dev lo table 100 2>/dev/null || true
    # Убираем fallback IPv6 блокировку (если была)
    for _if in br-lan eth0 eth1; do
        ip6tables -D FORWARD -i "$_if" -j DROP 2>/dev/null || true
    done
    conntrack -F 2>/dev/null || true
    _unpersist_iptables
    info "Прозрачный прокси отключён"
}

_persist_iptables() {
    local iface="${1:-br-lan}"
    _unpersist_iptables
    {
        printf '%s\n' "$FIREWALL_MARK"
        printf 'modprobe xt_TPROXY 2>/dev/null || true\n'
        printf 'ip rule add fwmark 0x1 table 100 2>/dev/null || true\n'
        printf 'ip route add local 0.0.0.0/0 dev lo table 100 2>/dev/null || true\n'
        printf 'iptables -t mangle -N XRAY_TP 2>/dev/null || true\n'
        if [ -f "$XRAY_EXCLUDED_IPS_FILE" ]; then
            while IFS= read -r _eip; do
                [ -z "$_eip" ] && continue
                case "$_eip" in '#'*) continue ;; esac
                printf 'iptables -t mangle -A XRAY_TP -s %s -j RETURN\n' "$_eip"
            done < "$XRAY_EXCLUDED_IPS_FILE"
        fi
        printf 'iptables -t mangle -A XRAY_TP -d 0.0.0.0/8 -j RETURN\n'
        printf 'iptables -t mangle -A XRAY_TP -d 10.0.0.0/8 -j RETURN\n'
        printf 'iptables -t mangle -A XRAY_TP -d 127.0.0.0/8 -j RETURN\n'
        printf 'iptables -t mangle -A XRAY_TP -d 169.254.0.0/16 -j RETURN\n'
        printf 'iptables -t mangle -A XRAY_TP -d 172.16.0.0/12 -j RETURN\n'
        printf 'iptables -t mangle -A XRAY_TP -d 192.168.0.0/16 -j RETURN\n'
        printf 'iptables -t mangle -A XRAY_TP -d 224.0.0.0/4 -j RETURN\n'
        printf 'iptables -t mangle -A XRAY_TP -d 240.0.0.0/4 -j RETURN\n'
        printf 'iptables -t mangle -A XRAY_TP -p tcp --dport 22 -j RETURN\n'
        printf 'iptables -t mangle -A XRAY_TP -p tcp -j TPROXY --on-port 12345 --tproxy-mark 1\n'
        printf 'iptables -t mangle -A XRAY_TP -p udp -j TPROXY --on-port 12345 --tproxy-mark 1\n'
        printf 'iptables -t mangle -A PREROUTING -i %s -j XRAY_TP\n' "$iface"
        # IPv6 TPROXY (с fallback на DROP если модуль недоступен)
        printf 'ip -6 rule add fwmark 0x1 table 100 2>/dev/null || true\n'
        printf 'ip -6 route add local ::/0 dev lo table 100 2>/dev/null || true\n'
        printf 'ip6tables -t mangle -N XRAY_TP 2>/dev/null || true\n'
        printf 'ip6tables -t mangle -A XRAY_TP -d ::1/128   -j RETURN 2>/dev/null || true\n'
        printf 'ip6tables -t mangle -A XRAY_TP -d fe80::/10 -j RETURN 2>/dev/null || true\n'
        printf 'ip6tables -t mangle -A XRAY_TP -d fc00::/7  -j RETURN 2>/dev/null || true\n'
        printf 'ip6tables -t mangle -A XRAY_TP -d ff00::/8  -j RETURN 2>/dev/null || true\n'
        printf 'ip6tables -t mangle -A XRAY_TP -p tcp --dport 22 -j RETURN 2>/dev/null || true\n'
        printf 'if ip6tables -t mangle -A XRAY_TP -p tcp -j TPROXY --on-port 12345 --tproxy-mark 1 2>/dev/null \\\n'
        printf '&& ip6tables -t mangle -A XRAY_TP -p udp -j TPROXY --on-port 12345 --tproxy-mark 1 2>/dev/null; then\n'
        printf '    ip6tables -t mangle -A PREROUTING -i %s -j XRAY_TP 2>/dev/null || true\n' "$iface"
        printf 'else\n'
        printf '    ip6tables -t mangle -F XRAY_TP 2>/dev/null || true\n'
        printf '    ip6tables -t mangle -X XRAY_TP 2>/dev/null || true\n'
        printf '    ip6tables -I FORWARD -i %s -j DROP 2>/dev/null || true\n' "$iface"
        printf 'fi\n'
        printf '%s-end\n' "$FIREWALL_MARK"
    } >> "$FIREWALL_USER"
    info "Правила TPROXY сохранены → $FIREWALL_USER"
}

_unpersist_iptables() {
    [ -f "$FIREWALL_USER" ] || return 0
    local tmp
    tmp=$(awk -v s="$FIREWALL_MARK" -v e="${FIREWALL_MARK}-end" \
        '$0==s{skip=1;next} $0==e{skip=0;next} !skip{print}' "$FIREWALL_USER")
    printf '%s\n' "$tmp" > "$FIREWALL_USER"
}

cmd_tproxy_menu() {
    local cur; iptables_active && cur="включён" || cur="выключен"
    printf '\nПрозрачный прокси (весь LAN-трафик через Xray): %s\n\n' "$cur"
    printf '  1  Включить\n'
    printf '  2  Выключить\n'
    printf '  0  Назад\n\n'
    printf 'Выбор: '; read -r ch
    case "$ch" in
        1)
            if [ ! -f "$XRAY_CONFIG" ]; then
                printf 'Сначала настройте подписку (пункт 1)\n'
            else
                _xray_is_running || start_xray
                setup_iptables || warn "Ошибка настройки iptables"
            fi
            ;;
        2)
            remove_iptables
            _stop_xray
            info "Xray остановлен"
            ;;
    esac
}

# ─── Применение подписки ──────────────────────────────────────────────────────
apply_subscription() {
    local sub_url="$1"

    _save_backup

    info "=== Установка Xray ==="
    install_xray

    info "=== Загрузка подписки ==="
    local vless_lines
    vless_lines=$(fetch_subscription "$sub_url")
    [ -n "$vless_lines" ] || die "В подписке не найдено ни одного vless:// сервера"

    local total
    total=$(printf '%s\n' "$vless_lines" | grep -c '^vless://' || true)
    info "Найдено серверов: $total"
    printf '%s\n' "$vless_lines" > "${WORK_DIR}/vless.txt"

    info "=== Выбор лучших серверов ==="
    local best
    best=$(select_best_servers "${WORK_DIR}/vless.txt" 3 20)
    [ -n "$best" ] || die "Не удалось выбрать серверы"
    printf '%s\n' "$best" > "${WORK_DIR}/best.txt"

    info "=== Парсинг ==="
    local i=0
    while IFS= read -r line && [ "$i" -lt 3 ]; do
        [ -z "$line" ] && continue
        i=$((i + 1))
        parse_vless "$line" "$i" || i=$((i - 1))
    done < "${WORK_DIR}/best.txt"
    [ "$i" -gt 0 ] || die "Не удалось распарсить ни один сервер"

    # Сохраняем серверы для последующей перегенерации
    cp "${WORK_DIR}/best.txt" "$XRAY_SERVERS_FILE" 2>/dev/null || true

    info "=== Генерация конфига ==="
    gen_config

    info "=== Запуск ==="
    start_xray

    info "=== Проверка подключения ==="
    sleep 2
    if _test_proxy; then
        info "Подключение через прокси: OK"
        _start_watchdog
    else
        warn "Прокси не отвечает — откат"
        _do_rollback
        die "Установка отменена: прокси не работает после запуска"
    fi

    local lan_ip; lan_ip=$(ip -4 addr show br-lan 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -1)
    [ -z "$lan_ip" ] && lan_ip="192.168.8.1"
    printf '\n'
    printf '  ✅ Xray запущен\n'
    printf '  SOCKS5 : %s:1080\n' "$lan_ip"
    printf '  HTTP   : %s:1081\n' "$lan_ip"
    printf '\n'
    printf '  Прозрачный прокси (tproxy) — ВЫКЛ  → пункт 9 для включения\n'
    printf '  Автозапуск                 — ВЫКЛ  → пункт 5 для включения\n'
    printf '  Автообновление             — ВЫКЛ  → пункт 6 для включения\n'
    printf '\n'
}

# ─── Статус ───────────────────────────────────────────────────────────────────
cmd_status() {
    printf '\n'
    if [ -x "$XRAY_BIN" ]; then
        printf '  Xray        : %s\n' "$("$XRAY_BIN" version 2>/dev/null | head -1)"
    else
        printf '  Xray        : не установлен\n'
    fi

    local _pid; _pid=$(_find_xray_pid)
    if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
        printf '  Процесс     : запущен (PID %s)\n' "$_pid"
    else
        printf '  Процесс     : не запущен\n'
    fi

    [ -f "$XRAY_CONFIG" ] \
        && printf '  Конфиг      : %s\n' "$XRAY_CONFIG" \
        || printf '  Конфиг      : отсутствует\n'

    [ -f "$XRAY_SUB_FILE" ] \
        && printf '  Подписка    : %s\n' "$(cat "$XRAY_SUB_FILE")"

    autostart_enabled \
        && printf '  Автозапуск  : включён\n' \
        || printf '  Автозапуск  : выключен\n'

    printf '  Автообновл. : %s\n' "$(cron_interval)"
    local lan_ip; lan_ip=$(ip -4 addr show br-lan 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -1)
    [ -z "$lan_ip" ] && lan_ip="192.168.8.1"
    printf '  SOCKS5      : %s:1080  (для RustDesk и др.)\n' "$lan_ip"
    iptables_active \
        && printf '  TProxy      : включён (весь LAN через Xray)\n' \
        || printf '  TProxy      : выключен (только ручной прокси)\n'
    printf '  Скрипт      : v%s\n' "$SCRIPT_VERSION"
    if [ -f "$XRAY_UPDATER_PID" ] && kill -0 "$(cat "$XRAY_UPDATER_PID")" 2>/dev/null; then
        printf '  Демон апдейт: запущен (PID %s)\n' "$(cat "$XRAY_UPDATER_PID")"
    else
        printf '  Демон апдейт: не запущен\n'
        printf '  Последний лог: %s\n' "$(logread 2>/dev/null | grep 'xray-upd' | tail -1 | sed 's/.*xray-upd: //')"
    fi
    if [ -f "$XRAY_TG_BOT_PID" ] && kill -0 "$(cat "$XRAY_TG_BOT_PID")" 2>/dev/null; then
        printf '  Telegram бот: запущен (PID %s)\n' "$(cat "$XRAY_TG_BOT_PID")"
    else
        printf '  Telegram бот: не запущен\n'
    fi
    printf '  SSH туннель : %s\n' "$(_tunnel_status)"

    if [ -f "$XRAY_WATCHDOG_PID" ] && kill -0 "$(cat "$XRAY_WATCHDOG_PID")" 2>/dev/null; then
        printf '  Watchdog    : активен (автооткат при обрыве)\n'
    fi
    printf '\n'
}

# ─── Автозапуск — подменю ─────────────────────────────────────────────────────
cmd_autostart_menu() {
    local cur; autostart_enabled && cur="включён" || cur="выключен"
    printf '\nАвтозапуск при загрузке: %s\n\n' "$cur"
    printf '  1  Включить\n'
    printf '  2  Выключить\n'
    printf '  0  Назад\n\n'
    printf 'Выбор: '; read -r ch
    case "$ch" in
        1)
            if [ ! -f "$XRAY_CONFIG" ]; then
                printf 'Сначала настройте подписку (пункт 1)\n'
            else
                install_init_script
            fi
            ;;
        2) remove_init_script ;;
    esac
}

# ─── Автообновление — подменю ─────────────────────────────────────────────────
cmd_autoupdate_menu() {
    printf '\nАвтообновление подписки: %s\n\n' "$(cron_interval)"
    printf '  1  Каждые 6 часов\n'
    printf '  2  Каждые 12 часов\n'
    printf '  3  Каждые 24 часа\n'
    printf '  4  Выключить\n'
    printf '  0  Назад\n\n'
    printf 'Выбор: '; read -r ch
    case "$ch" in
        1) install_cron 6  ;;
        2) install_cron 12 ;;
        3) install_cron 24 ;;
        4) remove_cron; info "Автообновление отключено" ;;
    esac
}

# ─── Удаление ─────────────────────────────────────────────────────────────────
cmd_uninstall() {
    printf '\nБудет удалено:\n'
    printf '  /usr/bin/xray, /etc/xray/,\n'
    printf '  автозапуск (/etc/init.d/xray),\n'
    printf '  автообновление (cron)\n\n'
    printf 'Подтвердите удаление [y/N]: '; read -r confirm
    case "$confirm" in
        y|Y) ;;
        *) printf 'Отменено\n'; return ;;
    esac

    info "Останавливаю xray..."
    [ -f "$XRAY_PID" ] && kill "$(cat "$XRAY_PID")" 2>/dev/null || true
    killall xray 2>/dev/null || true
    rm -f "$XRAY_PID"

    remove_init_script
    remove_cron

    remove_iptables 2>/dev/null || true

    info "Удаляю файлы..."
    rm -f "$XRAY_BIN"
    rm -rf /etc/xray       # удаляет config.json, servers.txt, geodata
    rm -f "$XRAY_LOG"

    printf '\nXray полностью удалён\n'
}

# ─── Тесты ────────────────────────────────────────────────────────────────────
_T_PASS=0; _T_FAIL=0

_ok()   { _T_PASS=$((_T_PASS+1)); printf '  [PASS] %s\n' "$1"; }
_fail() { _T_FAIL=$((_T_FAIL+1)); printf '  [FAIL] %s\n    got:      "%s"\n    expected: "%s"\n' "$1" "$2" "$3"; }
_assert() { [ "$2" = "$3" ] && _ok "$1" || _fail "$1" "$2" "$3"; }
_section() { printf '\n-- %s\n' "$1"; }

cmd_test() {
    _T_PASS=0; _T_FAIL=0

    _section "urldecode"
    _assert "путь %2F"       "$(urldecode '%2Fws%2Fpath')"    '/ws/path'
    _assert "запятая %2C"    "$(urldecode 'h2%2Chttp%2F1.1')" 'h2,http/1.1'
    _assert "пробел %20"     "$(urldecode 'hello%20world')"   'hello world'
    _assert "знак равно %3D" "$(urldecode 'a%3Db')"           'a=b'
    _assert "процент %25"    "$(urldecode '100%25')"           '100%'
    _assert "без кодирования" "$(urldecode 'plain')"           'plain'

    _section "alpn_to_json"
    _assert "два значения" "$(alpn_to_json 'h2,http/1.1')"    '["h2","http/1.1"]'
    _assert "одно значение" "$(alpn_to_json 'h2')"            '["h2"]'
    _assert "три значения" "$(alpn_to_json 'h2,http/1.1,h3')" '["h2","http/1.1","h3"]'

    _section "detect_arch"
    local arch; arch=$(detect_arch 2>/dev/null)
    [ -n "$arch" ] && _ok "detect_arch: $arch" || _fail "detect_arch" "" "непустая строка"

    _section "parse_vless (tls+ws)"
    local tls_url='vless://550e8400-e29b-41d4-a716-446655440000@example.com:443?type=ws&security=tls&sni=cdn.example.com&path=%2Fwspath&alpn=h2%2Chttp%2F1.1&host=cdn.example.com#test'
    parse_vless "$tls_url" "99" 2>/dev/null
    if [ -f /tmp/xray_sv_99.env ]; then
        . /tmp/xray_sv_99.env
        _assert "uuid"     "$SV_UUID" "550e8400-e29b-41d4-a716-446655440000"
        _assert "host"     "$SV_HOST" "example.com"
        _assert "port"     "$SV_PORT" "443"
        _assert "type"     "$SV_TYPE" "ws"
        _assert "security" "$SV_SEC"  "tls"
        _assert "path"     "$SV_PATH" "/wspath"
        _assert "sni"      "$SV_SNI"  "cdn.example.com"
        _assert "alpn"     "$SV_ALPN" "h2,http/1.1"
        _assert "host_hdr" "$SV_HOST_HDR" "cdn.example.com"
        rm -f /tmp/xray_sv_99.env
    else
        _fail "parse_vless env-файл" "" "/tmp/xray_sv_99.env"
    fi

    _section "parse_vless (reality+tcp)"
    local rl_url='vless://aaaabbbb-cccc-dddd-eeee-ffffffffffff@1.2.3.4:8443?type=tcp&security=reality&sni=www.apple.com&fp=chrome&pbk=PUBKEY123&sid=abc123&flow=xtls-rprx-vision#test'
    parse_vless "$rl_url" "98" 2>/dev/null
    if [ -f /tmp/xray_sv_98.env ]; then
        . /tmp/xray_sv_98.env
        _assert "host"     "$SV_HOST" "1.2.3.4"
        _assert "port"     "$SV_PORT" "8443"
        _assert "security" "$SV_SEC"  "reality"
        _assert "fp"       "$SV_FP"   "chrome"
        _assert "pbk"      "$SV_PBK"  "PUBKEY123"
        _assert "sid"      "$SV_SID"  "abc123"
        _assert "flow"     "$SV_FLOW" "xtls-rprx-vision"
        rm -f /tmp/xray_sv_98.env
    else
        _fail "parse_vless env-файл" "" "/tmp/xray_sv_98.env"
    fi

    _section "интеграция"
    if [ ! -f /etc/openwrt_release ]; then
        printf '  [SKIP] не OpenWrt окружение\n'
    else
        [ -x "$XRAY_BIN" ] \
            && _ok "бинарник: $XRAY_BIN" \
            || _fail "бинарник" "отсутствует" "$XRAY_BIN"
        [ -f "$XRAY_CONFIG" ] \
            && _ok "конфиг: $XRAY_CONFIG" \
            || _fail "конфиг" "отсутствует" "$XRAY_CONFIG"
        if [ -f "$XRAY_PID" ] && kill -0 "$(cat "$XRAY_PID")" 2>/dev/null; then
            _ok "процесс запущен (PID $(cat "$XRAY_PID"))"
            local ip
            if command -v curl >/dev/null 2>&1; then
                ip=$(curl -s --max-time 10 -x socks5://127.0.0.1:1080 https://ipinfo.io/ip 2>/dev/null | tr -d '\n')
            else
                ip=$(http_proxy="http://127.0.0.1:1081" wget --no-check-certificate -qO- https://ipinfo.io/ip 2>/dev/null | tr -d '\n')
            fi
            [ -n "$ip" ] && _ok "SOCKS5 :1080 работает (IP: $ip)" \
                         || _fail "SOCKS5 :1080" "нет ответа" "IP-адрес"
        else
            printf '  [SKIP] SOCKS5 — xray не запущен\n'
        fi
    fi

    printf '\n  Итог: %s пройдено, %s провалено\n\n' "$_T_PASS" "$_T_FAIL"
    [ "$_T_FAIL" -eq 0 ]
}

# ─── Меню ─────────────────────────────────────────────────────────────────────
menu() {
    while true; do
        local run_status="●"
        if _xray_is_running 2>/dev/null; then
            run_status="▶ запущен"
        else
            run_status="■ остановлен"
        fi

        printf '\n'
        printf '╔══════════════════════════════════╗\n'
        printf '║     Xray Setup / OpenWrt         ║\n'
        printf '║     %s%-27s║\n' "" "$run_status"
        printf '╠══════════════════════════════════╣\n'
        printf '║  1  Установить / обновить        ║\n'
        printf '║  2  Статус                       ║\n'
        printf '║  3  Перезапустить                ║\n'
        printf '║  4  Остановить                   ║\n'
        if autostart_enabled; then
        printf '║  5  Автозапуск (вкл) ✓           ║\n'
        else
        printf '║  5  Автозапуск (выкл)            ║\n'
        fi
        local cron_st; cron_st=$(cron_interval)
        if [ "$cron_st" = "выключено" ]; then
        printf '║  6  Автообновление (выкл)        ║\n'
        else
        printf '║  6  Автообновление (%s)   ║\n' "$cron_st"
        fi
        printf '║  7  Удалить всё                  ║\n'
        printf '║  8  Тесты                        ║\n'
        if iptables_active 2>/dev/null; then
        printf '║  9  Прозрачный прокси (вкл) ✓    ║\n'
        else
        printf '║  9  Прозрачный прокси (выкл)     ║\n'
        fi
        printf '║  r  Восстановить всё             ║\n'
        printf '║  c  Сброс сети (iptables+conntrack)║\n'
        local excl_count=0
        [ -s "$XRAY_EXCLUDED_IPS_FILE" ] && excl_count=$(grep -c '[0-9]' "$XRAY_EXCLUDED_IPS_FILE" 2>/dev/null || printf '0')
        if [ "$excl_count" -gt 0 ] 2>/dev/null; then
        printf '║  x  Исключить ПК из прокси [%s]   ║\n' "$excl_count"
        else
        printf '║  x  Исключить ПК из прокси       ║\n'
        fi
        printf '║  g  Обновить геоданные           ║\n'
        printf '║  u  Обновить скрипт              ║\n'
        if [ -f "$XRAY_WATCHDOG_PID" ] && kill -0 "$(cat "$XRAY_WATCHDOG_PID")" 2>/dev/null; then
        printf '║  w  Отменить watchdog ⚠           ║\n'
        fi
        if _tg_configured 2>/dev/null; then
        printf '║  t  Telegram (вкл) ✓             ║\n'
        else
        printf '║  t  Telegram (выкл)              ║\n'
        fi
        if [ -f "$XRAY_TUNNEL_CONF" ]; then
        printf '║  s  SSH туннель (вкл) ✓          ║\n'
        else
        printf '║  s  SSH туннель (выкл)           ║\n'
        fi
        printf '║  0  Выход                        ║\n'
        printf '╚══════════════════════════════════╝\n'
        printf 'Выбор: '; read -r choice

        case "$choice" in
            1)
                local saved=""
                [ -f "$XRAY_SUB_FILE" ] && saved=$(cat "$XRAY_SUB_FILE")
                if [ -n "$saved" ]; then
                    printf 'Текущая подписка:\n  %s\n' "$saved"
                    printf 'Новая (Enter — оставить текущую): '
                else
                    printf 'Ссылка на подписку: '
                fi
                read -r input_url
                local sub_url="${input_url:-$saved}"
                if [ -z "$sub_url" ]; then
                    printf 'Укажите ссылку на подписку\n'; continue
                fi
                mkdir -p /etc/xray
                printf '%s\n' "$sub_url" > "$XRAY_SUB_FILE"
                apply_subscription "$sub_url"
                ;;
            2) cmd_status ;;
            3)
                [ -f "$XRAY_CONFIG" ] || { printf 'Сначала настройте подписку (пункт 1)\n'; continue; }
                info "Перезапуск..."; start_xray
                ;;
            4)
                info "Останавливаю xray..."
                _stop_xray
                printf 'Xray остановлен\n'
                ;;
            5) cmd_autostart_menu ;;
            6) cmd_autoupdate_menu ;;
            7) cmd_uninstall ;;
            8) cmd_test ;;
            9) cmd_tproxy_menu ;;
            r|R) cmd_recover ;;
            c|C) cmd_netreset ;;
            x|X) cmd_exclude_pc ;;
            g|G) update_geodata && info "Перезапустите Xray (пункт 3) чтобы применить" ;;
            u|U) cmd_self_update ;;
            w|W) _cancel_watchdog ;;
            t|T) cmd_tg_setup ;;
            s|S) cmd_ssh_anywhere ;;
            0|q|Q) printf 'Выход\n'; exit 0 ;;
            *) printf 'Неверный выбор\n' ;;
        esac
    done
}

# ─── Сброс сети: полная очистка iptables/ip rules/conntrack ──────────────────
# Убирает ВСЁ что связано с tproxy — даже "призрачные" правила от прошлых запусков.
# Xray и конфиг НЕ удаляются. После сброса трафик идёт напрямую.
cmd_netreset() {
    info "=== Сброс сети ==="
    info "Останавливаю Xray..."
    killall xray 2>/dev/null || true
    rm -f "$XRAY_PID"

    info "Очищаю iptables (все интерфейсы, все дубли)..."
    for _if in br-lan eth0 eth1 eth0.2 br0; do
        iptables  -t mangle -D PREROUTING -i "$_if" -j "$IPTABLES_CHAIN" 2>/dev/null || true
        iptables  -t nat    -D PREROUTING -i "$_if" -j "$IPTABLES_CHAIN" 2>/dev/null || true
        ip6tables -t mangle -D PREROUTING -i "$_if" -j "$IPTABLES_CHAIN" 2>/dev/null || true
        ip6tables -D FORWARD -i "$_if" -j DROP 2>/dev/null || true
    done
    iptables  -t mangle -F "$IPTABLES_CHAIN" 2>/dev/null || true
    iptables  -t mangle -X "$IPTABLES_CHAIN" 2>/dev/null || true
    iptables  -t nat    -F "$IPTABLES_CHAIN" 2>/dev/null || true
    iptables  -t nat    -X "$IPTABLES_CHAIN" 2>/dev/null || true
    ip6tables -t mangle -F "$IPTABLES_CHAIN" 2>/dev/null || true
    ip6tables -t mangle -X "$IPTABLES_CHAIN" 2>/dev/null || true

    info "Удаляю все ip rule (все дубли)..."
    while ip rule del fwmark 0x1 lookup 100     2>/dev/null; do :; done
    while ip rule del fwmark 0x1/0x1 lookup 100 2>/dev/null; do :; done
    ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null || true
    while ip -6 rule del fwmark 0x1 lookup 100 2>/dev/null; do :; done
    ip -6 route del local ::/0 dev lo table 100 2>/dev/null || true

    info "Сбрасываю conntrack (зависшие соединения)..."
    conntrack -F 2>/dev/null || true

    info "Очищаю firewall.user..."
    _unpersist_iptables

    info "=== Готово: сеть сброшена, трафик идёт напрямую ==="
    info "Для запуска Xray нажмите r"
}

# ─── Исключить ПК из tproxy (авто-определение по SSH_CLIENT) ─────────────────
# Запускать по SSH с того компьютера который нужно исключить.
# IP определяется автоматически из $SSH_CLIENT — не нужно вводить вручную.
cmd_exclude_pc() {
    printf '\n'
    info "=== Исключение устройства из прозрачного прокси ==="

    # Показываем текущий список
    if [ -s "$XRAY_EXCLUDED_IPS_FILE" ]; then
        info "Текущие исключения:"
        local n=0
        while IFS= read -r _ip; do
            [ -z "$_ip" ] && continue
            case "$_ip" in '#'*) continue ;; esac
            n=$((n+1))
            printf '   %d. %s\n' "$n" "$_ip"
        done < "$XRAY_EXCLUDED_IPS_FILE"
    else
        info "Список исключений пуст"
    fi

    printf '\n'
    printf '  a  Добавить этот компьютер (авто)\n'
    printf '  d  Ввести IP вручную\n'
    printf '  c  Очистить весь список\n'
    printf '  0  Назад\n'
    printf 'Выбор: '; read -r xchoice

    case "$xchoice" in
        a|A)
            # Авто-определяем IP из SSH-сессии
            local pc_ip=""
            pc_ip=$(printf '%s' "$SSH_CLIENT" | awk '{print $1}')
            # Fallback через who (некоторые системы)
            if [ -z "$pc_ip" ] || [ "$pc_ip" = "?" ]; then
                pc_ip=$(who 2>/dev/null | awk 'NR==1{gsub(/[()]/,"",$NF); print $NF}')
            fi
            if [ -z "$pc_ip" ] || [ "$pc_ip" = "?" ]; then
                warn "Не удалось определить IP автоматически"
                warn "Убедитесь что скрипт запущен по SSH, или используйте вариант 'd'"
                return 1
            fi
            _add_excluded_ip "$pc_ip"
            ;;
        d|D)
            printf 'Введите IP устройства (например 192.168.8.100): '
            read -r manual_ip
            [ -z "$manual_ip" ] && return 0
            _add_excluded_ip "$manual_ip"
            ;;
        c|C)
            printf 'Точно очистить список? (y/N): '; read -r confirm
            case "$confirm" in y|Y)
                rm -f "$XRAY_EXCLUDED_IPS_FILE"
                info "Список исключений очищен"
                # Перестраиваем iptables если активны
                if iptables_active 2>/dev/null; then
                    local iface; iface=$(_lan_iface)
                    setup_iptables
                fi
                ;;
            esac
            ;;
        0|'') return 0 ;;
    esac
}

_add_excluded_ip() {
    local pc_ip="$1"
    mkdir -p /etc/xray
    info "IP устройства: $pc_ip"
    # Без дублей
    if grep -qF "$pc_ip" "$XRAY_EXCLUDED_IPS_FILE" 2>/dev/null; then
        info "IP $pc_ip уже в списке исключений"
    else
        printf '%s\n' "$pc_ip" >> "$XRAY_EXCLUDED_IPS_FILE"
        info "Добавлен в список: $pc_ip"
    fi
    # Применяем сразу если tproxy активен
    if iptables_active 2>/dev/null; then
        # Вставляем в начало цепочки (перед всеми правилами)
        iptables -t mangle -I "$IPTABLES_CHAIN" 1 -s "$pc_ip" -j RETURN 2>/dev/null && \
            info "✓ Правило применено — трафик с $pc_ip обходит прокси" || \
            warn "Не удалось применить правило — переключите прокси (9→выкл→вкл)"
        # Обновляем persist
        local iface; iface=$(_lan_iface)
        _persist_iptables "$iface"
    else
        info "Сохранено — правило применится при включении прокси (пункт 9)"
    fi
    info "Совет: зафиксируйте IP $pc_ip в DHCP-резервации роутера чтобы он не менялся"
}

# ─── Полное восстановление без ввода URL ─────────────────────────────────────
# Использует сохранённый URL, или DEFAULT_SUB_URL если сохранённый некорректен.
# Вызывается кнопкой r из меню — человеку нажать только одну кнопку.
cmd_recover() {
    local _url
    _url=$(cat "$XRAY_SUB_FILE" 2>/dev/null | tr -d '\n\r ')
    if ! printf '%s' "$_url" | grep -q '^https\?://'; then
        _url="$DEFAULT_SUB_URL"
    fi
    [ -n "$_url" ] || { warn "URL подписки не задан и DEFAULT_SUB_URL пуст"; return 1; }
    info "=== Восстановление ==="
    info "URL: $_url"
    printf '%s\n' "$_url" > "$XRAY_SUB_FILE"
    apply_subscription "$_url" || { warn "Установка не удалась"; return 1; }
    info "=== Готово: Xray запущен ==="
}

# ─── Автовосстановление URL подписки при старте ──────────────────────────────
# Если /etc/xray/sub_url содержит не-URL (например "5") — исправляем и
# запускаем полную установку автоматически, без участия пользователя.
_autofix_sub_url() {
    [ -n "$DEFAULT_SUB_URL" ] || return 0
    local _url; _url=$(cat "$XRAY_SUB_FILE" 2>/dev/null | tr -d '\n\r ')
    # URL корректен — ничего не делаем
    printf '%s' "$_url" | grep -q '^https\?://' && return 0
    warn "URL подписки некорректен ('$_url') — автовосстановление..."
    cmd_recover
}

# ─── Самовосстановление: tproxy активен но Xray не запущен → убрать хук ──────
# Вызывается при каждом запуске скрипта — до любых других действий.
_selfheal_tproxy() {
    _xray_is_running 2>/dev/null && return 0  # Xray жив — всё ок
    # Перезапускаем только если: autostart включён ИЛИ пользователь явно запускал в этой сессии
    # XRAY_INTENT (/var/run/xray-running) — tmpfs, очищается при перезагрузке.
    # Это предотвращает автостарт Xray при перезагрузке когда autostart выключен.
    if autostart_enabled 2>/dev/null || [ -f "$XRAY_INTENT" ]; then
        if [ -f "$XRAY_CONFIG" ]; then
            warn "Авторемонт: Xray не запущен — перезапускаю..."
            _fast_restart 2>/dev/null && {
                logger -t xray-heal "Xray перезапущен автоматически"
                return 0
            }
        fi
    fi
    # Не должен быть запущен или не удалось — если tproxy активен, снимаем
    iptables_active 2>/dev/null || return 0
    warn "Авторемонт: tproxy активен, Xray не запущен — снимаю перехват трафика"
    _tg_send "⚠️ Xray не запущен — tproxy снят, интернет работает напрямую. Запусти /restart"
    _tproxy_detach 2>/dev/null || true
}

# ─── Точка входа ──────────────────────────────────────────────────────────────
main() {
    _selfheal_tproxy   # если tproxy завис без Xray — чиним сразу
    _autofix_sub_url   # если URL подписки некорректен — восстанавливаем и устанавливаем
    local arg="${1:-${XRAY_SUB_URL:-}}"
    case "$arg" in
        test)           cmd_test ;;
        update)         update_subscription "" ;;
        geodata)        update_geodata && _fast_restart 2>/dev/null || true ;;
        u|U|self-update) cmd_self_update ;;
        script-check)   cmd_script_check ;;
        _updater_daemon) _updater_daemon ;;
        _tunnel_daemon)  _tunnel_daemon ;;
        _tg_bot_daemon)  _tg_bot_daemon ;;
        healthcheck)    _selfheal_tproxy; _start_updater; _start_tg_bot; _start_tunnel_if_configured ;;
        autostart-on)   install_init_script && info "Автозапуск включён" ;;
        autostart-off)  remove_init_script  && info "Автозапуск выключен" ;;
        cron-on)        install_cron 6      && info "Автообновление включено" ;;
        cron-off)       remove_cron         && info "Автообновление выключено" ;;
        tproxy-on)      setup_iptables      && info "Прозрачный прокси включён" ;;
        tproxy-off)     remove_iptables     && info "Прозрачный прокси выключен" ;;
        tunnel-on)      _start_tunnel ;;
        tunnel-off)     _stop_tunnel ;;
        "")          menu ;;
        *)
            mkdir -p /etc/xray
            printf '%s\n' "$arg" > "$XRAY_SUB_FILE"
            apply_subscription "$arg"
            ;;
    esac
}

main "$@"
