#!/bin/sh
# setup.sh — sing-box TPROXY туннель для OpenWrt
# Один коннектор: весь трафик → VPS, VPS решает маршрутизацию
# Использование: sh setup.sh <vless://...>  ИЛИ  sh setup.sh <https://.../sub/...>

SCRIPT_VERSION="20260651"
SCRIPT_URL="https://raw.githubusercontent.com/Alex12571333/xray-openwrt/main/xray-setup.sh"
SCRIPT_VERSION_URL="https://raw.githubusercontent.com/Alex12571333/xray-openwrt/main/version"

# sing-box 1.13+ собираются ДИНАМИЧЕСКИ (glibc) и не запускаются на OpenWrt (musl).
# Поэтому пинимся на последнюю СТАТИЧЕСКУЮ ветку 1.12.x.
SINGBOX_VERSION="1.12.8"

SINGBOX_BIN="/usr/bin/sing-box"
SINGBOX_CONFIG="/etc/sing-box/config.json"
SINGBOX_PID="/var/run/sing-box.pid"
SINGBOX_VLESS_FILE="/etc/sing-box/vless_url"
SINGBOX_SUB_FILE="/etc/sing-box/sub_url"          # URL подписки (если задан — источник истины)
SINGBOX_LOG="/var/log/sing-box.log"
SINGBOX_SELF="/etc/sing-box/setup.sh"
SINGBOX_CRON="/etc/crontabs/root"
CRON_MARKER="# sing-box-tunnel"
IPTABLES_CHAIN="SBOX_TP"

# ─── Утилиты ────────────────────────────────────────────────────────────────

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[sing-box] $*"; }
warn() { echo "[sing-box] WARN: $*" >&2; }

_is_running() {
    [ -f "$SINGBOX_PID" ] || return 1
    local pid; pid=$(cat "$SINGBOX_PID" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# ─── Архитектура ────────────────────────────────────────────────────────────

detect_arch() {
    case $(uname -m) in
        aarch64)        echo "linux-arm64" ;;
        armv7l)         echo "linux-armv7" ;;
        armv6l)         echo "linux-armv6" ;;
        x86_64)         echo "linux-amd64" ;;
        i686|i386)      echo "linux-386" ;;
        mipsel|mipsle)  echo "linux-mipsle-softfloat" ;;
        mips)           echo "linux-mips-softfloat" ;;
        *) die "Unsupported arch: $(uname -m)" ;;
    esac
}

# ─── Установка sing-box ──────────────────────────────────────────────────────

# Скачивание с поддержкой редиректа GitHub (busybox wget давится → пробуем curl)
_download() {
    # $1 = url, $2 = выходной файл
    if command -v curl >/dev/null 2>&1; then
        curl -Lk --max-time 180 -o "$2" "$1"
    elif command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch --no-check-certificate -O "$2" "$1"
    else
        wget --no-check-certificate -O "$2" "$1"
    fi
}

install_singbox() {
    # бинарник есть И реально запускается?
    if [ -x "$SINGBOX_BIN" ] && "$SINGBOX_BIN" version >/dev/null 2>&1; then
        info "sing-box уже установлен: $("$SINGBOX_BIN" version 2>/dev/null | head -1)"
        return 0
    fi
    info "Устанавливаю sing-box ${SINGBOX_VERSION} (статическая сборка)..."
    local arch archive url tmpdir bin
    arch=$(detect_arch)
    archive="sing-box-${SINGBOX_VERSION}-${arch}.tar.gz"
    url="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/${archive}"
    tmpdir=$(mktemp -d /tmp/singbox-XXXXXX)
    trap 'rm -rf "$tmpdir"' EXIT INT TERM

    info "Скачиваю ${archive}..."
    _download "$url" "$tmpdir/sb.tar.gz" || die "Ошибка скачивания sing-box"
    [ -s "$tmpdir/sb.tar.gz" ] || die "Архив пустой (проверь интернет на роутере)"

    tar -xzf "$tmpdir/sb.tar.gz" -C "$tmpdir/" || die "Ошибка распаковки архива"

    bin=$(find "$tmpdir" -name "sing-box" -type f | head -1)
    [ -n "$bin" ] || die "Бинарник sing-box не найден в архиве"

    mv "$bin" "$SINGBOX_BIN"
    chmod +x "$SINGBOX_BIN"
    # проверка совместимости (musl/динамический линкер)
    "$SINGBOX_BIN" version >/dev/null 2>&1 \
        || die "sing-box установлен, но не запускается (несовместимый бинарник)"
    info "sing-box установлен: $("$SINGBOX_BIN" version 2>/dev/null | head -1)"
}

# ─── Парсинг VLESS URL ───────────────────────────────────────────────────────

urldecode() {
    printf '%s' "$1" | sed \
        -e 's/%2[Ff]/\//g' \
        -e 's/%2[Cc]/,/g'  \
        -e 's/%3[Dd]/=/g'  \
        -e 's/%20/ /g'     \
        -e 's/%2[Bb]/+/g'  \
        -e 's/%25/%/g'
}

parse_vless() {
    local url="$1"
    local rest="${url#vless://}"
    SV_UUID="${rest%%@*}"
    local after_at="${rest#*@}"
    local hostport="${after_at%%\?*}"
    hostport="${hostport%/}"            # убираем хвостовой слэш (3x-ui даёт host:443/?...)
    SV_HOST="${hostport%:*}"
    SV_PORT="${hostport##*:}"
    SV_PORT="${SV_PORT%/}"              # на всякий случай
    local query="${after_at#*\?}"
    query="${query%%#*}"

    SV_TYPE=$(printf '%s' "$query"    | grep -o 'type=[^&]*'     | sed 's/type=//')
    SV_SEC=$(printf '%s' "$query"     | grep -o 'security=[^&]*' | sed 's/security=//')
    SV_PATH=$(urldecode "$(printf '%s' "$query" | grep -o 'path=[^&]*' | sed 's/path=//')")
    SV_SNI=$(printf '%s' "$query"     | grep -o 'sni=[^&]*'      | sed 's/sni=//')
    SV_ALPN=$(urldecode "$(printf '%s' "$query" | grep -o 'alpn=[^&]*' | sed 's/alpn=//')")
    SV_HOST_HDR=$(printf '%s' "$query"| grep -o 'host=[^&]*'     | sed 's/host=//')
    SV_FP=$(printf '%s' "$query"      | grep -o 'fp=[^&]*'       | sed 's/fp=//')
    SV_PBK=$(printf '%s' "$query"     | grep -o 'pbk=[^&]*'      | sed 's/pbk=//')
    SV_SID=$(printf '%s' "$query"     | grep -o 'sid=[^&]*'      | sed 's/sid=//')
    SV_FLOW=$(printf '%s' "$query"    | grep -o 'flow=[^&]*'     | sed 's/flow=//')

    SV_TYPE="${SV_TYPE:-tcp}"
    SV_SEC="${SV_SEC:-none}"
    SV_FP="${SV_FP:-chrome}"
}

# Печатает один sing-box vless outbound одной строкой, используя текущие SV_*
# (перед вызовом нужно выполнить parse_vless). $1 = tag
_emit_vless_outbound() {
    local tag="$1" tls="" tr="" flow=""
    case "$SV_SEC" in
        reality)
            tls="\"tls\":{\"enabled\":true,\"server_name\":\"${SV_SNI}\",\"utls\":{\"enabled\":true,\"fingerprint\":\"${SV_FP}\"},\"reality\":{\"enabled\":true,\"public_key\":\"${SV_PBK}\",\"short_id\":\"${SV_SID}\"}}," ;;
        tls)
            tls="\"tls\":{\"enabled\":true,\"server_name\":\"${SV_SNI}\",\"utls\":{\"enabled\":true,\"fingerprint\":\"${SV_FP}\"}}," ;;
    esac
    case "$SV_TYPE" in
        ws)   tr="\"transport\":{\"type\":\"ws\",\"path\":\"${SV_PATH}\",\"headers\":{\"Host\":\"${SV_HOST_HDR:-$SV_SNI}\"}}," ;;
        grpc) tr="\"transport\":{\"type\":\"grpc\",\"service_name\":\"${SV_PATH}\"}," ;;
    esac
    [ -n "$SV_FLOW" ] && flow="\"flow\":\"${SV_FLOW}\","
    printf '{"type":"vless","tag":"%s","server":"%s","server_port":%s,"uuid":"%s",%s%s%s"packet_encoding":"xudp"}' \
        "$tag" "$SV_HOST" "$SV_PORT" "$SV_UUID" "$flow" "$tls" "$tr"
}

# ─── Источник: vless:// напрямую или подписка http(s):// ─────────────────────
# Принимает $1 = vless://... ИЛИ http(s)://.../sub/...
# Результат — первая vless-ссылка в переменную RESOLVED_VLESS.
resolve_input() {
    RESOLVED_VLESS=""
    case "$1" in
        vless://*)
            RESOLVED_VLESS="$1"
            ;;
        http://*|https://*)
            info "Загружаю подписку..."
            local raw decoded tmpf
            tmpf=$(mktemp 2>/dev/null || echo "/tmp/sb_sub.$$")
            _download "$1" "$tmpf" >/dev/null 2>&1
            raw=$(cat "$tmpf" 2>/dev/null); rm -f "$tmpf"
            [ -n "$raw" ] || die "Подписка пустая или недоступна: $1"
            # подписка обычно в base64; если декодировалось в vless — берём, иначе как есть
            decoded=$(printf '%s' "$raw" | base64 -d 2>/dev/null)
            printf '%s' "$decoded" | grep -q 'vless://' || decoded="$raw"
            RESOLVED_VLESS=$(printf '%s\n' "$decoded" | tr -d '\r' | grep -o 'vless://[^[:space:]]*' | head -1)
            [ -n "$RESOLVED_VLESS" ] || die "В подписке не найдено vless://"
            ;;
        *)
            die "Нужен vless:// или http(s):// (подписка)"
            ;;
    esac
}

# Загружает источник (подписку из sub_url, иначе vless_url), парсит в SV_*.
# Возвращает 0 если получилось, 1 если источника нет.
load_source() {
    SV_HOST=""
    if [ -f "$SINGBOX_SUB_FILE" ]; then
        resolve_input "$(cat "$SINGBOX_SUB_FILE")"
        printf '%s\n' "$RESOLVED_VLESS" > "$SINGBOX_VLESS_FILE"   # кэш на случай офлайна
        parse_vless "$RESOLVED_VLESS"
        return 0
    elif [ -f "$SINGBOX_VLESS_FILE" ]; then
        parse_vless "$(cat "$SINGBOX_VLESS_FILE")"
        return 0
    fi
    return 1
}

# ─── Генерация конфига ───────────────────────────────────────────────────────
# Один коннектор: всё кроме приватных IP → VPS ("proxy"). VPS решает остальное.

gen_config() {
    info "Генерирую конфиг..."
    mkdir -p /etc/sing-box
    [ -n "$SV_HOST" ] || die "Не задан VLESS URL"

    local main_obj
    main_obj=$(_emit_vless_outbound "proxy")

    cat > "$SINGBOX_CONFIG" <<EOF
{
  "log": { "level": "warn", "output": "${SINGBOX_LOG}" },
  "inbounds": [
    { "type": "socks",  "tag": "socks-in",  "listen": "0.0.0.0", "listen_port": 1080 },
    { "type": "http",   "tag": "http-in",   "listen": "0.0.0.0", "listen_port": 1081 },
    { "type": "tproxy", "tag": "tproxy-in", "listen": "0.0.0.0", "listen_port": 12345 }
  ],
  "outbounds": [
    ${main_obj},
    { "type": "direct", "tag": "direct" },
    { "type": "block",  "tag": "block" }
  ],
  "route": {
    "rules": [
      { "ip_is_private": true, "outbound": "direct" }
    ],
    "final": "proxy"
  }
}
EOF
    info "Конфиг записан: $SINGBOX_CONFIG"
}

# ─── TPROXY iptables ─────────────────────────────────────────────────────────

setup_iptables() {
    info "Настраиваю iptables TPROXY..."

    ip rule add fwmark 0x1 table 100 2>/dev/null || true
    ip route add local 0.0.0.0/0 dev lo table 100 2>/dev/null || true

    iptables -t mangle -D PREROUTING -j "$IPTABLES_CHAIN" 2>/dev/null || true
    iptables -t mangle -F "$IPTABLES_CHAIN" 2>/dev/null || true
    iptables -t mangle -X "$IPTABLES_CHAIN" 2>/dev/null || true
    iptables -t mangle -N "$IPTABLES_CHAIN"

    iptables -t mangle -A "$IPTABLES_CHAIN" -d 0.0.0.0/8      -j RETURN
    iptables -t mangle -A "$IPTABLES_CHAIN" -d 10.0.0.0/8     -j RETURN
    iptables -t mangle -A "$IPTABLES_CHAIN" -d 127.0.0.0/8    -j RETURN
    iptables -t mangle -A "$IPTABLES_CHAIN" -d 169.254.0.0/16 -j RETURN
    iptables -t mangle -A "$IPTABLES_CHAIN" -d 172.16.0.0/12  -j RETURN
    iptables -t mangle -A "$IPTABLES_CHAIN" -d 192.168.0.0/16 -j RETURN
    iptables -t mangle -A "$IPTABLES_CHAIN" -d 224.0.0.0/4    -j RETURN
    iptables -t mangle -A "$IPTABLES_CHAIN" -d 240.0.0.0/4    -j RETURN
    iptables -t mangle -A "$IPTABLES_CHAIN" -p tcp --dport 22 -j RETURN

    iptables -t mangle -A "$IPTABLES_CHAIN" -p tcp -j TPROXY --on-port 12345 --tproxy-mark 1
    iptables -t mangle -A "$IPTABLES_CHAIN" -p udp -j TPROXY --on-port 12345 --tproxy-mark 1

    for br in br-lan br0 eth1; do
        iptables -t mangle -A PREROUTING -i "$br" -j "$IPTABLES_CHAIN" 2>/dev/null || true
    done

    info "TPROXY настроен"
}

cleanup_iptables() {
    iptables -t mangle -D PREROUTING -j "$IPTABLES_CHAIN" 2>/dev/null || true
    iptables -t mangle -F "$IPTABLES_CHAIN" 2>/dev/null || true
    iptables -t mangle -X "$IPTABLES_CHAIN" 2>/dev/null || true
    ip rule del fwmark 0x1 table 100 2>/dev/null || true
    ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null || true
    info "TPROXY правила удалены"
}

# ─── Запуск sing-box ─────────────────────────────────────────────────────────

start_singbox() {
    info "Запускаю sing-box..."
    mkdir -p /var/run /var/log

    if [ -f "$SINGBOX_PID" ]; then
        kill "$(cat "$SINGBOX_PID")" 2>/dev/null || true
        rm -f "$SINGBOX_PID"
    fi
    killall sing-box 2>/dev/null || true
    sleep 1

    "$SINGBOX_BIN" run -c "$SINGBOX_CONFIG" >> "$SINGBOX_LOG" 2>&1 &
    echo $! > "$SINGBOX_PID"
    sleep 2
    if _is_running; then
        info "sing-box запущен (PID $(cat "$SINGBOX_PID"))"
    else
        die "sing-box не запустился — проверь лог: $SINGBOX_LOG"
    fi
}

# ─── Watchdog ────────────────────────────────────────────────────────────────

install_cron() {
    grep -q "$CRON_MARKER" "$SINGBOX_CRON" 2>/dev/null && return 0
    printf '* * * * * sh %s watchdog %s\n' "$SINGBOX_SELF" "$CRON_MARKER" >> "$SINGBOX_CRON"
    /etc/init.d/cron restart 2>/dev/null || true
    info "Watchdog cron установлен"
}

remove_cron() {
    [ -f "$SINGBOX_CRON" ] || return 0
    sed -i "/sing-box-tunnel/d" "$SINGBOX_CRON" 2>/dev/null || true
    /etc/init.d/cron restart 2>/dev/null || true
    info "Watchdog cron удалён"
}

_watchdog() {
    _is_running && return 0
    logger -t singbox-watchdog "sing-box не запущен — перезапускаю"
    start_singbox
    setup_iptables
}

# ─── Self-update ─────────────────────────────────────────────────────────────

self_update() {
    local remote_ver
    remote_ver=$(wget --no-check-certificate -qO- "$SCRIPT_VERSION_URL" 2>/dev/null | tr -d ' \n')
    if [ -z "$remote_ver" ]; then
        warn "Не удалось проверить версию"; return 1
    fi
    if [ "$remote_ver" = "$SCRIPT_VERSION" ]; then
        info "Версия актуальна: $SCRIPT_VERSION"; return 0
    fi
    info "Обновляю скрипт: $SCRIPT_VERSION → $remote_ver"
    wget --no-check-certificate -qO "$SINGBOX_SELF" "$SCRIPT_URL" || die "Ошибка скачивания"
    chmod +x "$SINGBOX_SELF"
    info "Скрипт обновлён до $remote_ver"
}

# ─── Меню ────────────────────────────────────────────────────────────────────

show_menu() {
    local vps_info status_str
    if [ -f "$SINGBOX_VLESS_FILE" ]; then
        local _url; _url=$(cat "$SINGBOX_VLESS_FILE")
        vps_info=$(printf '%s' "${_url#vless://}" | sed 's/.*@//' | cut -d'?' -f1)
    else
        vps_info="не настроен"
    fi

    if _is_running; then
        status_str="работает, PID $(cat "$SINGBOX_PID")"
    else
        status_str="не запущен"
    fi

    echo ""
    echo "=============================="
    echo "  sing-box туннель v${SCRIPT_VERSION}"
    echo "=============================="
    printf "  VPS    : %s\n" "$vps_info"
    printf "  Статус : %s\n" "$status_str"
    echo "------------------------------"
    echo "  1) Запустить / перезапустить"
    echo "  2) Остановить (полностью)"
    echo "  3) Сменить VPS (новый VLESS)"
    echo "  4) Показать логи"
    echo "  5) Обновить скрипт"
    echo "  6) Выход"
    echo "=============================="
    printf "Выбор: "
    read -r choice
    echo ""
    case "$choice" in
        1)
            if load_source; then
                install_singbox
                gen_config
                start_singbox
                setup_iptables
                install_cron
            else
                echo "Сначала укажи VLESS-ссылку или подписку (пункт 3)"
            fi
            ;;
        2)
            remove_cron
            kill "$(cat "$SINGBOX_PID" 2>/dev/null)" 2>/dev/null || killall sing-box 2>/dev/null || true
            cleanup_iptables
            info "sing-box остановлен, watchdog снят, трафик идёт напрямую"
            ;;
        3)
            echo "Вставь vless:// ссылку ИЛИ http(s):// подписку:"
            printf "URL: "
            read -r new_url
            case "$new_url" in
                vless://*|http://*|https://*)
                    mkdir -p /etc/sing-box
                    case "$new_url" in
                        vless://*) rm -f "$SINGBOX_SUB_FILE"; printf '%s\n' "$new_url" > "$SINGBOX_VLESS_FILE" ;;
                        *)         printf '%s\n' "$new_url" > "$SINGBOX_SUB_FILE" ;;
                    esac
                    install_singbox
                    load_source || { echo "Не удалось получить конфиг"; return 2>/dev/null || true; }
                    gen_config
                    cp "$0" "$SINGBOX_SELF" 2>/dev/null || true
                    start_singbox
                    setup_iptables
                    install_cron
                    info "Готово! VPS: ${SV_HOST}:${SV_PORT}"
                    ;;
                *)
                    echo "Ошибка: нужен vless:// или http(s):// URL"
                    ;;
            esac
            ;;
        4)
            echo "--- Последние 30 строк лога ---"
            tail -30 "$SINGBOX_LOG" 2>/dev/null || echo "Лог пустой"
            ;;
        5)
            self_update
            ;;
        6)
            exit 0
            ;;
        *)
            echo "Неверный выбор"
            ;;
    esac
}

# ─── Main ────────────────────────────────────────────────────────────────────

case "${1:-}" in
    watchdog)
        _watchdog
        ;;
    stop)
        remove_cron
        kill "$(cat "$SINGBOX_PID" 2>/dev/null)" 2>/dev/null || killall sing-box 2>/dev/null || true
        cleanup_iptables
        info "sing-box остановлен, watchdog снят, трафик идёт напрямую"
        ;;
    restart)
        # источник истины: подписка (пере-скачиваем) или сохранённый vless
        if load_source; then gen_config; fi
        kill "$(cat "$SINGBOX_PID" 2>/dev/null)" 2>/dev/null || killall sing-box 2>/dev/null || true
        sleep 1
        start_singbox
        setup_iptables
        ;;
    self-update)
        self_update
        ;;
    status)
        if _is_running; then
            info "sing-box работает (PID $(cat "$SINGBOX_PID"))"
            [ -f "$SINGBOX_VLESS_FILE" ] && \
                info "VPS: $(cat "$SINGBOX_VLESS_FILE" | sed 's/vless:\/\///' | sed 's/.*@//' | cut -d'?' -f1)"
        else
            info "sing-box не запущен"
        fi
        ;;
    vless://*|http://*|https://*)
        mkdir -p /etc/sing-box
        case "$1" in
            vless://*) rm -f "$SINGBOX_SUB_FILE"; printf '%s\n' "$1" > "$SINGBOX_VLESS_FILE" ;;
            *)         printf '%s\n' "$1" > "$SINGBOX_SUB_FILE" ;;   # подписка
        esac
        install_singbox
        load_source || die "Не удалось получить конфиг из источника"
        gen_config
        cp "$0" "$SINGBOX_SELF" 2>/dev/null || true
        start_singbox
        setup_iptables
        install_cron
        info "Готово! VPS: ${SV_HOST}:${SV_PORT}"
        ;;
    *)
        show_menu
        ;;
esac
